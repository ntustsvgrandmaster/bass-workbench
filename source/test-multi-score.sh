#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/.test-work/multi-score-module-cache"
CORE_SOURCES=("$ROOT"/app/{Models,TimelineAlignment,Metronome,EstimatedGrid,AnalysisPlan,EditingDrafts,RegionAnalysis,AnalysisWorker,SpectrumCache,Files,Audio,ScoreIO,ProjectStore,WorkbenchStore}.swift)
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/.test-work/multi-score-module-cache" "${CORE_SOURCES[@]}" "$ROOT/tests/MultiScoreTests.swift" -o "$ROOT/.test-work/multi-score-tests" -framework SwiftUI -framework AVFoundation -framework AppKit -lsqlite3
TEST_ARGS=("$@")
if [[ "${BASS_TEST_INTEGRATION:-0}" != "1" && " ${*} " != *" --store "* && " ${*} " != *" --memory "* ]]; then
  TEST_ARGS+=(--model-only)
fi
BASS_DATA_ROOT="$ROOT/.test-work/multi-score-data" "$ROOT/.test-work/multi-score-tests" "${TEST_ARGS[@]}"
