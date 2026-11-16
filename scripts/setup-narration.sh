#!/bin/bash
# Prepare Reader-owned offline inference dependencies without changing R2M.
set -euo pipefail
READER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
READER_RUNTIME_SOURCE="${READER_NARRATION_SOURCE:-$READER_ROOT/../R2M/outputs/R2M.app/Contents/Resources}"
READER_MODELS_SOURCE="${READER_NARRATION_MODELS:-$HOME/Library/Application Support/R2M/Models}"
READER_RUNTIME_TARGET="$READER_ROOT/ReaderRuntime"
if [[ -e "$READER_RUNTIME_TARGET" ]]; then
    echo "Checking the existing ReaderRuntime; its files will be preserved."
    if [[ ! -x "$READER_RUNTIME_TARGET/runtime/bin/python3.11" || ! -x "$READER_RUNTIME_TARGET/bin/ffmpeg" ]] || ! "$READER_RUNTIME_TARGET/runtime/bin/python3.11" -I -B "$READER_ROOT/scripts/verify-narration-runtime.py" "$READER_RUNTIME_TARGET"; then
        echo "ReaderRuntime is incomplete or damaged. Preserve or rename this regenerable dependency folder, then rerun setup. Your ReaderData library is separate and must be kept." >&2
        exit 1
    fi
    echo "Runtime: $READER_RUNTIME_TARGET/runtime/bin/python3.11"
    exit 0
fi
[[ -x "$READER_RUNTIME_SOURCE/runtime/bin/python3.11" ]] || { echo "Missing prepared R2M Python runtime at $READER_RUNTIME_SOURCE" >&2; exit 1; }
[[ -x "$READER_RUNTIME_SOURCE/bin/ffmpeg" ]] || { echo "Missing prepared FFmpeg." >&2; exit 1; }
for READER_MODEL in speech cleanup; do
    [[ -f "$READER_MODELS_SOURCE/$READER_MODEL/.installed.json" ]] || { echo "Install R2M's $READER_MODEL model set first, or set READER_NARRATION_MODELS." >&2; exit 1; }
done
READER_STAGE="$(mktemp -d "$READER_ROOT/.ReaderRuntime-setup.XXXXXX")"
trap 'rm -rf "$READER_STAGE"' EXIT
copy_tree() {
    # APFS clones share unchanged extents while remaining independent files.
    # ditto merges into our new staging folder if this filesystem cannot clone.
    if ! /bin/cp -cpR "$1" "$2" 2>/dev/null; then
        /usr/bin/ditto "$1" "$2"
    fi
}
echo "Copying offline Python and FFmpeg into Reader-owned storage…"
copy_tree "$READER_RUNTIME_SOURCE/runtime" "$READER_STAGE/runtime"
copy_tree "$READER_RUNTIME_SOURCE/bin" "$READER_STAGE/bin"
mkdir -p "$READER_STAGE/Models"
for READER_MODEL in speech cleanup; do copy_tree "$READER_MODELS_SOURCE/$READER_MODEL" "$READER_STAGE/Models/$READER_MODEL"; done
for READER_FILE in THIRD_PARTY_NOTICES.md runtime-packages.json; do
    if [[ -f "$READER_RUNTIME_SOURCE/$READER_FILE" ]]; then /bin/cp -p "$READER_RUNTIME_SOURCE/$READER_FILE" "$READER_STAGE/$READER_FILE"; fi
done
if [[ -d "$READER_RUNTIME_SOURCE/Licenses" ]]; then copy_tree "$READER_RUNTIME_SOURCE/Licenses" "$READER_STAGE/Licenses"; fi
/bin/cp "$READER_ROOT/Sources/Reader/Resources/Narration/R2MBackend/models.json" "$READER_STAGE/models.json"
echo "Verifying copied model checksums and runtime imports…"
"$READER_STAGE/runtime/bin/python3.11" -I -B "$READER_ROOT/scripts/verify-narration-runtime.py" "$READER_STAGE"
mv "$READER_STAGE" "$READER_RUNTIME_TARGET"
trap - EXIT
echo "Ready: $READER_RUNTIME_TARGET"
echo "Reader user documents, scripts and audio remain in the configured Reader library."
