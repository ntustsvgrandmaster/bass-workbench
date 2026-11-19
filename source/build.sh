#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-$ROOT/build}"
mkdir -p "$DEST"
FINAL="$DEST/Bass Harmony Workbench.app"
STAGE="$(mktemp -d "$DEST/.bass-build.XXXXXX")"
APP="$STAGE/Bass Harmony Workbench.app"
PREVIOUS="$STAGE/previous/Bass Harmony Workbench.app"
cleanup() {
  if [[ -e "$PREVIOUS" && ! -e "$FINAL" ]]; then
    mv "$PREVIOUS" "$DEST/" || return
  fi
  rm -rf "$STAGE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/.module-cache"
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/.module-cache" -target arm64-apple-macosx14.0 "$ROOT"/app/*.swift -o "$APP/Contents/MacOS/BassHarmony" -framework SwiftUI -framework WebKit -framework AVFoundation -framework AppKit -lsqlite3
cp -R "$ROOT/worker" "$APP/Contents/Resources/"
cp -R "$ROOT/resources/score-viewer" "$APP/Contents/Resources/"
if [[ -n "${BASS_BUILD_BTC_CONFIG:-}" ]]; then
  cp "$BASS_BUILD_BTC_CONFIG" "$APP/Contents/Resources/btc-local.json"
fi
if [[ -f "$ROOT/resources/AppIcon.icns" ]]; then cp "$ROOT/resources/AppIcon.icns" "$APP/Contents/Resources/"; fi
if [[ -n "${BASS_PREBUNDLED_PYTHON:-}" ]]; then
  "$BASS_PREBUNDLED_PYTHON/bin/python3.12" "$ROOT/bundle_runtime.py" "$APP"
else
  "$ROOT/.venv/bin/python" "$ROOT/bundle_runtime.py" "$APP"
fi
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/README.md" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Bass Harmony Workbench</string>
<key>CFBundleDisplayName</key><string>Bass Harmony Workbench</string>
<key>CFBundleIdentifier</key><string>local.bassworkbench.harmony</string>
<key>CFBundleVersion</key><string>2</string><key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleExecutable</key><string>BassHarmony</string><key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>Bass Workbench Project</string><key>CFBundleTypeRole</key><string>Editor</string><key>LSHandlerRank</key><string>Owner</string><key>LSItemContentTypes</key><array><string>local.bassworkbench.project</string></array><key>LSTypeIsPackage</key><true/></dict></array>
<key>UTExportedTypeDeclarations</key><array><dict><key>UTTypeIdentifier</key><string>local.bassworkbench.project</string><key>UTTypeDescription</key><string>Bass Workbench Project</string><key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.directory</string></array><key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>basswork</string></array></dict></dict></array>
</dict></plist>
PLIST
if [[ -n "${BASS_BUILD_BUNDLE_ID:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BASS_BUILD_BUNDLE_ID" "$APP/Contents/Info.plist"
fi
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
if [[ -e "$FINAL" ]]; then
  mkdir "$STAGE/previous"
  mv "$FINAL" "$STAGE/previous/"
fi
mv "$APP" "$DEST/"
echo "$FINAL"
