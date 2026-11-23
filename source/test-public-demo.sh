#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/.test-work/module-cache"
SOURCES=("$ROOT"/app/{Models,TimelineAlignment,Metronome,EstimatedGrid,AnalysisPlan,EditingDrafts,RegionAnalysis,AnalysisWorker,Files,ScoreIO}.swift)
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/.test-work/module-cache" "${SOURCES[@]}" "$ROOT/tests/PublicDemoTests.swift" -o "$ROOT/.test-work/public-demo-tests"
"$ROOT/.test-work/public-demo-tests" "$ROOT/../demo/mint-groove"
