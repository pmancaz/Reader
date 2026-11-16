"""File-based jobs for the native Kokoro app. All inference and parsing run here."""
from pathlib import Path
import json
import os
import re
import sys
import traceback
import unicodedata
from urllib.parse import urlsplit, unquote

RESOURCES = Path(__file__).resolve().parent
sys.path.insert(0, str(RESOURCES))
VOICES = ("af_heart", "af_bella", "am_michael", "bf_emma", "bm_george")
os.environ.update(HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1",
                  PYTORCH_ENABLE_MPS_FALLBACK="1", TOKENIZERS_PARALLELISM="false")


def publish(path, payload):
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    temp.replace(path)


def _layout_preserves_page_text(page, paragraphs):
    """Detect silent omissions without depending on a layout engine's reading order.

    Native PDF text spans are the preservation baseline. Layout output may join
    lines and move columns, but every native span must still occur on this page.
    NFKC accounts for PDF ligatures while punctuation/whitespace changes are safe.
    """
    def normalized(value):
        return "".join(c for c in unicodedata.normalize("NFKC", value).casefold() if c.isalnum())
    actual = normalized("\n\n".join(paragraphs))
    if not actual:
        return False
    native = page.get_text("dict")
    for block in native.get("blocks", []):
        if block.get("type") != 0:
            continue
        for line in block.get("lines", []):
            for span in line.get("spans", []):
                expected = normalized(span.get("text", ""))
                if expected and expected not in actual:
                    return False
    return True


def read_pdf(source, label, progress):
    import pymupdf
    try:
        doc = pymupdf.open(stream=source, filetype="pdf") if isinstance(source, bytes) else pymupdf.open(source)
    except Exception as exc:
        raise ValueError("This PDF could not be opened. Try opening it in Preview first.") from exc
    with doc:
        if doc.needs_pass:
            raise ValueError("This PDF is locked. Import an unlocked copy.")
        title = (doc.metadata.get("title") or label).strip() or label
        paragraphs, roles, missing, fallback_pages = [], [], [], []
        from xml.etree import ElementTree
        for number, page in enumerate(doc):
            progress(f"Reading page {number + 1} of {len(doc)}…")
            if not page.get_text("words"):
                missing.append(str(number + 1))
                continue
            native_text = page.get_text("text", sort=True)
            prior = len(paragraphs)
            page_paragraphs, page_roles = [], []
            original_rotation = page.rotation
            try:
                # PyMuPDF 2.0's layout extractor can return empty text for a
                # page with /Rotate 90 even though its native text is complete.
                # Normalize only this unsaved in-memory parsing document.
                if original_rotation:
                    page.set_rotation(0)
                chunk = doc.to_text(pages=[number], header=True, footer=True, use_ocr=False,
                                    page_chunks=True, table_format="plain")[0]
                for box in chunk["page_boxes"]:
                    start, end = box["pos"]
                    value = chunk["text"][start:end]
                    if box["class"] == "formula" and not value.strip():
                        value = page.get_text("text", clip=pymupdf.Rect(box["bbox"]), sort=True)
                    value = re.sub(r"(?m)^-{3,} (?:Start|End) of picture text -{3,}\s*$", "", value)
                    for paragraph in re.split(r"\n\s*\n", value):
                        if paragraph.strip():
                            page_paragraphs.append(paragraph.strip())
                            page_roles.append(box["class"])
                if not _layout_preserves_page_text(page, page_paragraphs):
                    page_paragraphs = []
            except Exception:
                # The layout pass is an enhancement, never permission to lose
                # the native text that has already been extracted successfully.
                page_paragraphs = []
            finally:
                if page.rotation != original_rotation:
                    page.set_rotation(original_rotation)
            if not page_paragraphs:
                progress(f"Preserving all text on page {number + 1} with native extraction…")
                page_paragraphs = [p.strip() for p in re.split(r"\n\s*\n", native_text) if p.strip()]
                page_roles = ["text"] * len(page_paragraphs)
                fallback_pages.append(str(number + 1))
            paragraphs.extend(page_paragraphs)
            roles.extend(page_roles)
            if len(paragraphs) == prior:
                missing.append(str(number + 1))
        if not paragraphs:
            raise ValueError("No readable text was found. For a scanned PDF, run text recognition (OCR) and import the searchable copy.")
        note = f"{len(doc)} page" + ("s" if len(doc) != 1 else "")
        if missing:
            note += " · No readable text on page" + ("s " if len(missing) > 1 else " ") + ", ".join(missing)
        if fallback_pages:
            note += " · Native text fallback on page" + ("s " if len(fallback_pages) > 1 else " ") + ", ".join(fallback_pages)
        # Preserve publication metadata verbatim when the publisher embedded a venue.
        venue = ""
        try:
            metadata = ElementTree.fromstring(doc.get_xml_metadata() or "<metadata/>")
            venue = next((el.text.strip() for el in metadata.iter()
                          if el.tag.endswith("}publicationName") and el.text and el.text.strip()), "")
        except ElementTree.ParseError:
            pass
        if venue and len(venue)<200 and not any(venue.casefold() in s.casefold() for s in paragraphs[:24]):
            pos = next((i for i,s in enumerate(paragraphs[:24]) if re.match(r"(?i)^abstract\b",s)), None)
            if pos is not None:
                paragraphs.insert(pos,venue)
                roles.insert(pos,"venue")
        result = dict(title=title, text="\n\n".join(paragraphs), note=note, pdf=True, roles=roles)
        try:
            result["plan"] = prepare(result, progress)
        except Exception:
            traceback.print_exc()
            result["warning"] = "The PDF was imported, but its listening copy could not be prepared. Use Prepare listening text to retry."

        return result


