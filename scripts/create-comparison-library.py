#!/usr/bin/env python3
"""Make an independent OpenAI comparison library while the local Reader is closed.

Copies documents, notes and progress. Keeps local audio files and their record
metadata as an archive, but leaves the experiment's Create narration action ready.
Never replaces an existing destination or changes the source library.
"""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import tempfile
import uuid


def create(source: Path, destination: Path):
    source, destination = source.resolve(), destination.absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError("The comparison destination already exists; it has been preserved.")
    if source == destination or source in destination.parents:
        raise ValueError("Choose a separate sibling folder for the comparison library.")
    with (source / ".reader.lock").open("rb") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("Close the local Reader app before copying its library.") from None
        staging = Path(tempfile.mkdtemp(prefix=".ReaderOpenAI-copy-", dir=destination.parent))
        try:
            for item in (source / "Items").rglob("*"):
                if item.is_symlink():
                    raise ValueError("A source item contains a symbolic link; no comparison copy was made.")
            shutil.copytree(source / "Items", staging / "Items")
            original = sqlite3.connect((source / "Library.sqlite").as_uri() + "?mode=ro", uri=True)
            copy = sqlite3.connect(staging / "Library.sqlite")
            try:
                original.backup(copy)
                if copy.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    raise ValueError("The copied database did not validate.")
                archived = {}
                rows = copy.execute("SELECT id,payload FROM items").fetchall()
                for item_id, payload in rows:
                    item = json.loads(payload)
                    base = staging / "Items" / item_id
                    relative = Path(item["contentPath"])
                    if relative.is_absolute() or ".." in relative.parts or not (base / relative).is_file():
                        raise ValueError("A document is incomplete; no comparison copy was made.")
                    if item.get("narration"):
                        archived[item_id] = item["narration"]
                        for key in ("relativeAudioPath", "relativeScriptPath"):
                            relative = Path(item["narration"][key])
                            if relative.is_absolute() or ".." in relative.parts or not (base / relative).is_file():
                                raise ValueError("A local recording is incomplete; no comparison copy was made.")
                        item.pop("narration")
                        copy.execute("UPDATE items SET payload=? WHERE id=?", (json.dumps(item, sort_keys=True).encode(), item_id))
                copy.commit()
            finally:
                original.close(); copy.close()
            # Verify every immutable copied file before publishing the new folder.
            def digest(path):
                result = hashlib.sha256()
                with path.open("rb") as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        result.update(chunk)
                return result.hexdigest()
            for item in (source / "Items").rglob("*"):
                if item.is_file() and digest(item) != digest(staging / item.relative_to(source)):
                    raise ValueError("A copied file did not match its source.")
            marker = json.loads((source / "Library.json").read_text())
            marker["id"] = str(uuid.uuid4())
            (staging / "Library.json").write_text(json.dumps(marker, indent=2))
            (staging / "Comparison.json").write_text(json.dumps({"source": str(source), "localNarrations": archived}, indent=2))
            (staging / ".gitignore").write_text("*\n!.gitignore\n")
            staging.rename(destination)
            return len(rows), len(archived)
        finally:
            if staging.exists():
                shutil.rmtree(staging)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    args = parser.parse_args()
    try:
        items, recordings = create(args.source, args.destination)
    except (ValueError, OSError, sqlite3.Error) as error:
        parser.exit(1, str(error) + "\n")
    print(f"Created comparison library with {items} items; {recordings} local narration records archived. Source unchanged.")
