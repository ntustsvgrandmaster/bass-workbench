import AppKit
import AVFoundation
import Combine
import SwiftUI

/// T01 操作鎖定回歸與 T02 調查工具，直接編譯目前產品原始碼。
/// --interactive 顯示真正 WorkbenchView，供 CUA／人工點左側小節確認。
@MainActor final class NavigationProbe: ObservableObject {
  @Published var scenario = "normal"
  @Published var note = ""
  let worker = NavigationProbeWorker()
  let store: WorkbenchStore
  let root: URL
  var records: [[String: Any]] = []
  var longNavigation = false
  var activeTask: Task<Void, Never>?

  init(root: URL) throws {
    self.root = root
    store = WorkbenchStore(worker: worker)
    try reset()
  }

  func reset() throws {
    store.cancel()
    store.transport.unload()
    store.setEditing("probe", active: false)
    store.followPlayback = false
    store.error = nil
    worker.mode = .success
    store.project = Project()
    store.analysisSummary = ""
    store.analysisExclusions = []
    store.status = "合成資料測試，與使用者專案隔離"
    store.project.title = "T02 小節導覽重現（合成資料）"
    let audio = store.folder.appendingPathComponent("probe.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
    let duration = longNavigation ? 134 : 12
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(22050 * duration))!
    buffer.frameLength = buffer.frameCapacity
    buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
    do {
      let file = try AVAudioFile(forWriting: audio, settings: format.settings)
      try file.write(from: buffer)
    }
    let asset = MediaAsset(role: "original", name: "\(duration) 秒合成靜音", originalPath: "probe.wav",
      pcmPath: "probe.wav", hash: try Files.hash(audio), duration: Double(duration), sampleRate: 22050, channels: 1)
    store.project.assets = [asset]
    store.project.selectedAsset = asset.id
    let measures = (1...(longNavigation ? 134 : 16)).map {
      "<measure number='\($0)'>\($0 == 1 ? "<attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>F</sign><line>4</line></clef></attributes>" : "")<note><pitch><step>E</step><octave>2</octave></pitch><duration>4</duration><type>whole</type></note></measure>"
    }.joined()
    let xml = "<?xml version='1.0' encoding='UTF-8'?>\n<score-partwise version='4.0'><part-list><score-part id='P1'><part-name>Bass</part-name></score-part></part-list><part id='P1'>\(measures)</part></score-partwise>"
    try Files.directory(store.folder.appendingPathComponent("originals"))
    try Data(xml.utf8).write(to: store.folder.appendingPathComponent("originals/probe.musicxml"))
    store.project.score = try ScoreIO.parse(Data(xml.utf8), xmlPath: "originals/probe.musicxml")
    store.project.selectedStaff = store.project.score!.staves[0].id
    store.project.timing.bpm = 240 // 每小節一秒；長列表情境讓全部 134 小節都有音源覆蓋。
    if scenario == "negative" { store.project.timing.biasSeconds = -3.25 }
    if scenario == "short" {
      var stem = asset
      stem.id = UUID().uuidString
      stem.role = "bass"
      stem.duration = 3
      stem.name = "3 秒合成 stem"
      stem.originalPath = "short-stem.wav"
      stem.pcmPath = "short-stem.wav"
      buffer.frameLength = 22050 * 3
      do {
        let shortFile = try AVAudioFile(forWriting: store.folder.appendingPathComponent(stem.originalPath), settings: format.settings)
        try shortFile.write(from: buffer)
      }
      stem.hash = try Files.hash(store.folder.appendingPathComponent(stem.originalPath))
      store.project.assets.append(stem)
      store.project.selectedAsset = stem.id
    }
    if scenario == "grid" { store.project.score = nil }
    store.project.regions = store.project.measures.map {
      HarmonyRegion(measureID: $0.id, startBeat: $0.beat, endBeat: $0.end)
    }
    store.project.regions[0].annotation = HumanAnnotation(root: "", chord: "manual", rootLocked: true)
    try store.transport.load(store.folder.appendingPathComponent(store.currentAsset!.originalPath))
    store.configureTransport()
    store.transport.position = 0
    store.followPlayback = true
    store.synchronizePlayback(at: 0)
    store.selectedRegionID = store.regionsInMeasure.first?.id ?? ""
    store.zoomMeasure()
    store.scoreRefresh = UUID()
    store.waveform = WaveformData(peaks: Array(repeating: 0, count: Int(store.currentAsset!.duration * 100)), duration: store.currentAsset!.duration)
    store.persist()
    note = "情境：\(scenario)"
  }

