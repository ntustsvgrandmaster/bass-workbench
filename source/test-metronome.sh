#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/.test-work/metronome-module-cache"
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/.test-work/metronome-module-cache" "$ROOT"/app/{Models,TimelineAlignment,Metronome,EstimatedGrid,Files,Audio}.swift "$ROOT/tests/MetronomeTests.swift" -o "$ROOT/.test-work/metronome-tests" -framework AVFoundation -framework AppKit -lsqlite3
BASS_DATA_ROOT="$ROOT/.test-work/metronome-data" "$ROOT/.test-work/metronome-tests" "$@"