def read_link(value, progress):
    import requests
    import trafilatura
    url = value.strip()
    if "://" not in url:
        url = "https://" + url
    try:
        parts = urlsplit(url)
        valid = parts.scheme in {"http", "https"} and parts.hostname and parts.username is None and parts.password is None
        _ = parts.port
    except ValueError:
        valid = False
    if not valid:
        raise ValueError("Enter an http or https link to an article.")
    progress("Opening the link…")
    try:
        with website_session() as session, session.get(url, timeout=(8, 22), stream=True,
                headers={"User-Agent": "Mozilla/5.0 (Macintosh) R2M/1.0"}) as response:
            response.raise_for_status()
            content = bytearray()
            for chunk in response.iter_content(65536):
                content.extend(chunk)
                if len(content) > 40 * 1024**2:
                    raise ValueError("This download exceeds 40 MB. For a PDF, save it and use Import PDF.")
            from email.message import Message
            content_type = Message()
            content_type["Content-Type"] = response.headers.get("Content-Type", "")
            mime = response.headers.get("Content-Type", "").split(";")[0].lower().strip()
            charset = content_type.get_content_charset() or "utf-8-sig"
            final = response.url
    except requests.exceptions.SSLError as exc:
        raise ValueError("Could not verify the website's secure connection. If you use a workplace network or VPN, ask IT to check its trusted certificates, or try another network.") from exc
    except requests.RequestException as exc:
        code = getattr(getattr(exc, "response", None), "status_code", None)
        if code in {401, 403, 429}:
            raise ValueError("This site restricted access. You can paste text from your browser.") from exc
        detail = f" (HTTP {code})" if code else ""
        raise ValueError(f"Could not load the website{detail}. Check the link and your connection.") from exc
    data = bytes(content)
    if b"%PDF-" in data[:1024] or mime == "application/pdf":
        return read_pdf(data, Path(unquote(urlsplit(final).path)).stem or "Linked PDF", progress)
    if mime and mime not in {"text/html", "application/xhtml+xml", "text/plain"}:
        raise ValueError("This link did not return an article or PDF.")
    progress("Extracting the article…")
    if mime == "text/plain":
        try:
            body = data.decode(charset).strip()
        except (LookupError, UnicodeError) as exc:
            raise ValueError("This page's text encoding could not be read. Try copying the text from your browser.") from exc
        title = None
    else:
        article = trafilatura.bare_extraction(data, url=final, with_metadata=True, favor_recall=True, include_comments=False, include_tables=False)
        body = (article.text or "").strip() if article else ""
        title = article.title if article else None
    if not body:
        raise ValueError("No article text was found. Pages that need a login or JavaScript may need to be pasted from your browser.")
    return dict(text=body, title=title or urlsplit(final).hostname, note=urlsplit(final).hostname)


