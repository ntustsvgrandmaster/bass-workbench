#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TEST_APP="$ROOT/.test-work/NavigationReproductionTests.app"
mkdir -p "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Resources" "$ROOT/.test-work/app-module-cache"
cp -R "$ROOT/resources/score-viewer" "$TEST_APP/Contents/Resources/"
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.bassworkbench.navigation-reproduction</string>
<key>CFBundleExecutable</key><string>NavigationReproductionTests</string>
<key>CFBundleName</key><string>T02 Navigation Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
APP_SOURCES=("$ROOT"/app/*.swift)
APP_SOURCES=("${(@)APP_SOURCES:#*/App.swift}")
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/.test-work/app-module-cache" "${APP_SOURCES[@]}" "$ROOT/tests/NavigationReproductionTests.swift" -o "$TEST_APP/Contents/MacOS/NavigationReproductionTests" -framework SwiftUI -framework WebKit -framework AVFoundation -framework AppKit -lsqlite3
codesign --force --sign - "$TEST_APP"
if [[ "${1:-}" == "--build-only" ]]; then
  print "$TEST_APP"
  exit 0
fi
BASS_DATA_ROOT="$ROOT/.test-work/navigation-repro-data" "$TEST_APP/Contents/MacOS/NavigationReproductionTests" "$@"