  func begin(_ mode: NavigationProbeWorker.Mode) {
    worker.mode = mode
    activeTask = store.analyze()
  }

  func snapshot() -> [String: Any] {
    ["pid": ProcessInfo.processInfo.processIdentifier, "scenario": scenario, "selectedIndex": store.project.selectedMeasure,
     "selectedNumber": store.measure.number, "measureCount": store.project.measures.count, "playbackIndex": store.playbackMeasure ?? -1,
     "position": store.transport.position, "busy": store.busy, "analysisRunning": store.analysisRunning,
     "activeAnalysis": store.activeAnalysis?.rawValue ?? "", "folder": store.folder.path,
     "playing": store.transport.playing, "editing": store.editingPlaybackSelection,
     "regionBelongsToMeasure": store.currentRegion?.measureID == store.measure.id,
     "a": store.project.a, "b": store.project.b, "loop": store.project.loop,
     "status": store.status, "error": store.error ?? ""]
  }

  func saveState() {
    if let data = try? JSONSerialization.data(withJSONObject: snapshot(), options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: root.appendingPathComponent("state.json"), options: .atomic)
    }
  }
}

@MainActor final class NavigationProbeWorker: @preconcurrency AnalysisRequesting {
  enum Mode { case success, failure, held }
  var mode = Mode.success
  var realWorker: AnalysisWorker?
  struct HeldRequest {
    let continuation: CheckedContinuation<Data, Error>
    let values: [String: Any]
    let progress: (Double, String) -> Void
  }
  private(set) var pending: HeldRequest?
  var deferCancellation = false
  private var cancelled: [HeldRequest] = []

  func request(_ values: [String: Any], cacheRoot: URL,
               progress: @escaping (Double, String) -> Void) async throws -> Data {
    if let realWorker { return try await realWorker.request(values, cacheRoot: cacheRoot, progress: progress) }
    if mode == .failure { throw WorkbenchError.message("合成 Worker 的可控錯誤") }
    if mode == .held {
      return try await withCheckedThrowingContinuation {
        pending = HeldRequest(continuation: $0, values: values, progress: progress)
      }
    }
    return try result(values)
  }

  func result(_ values: [String: Any]) throws -> Data {
    if values["op"] as? String == "tempo" {
      return try JSONEncoder().encode(TempoEstimate(bpm: 120, alternatives: [60, 120, 240],
        beats: [0, 0.5, 1, 1.5], start: 0, end: 12,
        sourceHash: (values["asset"] as! [String: Any])["hash"] as! String,
        method: "probe-tempo", warnings: ["合成估測"]))
    }
    let start = values["start"] as! Double
    if values["op"] as? String == "features" {
      let binary = URL(fileURLWithPath: values["cache"] as! String).appendingPathComponent("probe.f32")
      try Files.directory(binary.deletingLastPathComponent())
      let rows = ((values["maxMIDI"] as! Int) - (values["minMIDI"] as! Int)) * (values["binsPerOctave"] as! Int) / 12 + 1
      let floats = [Float](repeating: -80, count: rows * 2)
      try floats.withUnsafeBytes { try Data($0).write(to: binary) }
      let features = AnalysisFeatures(cacheKey: "probe", method: SpectrumCache.method, sampleRate: 22050,
        hop: 256, start: start, end: values["end"] as! Double, frameOrigin: start,
        binsPerOctave: values["binsPerOctave"] as! Int, minMIDI: values["minMIDI"] as! Int,
        maxMIDI: values["maxMIDI"] as! Int, rows: rows, columns: 2, binaryPath: binary.path,
        onsets: [], lowWindowSeconds: 1, tuningCents: 0, elapsed: 0, cacheHit: false,
        warnings: ["合成 Worker，僅用於操作狀態重現"], sourceHash: (values["asset"] as! [String: Any])["hash"] as! String)
      return try JSONEncoder().encode(features)
    }
    let e = HarmonyEvidence(firstPitch: nil, firstTime: nil, firstScore: 0, bassCenter: nil,
      bassStrongBeat: nil, root: nil, chord: nil, rootMargin: 0, candidates: [], chroma: [],
      warnings: ["合成 Worker"], arrangementSource: (values["arrangement"] as! [String: Any])["hash"] as! String,
      bassSource: (values["bass"] as! [String: Any])["hash"] as! String,
      method: values["method"] as? String ?? AnalysisMethod.harmony,
      timingRevision: values["timingRevision"] as! Int, createdAt: "probe")
    return try JSONEncoder().encode(e)
  }

