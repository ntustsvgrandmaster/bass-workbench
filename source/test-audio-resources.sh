#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="${BASS_AUDIO_TEST_BUILD:-$ROOT/.test-work/audio-resources}"
AUDIO_SOURCE="${BASS_TEST_AUDIO_SOURCE:-$ROOT/app/Audio.swift}"
FLAGS=()
if [[ "$AUDIO_SOURCE" == "$ROOT/app/Audio.swift" ]]; then FLAGS=(-D BASS_PRACTICE_METRICS); fi
mkdir -p "$DEST" "$ROOT/.test-work/audio-resource-module-cache"
xcrun swiftc -swift-version 5 -O -parse-as-library "${FLAGS[@]}" -module-cache-path "$ROOT/.test-work/audio-resource-module-cache" "$ROOT"/app/{Models,TimelineAlignment,Metronome,EstimatedGrid,Files}.swift "$AUDIO_SOURCE" "$ROOT/tests/TransportResourceTests.swift" -o "$DEST/transport-resource-tests" -framework AVFoundation -framework CoreAudio -lsqlite3
shasum -a 256 "$ROOT"/app/{Models,TimelineAlignment,Metronome,EstimatedGrid,Files}.swift "$AUDIO_SOURCE" "$ROOT/tests/TransportResourceTests.swift" > "$DEST/build-source.sha256"
if [[ "${1:-}" == "--build-only" ]]; then
  print "$DEST/transport-resource-tests"
else
  BASS_DATA_ROOT="$DEST/data" "$DEST/transport-resource-tests" "$@"
fi
