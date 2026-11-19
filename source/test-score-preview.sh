#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TEST_APP="$ROOT/.test-work/ScorePreviewTests.app"
mkdir -p "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Resources" "$ROOT/.test-work/app-module-cache"
cp -R "$ROOT/resources/score-viewer" "$TEST_APP/Contents/Resources/"
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.bassworkbench.score-preview-tests</string>
<key>CFBundleExecutable</key><string>ScorePreviewTests</string>
<key>CFBundleName</key><string>Score Preview Tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
APP_SOURCES=("$ROOT"/app/{Models,TimelineAlignment,Metronome,EstimatedGrid,Files,ScoreIO,ScoreView}.swift)
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/.test-work/app-module-cache" "${APP_SOURCES[@]}" "$ROOT/tests/ScorePreviewTests.swift" -o "$TEST_APP/Contents/MacOS/ScorePreviewTests" -framework SwiftUI -framework WebKit -framework AVFoundation -framework AppKit -lsqlite3
codesign --force --sign - "$TEST_APP"
BASS_DATA_ROOT="$ROOT/.test-work/score-preview-data" "$TEST_APP/Contents/MacOS/ScorePreviewTests" "$@"