  func finish() {
    mode = .success
    let p = pending; pending = nil
    if let p { p.continuation.resume(with: Result { try result(p.values) }) }
  }
  func fail() {
    let p = pending; pending = nil
    p?.continuation.resume(throwing: WorkbenchError.message("合成 Worker 的可控錯誤"))
  }
  func cancel() {
    realWorker?.cancel()
    let p = pending; pending = nil
    if let p {
      if deferCancellation { cancelled.append(p) }
      else { p.continuation.resume(throwing: CancellationError()) }
    }
  }
  func finishCancelled(failing: Bool) {
    let p = cancelled.removeFirst()
    p.progress(1, "舊工作遲到進度")
    if failing { p.continuation.resume(throwing: WorkbenchError.message("舊工作遲到錯誤")) }
    else { p.continuation.resume(with: Result { try result(p.values) }) }
  }
}

struct NavigationProbeRoot: View {
  @ObservedObject var probe: NavigationProbe
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("T02 重現工具")
        Picker("情境", selection: $probe.scenario) {
          Text("一般有譜").tag("normal")
          Text("無譜格線").tag("grid")
          Text("負起點 -3.25s").tag("negative")
          Text("短 stem 範圍").tag("short")
        }.frame(width: 220)
        Button("重設情境") { do { try probe.reset() } catch { probe.note = error.localizedDescription } }
        Button("成功分析") { probe.begin(.success) }
        Button("失敗分析") { probe.begin(.failure) }
        Button("保持分析中") { probe.begin(.held) }
        Button("釋放分析") { probe.worker.finish() }
        Button("取消分析") { probe.store.cancel() }
      }.padding(8)
      WorkbenchView().environmentObject(probe.store)
    }
  }
}

