import AVFoundation
import Foundation

/// 小型真實 Worker 串接檢查，補足單元測試未涵蓋的 App ↔ Python 邊界。
@main struct DeliveryIntegrationTests {
  static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw WorkbenchError.message("TEST FAILED: \(message)") }
  }
  @MainActor static func main() async throws {
    guard ProcessInfo.processInfo.environment["BASS_DATA_ROOT"] != nil else {
      throw WorkbenchError.message("Specify disposable BASS_DATA_ROOT")
    }
    let store = WorkbenchStore()
    let audio = store.folder.appendingPathComponent("synthetic.wav")
    let sr = 22050.0
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050 * 12)!
    buffer.frameLength = buffer.frameCapacity
    for index in 0..<Int(buffer.frameLength) {
      let t = Double(index) / sr
      let pulse = t.truncatingRemainder(dividingBy: 0.5)
      let click = pulse < 0.006 ? 0.5 * sin(2 * .pi * 1500 * t) : 0
      let harmony = [261.6256, 329.6276, 391.9954].reduce(0.0) { $0 + 0.06 * sin(2 * .pi * $1 * t) }
      buffer.floatChannelData![0][index] = Float(harmony + 0.1 * sin(2 * .pi * 82.4069 * t) + click)
    }
    do {
      let file = try AVAudioFile(forWriting: audio, settings: format.settings)
      try file.write(from: buffer)
    }
    let hash = try Files.hash(audio)
    let asset = MediaAsset(role: "original", name: "synthetic", originalPath: "synthetic.wav",
                           pcmPath: "synthetic.wav", hash: hash, duration: 12, sampleRate: sr, channels: 1)
    store.project.assets = [asset]
    store.project.selectedAsset = asset.id
    store.project.timing.bpm = 120
    store.project.reconcileEstimatedRegions()
    try store.transport.load(audio)
    store.zoomMeasure()
    store.project.regions[0].annotation = HumanAnnotation(root: "", chord: "human", rootLocked: true, confirmed: true)
    let human = store.project.regions.map(\.annotation)
    let gridBeforeEstimate = store.project
    await store.estimateTempo()?.value
    try check(store.error == nil && store.tempoEstimate?.bpm != nil, "tempo travels through real JSONL worker")
    try check(store.project == gridBeforeEstimate, "tempo estimate does not apply grid automatically")
    store.previewFirstBar(-0.1)
    try check(store.viewportStart < 0 && !store.canAnalyze, "calibration viewport can show pre-roll before the audio")
    await store.analyzeCalibrationSpectrum()?.value
    try check(store.error == nil && store.spectrum?.metadata.start == 0,
              "calibration-only CQT clips pre-roll to the real audio and loads its cache")
    store.previewFirstBar(-0.09)
    try check(!store.spectrumSegments.isEmpty && store.project == gridBeforeEstimate,
              "small calibration pans keep overlapping energy without changing saved alignment or annotations")
    store.endFirstBarPreview()
    await store.analyze(fullSong: true)?.value
    try check(store.error == nil && !store.busy && !store.analysisRunning, "full-song store task finishes cleanly")
    try check(store.project.regions.count == 6 && store.project.regions.allSatisfy { $0.evidence?.contextKey != nil },
              "store writes every region with a resumable context")
    try check(store.project.regions.map(\.annotation) == human, "real worker cannot overwrite human data")
    let plan = AnalysisPlan(project: store.project, arrangement: asset, bass: asset,
                            method: AnalysisMethod.sourceHarmony)
    try check(plan.reused == 6 && plan.pending == 0, "finished real results are reusable")
    let resumed = store.analyze(fullSong: true)
    try check(resumed == nil && !store.busy, "completed song resumes without another worker request")
    let persisted = try ProjectStore.load(store.folder)
    try check(persisted.regions.map(\.annotation) == human && persisted.regions.allSatisfy { $0.evidence != nil },
              "real analysis and locks saved to SQLite")
    await store.analyze(fullSong: true, globalTuning: true)?.value
    try check(store.error == nil && store.project.regions.allSatisfy {
      $0.evidence?.method == AnalysisMethod.tunedHarmony && $0.evidence?.tuningCents != nil
    }, "Global tuning produces versioned evidence through the real worker")
    try check(store.analyze(fullSong: true, globalTuning: true) == nil, "Tuned results resume independently")
    await store.analyze()?.value
    try check(store.error == nil && store.spectrum != nil, "current-range CQT still works after full analysis")
    try check(try Files.hash(audio) == hash, "analysis leaves original audio unchanged")
    let historyCount = store.project.regions.count
    try check(store.applyEstimatedGrid(GridInput(bpm: 120, numerator: 3, denominator: 4, firstBar: 0.5)), "store applies manual grid")
    try check(store.project.archivedRegions.count == historyCount && store.project.archivedRegions[0].annotation == human[0],
              "store archives prior human annotations")
    store.undo()
    try check(store.project.regions.map(\.annotation) == human && store.project.measures.count == 6,
              "undo restores original analyzed grid")
    let originalIDs = store.project.regions.map(\.id)
    var shifted = store.project.timing
    try shifted.setBias(0.25)
    try check(store.applyAlignment(shifted), "store commits signed bias")
    try check(store.viewportStart == 0.25 && store.project.regions.map(\.id) == originalIDs
              && store.project.regions.map(\.annotation) == human,
              "bias changes viewport time while preserving regions and human data")
    try check(store.project.regions[0].evidence != nil && store.freshEvidence(store.project.regions[0]) == nil,
              "alignment keeps old evidence traceable but marks it stale")
    await store.restoreSpectrum()?.value
    try check(store.spectrumSegments.contains { $0.metadata.start == 0 && $0.metadata.end == 2 },
              "shifted viewport retains partial cache at its original times")
    store.undo()
    try check(store.project.timing.bias == 0 && store.project.regions.map(\.id) == originalIDs,
              "bias correction undo restores original timing and region identities")
    let calibrated = try store.project.timing.calibrated(from: AlignmentPoint(beat: 0, seconds: 0.5),
                                                         to: AlignmentPoint(beat: 16, seconds: 8.5))
    try check(store.applyAlignment(calibrated), "store applies two-point timing")
    var translated = store.project.timing
    try translated.setBias(-0.125)
    try check(store.applyAlignment(translated), "bias also shifts existing two-point anchors")
    store.openProject(store.folder)
    try check(store.project.timing.bias == -0.125 && store.project.timing.seconds(at: 0) == 0.375
              && store.project.timing.seconds(at: 16) == 8.375,
              "actual project reopen restores bias and both calibration points")
    try check(store.project.regions.map(\.annotation) == human, "calibration and reopen retain locked blanks")
    try check(store.error == nil, "no hidden persistence error")
    let worker = CancelAfterFirstResult()
    let interrupted = WorkbenchStore(worker: worker)
    interrupted.project = store.project
    for index in interrupted.project.regions.indices { interrupted.project.regions[index].evidence = nil }
    interrupted.persist()
    let task = interrupted.analyze(fullSong: true)!
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while worker.waiting == nil && clock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try check(worker.waiting != nil && interrupted.project.regions.allSatisfy { $0.evidence == nil },
              "First result remains buffered while waiting for the second worker response")
    interrupted.cancel()
    await task.value
    let reopened = try ProjectStore.load(interrupted.folder)
    try check(reopened.regions.filter { $0.evidence != nil }.count == 1 && reopened.regions.map(\.annotation) == human,
              "Cancellation flushes delivered evidence and preserves human annotations")
    try check(interrupted.analysisSummary.contains("已保存"), "Cancellation shows saved results as resumable")
    let resumedPlan = AnalysisPlan(project: reopened, arrangement: asset, bass: asset,
                                   method: AnalysisMethod.sourceHarmony)
    try check(resumedPlan.reused == 1 && resumedPlan.pending > 0, "Resume skips the saved result only")
    print("PASS delivery integration: real JSONL / whole-song / resume / cancellation flush / SQLite / CQT / grid / stale evidence")
  }
}

@MainActor private final class CancelAfterFirstResult: @preconcurrency AnalysisRequesting {
  private var requests = 0
  var waiting: CheckedContinuation<Data, Error>?

  func request(_ values: [String: Any], cacheRoot: URL,
               progress: @escaping (Double, String) -> Void) async throws -> Data {
    requests += 1
    if requests > 1 { return try await withCheckedThrowingContinuation { waiting = $0 } }
    let source = (values["arrangement"] as! [String: Any])["hash"] as! String
    return try JSONEncoder().encode(HarmonyEvidence(firstScore: 0, rootMargin: 0, candidates: [], chroma: [],
      warnings: [], arrangementSource: source, bassSource: source, method: values["method"] as! String,
      timingRevision: values["timingRevision"] as! Int, createdAt: "test"))
  }

  func cancel() {
    waiting?.resume(throwing: CancellationError())
    waiting = nil
  }
}
