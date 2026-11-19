import AVFoundation
import Foundation

/// 獨立合成專案；可控回應驗證一次性觸發／取消與來源身分，--real 補真 Worker。
@main struct TempoWorkflowTests {
  static var assertions = 0
  static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    assertions += 1
    if try !value() { throw WorkbenchError.message("TEST FAILED: \(message)") }
  }
  @MainActor static func wait(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    try check(predicate(), "workflow reached expected asynchronous state")
  }
  static func audio(_ root: URL) throws -> URL {
    let url = root.appendingPathComponent("tempo-clicks.wav")
    let sr = 22050.0
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050 * 16)!
    buffer.frameLength = buffer.frameCapacity
    buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
    for beat in 0..<31 {
      let first = Int((0.5 + Double(beat) * 0.5) * sr)
      for n in 0..<120 {
        buffer.floatChannelData![0][first + n] = Float(0.6 * pow(sin(.pi * Double(n) / 119), 2) * sin(2 * .pi * 1500 * Double(n) / sr))
      }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
  }
  @MainActor static func main() async throws {
    guard let path = ProcessInfo.processInfo.environment["BASS_DATA_ROOT"] else { fatalError("Specify disposable BASS_DATA_ROOT") }
    let root = URL(fileURLWithPath: path)
    try Files.directory(root)
    if CommandLine.arguments.contains("--btc-real") {
      try await realBTC()
      print("PASS BTC real workflow: \(assertions) assertions")
      return
    }
    let input = try audio(root)
    try await workflows(input, root)
    try await estimatorPreferences(input, root)
    try await automaticBTC(input, root)
    if CommandLine.arguments.contains("--real") {
      let store = WorkbenchStore()
      let original = try Data(contentsOf: input)
      await store.importAudio(input, role: "original")?.value
      try check(store.error == nil && !store.busy && !store.analysisRunning, "real import and automatic JSONL estimation finish")
      try check(store.currentTempoEstimate?.bpm == 120, "real automatic candidate is quantized")
      let fit = store.currentTempoEstimate?.candidates?.first { $0.multiplier == 1 }?.fit
      try check(fit?.status == "good" && (fit?.p95Ms ?? 999) < 20, "real onsets provide refitted residual summary")
      try check(store.project.timing.bpm == 120 && store.project.timing.anchors.isEmpty
                  && store.project.timing.seconds(at: 0) == 0,
                "real first import sets recommended BPM without applying beat phase")
      try check(store.project.estimatedGrid != nil && store.canAnalyze && store.autoAppliedGridBPM == 120,
                "real first import applies a usable grid and exposes the recommendation")
      try check(try ProjectStore.load(store.folder).estimatedGrid != nil, "automatic grid survives reopening")
      try check(try Data(contentsOf: input) == original, "real estimation never changes original input")
      print("PASS real import → automatic JSONL → observed fit → initial BPM")
    }
    if CommandLine.arguments.contains("--optional-real") {
      guard let path=ProcessInfo.processInfo.environment["BASS_T14_AUDIO"] else { fatalError("Disposable local test WAV required") }
      let prefs=UserDefaults(suiteName:"local.bassworkbench.tempo.realoptional")!
      prefs.removePersistentDomain(forName:"local.bassworkbench.tempo.realoptional")
      defer { prefs.removePersistentDomain(forName:"local.bassworkbench.tempo.realoptional") }
      let optional=WorkbenchStore(preferences:prefs)
      try check(optional.small0Available,"registered optional runtime is available")
      optional.selectTempoEstimator(.small0)
      await optional.importAudio(URL(fileURLWithPath:path),role:"original")?.value
      try check(optional.error == nil && optional.currentTempoEstimate?.estimator == "small0",
        "real optional JSONL and first import complete")
      try check(optional.currentTempoEstimate?.buttonBPMS.contains(190) == true,
        "real mixed-level song includes 190 BPM candidate")
      try check(optional.currentTempoEstimate?.recommendedBPM == nil
                  && optional.project.timing.bpm == optional.currentTempoEstimate?.preferredBPM,
        "mixed beat levels apply the leading candidate without upgrading its recommendation")
      try check(optional.project.estimatedGrid != nil && optional.canAnalyze,
        "ambiguous estimate creates an initial grid")
      try check(prefs.string(forKey:"tempo.lastSuccessfulModel") == "small0","real success remembers small0")
      await optional.estimateTempo(using: .librosa)?.value
      try check(optional.error == nil && optional.currentTempoEstimate?.buttonBPMS.isEmpty == false
                  && optional.tempoEstimator == .librosa, "real librosa re-estimation provides candidates")
      try check(optional.setBPM(191), "existing tempo can be manually calibrated")
      let calibration = optional.project.timing
      guard let reestimate = optional.estimateTempo(using: .small0) else {
        throw WorkbenchError.message("Manual small0 re-estimation did not start")
      }
      try check(optional.busy && optional.estimateTempo() == nil, "manual model switch locks duplicate requests")
      await reestimate.value
      try check(optional.error == nil && optional.currentTempoEstimate?.estimator == "small0"
                  && optional.currentTempoEstimate?.buttonBPMS == [190, 95],
                "real librosa to small0 switch returns both candidates from the project audio")
      try check(optional.project.timing == calibration && optional.currentTempoEstimate?.recommendedBPM == nil,
                "manual model switch preserves calibration and requires review")
      let original=optional.project
      let cancellation=optional.estimateTempo()!
      try await wait { optional.progress >= 0.35 }
      optional.cancel();await cancellation.value
      try check(!optional.busy && optional.project == original && optional.currentTempoEstimate == nil,
        "cancel real CPU inference keeps project and clears pending result")
      print("PASS real optional worker / mixed-level candidates / remembered model / cancellation")
    }
    print("PASS T07 workflow: \(assertions) assertions")
  }
  @MainActor static func realBTC() async throws {
    let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BASS_T14_AUDIO"]!)
    let before = try Files.hash(source)
    let store = WorkbenchStore()
    try check(store.small0Available && store.btcAvailable, "both local model installations available")
    let start = Date()
    await store.importAudio(source, role: "original")?.value
    let cold = Date().timeIntervalSince(start)
    try check(store.error == nil && !store.busy && !store.showsSetupProgress, "model pipeline finishes and unlocks")
    let offset = store.project.timing.seconds(at: 0)
    try check(store.project.timing.bpm == 190 && (0.420...0.455).contains(offset),
      "What Is Love real pipeline returns 190 BPM and an offset near +0.44")
    let regions = store.project.regions
    try check(regions.count > 150 && regions.filter { $0.evidence?.method == AnalysisMethod.btcHarmony }.count == regions.count,
      "projected BTC evidence covers the grid")
    try check(regions.contains { $0.evidence?.chord != nil } && regions.allSatisfy { $0.evidence?.firstPitch == nil },
      "BTC produces chords and leaves Bass first notes separate")
    let id = regions[0].id
    store.annotate(regionID: id) { $0.chord = ""; $0.chordLocked = true; $0.firstNote = "B1" }
    var draft = AlignmentEditorDraft()
    draft.reset(project: store.project, asset: store.currentAsset)
    draft.firstBar = "0.450"
    try check(store.applyAlignmentEditor(draft) && store.freshEvidence(store.project.regions[0]) == nil,
      "manual alignment makes older evidence stale")
    let repeatStart = Date()
    await store.analyze(fullSong: true)?.value
    let warm = Date().timeIntervalSince(repeatStart)
    let first = store.project.regions[0]
    try check(store.freshEvidence(first)?.method == AnalysisMethod.btcHarmony && store.status.contains("重用音源快取"),
      "standard full-song action uses the source-time cache and updates revision")
    try check(store.analysisSummary == "已分析 \(regions.count) 區間", "full-song summary uses neutral wording")
    try check(store.chordText(first).isEmpty && first.annotation.chordLocked && first.annotation.firstNote == "B1",
      "reanalysis preserves locked blank and unlocked human note")
    try check(try ProjectStore.load(store.folder).regions == store.project.regions, "BTC and annotations persist together")
    try check(try Files.hash(source) == before, "import and analysis leave original audio bytes unchanged")
    print("Real import: BPM \(store.project.timing.bpm), offset \(offset) s, \(regions.count) regions, cold \(cold) s, reproject \(warm) s")
  }

  @MainActor static func automaticBTC(_ input: URL, _ root: URL) async throws {
    let checkout = root.appendingPathComponent("btc-probe")
    try Files.directory(checkout.appendingPathComponent("test"))
    for path in ["btc_model.py", "run_config.yaml", "test/btc_model.pt"] {
      try Data().write(to: checkout.appendingPathComponent(path))
    }
    let model = BTCInstallation(python: "/usr/bin/true", checkout: checkout.path)
    let beats = Small0Installation(python: "/usr/bin/true", checkpoint: "/dev/null")
    let fallback = TempoProbeWorker()
    let small0 = TempoProbeWorker(estimator: "small0")
    let btc = BTCProbeWorker()
    let store = WorkbenchStore(worker: fallback, optionalTempoWorker: small0, installation: beats,
      btcInstallation: model, btcWorker: btc)
    await store.importAudio(input, role: "original")?.value
    try check(small0.count == 1 && fallback.count == 0 && btc.hasTiming, "automatic flow passes downbeats and BPM to BTC")
    try check(store.project.timing.seconds(at: 0) == 0.438 && store.project.timing.bpm == 120.22,
      "applies both timing estimates")
    try check(store.project.regions.allSatisfy { $0.evidence?.chord == "C" }, "BTC candidates map to the finalized grid")
    try check(store.tempoEstimator == .librosa, "automatic small0 keeps the manual model preference")
    let ambiguous = WorkbenchStore(worker: fallback, optionalTempoWorker: small0, installation: beats,
      btcInstallation: model, btcWorker: BTCProbeWorker(offset: nil))
    await ambiguous.importAudio(input, role: "original")?.value
    try check(ambiguous.project.timing.bpm == 120.22 && ambiguous.project.timing.seconds(at: 0) == 0
      && ambiguous.project.regions.allSatisfy { $0.evidence == nil } && ambiguous.canAnalyze,
      "unresolved phase leaves chord projection for manual review")
    let delayed = BTCProbeWorker(deferred: true)
    let cancel = WorkbenchStore(worker: fallback, optionalTempoWorker: small0, installation: beats,
      btcInstallation: model, btcWorker: delayed)
    let pending = cancel.importAudio(input, role: "original")!
    try await wait { delayed.hasTiming }
    let imported = cancel.project
    try check(cancel.showsSetupProgress && cancel.activeAnalysis == .initialSong, "combined progress masks the workbench")
    cancel.cancel()
    delayed.finish()
    await pending.value
    try check(!cancel.busy && cancel.project == imported, "cancelling during BTC rejects a delayed model response")
    print("PASS automatic BTC timing / provisional fallback / cancellation")
  }
  @MainActor static func estimatorPreferences(_ input:URL,_ root:URL) async throws {
    let domain = "local.bassworkbench.tempo.tests.\(UUID().uuidString)"
    let prefs = UserDefaults(suiteName:domain)!
    defer { prefs.removePersistentDomain(forName:domain) }
    let install = Small0Installation(python:"/usr/bin/true",checkpoint:"/dev/null")
    let main = TempoProbeWorker(), small = TempoProbeWorker(estimator:"small0")
    let store = WorkbenchStore(worker:main,optionalTempoWorker:small,preferences:prefs,installation:install)
    try check(store.tempoEstimator == .librosa,"no preference defaults librosa")
    store.selectTempoEstimator(.small0)
    try check(prefs.string(forKey:"tempo.lastSuccessfulModel") == nil,"selection alone does not record successful use")
    await store.importAudio(input,role:"original")?.value
    try check(small.count == 1 && main.count == 0 && store.currentTempoEstimate?.estimator == "small0",
      "first import routes to selected optional worker")
    try check(prefs.string(forKey:"tempo.lastSuccessfulModel") == "small0","successful optional estimate remembered")
    let restored = WorkbenchStore(worker:main,optionalTempoWorker:small,preferences:prefs,installation:install)
    try check(restored.tempoEstimator == .small0,"new app store restores successful model")
    await restored.importAudio(input,role:"original")?.value
    try check(small.count == 2 && main.count == 0,"new project automatically uses remembered optional model")
    let baseline = restored.project
    await restored.estimateTempo()?.value
    try check(restored.project == baseline,"manual optional estimate preserves calibration and human data")
    let missing = WorkbenchStore(worker:main,preferences:prefs,installation:nil)
    try check(missing.tempoEstimator == .librosa && missing.tempoModelNotice != nil,"missing optional model visibly falls back")
    await missing.importAudio(input,role:"original")?.value
    try check(main.count == 1 && prefs.string(forKey:"tempo.lastSuccessfulModel") == "small0",
      "fallback request uses librosa without erasing remembered model")
    let bad = WorkbenchStore(worker:main,optionalTempoWorker:TempoProbeWorker(),preferences:prefs,installation:install)
    await bad.importAudio(input,role:"original")?.value
    try check(bad.error != nil && bad.currentTempoEstimate == nil,"wrong model metadata cannot be accepted")
    let delayed = TempoProbeWorker(deferred:true,estimator:"small0")
    let cancel = WorkbenchStore(worker:main,optionalTempoWorker:delayed,preferences:prefs,installation:install)
    let pending = cancel.importAudio(input,role:"original")!
    try await wait { delayed.count == 1 }
    let imported = cancel.project
    cancel.cancel(); delayed.finish(0)
    await pending.value
    try check(cancel.project == imported && cancel.currentTempoEstimate == nil && !cancel.busy,
      "late cancelled optional result cannot apply or change preference")
    restored.selectTempoEstimator(.librosa)
    try check(restored.currentTempoEstimate == nil,"changing models clears old displayed candidates")
    await restored.estimateTempo()?.value
    try check(prefs.string(forKey:"tempo.lastSuccessfulModel") == "librosa","successful explicit librosa choice remembered")
    print("PASS model routing / successful preference / fallback / provenance / cancellation")
  }
  @MainActor static func workflows(_ input: URL, _ root: URL) async throws {
    let worker = TempoProbeWorker()
    let store = WorkbenchStore(worker: worker)
    store.project.timing.bpm = 111.75
    try store.project.timing.setBias(0.2)
    await store.importAudio(input, role: "original")?.value
    try check(worker.count == 1 && store.currentTempoEstimate?.bpm == 120.22, "fresh initial project triggers once after successful original import")
    try check(store.project.timing.bpm == 120.22 && store.project.timing.bias == 0.2 && store.project.timing.anchors.isEmpty,
              "first original sets recommended BPM while preserving bias and beat phase")
    let first = store.project.masterAsset!
    await store.importAudio(input, role: "bass")?.value
    await store.importAudio(input, role: "original")?.value
    try check(worker.count == 1, "additional stem and original do not repeat automatic estimate")
    let before = store.project
    await store.estimateTempo()?.value
    try check(worker.count == 2 && store.project == before, "manual estimate remains available and leaves all project data unchanged")
    let ids = Set(before.regions.map(\.id))
    try check(store.applyTempoCandidate(240.44) && store.project.timing.bpm == 240.44
              && store.project.timing.bias == before.timing.bias
              && Set(store.project.regions.map(\.id)).isSuperset(of: ids),
              "one candidate press applies exact BPM and preserves existing grid IDs and bias")
    let applied = store.project
    try check(!store.applyTempoCandidate(999) && store.project == applied, "unoffered BPM cannot be applied")
    try check(store.setBPM(191.401234567) && store.project.timing.bpm == 191.401234567,
              "manual BPM retains full precision")
    store.setAssetOffset(0.4)
    // Offset belongs to selected playback source; change master too to exercise source invalidation.
    store.edit { p in p.assets[p.assets.firstIndex { $0.id == first.id }!].offset = 0.3 }
    try check(store.currentTempoEstimate == nil, "changing original offset invalidates old candidate")

    let empty = root.appendingPathComponent("existing-empty-\(UUID().uuidString).basswork")
    try ProjectStore.save(Project(), to: empty)
    store.openProject(empty)
    await store.importAudio(input, role: "original")?.value
    try check(worker.count == 2, "opening existing empty project and importing its first original does not auto estimate")
    let saved = store.folder
    store.openProject(saved)
    try check(worker.count == 2 && store.tempoEstimate == nil, "reopening existing project does not estimate")
    await store.importAudio(input, role: "original")?.value
    try check(worker.count == 2, "existing project import does not auto estimate")

    store.newProject()
    await store.importAudio(input, role: "original")?.value
    try check(worker.count == 3, "explicit new project re-enables first-original automatic estimate")
    store.undo()
    await store.importAudio(input, role: "original")?.value
    try check(worker.count == 3, "undo and reimport do not reset one-shot attempt")
    store.newProject()
    let bad = root.appendingPathComponent("invalid-audio.wav")
    try Data("invalid".utf8).write(to: bad)
    await store.importAudio(bad, role: "original")?.value
    try check(store.error != nil && worker.count == 3 && !store.busy, "failed audio decode does not start estimation")
    store.error = nil
    await store.importAudio(input, role: "original")?.value
    try check(worker.count == 4, "successful import after decode failure can still auto estimate")

    // 分析雖封鎖操作，仍以可控回應直接驗證來源／專案與 job 身分守門。
    let deferred = TempoProbeWorker(deferred: true)
    let controlled = WorkbenchStore(worker: deferred)
    let firstTask = controlled.importAudio(input, role: "original")!
    try await wait { deferred.count == 1 }
    let importedProject = controlled.project
    try check(controlled.analysisRunning && controlled.busy, "auto estimate uses cancellable locked analysis state")
    controlled.cancel()
    try check(controlled.project == importedProject && !controlled.busy && controlled.tempoEstimate == nil,
              "cancellation keeps imported original and grid")
    controlled.newProject()
    let secondTask = controlled.importAudio(input, role: "original")!
    try await wait { deferred.count == 2 }
    deferred.finish(0)
    await firstTask.value
    try check(controlled.busy && controlled.analysisRunning && controlled.tempoEstimate == nil,
              "late cancelled result cannot unlock or fill new project")
    deferred.finish(1)
    await secondTask.value
    try check(!controlled.busy && controlled.currentTempoEstimate != nil, "new project receives only its own result")
    let guarded = controlled.estimateTempo()!
    try await wait { deferred.count == 3 }
    controlled.project.assets[0].offset = 1
    deferred.finish(2)
    await guarded.value
    try check(controlled.tempoEstimate == nil && !controlled.busy, "late source-offset result rejected")
    let mismatch = controlled.estimateTempo()!
    try await wait { deferred.count == 4 }
    deferred.finish(3, wrongHash: true)
    await mismatch.value
    try check(controlled.error != nil && controlled.tempoEstimate == nil && !controlled.busy,
              "worker source hash mismatch is rejected")
    controlled.error = nil
    let failure = controlled.estimateTempo()!
    try await wait { deferred.count == 5 }
    let beforeFailure = controlled.project
    deferred.finish(4, failing: true)
    await failure.value
    try check(controlled.error != nil && controlled.project == beforeFailure && !controlled.busy,
              "worker error preserves imported audio and project")

    store.newProject()
    let xml = "<score-partwise><part-list><score-part id='P1'><part-name>Bass</part-name></score-part></part-list><part id='P1'><measure number='1'><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes><note><rest/><duration>4</duration></note></measure></part></score-partwise>"
    _ = store.project.addScore(try ScoreIO.parse(Data(xml.utf8), hash: "tempo-score"))
    store.project.timing.bpm = 137.5
    await store.importAudio(input, role: "original")?.value
    try check(store.currentTempoEstimate != nil && store.project.timing.bpm == 120.22,
              "new project with score applies initial recommended BPM")
    let context = store.project.activeContextID
    try check(store.applyTempoCandidate(60.11) && store.project.activeContextID == context
              && store.project.timing.bpm == 60.11, "candidate sets currently referenced score BPM")
    store.project.timing.anchors = [Anchor(beat: 0, seconds: 0), Anchor(beat: 4, seconds: 2)]
    let anchored = store.project
    try check(!store.applyTempoCandidate(120.22) && store.project == anchored,
              "multi-anchor BPM cannot silently accept an ineffective speed change")

    let poor = WorkbenchStore(worker: TempoProbeWorker(fitStatus: "poor"))
    await poor.importAudio(input, role: "original")?.value
    try check(poor.currentTempoEstimate?.recommendedBPM == nil && poor.autoAppliedGridBPM == 120.22
                && poor.project.timing.bpm == 120.22 && poor.canAnalyze,
              "poor first estimate creates a usable provisional grid")
    try check(poor.applyTempoCandidate(60.11) && poor.project.timing.bpm == 60.11,
              "user can replace a provisional BPM")
    poor.project.regions[0].annotation.rootLocked = true
    poor.project.regions[0].annotation.root = ""
    let region = poor.project.regions[0]
    _ = poor.setBPM(130)
    try check(poor.project.regions.contains { $0.id == region.id && $0.annotation == region.annotation },
              "direct BPM setting preserves locked human blanks")
    poor.error = nil
    let stable = poor.project
    for invalid in [Double.nan, .infinity, 19.99, 400.01] {
      try check(!poor.setBPM(invalid) && poor.project == stable, "invalid manual BPM never changes project")
    }
  }
}

