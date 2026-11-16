#!/usr/bin/env python3
"""Reader-owned offline narration adapter around versioned R2M components.

Inputs/outputs are ordinary files inside a caller-owned staged library job.
No source PDF, saved article, library database, R2M source or R2M data is changed.
Only the copied local neural models are loaded. Network is explicitly disabled.
"""
from pathlib import Path
import argparse
from contextlib import redirect_stdout
import hashlib
import json
import math
import os
import signal
import sys
import time
import traceback

OUTPUT = sys.stdout
LAST_FRACTION = 0.0
os.environ.update(HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1",
                  TRANSFORMERS_OFFLINE="1", HF_DATASETS_OFFLINE="1",
                  PYTORCH_ENABLE_MPS_FALLBACK="1", TOKENIZERS_PARALLELISM="false")
BACKEND = Path(__file__).resolve().parent / "R2MBackend"
sys.path.insert(0, str(BACKEND))

class Cancelled(BaseException):
    pass

def publish(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(path)

def emit(stage, fraction, message, **extra):
    global LAST_FRACTION
    LAST_FRACTION = max(LAST_FRACTION, max(0.0, min(1.0, float(fraction))))
    payload = {"stage": stage, "fraction": LAST_FRACTION, "message": message, **extra}
    OUTPUT.write(json.dumps(payload, ensure_ascii=False) + "\n")
    OUTPUT.flush()
    return payload

def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()

def render_plan(plan, cleanup=True, skip_references=True):
    """Mirror R2M's immutable UTF-16 anchored, reversible ReadingPlan renderer."""
    units = plan.get("units", [])
    def enabled(group):
        return skip_references if group == "references" else cleanup
    def rank(index):
        return units[index].get("order", index * 10) if cleanup else index * 10
    output = ""
    previous = -1
    for index in sorted(range(len(units)), key=rank):
        unit = units[index]
        if unit.get("reason") and enabled(unit.get("group", "cleanup")):
            continue
        raw = unit.get("raw", "").encode("utf-16-le")
        boundary = len(raw) // 2
        for edit in sorted(unit.get("edits", []), key=lambda e: e.get("at", -1), reverse=True):
            if not enabled(edit.get("group", "cleanup")):
                continue
            at, length = edit.get("at", -1), edit.get("length", 0)
            if not isinstance(at, int) or not isinstance(length, int) or at < 0 or length <= 0 or at > boundary or length > boundary - at:
                continue
            raw = raw[:at * 2] + edit.get("replacement", "").encode("utf-16-le") + raw[(at + length) * 2:]
            boundary = at
        value = raw.decode("utf-16-le").strip()
        if not value:
            continue
        if output:
            output += " " if cleanup and unit.get("joinFrom") == previous else "\n\n"
        if cleanup and unit.get("label"):
            output += unit["label"] + "\n\n"
        output += value
        previous = index
    return output

def change_list(plan):
    changes = []
    for index, unit in enumerate(plan.get("units", [])):
        if unit.get("reason"):
            changes.append({"id": f"{index}:block", "reason": unit["reason"], "group": unit.get("group", "cleanup"), "text": unit.get("raw", "")})
        for number, edit in enumerate(unit.get("edits", [])):
            changes.append({"id": f"{index}:edit:{number}", "reason": edit.get("reason", "Text formatting"), "group": edit.get("group", "cleanup")})
        if unit.get("joinFrom") is not None:
            changes.append({"id": f"{index}:join", "reason": "Join a split paragraph", "group": "cleanup"})
    return changes

def cleanup_encoder():
    module = sys.modules.get("loudness")
    process = getattr(module, "ACTIVE", None)
    if process is not None and process.poll() is None:
        process.kill()
        try:
            process.wait(timeout=5)
        except Exception:
            pass

def cancel(signum, frame):
    cleanup_encoder()
    raise Cancelled("Narration cancelled. Existing saved audio is unchanged.")

def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--job", required=True)
    parser.add_argument("--text", required=True)
    parser.add_argument("--title", default="Untitled reading")
    parser.add_argument("--voice", default="af_heart")
    parser.add_argument("--speed", type=float, default=1.0)
    parser.add_argument("--models", required=True)
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--pdf", help="Optional managed original PDF for R2M's layout-aware extraction")
    parser.add_argument("--keep-references", action="store_true")
    parser.add_argument("--no-cleanup", action="store_true")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--item-id", default="")
    return parser.parse_args()

def run(args):
    job = Path(args.job).expanduser().resolve()
    text_file = Path(args.text).expanduser().resolve()
    models = Path(args.models).expanduser().resolve()
    ffmpeg = Path(args.ffmpeg).expanduser().resolve()
    pdf = Path(args.pdf).expanduser().resolve() if args.pdf else None
    job.mkdir(parents=True, exist_ok=True)
    if (job / "audio.mp3").exists() or (job / "result.json").exists():
        raise ValueError("This narration job already has a result. Retry in a new job folder to preserve saved audio.")
    if not text_file.is_file():
        raise ValueError("The saved reading text is missing. Reopen the document and retry.")
    if not math.isfinite(args.speed) or not 0.6 <= args.speed <= 1.5:
        raise ValueError("Choose a speaking speed between 0.6 and 1.5.")
    os.environ["R2M_MODEL_DIR"] = str(models)
    os.environ["R2M_MODELS_MANIFEST"] = str(BACKEND / "models.json")
    import model_paths
    if not args.no_cleanup:
        model_paths.model_dir("cleanup")
    if not args.prepare_only:
        model_paths.model_dir("speech")
    import reader
    import loudness
    if args.voice not in reader.VOICES:
        raise ValueError("Choose Heart, Bella, Michael, Emma or George.")
    if not args.prepare_only and (not ffmpeg.is_file() or not os.access(ffmpeg, os.X_OK)):
        raise ValueError("Reader's local MP3 encoder is unavailable. Run scripts/setup-narration.sh and rebuild the app.")
    loudness.FFMPEG = ffmpeg
    def preparation(message, fraction=None):
        update = emit("preparing", 0.04 if fraction is None else 0.03 + 0.16 * fraction, message)
        publish(job / "progress.json", update)
    original_text = text_file.read_text(encoding="utf-8")
    if not original_text.strip() and pdf is None:
        raise ValueError("This document has no readable text. A scanned PDF needs a text layer before it can be narrated.")
    preparation("Preparing a separate listening copy…")
    extraction_note = None
    if pdf is not None:
        if not pdf.is_file():
            raise ValueError("The managed original PDF is missing.")
        extraction = reader.read_pdf(pdf, args.title, preparation)
        plan = extraction.get("plan")
        original_text = extraction["text"]
        extraction_note = extraction.get("note")
        if plan is None:
            raise ValueError(extraction.get("warning") or "The PDF listening copy could not be prepared. Retry the narration.")
    else:
        plan = reader.prepare({"text": original_text, "title": args.title}, preparation)
    script = render_plan(plan, cleanup=not args.no_cleanup, skip_references=not args.keep_references)
    if not script.strip():
        raise ValueError("The listening copy is empty. Turn off cleanup or keep references and retry.")
    # Keep the extracted copy, reversible plan and final script alongside audio.
    (job / "extracted.txt").write_text(original_text, encoding="utf-8")
    (job / "script.txt").write_text(script, encoding="utf-8")
    publish(job / "plan.json", plan)
    changes = change_list(plan)
    metadata = {"formatVersion": 1, "itemID": args.item_id, "title": args.title,
                "engine": "Kokoro-82M", "voice": args.voice, "speed": args.speed,
                "cleanupEngine": "R2M reversible rules + DeBERTa-v3-large zero-shot",
                "cleanupEnabled": not args.no_cleanup, "skipReferences": not args.keep_references,
                "classifierCount": plan.get("classifierCount", 0), "changes": changes,
                "sourceTextSHA256": digest(text_file), "scriptSHA256": digest(job / "script.txt"),
                "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "modelRevisions": {model["id"]: model["revision"] for model in model_paths.load_manifest()["models"] if model["id"] in ("speech", "cleanup")}}
    if pdf is not None:
        metadata["sourcePDFSHA256"] = digest(pdf)
        metadata["extractionNote"] = extraction_note
    if args.prepare_only:
        publish(job / "metadata.json", metadata)
        result = {"script": "script.txt", "plan": "plan.json", "metadata": "metadata.json", "classifierCount": metadata["classifierCount"]}
    else:
        def voicing(message, fraction=None):
            update = emit("voicing", 0.21 + 0.62 * (fraction or 0.0), message)
            publish(job / "progress.json", update)
        reader.speak({"text": script, "voice": args.voice, "speed": args.speed}, job, voicing)
        def encoding(message, fraction=None):
            update = emit("encoding", 0.85 + 0.13 * (fraction or 0.0), message)
            publish(job / "progress.json", update)
        reader.export_mp3({"source": str(job / "speech.wav")}, job, encoding)
        (job / "speech.mp3").replace(job / "audio.mp3")
        import soundfile
        info = soundfile.info(job / "speech.wav")
        metadata.update(duration=info.duration, mp3Bitrate=192000, mp3SampleRate=32000)
        publish(job / "metadata.json", metadata)
        # The finished MP3 is authoritative; playback WAV is a disposable intermediate.
        (job / "speech.wav").unlink(missing_ok=True)
        result = {"script": "script.txt", "plan": "plan.json", "audio": "audio.mp3", "metadata": "metadata.json", "duration": info.duration}
    publish(job / "result.json", result)
    emit("complete", 1.0, "Listening copy prepared" if args.prepare_only else "Narration saved", result=result)

def main():
    args = arguments()
    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    try:
        # Third-party diagnostic prints must never corrupt the JSON-lines protocol.
        with redirect_stdout(sys.stderr):
            run(args)
    except (Cancelled, KeyboardInterrupt) as error:
        emit("cancelled", 0, str(error) or "Narration cancelled.")
        return 130
    except SystemExit as error:
        # R2M's FFmpeg wrapper owns SIGTERM while an encoder is running.
        if isinstance(error.code, int) and error.code >= 128:
            emit("cancelled", 0, "Narration cancelled. Existing saved audio is unchanged.")
            return 130
        raise
    except Exception as error:
        message = str(error) or "Reader could not generate this narration."
        message = message.replace("in R2M's Models window first.", "using Reader's local narration setup first.")
        emit("error", 0, message, error=True)
        traceback.print_exc(file=sys.stderr)
        return 1
    finally:
        cleanup_encoder()
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
