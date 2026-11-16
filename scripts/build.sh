#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
if [[ "$CONFIGURATION" != "release" && "$CONFIGURATION" != "debug" ]]; then
  echo 'Usage: scripts/build.sh [release|debug]' >&2
  exit 2
fi
cd "$ROOT"
swift build --build-system native --configuration "$CONFIGURATION" --product Reader
BIN_DIR="$(swift build --build-system native --configuration "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/build/Reader.app"
mkdir -p "$ROOT/build"
# This script only replaces build/Reader.app. It never touches ReaderData.
if [[ "$APP" != "$ROOT/build/Reader.app" ]]; then exit 3; fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Reader" "$APP/Contents/MacOS/Reader"
chmod +x "$APP/Contents/MacOS/Reader"
shopt -s nullglob
for RESOURCE_BUNDLE in "$BIN_DIR"/*.bundle; do
  /usr/bin/ditto "$RESOURCE_BUNDLE" "$APP/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
done
# Narration dependencies are installed once with setup-narration.sh. Runtime
# binaries are copied into the app; model weights stay in the regenerable
# project ReaderRuntime/Models folder rather than enlarging every app build.
if [[ -x "$ROOT/ReaderRuntime/runtime/bin/python3.11" && -x "$ROOT/ReaderRuntime/bin/ffmpeg" ]]; then
  NARRATION_RUNTIME="$APP/Contents/Resources/NarrationRuntime"
  mkdir -p "$NARRATION_RUNTIME"
  # Clone on APFS when possible; the app remains independent of the source.
  if ! /bin/cp -cpR "$ROOT/ReaderRuntime/runtime" "$NARRATION_RUNTIME/runtime" 2>/dev/null; then
    /usr/bin/ditto "$ROOT/ReaderRuntime/runtime" "$NARRATION_RUNTIME/runtime"
  fi
  if ! /bin/cp -cpR "$ROOT/ReaderRuntime/bin" "$NARRATION_RUNTIME/bin" 2>/dev/null; then
    /usr/bin/ditto "$ROOT/ReaderRuntime/bin" "$NARRATION_RUNTIME/bin"
  fi
  if [[ -d "$ROOT/ReaderRuntime/Licenses" ]]; then
    /usr/bin/ditto "$ROOT/ReaderRuntime/Licenses" "$NARRATION_RUNTIME/Licenses"
  fi
  for NOTICE in "$ROOT/ReaderRuntime"/THIRD_PARTY* "$ROOT/ReaderRuntime"/LICENSE* "$ROOT/ReaderRuntime"/runtime-packages.json; do
    if [[ -f "$NOTICE" ]]; then cp "$NOTICE" "$NARRATION_RUNTIME/"; fi
  done
else
  echo 'Narration runtime is not installed; run scripts/setup-narration.sh to enable local narration.' >&2
fi
if [[ -f "$ROOT/assets/Reader.icns" ]]; then
  cp "$ROOT/assets/Reader.icns" "$APP/Contents/Resources/Reader.icns"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>Reader</string>
<key>CFBundleIdentifier</key><string>au.pcarroll.Reader</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>Reader</string>
<key>CFBundleDisplayName</key><string>Reader</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>Reader</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSSupportsAutomaticTermination</key><false/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
echo "Built $APP ($CONFIGURATION; local ad-hoc signature)"
