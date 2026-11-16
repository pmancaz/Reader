#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
case "${1:-}" in
  "") export READER_VERIFY_NARRATION=0 ;;
  --narration) export READER_VERIFY_NARRATION=1 ;;
  *) echo 'Usage: scripts/verify.sh [--narration]' >&2; exit 2 ;;
esac
swift run --build-system native ReaderCoreChecks
if [[ -x "$ROOT/ReaderRuntime/runtime/bin/python3.11" ]]; then
  "$ROOT/ReaderRuntime/runtime/bin/python3.11" -I -B -m unittest discover -s Tests -p 'test_narration*.py' -v
else
  python3 -B -m unittest discover -s Tests -p test_narration_worker.py -v
  echo 'PDF extraction regressions require the optional narration runtime setup.'
fi
./scripts/build.sh debug
VERIFY_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/Reader-check.XXXXXX")"
FIXTURE_PID=""
cleanup() {
  if [[ -n "$FIXTURE_PID" ]]; then kill "$FIXTURE_PID" 2>/dev/null || true; fi
  rm -rf "$VERIFY_TEMP"
}
trap cleanup EXIT INT TERM
python3 scripts/fixture-server.py --port 0 --port-file "$VERIFY_TEMP/port" > "$VERIFY_TEMP/server.log" 2>&1 &
FIXTURE_PID=$!
for attempt in {1..50}; do
  if [[ -s "$VERIFY_TEMP/port" ]]; then break; fi
  if ! kill -0 "$FIXTURE_PID" 2>/dev/null; then cat "$VERIFY_TEMP/server.log"; exit 1; fi
  sleep 0.1
done
if [[ ! -s "$VERIFY_TEMP/port" ]]; then echo 'Fixture server did not start' >&2; exit 1; fi
export READER_FIXTURE_PDF="$ROOT/Tests/Fixtures/reading-fixture.pdf"
export READER_FIXTURE_BASE_URL="http://127.0.0.1:$(cat "$VERIFY_TEMP/port")"
# These opt-in verifier modes create isolated temporary libraries only.
python3 - "$ROOT/build/Reader.app/Contents/MacOS/Reader" <<'PY'
import os, subprocess, sys
modes = ['--verify-imports', '--verify-reading']
if os.environ.get('READER_VERIFY_NARRATION') == '1': modes.append('--verify-narration')
for mode in modes:
    result = subprocess.run([sys.argv[1], mode], timeout=600 if mode == '--verify-narration' else 240)
    if result.returncode:
        raise SystemExit(result.returncode)
PY
