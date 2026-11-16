"""External, verified model locations shared by the download and inference workers."""
from pathlib import Path, PurePosixPath
import hashlib
import json
import os
from urllib.parse import urlsplit

MODEL_IDS = frozenset(("speech", "cleanup", "chat"))


def model_root():
    override = os.environ.get("R2M_MODEL_DIR")
    return Path(override).expanduser() if override else Path.home() / "Library/Application Support/R2M/Models"


def manifest_path():
    override = os.environ.get("R2M_MODELS_MANIFEST")
    if override:
        return Path(override)
    here = Path(__file__).resolve().parent
    bundled = here / "models.json"
    return bundled if bundled.is_file() else here.parent / "Resources/models.json"


def load_manifest():
    data = json.loads(manifest_path().read_text(encoding="utf-8"))
    if data.get("version") != 1 or not isinstance(data.get("models"), list):
        raise ValueError("The model download manifest is unsupported.")
    seen = set()
    for model in data["models"]:
        key = model.get("id")
        if key not in MODEL_IDS or key in seen or not model.get("revision"):
            raise ValueError("The model download manifest is invalid.")
        seen.add(key)
        paths = set()
        for item in model.get("files", []):
            name = item.get("path", "")
            parts = PurePosixPath(name)
            if not name or parts.is_absolute() or ".." in parts.parts or "\\" in name or name in paths:
                raise ValueError("The model manifest contains an invalid filename.")
            paths.add(name)
            sha = item.get("sha256", "")
            if len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha):
                raise ValueError("A model download checksum is invalid.")
            if not isinstance(item.get("size"), int) or item["size"] < 0:
                raise ValueError("A model download size is invalid.")
            parsed = urlsplit(item.get("url", ""))
            local_test = bool(os.environ.get("R2M_MODELS_MANIFEST")) and parsed.hostname in {"localhost", "127.0.0.1", "::1"}
            if parsed.scheme != "https" and not (local_test and parsed.scheme == "http"):
                raise ValueError("Model downloads require HTTPS.")
            if parsed.username is not None or parsed.password is not None or not parsed.hostname:
                raise ValueError("The model manifest contains an invalid download URL.")
        if not paths or model.get("bytes") != sum(f["size"] for f in model["files"]):
            raise ValueError("The model download manifest has inconsistent file sizes.")
    return data


def installed_marker(model, version=1):
    return {"manifest_version": version, "id": model["id"], "revision": model["revision"],
            "files": [{"path": f["path"], "size": f["size"], "sha256": f["sha256"]} for f in model["files"]]}


def is_installed(model, root=None, version=1):
    directory = (root or model_root()) / model["id"]
    try:
        saved = json.loads((directory / ".installed.json").read_text(encoding="utf-8"))
        if saved != installed_marker(model, version):
            return False
        return all((directory / f["path"]).is_file() and (directory / f["path"]).stat().st_size == f["size"]
                   for f in model["files"])
    except (OSError, ValueError, TypeError):
        return False


def status(manifest=None):
    manifest = manifest or load_manifest()
    root = model_root()
    return {m["id"]: {"installed": is_installed(m, root, manifest["version"]),
                      "path": str(root / m["id"]), "bytes": m["bytes"]}
            for m in manifest["models"]}


def optional_model_dir(key):
    if key not in MODEL_IDS:
        raise ValueError("Unknown local model.")
    manifest = load_manifest()
    for model in manifest["models"]:
        if model["id"] == key and is_installed(model, version=manifest["version"]):
            return model_root() / key
    return None


def model_dir(key):
    directory = optional_model_dir(key)
    if directory is None:
        labels = {"speech": "Speech", "cleanup": "Enhanced PDF cleanup", "chat": "Paper chat"}
        raise ValueError(f"Download {labels.get(key, key)} in R2M's Models window first.")
    return directory
