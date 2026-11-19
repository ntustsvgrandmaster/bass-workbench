#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TEST_APP="$ROOT/.test-work/MeasureNavigationAppTests.app"
mkdir -p "$TEST_APP/Contents/MacOS" "$ROOT/.test-work/navigation-app-module-cache"
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.bassworkbench.navigation-app-tests</string>
<key>CFBundleExecutable</key><string>MeasureNavigationAppTests</string>
<key>CFBundleName</key><string>Measure Navigation App Tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
APP_SOURCES=("$ROOT"/app/*.swift)
APP_SOURCES=("${(@)APP_SOURCES:#*/App.swift}")
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/.test-work/navigation-app-module-cache" "${APP_SOURCES[@]}" "$ROOT/tests/MeasureNavigationAppTests.swift" -o "$TEST_APP/Contents/MacOS/MeasureNavigationAppTests" -framework SwiftUI -framework WebKit -framework AVFoundation -framework AppKit -lsqlite3
codesign --force --sign - "$TEST_APP"
BASS_DATA_ROOT="$ROOT/.test-work/navigation-app-data" "$TEST_APP/Contents/MacOS/MeasureNavigationAppTests"
