#!/bin/zsh
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/.test-work/module-cache" "$ROOT/.test-work/numba"
TEST_PYTHON="${BASS_TEST_PYTHON:-$ROOT/.venv/bin/python}"
NUMBA_CACHE_DIR="$ROOT/.test-work/numba" "$TEST_PYTHON" -m unittest discover -s "$ROOT/tests" -p 'test_*.py' -v
UNIT_SOURCES=("$ROOT"/app/{Models,TimelineAlignment,Metronome,EstimatedGrid,AnalysisPlan,EditingDrafts,RegionAnalysis,AnalysisWorker,Files,ProjectStore}.swift)
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/.test-work/module-cache" "${UNIT_SOURCES[@]}" "$ROOT/tests/UnitTests.swift" -o "$ROOT/.test-work/unit-tests" -lsqlite3
"$ROOT/.test-work/unit-tests" "$ROOT/.test-work/unit-data"
"$ROOT/test-metronome.sh" --model-only
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/.test-work/module-cache" "$ROOT/app/Models.swift" "$ROOT/app/TimelineAlignment.swift" "$ROOT/app/Metronome.swift" "$ROOT/app/EstimatedGrid.swift" "$ROOT/app/AnalysisPlan.swift" "$ROOT/app/EditingDrafts.swift" "$ROOT/app/RegionAnalysis.swift" "$ROOT/app/AnalysisWorker.swift" "$ROOT/app/SpectrumCache.swift" "$ROOT/app/Files.swift" "$ROOT/app/Audio.swift" "$ROOT/app/ScoreIO.swift" "$ROOT/app/ProjectStore.swift" "$ROOT/tests/NativeTests.swift" -o "$ROOT/.test-work/native-tests" -framework AVFoundation -framework AppKit -lsqlite3
if [[ "${BASS_TEST_INTEGRATION:-0}" == "1" ]]; then
  "$ROOT/.test-work/native-tests" "$ROOT/.test-work/fixtures"
else
  BASS_TEST_UNIT_ONLY=1 "$ROOT/.test-work/native-tests" "$ROOT/.test-work/fixtures"
fi
"$ROOT/test-multi-score.sh"
if [[ "${BASS_TEST_INTEGRATION:-0}" == "1" ]]; then
"$ROOT/test-audio-resources.sh"
"$ROOT/test-metronome.sh" --live
BASS_WORKER_PYTHON="$TEST_PYTHON" BASS_WORKER_SCRIPT="$ROOT/worker/main.py" "$ROOT/test-tempo-workflow.sh" --real
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/.test-work/module-cache" "$ROOT/app/Models.swift" "$ROOT/app/TimelineAlignment.swift" "$ROOT/app/Metronome.swift" "$ROOT/app/EstimatedGrid.swift" "$ROOT/app/AnalysisPlan.swift" "$ROOT/app/EditingDrafts.swift" "$ROOT/app/RegionAnalysis.swift" "$ROOT/app/SpectrumCache.swift" "$ROOT/app/Files.swift" "$ROOT/app/Audio.swift" "$ROOT/app/ScoreIO.swift" "$ROOT/app/ProjectStore.swift" "$ROOT/app/AnalysisWorker.swift" "$ROOT/app/WorkbenchStore.swift" "$ROOT/tests/WorkbenchTests.swift" -o "$ROOT/.test-work/workbench-tests" -framework SwiftUI -framework AVFoundation -framework AppKit -lsqlite3
BASS_DATA_ROOT="$ROOT/.test-work/workbench-data" "$ROOT/.test-work/workbench-tests"
NUMBA_CACHE_DIR="$ROOT/.test-work/numba" "$TEST_PYTHON" "$ROOT/tests/create_feature_fixture.py" "$ROOT/.test-work/cache-fixture"
CORE_SOURCES=("$ROOT"/app/{Models,TimelineAlignment,Metronome,EstimatedGrid,AnalysisPlan,RegionAnalysis,SpectrumCache,EditingDrafts,Files,Audio,ScoreIO,ProjectStore,AnalysisWorker,WorkbenchStore}.swift)
for TEST_NAME in Editing CacheIntegration DeliveryIntegration; do
  xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/.test-work/module-cache" "${CORE_SOURCES[@]}" "$ROOT/tests/${TEST_NAME}Tests.swift" -o "$ROOT/.test-work/${TEST_NAME}Tests" -framework SwiftUI -framework AVFoundation -framework AppKit -lsqlite3
  BASS_WORKER_PYTHON="$TEST_PYTHON" BASS_WORKER_SCRIPT="$ROOT/worker/main.py" BASS_DATA_ROOT="$ROOT/.test-work/${TEST_NAME}-data" "$ROOT/.test-work/${TEST_NAME}Tests" "$ROOT/.test-work/cache-fixture"
done
else
  print "SKIP worker/cache/live audio integration (set BASS_TEST_INTEGRATION=1)"
fi
if [[ "${BASS_TEST_UI:-0}" == "1" ]]; then
  "$ROOT/test-score-preview.sh"
  "$ROOT/test-ui.sh"
  BASS_DATA_ROOT="$ROOT/.test-work/interface-data" "$ROOT/.test-work/InterfaceTests.app/Contents/MacOS/InterfaceTests" --r09-only
  "$ROOT/test-navigation-app.sh"
else
  print "SKIP interface/App visual tests (set BASS_TEST_UI=1, or run ./test-score-preview.sh, ./test-ui.sh and ./test-navigation-app.sh)"
fi