@main struct NavigationReproductionTests {
  static var analysisAssertions = 0
  @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    analysisAssertions += 1
    guard condition() else { throw WorkbenchError.message("T01 FAILED: \(message)") }
  }
  @MainActor static func spin(until condition: () -> Bool, timeout: Double = 5) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    guard condition() else { throw WorkbenchError.message("probe condition timed out") }
  }

  @MainActor static func matrix(_ p: NavigationProbe) throws {
    func record(_ name: String, _ target: Int, expectedBug: Bool = false) throws {
      var changes: [Int] = []
      let observation = p.store.$project.map(\.selectedMeasure).removeDuplicates().sink { changes.append($0) }
      let before = p.store.project.selectedMeasure
      p.store.navigate(target)
      let actual = p.store.project.selectedMeasure
      var row = p.snapshot()
      row["case"] = name; row["targetIndex"] = target; row["beforeIndex"] = before
      row["selectionEvents"] = changes; row["reproduced"] = actual != target
      p.records.append(row)
      observation.cancel()
      print("\(actual == target ? "NORMAL" : "REPRODUCED") \(name): target=\(target + 1) actual=\(actual + 1) pos=\(p.store.transport.position) events=\(changes)")
      if (actual != target) != expectedBug { throw WorkbenchError.message("unexpected characterization: \(name)") }
      guard p.store.currentRegion?.measureID == p.store.measure.id else { throw WorkbenchError.message("region disagrees") }
    }
    for scenario in ["normal", "grid"] {
      p.scenario = scenario
      try p.reset()
      try record("\(scenario)-baseline", 3)
      p.begin(.success)
      try spin(until: { !p.store.busy })
      try record("\(scenario)-after-success", 5)
      p.begin(.held)
      try spin(until: { p.worker.pending != nil })
      let before = p.store.project.selectedMeasure
      p.store.navigate(2)
      guard p.store.project.selectedMeasure == before else { throw WorkbenchError.message("busy navigation was not blocked") }
      p.store.cancel()
      try record("\(scenario)-after-cancel", 2)
      p.begin(.failure)
      try spin(until: { !p.store.busy })
      guard p.store.error != nil else { throw WorkbenchError.message("expected worker error") }
      p.store.error = nil
      try record("\(scenario)-after-failure", 4)
      p.store.followPlayback = false
      try record("\(scenario)-follow-off", 6)
      p.store.followPlayback = true
      p.store.setEditing("probe", active: true)
      try record("\(scenario)-editing", 1)
      p.store.setEditing("probe", active: false)
      _ = p.store.setLoop(a: 2, b: 8, enable: true)
      try record("\(scenario)-loop", 4)
      guard p.store.project.a == 2 && p.store.project.b == 8 && p.store.project.loop else { throw WorkbenchError.message("loop changed") }
    }
    for outcome in ["success", "cancel", "failure"] {
      p.scenario = "normal"; try p.reset()
      p.store.playPause()
      if !p.store.transport.playing {
        let error = p.store.error ?? "unknown audio error"
        p.records.append(["case": "playing-after-\(outcome)", "skipped": true, "reason": error])
        print("SKIP playing-after-\(outcome): \(error)")
        continue
      }
      p.begin(.held)
      try spin(until: { p.worker.pending != nil })
      try check(!p.store.transport.playing, "analysis pauses actual playback before Worker returns")
      if outcome == "success" { p.worker.finish() }
      else if outcome == "cancel" { p.store.cancel() }
      else { p.worker.fail() }
      try spin(until: { !p.store.busy })
      p.store.error = nil
      try record("playing-after-\(outcome)", 5)
    }
    p.scenario = "normal"; try p.reset()
    try record("score-after-audio-end", 14, expectedBug: true)
    p.scenario = "short"; try p.reset()
    try record("short-source", 6, expectedBug: true)
    p.scenario = "negative"; try p.reset()
    try record("negative-start", 0, expectedBug: true)
    p.begin(.success)
    try spin(until: { !p.store.busy })
    try record("negative-after-success", 1, expectedBug: true)
    p.store.followPlayback = false
    try record("negative-follow-off-control", 0)
    if CommandLine.arguments.contains("--real-worker") {
      p.scenario = "normal"; try p.reset()
      p.worker.realWorker = AnalysisWorker()
      p.begin(.success)
      try spin(until: { !p.store.busy }, timeout: 120)
      guard p.store.error == nil, p.store.spectrum != nil,
        p.store.project.regions[0].evidence != nil else {
        throw WorkbenchError.message("real worker did not complete: \(p.store.error ?? "missing data")")
      }
      try record("real-worker-after-success", 5)
      p.worker.realWorker?.cancel()
      p.worker.realWorker = nil
    }
    try JSONSerialization.data(withJSONObject: p.records, options: [.prettyPrinted, .sortedKeys])
      .write(to: p.root.appendingPathComponent("matrix.json"))
    print("CHARACTERIZATION COMPLETE: \(p.records.count) cases; T02 known boundary bugs remain")
  }

  @MainActor static func analysisTests(_ p: NavigationProbe) throws {
    let store = p.store
    for kind in [WorkbenchStore.AnalysisKind.range, .song, .tempo] {
      for outcome in ["success", "failure", "cancel"] {
        p.scenario = "normal"; try p.reset()
        store.playPause()
        try check(store.transport.playing, "actual playback starts before \(kind)")
        p.worker.mode = .held
        let task = kind == .tempo ? store.estimateTempo() : store.analyze(fullSong: kind == .song)
        try check(store.busy && store.activeAnalysis == kind && !store.transport.playing,
                  "\(kind) locks and pauses synchronously")
        try spin(until: { p.worker.pending != nil })
        let original = store.project
        let position = store.transport.position
        let region = store.selectedRegionID
        let viewport = [store.viewportStart, store.viewportEnd]
        let follow = store.followPlayback
        let note = store.selectedNoteID
        let status = store.status
        let canUndo = store.canUndo, canRedo = store.canRedo
        store.playPause(); store.seek(7)
        store.navigate(5); store.selectRegion(store.project.regions[5].id)
        _ = store.setLoop(a: 2, b: 8, enable: true); store.setLoopEnabled(true)
        store.setPlaybackRate(0.5); store.setFollowPlayback(!follow); store.setContrast(40)
        store.edit { $0.title = "blocked" }; _ = store.renameProject("blocked")
        store.annotate { $0.root = "D" }; store.setBPM(90); store.setAssetOffset(1)
        store.setAnchor(); store.removeAnchor("missing")
        store.zoom(0.5); store.zoomMeasure(); store.zoomLoop()
        if let n = store.project.score?.notes.first { store.auditionNote(n) }
        _ = store.applyAlignment(TimingMap(bpm: 90))
        _ = store.applyEstimatedGrid(GridInput(bpm: 90, numerator: 3, denominator: 4, firstBar: 1))
        store.loadAsset(store.currentAsset!.id); store.clearCache()
        store.undo(); store.redo(); store.save(); store.saveAs(); store.revealAutosave()
        store.exportAnalysis(); store.exportCSV(); store.exportMusicXML(); store.editInMuseScore()
        store.newProject(); store.openProject(store.folder)
        try check(store.analyze() == nil && store.estimateTempo() == nil, "no second job")
        try check(store.project == original, "\(kind): blocked commands preserve entire project")
        try check(!store.transport.playing && store.transport.position == position,
                  "\(kind): playback and seek cannot bypass lock")
        try check(store.selectedRegionID == region && store.selectedNoteID == note
                  && [store.viewportStart, store.viewportEnd] == viewport && store.followPlayback == follow,
                  "\(kind): selection, follow and viewport remain fixed")
        try check(store.status == status && store.error == nil
                  && store.canUndo == canUndo && store.canRedo == canRedo,
                  "blocked commands do not change history or open dialogs")
        if outcome == "success" { p.worker.finish() }
        else if outcome == "failure" { p.worker.fail() }
        else { store.cancel() }
        try spin(until: { !store.busy })
        try check(!store.analysisRunning && store.activeAnalysis == nil && !store.transport.playing,
                  "\(kind)-\(outcome): cleanup unlocks without resuming")
        try check(store.project.regions.map(\.annotation) == original.regions.map(\.annotation),
                  "\(kind)-\(outcome): locked blank and manual text survive")
        store.error = nil
        store.navigate(5)
        try check(store.project.selectedMeasure == 5 && store.transport.position == 5,
                  "\(kind)-\(outcome): navigation usable again")
        withExtendedLifetime(task) {}
      }
    }
    // 準備真正可 undo 與 redo 的歷史，確認鎖定不能先 pop 再退出。
    p.scenario = "normal"; try p.reset()
    let title = store.project.title
    _ = store.renameProject("history")
    p.begin(.held); try spin(until: { p.worker.pending != nil })
    store.undo(); store.cancel(); store.undo()
    try check(store.project.title == title, "blocked undo does not consume history")
    p.begin(.held); try spin(until: { p.worker.pending != nil })
    store.redo(); store.cancel(); store.redo()
    try check(store.project.title == "history", "blocked redo does not consume history")
    // 取消後立刻開新工作，再讓舊工作回報進度／成功／錯誤，不得解鎖或改寫。
    for failing in [false, true] {
      p.scenario = "normal"; try p.reset()
      p.worker.deferCancellation = true
      p.begin(.held); try spin(until: { p.worker.pending != nil })
      store.cancel()
      p.begin(.held); try spin(until: { p.worker.pending != nil })
      let original = store.project, status = store.status, progress = store.progress
      p.worker.finishCancelled(failing: failing)
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      try check(store.busy && store.analysisRunning && store.project == original
                && store.status == status && store.progress == progress && store.error == nil,
                "late old response cannot unlock, publish progress or overwrite new job")
      p.worker.deferCancellation = false
      store.cancel()
    }
    print("PASS T01: \(analysisAssertions) assertions (pause / locked commands / three kinds × three outcomes / stale jobs)")
  }

  @MainActor static func main() throws {
    guard let path = ProcessInfo.processInfo.environment["BASS_DATA_ROOT"] else {
      throw WorkbenchError.message("Specify disposable BASS_DATA_ROOT")
    }
    // 不污染使用者的上次專案設定；測試有獨立 bundle ID。
    UserDefaults.standard.removeObject(forKey: "lastProject")
    let root = URL(fileURLWithPath: path).appendingPathComponent("results")
    try Files.directory(root)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let probe = try NavigationProbe(root: root)
    let projectArgument = CommandLine.arguments.firstIndex(of: "--project")
    if let index = projectArgument {
      guard CommandLine.arguments.indices.contains(index + 1) else {
        throw WorkbenchError.message("--project requires a disposable local copy")
      }
      let project = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL.resolvingSymlinksInPath()
      let dataRoot = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
      guard project.path.hasPrefix(dataRoot.path + "/") else {
        throw WorkbenchError.message("Project must be a copy inside disposable BASS_DATA_ROOT")
      }
      probe.store.openProject(project)
      guard probe.store.error == nil else { throw WorkbenchError.message(probe.store.error!) }
      if CommandLine.arguments.contains("--real-worker") { probe.worker.realWorker = AnalysisWorker() }
    } else {
      try analysisTests(probe)
      try matrix(probe)
    }
    guard CommandLine.arguments.contains("--interactive") else { return }
    probe.longNavigation = CommandLine.arguments.contains("--long-navigation")
    if projectArgument == nil { probe.scenario = "normal"; try probe.reset() }
    let host = NSHostingView(rootView: NavigationProbeRoot(probe: probe))
    let window = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 1340, height: 960),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = projectArgument == nil ? "T02 小節導覽重現 · 合成資料" : "T02 小節導覽重現 · 本機專案副本"
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    // 只觀察本測試視窗收到的實際滑鼠事件；不合成或改寫輸入。
    var mouseRecords: [[String: Any]] = []
    let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
      guard event.window === window else { return event }
      MainActor.assumeIsolated {
        let kind = event.type == .leftMouseDown ? "down" : "up"
        let point = event.locationInWindow
        DispatchQueue.main.async {
          var row = probe.snapshot()
          row["mouseEvent"] = kind
          row["windowX"] = point.x
          row["windowY"] = point.y
          mouseRecords.append(row)
          if let data = try? JSONSerialization.data(withJSONObject: mouseRecords, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("mouse-events.json"), options: .atomic)
          }
        }
      }
      return event
    }
    var previous = Data()
    let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
      Task { @MainActor in
        let data = (try? JSONSerialization.data(withJSONObject: probe.snapshot(), options: [.sortedKeys])) ?? Data()
        if data != previous { previous = data; probe.saveState() }
      }
    }
    probe.saveState()
    if CommandLine.arguments.contains("--replay-analysis") {
      // 只驅動本測試視窗的模型，讓真正 SwiftUI 在播放與分析狀態間更新。
      // 不使用外部輸入注入；輸出限於 BASS_DATA_ROOT 下的調查紀錄。
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 500_000_000)
        probe.store.navigate(min(36, probe.store.project.measures.count - 1))
        try? await Task.sleep(nanoseconds: 500_000_000)
        probe.store.playPause()
        var replay = [probe.snapshot()]
        probe.begin(.held)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        replay.append(probe.snapshot())
        probe.worker.finish()
        while probe.store.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        probe.store.transport.stop()
        replay.append(probe.snapshot())
        if let data = try? JSONSerialization.data(withJSONObject: replay, options: [.prettyPrinted, .sortedKeys]) {
          try? data.write(to: root.appendingPathComponent("replay.json"), options: .atomic)
        }
        probe.saveState()
      }
    }
    print("READY T02 test window; state: \(root.appendingPathComponent("state.json").path)")
    fflush(stdout)
    let timeout = Timer.scheduledTimer(withTimeInterval: 1200, repeats: false) { _ in
      Task { @MainActor in NSApplication.shared.terminate(nil) }
    }
    // NSApplication.run 才會分派真正的滑鼠事件；只有 RunLoop 會漏掉這一層，
    // 雖可執行 accessibility 的按鈕動作，卻不能據此驗證灰底的滑鼠命中範圍。
    app.run()
    timeout.invalidate()
    timer.invalidate()
    if let monitor { NSEvent.removeMonitor(monitor) }
    probe.store.cancel()
    probe.store.transport.unload()
    window.orderOut(nil)
  }
}