final class TempoProbeWorker: AnalysisRequesting, @unchecked Sendable {
  private let lock = NSLock()
  private var requests: [(String, CheckedContinuation<Data, Error>?)] = []
  let deferred: Bool
  let fitStatus: String?
  let estimator: String?
  init(deferred: Bool = false, fitStatus: String? = nil, estimator:String? = nil) {
    self.deferred = deferred; self.fitStatus = fitStatus; self.estimator = estimator
  }
  var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
  static func response(_ hash: String, status: String? = nil, estimator:String? = nil) throws -> Data {
    var estimate = TempoEstimate(bpm: 120.22, alternatives: [60.11, 120.22, 240.44], beats: [0.5, 1],
      start: 0, end: 16, sourceHash: hash, method: "legacy-test", warnings: [])
    if let status {
      let fit = TempoFit(intercept: 0.5, medianMs: 40, p95Ms: 80, maxMs: 95, driftMs: 50,
        count: 20, span: 10, coverage: 1, outlierFraction: 0.5, status: status)
      estimate.candidates = [TempoCandidate(bpm: 120.22, originalBPM: 120.22, quantizedBPM: 120,
        usedFloat: true, multiplier: 1, fit: fit, quantizedFit: fit, originalFit: fit)]
    }
    estimate.estimator = estimator
    if estimator == "small0" {
      estimate.weightsHash = Small0Installation.weightsHash
      estimate.downbeats = [0.5, 2.5]
    }
    return try JSONEncoder().encode(estimate)
  }
  func request(_ values: [String: Any], cacheRoot: URL, progress: @escaping (Double, String) -> Void) async throws -> Data {
    let hash = (values["asset"] as! [String: Any])["hash"] as! String
    return try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      requests.append((hash, deferred ? continuation : nil))
      lock.unlock()
      if !deferred { continuation.resume(with: Result { try Self.response(hash, status: fitStatus, estimator:estimator) }) }
    }
  }
  func finish(_ index: Int, wrongHash: Bool = false, failing: Bool = false) {
    lock.lock()
    let (hash, continuation) = requests[index]
    requests[index].1 = nil
    lock.unlock()
    if failing { continuation?.resume(throwing: WorkbenchError.message("injected tempo error")) }
    else { continuation?.resume(with: Result { try Self.response(wrongHash ? "wrong" : hash, estimator:estimator) }) }
  }
  // 特意保留舊 continuation，模擬取消後才抵達的回應。
  func cancel() {}
}

