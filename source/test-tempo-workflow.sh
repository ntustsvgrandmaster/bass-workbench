#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/.test-work/tempo-module-cache"
CORE_SOURCES=("$ROOT"/app/{Models,TimelineAlignment,Metronome,EstimatedGrid,AnalysisPlan,EditingDrafts,RegionAnalysis,AnalysisWorker,SpectrumCache,Files,Audio,ScoreIO,ProjectStore,WorkbenchStore}.swift)
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/.test-work/tempo-module-cache" "${CORE_SOURCES[@]}" "$ROOT/tests/TempoWorkflowTests.swift" -o "$ROOT/.test-work/tempo-workflow-tests" -framework SwiftUI -framework AVFoundation -framework AppKit -lsqlite3
BASS_DATA_ROOT="$ROOT/.test-work/tempo-workflow-data" "$ROOT/.test-work/tempo-workflow-tests" "$@"