def website_session():
    """Use the same native certificate checks as model setup, without global patches."""
    import requests
    if sys.platform != "darwin":
        return requests.Session()
    from asset_manager import verified_tls_context
    context = verified_tls_context()

    class NativeHTTPSAdapter(requests.adapters.HTTPAdapter):
        def init_poolmanager(self, *args, **kwargs):
            kwargs["ssl_context"] = context
            return super().init_poolmanager(*args, **kwargs)

        def proxy_manager_for(self, proxy, **kwargs):
            kwargs["ssl_context"] = context
            if proxy.lower().startswith("https://"):
                kwargs["proxy_ssl_context"] = context
            return super().proxy_manager_for(proxy, **kwargs)

        def build_connection_pool_key_attributes(self, request, verify, cert=None):
            host, pool = super().build_connection_pool_key_attributes(request, verify, cert)
            pool["ssl_context"] = context
            pool["cert_reqs"] = "CERT_REQUIRED"
            pool.pop("ca_certs", None)
            pool.pop("ca_cert_dir", None)
            return host, pool

        def cert_verify(self, conn, url, verify, cert):
            # Requests otherwise adds certifi anchors, bypassing macOS distrust
            # settings and still missing certificates managed in Keychain.
            conn.cert_reqs = "CERT_REQUIRED"
            conn.ca_certs = None
            conn.ca_cert_dir = None
            if cert:
                certificate, key = cert if isinstance(cert, tuple) else (cert, None)
                context.load_cert_chain(certificate, key)

    session = requests.Session()
    session.mount("https://", NativeHTTPSAdapter())
    return session


def speak(data, folder, progress):
    from model_paths import model_dir as installed_model_dir
    model_dir = installed_model_dir("speech")
    import torch
    import soundfile as sf
    import espeakng_loader
    # eSpeak has a short native path buffer. Use a relative data path even if
    # the app was moved into a deeply nested folder.
    os.chdir(espeakng_loader.get_data_path())
    os.environ["ESPEAK_DATA_PATH"] = "."
    from kokoro import KPipeline, KModel
    voice = data["voice"]
    if voice not in VOICES:
        raise ValueError("Select one of the installed voices.")
    torch.set_num_threads(4)
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    model = KModel(repo_id="hexgrad/Kokoro-82M", config=model_dir / "config.json",
                   model=model_dir / "kokoro-v1_0.pth").to(device).eval()
    pipeline = KPipeline(lang_code=voice[0], model=model, repo_id="hexgrad/Kokoro-82M")
    paragraphs = [s.strip() for s in data["text"].splitlines() if s.strip()]
    voicepack = torch.load(model_dir / "voices" / (voice + ".pt"), weights_only=True)
    with sf.SoundFile(folder / "raw-speech.wav", "w", samplerate=24000, channels=1, subtype="FLOAT") as audio:
        for n, paragraph in enumerate(paragraphs, 1):
            progress(f"Voicing paragraph {n} of {len(paragraphs)}…", 0.75 * (n - 1) / len(paragraphs))
            for _, _, samples in pipeline(paragraph, voice=voicepack, speed=data["speed"]):
                audio.write(samples.cpu().numpy())
        if not audio.tell():
            raise ValueError("No speech was produced. Try a passage with English words.")
    from loudness import normalize
    normalize(folder / "raw-speech.wav", folder / "speech.wav", progress,
              report=lambda message,f:progress(message,0.75+0.25*f))
    (folder / "raw-speech.wav").unlink()
    return dict(audio="speech.wav")


def export_mp3(data, folder, progress):
    from loudness import normalize
    normalize(Path(data["source"]), folder / "speech.mp3", progress, mp3=True,
              report=lambda message,f:progress(message,f))
    return dict(mp3="speech.mp3")


def prepare(data, progress):
    from paper import make_plan
    progress("Preparing listening text…")
    from model_paths import optional_model_dir
    return make_plan(data["text"], data.get("title",""), optional_model_dir("cleanup"), progress, data.get("roles"))


def main():
    sys.path.insert(0, str(RESOURCES))
    folder = Path(sys.argv[1]).resolve()
    def progress(message, fraction=None):
        payload = {"message": message}
        if fraction is not None:
            payload["fraction"] = fraction
        publish(folder / "progress.json", payload)
    try:
        data = json.loads((folder / "request.json").read_text())
        if data["kind"] == "pdf":
            path = Path(data["source"])
            result = read_pdf(path, path.stem, progress)
        elif data["kind"] == "link":
            result = read_link(data["source"], progress)
        elif data["kind"] == "prepare":
            result = {"plan": prepare(data, progress)}
        elif data["kind"] == "normalize":
            from loudness import normalize
            normalize(Path(data["source"]), folder / "speech.wav", progress)
            result = dict(audio="speech.wav")
        elif data["kind"] == "mp3":
            result = export_mp3(data, folder, progress)
        else:
            result = speak(data, folder, progress)
    except Exception as exc:
        traceback.print_exc()
        result = {"error": str(exc) or "This item could not be processed."}
    publish(folder / "result.json", result)


if __name__ == "__main__":
    main()