final class BTCProbeWorker: AnalysisRequesting, @unchecked Sendable {
  private let lock = NSLock()
  private var timing = false
  private var completion: (() -> Void)?
  let offset: Double?
  let deferred: Bool

  init(offset: Double? = 0.438, deferred: Bool = false) { self.offset = offset; self.deferred = deferred }
  var hasTiming: Bool { lock.lock(); defer { lock.unlock() }; return timing }

  func request(_ values: [String: Any], cacheRoot: URL, progress: @escaping (Double, String) -> Void) async throws -> Data {
    let asset = values["asset"] as! [String: Any]
    let inputTiming = values["timing"] as? [String: Any]
    let step = 10.0 / 108
    let row = [1.0] + Array(repeating: 0.0, count: 24)
    var response: [String: Any] = ["method": AnalysisMethod.btcHarmony, "sourceHash": asset["hash"]!,
      "duration": 16.0, "step": step, "cached": false,
      "scores": Array(repeating: row, count: Int(ceil(16 / step)))]
    if let offset { response["firstBar"] = offset }
    let data = try JSONSerialization.data(withJSONObject: response)
    return await withCheckedContinuation { continuation in
      lock.lock()
      timing = inputTiming?["downbeats"] as? [Double] == [0.5, 2.5]
        && inputTiming?["bpm"] as? Double == 120.22
      if deferred { completion = { continuation.resume(returning: data) } }
      lock.unlock()
      if !deferred { continuation.resume(returning: data) }
    }
  }
  func finish() {
    lock.lock()
    let completion = completion
    self.completion = nil
    lock.unlock()
    completion?()
  }
  func cancel() {}
}
