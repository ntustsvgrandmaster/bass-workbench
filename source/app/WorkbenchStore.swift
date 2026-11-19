// 應用協調層：把 UI 動作轉成專案編輯、播放、匯入或分析。演算法本體在 worker/analysis.py。

import Combine
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  static let bassProject = UTType(exportedAs: "local.bassworkbench.project", conformingTo: .package)
}

/// 所有 Published 狀態與人工編輯都在 MainActor；昂貴的讀檔／解碼交給背景任務。
@MainActor final class WorkbenchStore: ObservableObject, DraftEditing {
  enum AnalysisKind: String {
    case range = "範圍分析", song = "全曲分析", tempo = "BPM／拍點估測"
    case initialSong = "速度、起點與和弦估測", btcSong = "全曲和弦分析"
    case calibrationSpectrum = "校正範圍能量分析"
  }
  struct NavigationScrollRequest: Equatable {
    let index: Int
    let token = UUID()
  }
  struct AlignmentRevealRequest: Equatable {
    let id = UUID()
    var initialEstimate = false
  }
  @Published var project = Project() {
    didSet {
      if project.selectedMeasure != oldValue.selectedMeasure, !navigatingMeasure {
        requestNavigationScroll()
      }
    }
  }
  @Published private(set) var navigationScrollRequest: NavigationScrollRequest?
  @Published var folder: URL
  @Published var waveform: WaveformData?
  @Published private(set) var spectrumSegments: [SpectrumData] = []
  var spectrum: SpectrumData? { spectrumSegments.first }
  @Published private(set) var spectrumLoading = false
  private var spectrumContext: (query: SpectrumCache.Query, directory: URL)?
  @Published var busy = false {
    didSet { if !busy { synchronizePlayback(at: transport.position, followViewport: false) } }
  }
  @Published private(set) var scoreUpdating = false
  @Published private(set) var activeAnalysis: AnalysisKind?
  var analysisRunning: Bool { activeAnalysis != nil }
  @Published var tempoEstimate: TempoEstimate? {
    didSet { if tempoEstimate == nil { tempoEstimateAsset = nil } }
  }
  private var tempoEstimateAsset: MediaAsset?
  @Published private(set) var tempoEstimator: TempoEstimator = .librosa
  @Published private(set) var tempoModelNotice: String?
  let small0Installation: Small0Installation?
  var small0Available: Bool { small0Installation?.available == true }
  private let tempoPreferences: UserDefaults
  private let optionalTempoWorker: AnalysisRequesting?
  private let btcInstallation: BTCInstallation?
  private let btcWorker: AnalysisRequesting?
  var btcAvailable: Bool { btcInstallation?.available == true && btcWorker != nil }
  func selectTempoEstimator(_ model: TempoEstimator) {
    guard !busy else { return }
    guard model != .small0 || small0Available else {
      tempoModelNotice = "small0 尚未安裝，請先使用 librosa。"; return
    }
    tempoEstimator = model; tempoEstimate = nil; tempoModelNotice = nil
  }
  // 只在這個 Store 新建的專案首次成功匯入原音後嘗試一次；不隨 undo 重置。
  private var freshProjectID: String?
  private var autoTempoAttempted = false
  var currentTempoEstimate: TempoEstimate? {
    guard tempoEstimateAsset == project.masterAsset,
      let value = tempoEstimate, value.sourceHash == project.masterAsset?.hash else { return nil }
    return value
  }
  @Published var analysisSummary = ""
  @Published var analysisExclusions: [String] = []
  @Published var progress: Double = 0
  @Published var status = "準備開始 · 本機分析，不上傳音源"
  @Published var error: String?
  @Published var log: [String] = []
  @Published var viewportStart: Double = 0
  @Published var viewportEnd: Double = 4
  @Published private(set) var viewportMode: ViewportMode = .measure
  @Published private(set) var firstBarPreview: Double?
  private var firstBarPreviewReturn: (project: String, context: String, asset: String, range: ViewportRange)?
  @Published var selectedRegionID = ""
  @Published var selectedNoteID: String?
  @Published var scoreRefresh = UUID()
  @Published var showAssetImport = false
  @Published var importRole = "original"
  @Published var sourceImportWarnings: [String] = []
  @Published var followPlayback = true {
    didSet { if followPlayback { synchronizePlayback(at: transport.position) } }
  }
  @Published private(set) var playbackMeasure: Int?
  @Published private(set) var editingPlaybackSelection = false
  let transport = Transport()
  private let worker: AnalysisRequesting
  private let regionAnalysis: RegionAnalysis
  @Published private var undoStack: [Project] = []
  @Published private var redoStack: [Project] = []
  // job 是本層的取消憑證；它與 AnalysisWorker 的程序 generation 各自防止遲到結果寫入。
  private var job = UUID()
  private var spectrumLoad: Task<Void, Never>?
  private var playbackObservation: AnyCancellable?
  private var editingScopes: Set<String> = []
  // navigate 的 stop／seek 也會同步回報 position；整段操作只在結尾決定是否捲動。
  private var navigatingMeasure = false
  private var switchingScoreContext = false
  private var namedProject = false
  private var saveFailed = false
  var measure: ScoreMeasure {
    project.measures[min(max(0, project.selectedMeasure), project.measures.count - 1)]
  }
  @Published private(set) var importingFirstOriginal = false
  @Published private var initialGridBPM: Double?
  @Published private(set) var alignmentRevealRequest = AlignmentRevealRequest()

  var showsSetupProgress: Bool {
    importingFirstOriginal || activeAnalysis == .tempo || activeAnalysis == .initialSong
  }
  var autoAppliedGridBPM: Double? {
    guard project.score == nil, project.estimatedGrid != nil,
      let bpm = initialGridBPM, bpm == project.timing.bpm,
      currentTempoEstimate?.preferredBPM == bpm else { return nil }
    return bpm
  }
  func reviewAlignment() {
    alignmentRevealRequest = AlignmentRevealRequest()
  }

  @Published var hasPendingAlignmentDraft = false

  var analysisUnavailableReason: String? {
    if currentAsset == nil { return "先匯入原曲或其他音源。" }
    if hasPendingAlignmentDraft || firstBarPreview != nil { return "請先確認或取消時間對齊草稿。" }
    if project.requiresAlignmentConfirmation {
      return project.score == nil
        ? "請先確認速度、拍號與起點，建立小節格線。"
        : "請先在速度與時間對齊確認設定。"
    }
    return nil
  }
  var canAnalyze: Bool { !busy && analysisUnavailableReason == nil }
  var showsMeasureNavigation: Bool {
    project.score != nil || (!project.assets.isEmpty && !project.requiresAlignmentConfirmation)
  }

  var currentAsset: MediaAsset? {
    project.assets.first { $0.id == project.selectedAsset } ?? project.assets.first
  }
  var analysisSources: (chart: MediaAsset, harmony: MediaAsset, bass: MediaAsset)? {
    guard let asset = currentAsset else { return nil }
    let arrangement = project.assets.first(where: { $0.id == project.harmonyAsset })
      ?? project.assets.first(where: { $0.role == "accompaniment" })
      ?? project.assets.first(where: { $0.role == "original" }) ?? asset
    let bass = project.assets.first(where: { $0.id == project.bassAsset })
      ?? project.assets.first(where: { $0.role == "bass" }) ?? asset
    return (asset, arrangement, bass)
  }
  var currentRegion: HarmonyRegion? {
    project.regions.first { $0.id == selectedRegionID } ?? regionsInMeasure.first
  }
  var regionsInMeasure: [HarmonyRegion] {
    project.regions.filter { $0.measureID == measure.id }.sorted { $0.startBeat < $1.startBeat }
  }
  var notes: [ScoreNote] {
    project.score?.notes.filter {
      $0.staffID == project.selectedStaff && $0.measureID == measure.id
    } ?? []
  }
  var firstScoreNote: ScoreNote? { notes.first { $0.kind != "rest" && $0.kind != "grace" } }
  var canUndo: Bool { !undoStack.isEmpty }
  var canRedo: Bool { !redoStack.isEmpty }
  var isEstimated: Bool { !project.timing.calibrated }
  var playbackMeasureNumber: String {
    let measures = project.measures
    guard !measures.isEmpty else { return "—" }
    return measures[min(max(0, playbackMeasure ?? project.selectedMeasure), measures.count - 1)]
      .number
  }
  var support: URL {
    ProcessInfo.processInfo.environment["BASS_DATA_ROOT"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("BassHarmony")
  }
  init(worker: AnalysisRequesting = AnalysisWorker(), optionalTempoWorker: AnalysisRequesting? = nil,
       preferences: UserDefaults? = nil, installation: Small0Installation? = Small0Installation.discover(),
       btcInstallation: BTCInstallation? = BTCInstallation.discover(), btcWorker: AnalysisRequesting? = nil) {
    let preferenceDomain = ProcessInfo.processInfo.environment["BASS_DATA_ROOT"] == nil
      ? "local.bassworkbench.tempo" : "local.bassworkbench.tempo.tests"
    let preferences = preferences ?? UserDefaults(suiteName:preferenceDomain)!
    tempoPreferences = preferences
    small0Installation = installation
    let requested = TempoEstimator(rawValue: preferences.string(forKey: "tempo.lastSuccessfulModel") ?? "librosa") ?? .librosa
    tempoEstimator = requested == .small0 && installation?.available != true ? .librosa : requested
    if requested == .small0 && installation?.available != true {
      tempoModelNotice = "上次使用的 small0 目前不可用，這次改用 librosa。"
    }
    let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let mainScript = ProcessInfo.processInfo.environment["BASS_WORKER_SCRIPT"].map { URL(fileURLWithPath: $0) }
      ?? resources.appendingPathComponent("worker/main.py")
    let scripts = mainScript.deletingLastPathComponent()
    if let optionalTempoWorker { self.optionalTempoWorker = optionalTempoWorker }
    else if let installation {
      self.optionalTempoWorker = AnalysisWorker(python:URL(fileURLWithPath:installation.python),
        script:scripts.appendingPathComponent("beat_this_tempo.py"),oneShot:true)
    } else { self.optionalTempoWorker = nil }
    self.btcInstallation = btcInstallation
    self.btcWorker = btcWorker ?? btcInstallation.map {
      AnalysisWorker(python: URL(fileURLWithPath: $0.python),
        script: scripts.appendingPathComponent("btc_song.py"), oneShot: true)
    }
    self.worker = worker
    self.regionAnalysis = RegionAnalysis(worker: worker)
    let base =
      ProcessInfo.processInfo.environment["BASS_DATA_ROOT"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("BassHarmony")
    folder = base.appendingPathComponent("sessions/\(UUID().uuidString).basswork")
    freshProjectID = project.id
    do {
      try Files.directory(folder)
      try ProjectStore.save(project, to: folder)
    } catch { self.error = error.localizedDescription }
    playbackObservation = transport.$position.sink { [weak self] second in
      self?.synchronizePlayback(at: second)
    }
  }
  /// 小節／和聲在邊界更新；手動取景只在游標離開畫面時平移，不停止播放或改寫循環。
  func synchronizePlayback(at second: Double, followViewport: Bool = true) {
    guard second.isFinite, currentAsset != nil else { return }
    let measures = project.measures
    guard !measures.isEmpty else { return }
    let beat = project.timing.beat(at: second)
    guard let index = PlaybackTimeline.measureIndex(at: second, timing: project.timing, measures: measures) else { return }
    if playbackMeasure != index { playbackMeasure = index }
    guard followPlayback, !editingPlaybackSelection, firstBarPreview == nil, !busy, !switchingScoreContext else { return }
    let selectionChanged = project.selectedMeasure != index
    if selectionChanged {
      project.selectedMeasure = index
      selectedNoteID = nil
    }
    let moveViewport: Bool
    switch viewportMode {
    case .measure: moveViewport = selectionChanged
    case .manual: moveViewport = followViewport
    case .loop: moveViewport = false
    case .loopZoom(let indices):
      moveViewport = !indices.contains(index) && second >= project.a && second < project.b
    }
    if !navigatingMeasure, moveViewport {
      refreshViewport(at: second)
    }
    let region =
      regionsInMeasure.first { $0.startBeat <= beat + 0.0000001 && $0.endBeat > beat + 0.0000001 }
      ?? regionsInMeasure.last
    let regionID = region?.id ?? ""
    if selectedRegionID != regionID { selectedRegionID = regionID }
  }

  func setEditing(_ scope: String, active: Bool) {
    updateEditingScope(scope, active: active)
    if !editingPlaybackSelection {
      synchronizePlayback(at: transport.position, followViewport: false)
    }
  }
  func setAlignmentEditing(active: Bool) {
    updateEditingScope("alignment", active: active)
  }
  private func updateEditingScope(_ scope: String, active: Bool) {
    if active { editingScopes.insert(scope) } else { editingScopes.remove(scope) }
    editingPlaybackSelection = !editingScopes.isEmpty
  }

  @discardableResult func renameProject(_ title: String) -> Bool {
    let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !busy, !value.isEmpty else { return false }
    if value != project.title { edit { $0.title = value } }
    return true
  }

  func record(_ message: String) {
    status = message
    log.insert(message, at: 0)
    if log.count > 40 { log.removeLast() }
  }

  func persist() {
    do {
      try ProjectStore.save(project, to: folder)
      saveFailed = false
      UserDefaults.standard.set(folder.path, forKey: "lastProject")
    } catch {
      saveFailed = true
      self.error = "專案未能儲存：\(error.localizedDescription)"
    }
  }

  /// 統一的人工／專案編輯入口：記錄 undo 快照並自動保存。自動 Evidence 更新不走此入口。
  func edit(_ operation: (inout Project) -> Void) {
    guard !analysisRunning else { return }
    let oldTiming = project.timing
    let oldMaster = project.masterAsset
    let oldScore = project.score?.sourceHash
    let oldSources = (project.assets, project.harmonyAsset, project.bassAsset)
    undoStack.append(project)
    if undoStack.count > 40 { undoStack.removeFirst() }
    redoStack = []
    operation(&project)
    if oldSources.0 != project.assets || oldSources.1 != project.harmonyAsset || oldSources.2 != project.bassAsset {
      // 分析來源是專案共用設定；非作用中譜也不能把舊來源結果當成當前答案。
      for i in project.scoreContexts.indices { project.scoreContexts[i].timing.revision += 1 }
    }
    if oldMaster != project.masterAsset { tempoEstimate = nil }
    if oldTiming != project.timing || oldMaster != project.masterAsset || oldScore != project.score?.sourceHash {
      analysisSummary = ""
      analysisExclusions = []
    }
    persist()
  }
  func undo() {
    guard !busy, let p = undoStack.popLast() else { return }
    redoStack.append(project)
    restore(p)
  }
  func redo() {
    guard !busy, let p = redoStack.popLast() else { return }
    undoStack.append(project)
    restore(p)
  }
  private func restore(_ p: Project) {
    switchingScoreContext = true
    defer { switchingScoreContext = false }
    let oldAsset = project.selectedAsset
    let oldContext = project.activeContextID
    let oldScore = project.score?.revision
    if oldContext != p.activeContextID { transport.stop() }
    project = p
    tempoEstimate = nil
    analysisSummary = ""
    analysisExclusions = []
    persist()
    configureTransport()
    if oldAsset != p.selectedAsset { loadAsset(p.selectedAsset) }
    if oldContext != p.activeContextID {
      finishScoreTransition()
    } else {
      if oldScore != p.score?.revision { finishScoreRefresh() }
      refreshViewport(refreshCache: true)
    }
    selectedRegionID = regionsInMeasure.first?.id ?? ""
  }
  func newProject() {
    guard !busy else { return }
    persist()
    transport.unload()
    folder = support.appendingPathComponent("sessions/\(UUID().uuidString).basswork")
    project = Project()
    freshProjectID = project.id
    autoTempoAttempted = false
    tempoEstimate = nil
    analysisSummary = ""
    analysisExclusions = []
    waveform = nil
    spectrumSegments = []
    selectedRegionID = ""
    undoStack = []
    redoStack = []
    namedProject = false
    playbackMeasure = nil
    persist()
    zoomMeasure()
    scoreRefresh = UUID()
    record("新專案已建立，編輯會自動儲存")
  }
  func chooseAudio(role: String? = nil) {
    importRole = role ?? (project.assets.isEmpty ? "original" : "bass")
    showAssetImport = true
  }
  func selectAudio() {
    showAssetImport = false
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio]
    panel.allowsOtherFileTypes = true
    if panel.runModal() == .OK, let url = panel.url { importAudio(url, role: importRole) }
  }
  @discardableResult func importAudio(_ source: URL, role: String) -> Task<Void, Never>? {
    guard !busy else { return nil }
    let importToken = UUID()
    job = importToken
    let projectID = project.id
    let autoEstimate = freshProjectID == projectID && !autoTempoAttempted && role == "original"
      && !project.assets.contains(where: { $0.role == "original" })
    importingFirstOriginal = autoEstimate
    busy = true
    progress = 0.05
    record("匯入\(roleName(role))：\(source.lastPathComponent)")
    let destinationFolder = folder
    return Task {
      defer { if job == importToken { importingFirstOriginal = false } }
      var shouldEstimate = false
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          () throws -> (MediaAsset, WaveformData) in
          let hash = try Files.hash(source)
          let id = UUID().uuidString
          let original = "originals/audio-\(id)/\(source.lastPathComponent)"
          let pcm = "derived/audio/\(hash).wav"
          let originalURL = destinationFolder.appendingPathComponent(original)
          let pcmURL = destinationFolder.appendingPathComponent(pcm)
          try Files.directory(originalURL.deletingLastPathComponent())
          try Files.directory(pcmURL.deletingLastPathComponent())
          try FileManager.default.copyItem(at: source, to: originalURL)
          let decoded = try AudioIO.decode(originalURL, to: pcmURL)
          let asset = MediaAsset(
            id: id, role: role, name: source.lastPathComponent, originalPath: original,
            pcmPath: pcm, hash: hash, duration: decoded.0, sampleRate: decoded.1,
            channels: decoded.2)
          return (asset, decoded.3)
        }.value
        guard job == importToken, project.id == projectID, folder == destinationFolder else {
          if job == importToken { busy = false }
          return
        }
        edit { p in
          p.assets.append(result.0)
          p.selectedAsset = result.0.id
          if role == "original" || p.harmonyAsset.isEmpty { p.harmonyAsset = result.0.id }
          if role == "bass" { p.bassAsset = result.0.id }
          p.timing.revision += 1
          p.reconcileEstimatedRegions()
        }
        waveform = result.1
        try transport.load(folder.appendingPathComponent(result.0.originalPath), offset: 0)
        configureTransport()
        refreshViewport(refreshCache: true)
        record(
          "\(roleName(role))已匯入 · \(String(format:"%.1f",result.0.duration)) 秒 · 原檔副本與高品質分析副本分開保存")
        shouldEstimate = autoEstimate && !saveFailed
        if shouldEstimate { autoTempoAttempted = true }
      } catch {
        guard job == importToken else { return }
        self.error = error.localizedDescription
        record("音源匯入未完成")
      }
      guard job == importToken else { return }
      importingFirstOriginal = false
      busy = false
      if shouldEstimate { await estimateTempo(applyInitialBPM: true)?.value }
    }
  }
  func chooseScore() {
    guard !busy else { return }
    if let url = chooseScoreFile() { importScore(url) }
  }
  private func chooseScoreFile() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = ["mscz", "mscx", "musicxml", "xml", "mxl"].compactMap {
      UTType(filenameExtension: $0)
    }
    panel.allowsOtherFileTypes = true
    return panel.runModal() == .OK ? panel.url : nil
  }
  @discardableResult func importScore(_ source: URL) -> Task<Void, Never>? {
    guard !busy else { return nil }
    busy = true
    transport.stop()
    progress = 0.1
    record("讀取完整樂譜，保留 TAB 與原記號")
    let destinationFolder = folder
    return Task {
      defer { busy = false }
      do {
        let document = try await Task.detached(priority: .userInitiated) {
          try ScoreIO.importDocument(source, project: destinationFolder)
        }.value
        guard folder == destinationFolder else { return }
        let existing = project.scoreContexts.contains { $0.score?.sourceHash == document.sourceHash }
        guard commitScoreChange({ p in
          p.addScore(document)
          p.scoreSourcePath = source.standardizedFileURL.path
          if p.title == "未命名採譜專案" { p.title = source.deletingPathExtension().lastPathComponent }
        }) else { return }
        record(existing ? "已選用既有樂譜 · 校準與人工標註保留，未重複加入"
               : "已新增參考譜 · \(document.measures.count) 小節 · 各譜校準與人工標註分開保存")
      } catch {
        self.error = error.localizedDescription
        record("樂譜匯入失敗，原檔未改動")
      }
    }
  }

  @discardableResult func requestScoreUpdate() -> Task<Void, Never>? {
    guard !busy, project.score != nil else { return nil }
    let source = project.editingScorePath.map { folder.appendingPathComponent($0) }
      ?? project.scoreSourcePath.map { URL(fileURLWithPath: $0) }
    guard let source, FileManager.default.isReadableFile(atPath: source.path) else {
      error = "找不到這份參考譜的來源。請從「匯出／MuseScore」選擇「連結參考譜來源…」，之後即可直接更新。"
      return nil
    }
    return updateReferenceScore(source)
  }

  func chooseScoreUpdateSource() {
    guard !busy, project.score != nil else { return }
    if let url = chooseScoreFile() { updateReferenceScore(url) }
  }

  @discardableResult func updateReferenceScore(_ source: URL, confirmNewScore: (() -> Bool)? = nil)
    -> Task<Void, Never>? {
    guard !busy, !analysisRunning, let previous = project.score else { return nil }
    busy = true
    scoreUpdating = true
    let destinationFolder = folder
    let contextID = project.activeContextID
    let sourcePath = source.standardizedFileURL.path
    let fromEditingCopy = project.editingScorePath.map {
      destinationFolder.appendingPathComponent($0).standardizedFileURL.path == sourcePath
    } ?? false
    return Task {
      defer { scoreUpdating = false; busy = false }
      do {
        let document = try await Task.detached(priority: .userInitiated) {
          try ScoreIO.readUpdatedDocument(source, project: destinationFolder, previousHash: previous.sourceHash)
        }.value
        guard folder == destinationFolder, project.activeContextID == contextID,
          project.score?.sourceHash == previous.sourceHash else { return }
        var revised = project
        if !fromEditingCopy {
          revised.editingScorePath = nil
          revised.scoreSourcePath = sourcePath
        }
        if let document {
          if revised.updateReferenceScore(document) {
            guard commitScoreChange(stopPlayback: false, { $0 = revised }) else { return }
            record("參考譜已更新 · 已保留對齊與人工標註")
          } else {
            guard confirmNewScore?() ?? confirmUpdatedScoreAsNew() else { return }
            revised = project
            let copyPath = fromEditingCopy ? revised.editingScorePath : nil
            if fromEditingCopy { revised.editingScorePath = nil }
            else if revised.scoreSourcePath == sourcePath { revised.scoreSourcePath = nil }
            revised.addScore(document)
            revised.editingScorePath = copyPath
            if !fromEditingCopy { revised.scoreSourcePath = sourcePath }
            guard commitScoreChange({ $0 = revised }) else { return }
            record("新版已獨立加入參考譜 · 舊譜的對齊與標註可在管理樂譜找回")
          }
        } else {
          if revised != project {
            guard commitScoreChange(stopPlayback: false, { $0 = revised }) else { return }
            record("已連結參考譜來源 · 樂譜內容已是最新")
          } else { record("參考譜內容已是最新") }
        }
      } catch {
        self.error = "參考譜更新失敗：\(error.localizedDescription)"
      }
    }
  }

  private func confirmUpdatedScoreAsNew() -> Bool {
    let alert = NSAlert()
    alert.messageText = "新版樂譜的小節格線已變更"
    alert.informativeText = "可以將新版加入為獨立參考譜。舊譜與校準、人工標註會一起保留。"
    alert.addButton(withTitle: "加入為獨立參考譜")
    alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// 先完成同一筆資料庫交易才發布切換；失敗時維持原 context 與復原紀錄。
  private func commitScoreChange(stopPlayback: Bool = true, _ operation: (inout Project) -> Void) -> Bool {
    guard !analysisRunning else { return false }
    switchingScoreContext = true
    defer { switchingScoreContext = false }
    if stopPlayback { transport.stop() }
    var revised = project
    operation(&revised)
    do {
      try ProjectStore.save(revised, to: folder)
      if revised != project {
        undoStack.append(project)
        if undoStack.count > 40 { undoStack.removeFirst() }
        redoStack = []
        let changed = project.activeContextID != revised.activeContextID
        let scoreChanged = project.score?.revision != revised.score?.revision
        project = revised
        if changed { finishScoreTransition() }
        else if scoreChanged { finishScoreRefresh() }
      }
      saveFailed = false
      return true
    } catch {
      saveFailed = true
      self.error = "樂譜變更未能儲存，維持原參考譜：\(error.localizedDescription)"
      return false
    }
  }

  private func finishScoreRefresh() {
    selectedNoteID = nil
    scoreRefresh = UUID()
  }

  private func finishScoreTransition() {
    editingScopes = []
    editingPlaybackSelection = false
    selectedNoteID = nil
    selectedRegionID = regionsInMeasure.first?.id ?? ""
    analysisSummary = ""
    analysisExclusions = []
    scoreRefresh = UUID()
    let second = max(0, project.timing.seconds(at: measure.beat))
    do {
      try transport.seek(min(currentAsset.map { $0.duration + $0.offset } ?? second, second))
    } catch { self.error = error.localizedDescription }
    refreshViewport(refreshCache: true)
    requestNavigationScroll()
  }

  @discardableResult func selectScore(id: String) -> Bool {
    guard !busy, project.activeContextID != id,
      project.scoreContexts.contains(where: { $0.id == id && !$0.removed }) else { return false }
    guard commitScoreChange({ _ = $0.selectScoreContext(id) }) else { return false }
    record("參考譜：\(project.referenceScoreName) · 已恢復各自校準與標註")
    return true
  }

  @discardableResult func removeScore(id: String) -> Bool {
    guard !busy, project.availableScoreContexts.contains(where: { $0.id == id }) else { return false }
    guard commitScoreChange({ _ = $0.removeScoreContext(id) }) else { return false }
    record("已移除樂譜 · 原檔與工作資料保留，可復原或從已移除清單恢復")
    return true
  }

  @discardableResult func restoreScore(id: String) -> Bool {
    guard !busy, project.removedScoreContexts.contains(where: { $0.id == id }) else { return false }
    guard commitScoreChange({ _ = $0.restoreScoreContext(id) }) else { return false }
    record("樂譜已恢復至清單 · 原校準與人工標註保留")
    return true
  }

  /// 只能清除已標記的譜；先提交資料庫，再同步清理所有 undo／redo 快照。
  /// 不刪 originals／外部檔案，也不刪其他譜共用的音訊分析快取。
  @discardableResult func finalizeScoreRemovals(_ ids: Set<String>) -> Bool {
    guard !busy else { return false }
    guard !ids.isEmpty else { return true }
    let pending = Set(project.removedScoreContexts.map(\.id))
    guard ids.isSubset(of: pending) else {
      error = "待移除清單已改變，請重新確認。"
      return false
    }
    var revised = project
    revised.forgetScoreContexts(ids)
    do {
      try ProjectStore.save(revised, to: folder)
    } catch {
      saveFailed = true
      self.error = "未能移除工作資料，資料仍保留，請重試：\(error.localizedDescription)"
      return false
    }
    // 歷史快照中的 context 可能尚未標記 removed；仍須逐一清掉，不能讓 undo 帶回。
    func sanitized(_ snapshot: Project) -> Project {
      var result = snapshot
      result.forgetScoreContexts(ids)
      return result
    }
    undoStack = undoStack.map(sanitized)
    redoStack = redoStack.map(sanitized)
    project = revised
    saveFailed = false
    record("已移除 \(ids.count) 份樂譜的工作資料")
    return true
  }
  /// 播放來源與和聲／Bass 分析來源分開選擇；切換聆聽來源保留目前主時間。
  func loadAsset(_ id: String) {
    guard let asset = project.assets.first(where: { $0.id == id }), !busy else { return }
    let position = transport.position
    let wasPlaying = transport.playing && !transport.countingIn
    do {
      try transport.load(folder.appendingPathComponent(asset.originalPath), offset: asset.offset)
      project.selectedAsset = id
      configureTransport()
      transport.position = position
      if wasPlaying { try transport.play(countIn: false) }
      let pcm = folder.appendingPathComponent(asset.pcmPath)
      Task {
        do { waveform = try await Task.detached { try AudioIO.waveform(pcm) }.value } catch {
          self.error = error.localizedDescription
        }
      }
      refreshViewport(at: position, refreshCache: true)
      persist()
      record("已切換至\(roleName(asset.role)) · 播放時間保持 \(String(format:"%.3f",position)) 秒")
    } catch { self.error = "找不到或無法播放素材，請用「重新連結音源」：\(error.localizedDescription)" }
  }
  func relinkAsset() {
    guard let selected = currentAsset, !busy else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio]
    panel.allowsOtherFileTypes = true
    guard panel.runModal() == .OK, let source = panel.url else { return }
    busy = true
    let directory = folder
    Task {
      do {
        let result = try await Task.detached { () throws -> (String, Double, Double, Int) in
          let hash = try Files.hash(source)
          // 重新連結只允許相同內容；不同版本應另行匯入，避免舊對齊套到新音源。
          guard hash == selected.hash else {
            throw WorkbenchError.message("檔案內容與原素材不同。若要使用另一音源，請另行匯入，避免把既有標註套到不同版本。")
          }
          let original = directory.appendingPathComponent(selected.originalPath)
          let pcm = directory.appendingPathComponent(selected.pcmPath)
          try Files.directory(original.deletingLastPathComponent())
          try Files.directory(pcm.deletingLastPathComponent())
          if FileManager.default.fileExists(atPath: original.path) {
            try FileManager.default.removeItem(at: original)
          }
          try FileManager.default.copyItem(at: source, to: original)
          let d = try AudioIO.decode(original, to: pcm)
          return (hash, d.0, d.1, d.2)
        }.value
        _ = result
        busy = false
        loadAsset(selected.id)
        record("音源已重新連結，內容 hash 一致")
      } catch {
        self.error = error.localizedDescription
        busy = false
      }
    }
  }
  // MARK: - 主時間、循環與手動對齊
  func setAssetOffset(_ value: Double) {
    guard !analysisRunning else { return }
    guard value.isFinite, abs(value) < 3600, let id = currentAsset?.id,
      let i = project.assets.firstIndex(where: { $0.id == id })
    else { return }
    transport.stop()
    edit {
      $0.assets[i].offset = value
      $0.timing.revision += 1
      $0.reconcileEstimatedRegions()
    }
    transport.offset = value
    refreshViewport(refreshCache: true)
  }
  func configureTransport() {
    transport.a = project.a
    transport.b = project.b
    transport.loop = project.loop
    transport.rate = project.rate
    transport.offset = currentAsset?.offset ?? 0
    transport.practice = project.practice
    transport.measures = project.measures
    transport.timing = project.timing
  }
  func playPause(countIn: Bool = true) {
    guard !busy else { return }
    do {
      if transport.playing {
        transport.stop()
      } else {
        configureTransport()
        try transport.play(countIn: countIn)
      }
    } catch { self.error = error.localizedDescription }
  }
  func setPlaybackRate(_ value: Float) {
    guard !busy, value.isFinite, (0.25...2).contains(value) else { return }
    if transport.countingIn { transport.stop() }
    project.rate = value
    configureTransport()
    persist()
  }
  func setMetronome(_ enabled: Bool) {
    guard !busy else { return }
    let resume = transport.playing && !transport.countingIn
    transport.stop()
    project.practice.metronome = enabled
    configureTransport()
    persist()
    if resume { do { try transport.play(countIn: false) } catch { self.error = error.localizedDescription } }
  }
  func setMetronomeVolume(_ value: Float, persist: Bool = true) {
    guard !busy, value.isFinite, (0...PracticeSettings.maximumClickVolume).contains(value) else { return }
    project.practice.volume = value
    transport.practice = project.practice
    if persist { self.persist() }
  }
  func setMusicVolume(_ value: Float, persist: Bool = true) {
    guard !busy, value.isFinite, (0...1).contains(value) else { return }
    project.practice.musicVolume = value
    transport.practice = project.practice
    if persist { self.persist() }
  }
  func setCountInBars(_ bars: Int) {
    guard !busy, (0...3).contains(bars) else { return }
    if transport.countingIn { transport.stop() }
    project.practice.countInBars = bars
    transport.practice = project.practice
    persist()
  }
  func setFollowPlayback(_ value: Bool) {
    guard !busy else { return }
    followPlayback = value
  }
  func setContrast(_ value: Double) {
    guard !busy, value.isFinite, (35...95).contains(value) else { return }
    project.contrast = value
  }
  func seek(_ second: Double) {
    guard !busy, second.isFinite else { return }
    do {
      try transport.seek(
        max(0, min(currentAsset.map { $0.duration + $0.offset } ?? second, second)))
    } catch { self.error = error.localizedDescription }
  }
  func previewFirstBar(_ second: Double) {
    guard !busy, let asset = currentAsset, second.isFinite, second >= -3600,
      let end = project.masterEnd, second < end, second != firstBarPreview else { return }
    if firstBarPreview == nil {
      firstBarPreviewReturn = (project.id, project.activeContextID, asset.id,
        ViewportRange(start: viewportStart, end: viewportEnd))
    }
    let delta = second - (firstBarPreview ?? project.timing.seconds(at: 0))
    firstBarPreview = second
    applyViewport(ViewportRange(start: viewportStart + delta, end: viewportEnd + delta), refreshCache: false)
  }
  func dragFirstBarPreview(to second: Double) {
    guard firstBarPreview != nil, second.isFinite, let end = project.masterEnd else { return }
    let rounded = (second * 1000).rounded() / 1000
    previewFirstBar(max(-3600, min(end - min(0.001, end / 2), rounded)))
  }
  func endFirstBarPreview(keepingViewport: Bool = false) {
    guard let previous = firstBarPreviewReturn else { return }
    firstBarPreview = nil
    firstBarPreviewReturn = nil
    if keepingViewport {
      if viewportMode.isLoopView { viewportMode = .manual(span: viewportEnd - viewportStart) }
      restoreSpectrum()
    } else if previous.project == project.id, previous.context == project.activeContextID,
      previous.asset == currentAsset?.id {
      applyViewport(previous.range, refreshCache: false)
    } else {
      refreshViewport(refreshCache: true)
    }
  }
  var previewTiming: TimingMap {
    var timing = project.timing
    if let firstBarPreview {
      timing.biasSeconds = timing.bias + (firstBarPreview - timing.seconds(at: 0))
    }
    return timing
  }
  var previewMeasureStart: Double? {
    guard firstBarPreview != nil else { return nil }
    return previewTiming.seconds(at: measure.beat)
  }
  func loopValidation(a: Double, b: Double) -> String? {
    LoopRange.validation(a: a, b: b, asset: currentAsset)
  }
  var activeLoopRange: ViewportRange? {
    guard project.loop, currentAsset != nil,
      loopValidation(a: project.a, b: project.b) == nil else { return nil }
    return ViewportRange(start: project.a, end: project.b)
  }
  var loopMeasureRange: MeasureRange? {
    activeLoopRange.flatMap(measureRange(in:))
  }
  var analysisRangeTitle: String {
    guard viewportMode.isLoopView, activeLoopRange != nil,
      let range = measureRange(in: ViewportRange(start: viewportStart, end: viewportEnd)),
      range.includesWholeMeasures else { return "分析目前範圍" }
    return "分析第 \(range.numbers) 小節"
  }
  private func measureRange(in range: ViewportRange) -> MeasureRange? {
    guard showsMeasureNavigation else { return nil }
    let timing = project.timing
    let start = timing.beat(at: range.start)
    let end = timing.beat(at: range.end)
    let measures = project.measures
    guard let first = measures.first(where: { $0.end > start + 1e-7 && $0.beat < end - 1e-7 }),
      let last = measures.last(where: { $0.beat < end - 1e-7 && $0.end > start + 1e-7 }) else { return nil }
    return MeasureRange(indices: first.index...last.index, first: first.number, last: last.number,
      includesWholeMeasures: abs(first.beat - start) < 1e-7 && abs(last.end - end) < 1e-7)
  }
  @discardableResult func setLoop(a: Double? = nil, b: Double? = nil, enable: Bool? = nil) -> Bool {
    guard !busy else { return false }
    let start = a ?? project.a
    let end = b ?? project.b
    if let message = loopValidation(a: start, b: end) {
      error = message
      return false
    }
    let boundsChanged = start != project.a || end != project.b
    transport.stop()
    edit {
      $0.a = start
      $0.b = end
      if let enable { $0.loop = enable }
    }
    configureTransport()
    if viewportMode.isLoopView {
      if boundsChanged { viewportMode = .loop }
      refreshViewport()
    }
    return true
  }
  func setLoopEnabled(_ enabled: Bool) {
    guard !busy else { return }
    if enabled, let message = loopValidation(a: project.a, b: project.b) {
      error = message
      return
    }
    transport.stop()
    edit { $0.loop = enabled }
    configureTransport()
    if !enabled, viewportMode.isLoopView { zoomMeasure() }
  }
  @discardableResult func loopCurrentMeasure() -> Bool {
    let start = max(0, project.timing.seconds(at: measure.beat))
    let end = min(
      currentAsset.map { $0.duration + $0.offset } ?? .greatestFiniteMagnitude,
      project.timing.seconds(at: measure.end))
    guard setLoop(a: start, b: end, enable: true) else { return false }
    zoomMeasure()
    return true
  }
  func loopMeasures(_ first: Int, _ second: Int) {
    guard !busy, firstBarPreview == nil, showsMeasureNavigation, let asset = currentAsset else { return }
    let measures = project.measures
    guard measures.indices.contains(first), measures.indices.contains(second) else { return }
    let left = measures[min(first, second)]
    let right = measures[max(first, second)]
    let timing = project.timing
    let audioStart = max(0, asset.offset)
    let audioEnd = asset.offset + asset.duration
    guard timing.seconds(at: left.end) > audioStart,
      timing.seconds(at: right.beat) < audioEnd else { return }
    let start = max(audioStart, timing.seconds(at: left.beat))
    let end = min(audioEnd, timing.seconds(at: right.end))
    guard loopValidation(a: start, b: end) == nil,
      setLoop(a: start, b: end, enable: true) else { return }
    if viewportMode != .loop { zoomLoop() }
  }
  private func requestNavigationScroll() {
    navigationScrollRequest = NavigationScrollRequest(index: project.selectedMeasure)
  }
  func navigate(_ index: Int, scrollNavigation: Bool = true) {
    guard !busy else { return }
    navigatingMeasure = true
    defer { navigatingMeasure = false }
    // 左側格子不移動列表，也撤銷尚未由畫面消費的舊捲動請求。
    navigationScrollRequest = nil
    transport.stop()
    // 手動定位與自動跟隨分開：點小節只定位並暫停，循環由明確操作設定。
    project.selectedMeasure = min(max(0, index), project.measures.count - 1)
    selectedNoteID = nil
    selectedRegionID = regionsInMeasure.first?.id ?? ""
    seek(previewTiming.seconds(at: measure.beat))
    refreshViewport()
    persist()
    if scrollNavigation { requestNavigationScroll() }
  }
  func selectRegion(_ id: String) {
    guard !busy else { return }
    selectedRegionID = id
  }
  func zoomMeasure() {
    guard !analysisRunning else { return }
    endFirstBarPreview()
    viewportMode = .measure
    refreshViewport(refreshCache: true)
  }
  func zoomLoop() {
    guard !analysisRunning else { return }
    endFirstBarPreview()
    viewportMode = .loop
    refreshViewport(refreshCache: true)
  }
  func zoom(_ factor: Double) {
    guard !analysisRunning, factor.isFinite, factor > 0 else { return }
    let center = (viewportStart + viewportEnd) / 2
    let span = min(90, max(0.25, (viewportEnd - viewportStart) * factor))
    if firstBarPreview != nil {
      applyViewport(ViewportRange(start: center - span / 2, end: center + span / 2), refreshCache: false)
      return
    }
    if viewportMode.isLoopView,
      let loop = measureRange(in: ViewportRange(start: project.a, end: project.b)) {
      let visible: ClosedRange<Int>
      if case .loopZoom(let indices) = viewportMode { visible = indices }
      else { visible = loop.indices }
      viewportMode = .loopZoom(ViewportLayout.resizedMeasures(visible, within: loop.indices, factor: factor))
      refreshViewport()
      return
    }
    viewportMode = .manual(span: span)
    applyViewport(ViewportLayout.fitted(start: center - span / 2, span: span,
                                      limit: viewportLimit), refreshCache: true)
  }
  var viewportDescription: String {
    if let firstBarPreview {
      return "起點草稿 · \(String(format: "%.3f", firstBarPreview)) s · 左右拖曳波形可微調"
    }
    switch viewportMode {
    case .measure: return "跟隨本小節"
    case .manual: return "手動縮放 · \(String(format: "%.2f", viewportEnd - viewportStart)) 秒"
    case .loop: return "固定 A–B 範圍"
    case .loopZoom(let indices): return "A–B 取景 · \(indices.count) 小節"
    }
  }
  private var viewportLimit: Double {
    currentAsset.map { max(0, $0.duration + $0.offset) } ?? 3600
  }
  private func refreshViewport(at position: Double? = nil, refreshCache: Bool = false) {
    let draftShift = firstBarPreview.map { $0 - project.timing.seconds(at: 0) }
    if draftShift != nil, !navigatingMeasure {
      if refreshCache { restoreSpectrum() }
      return
    }
    let target = position ?? (transport.position - (draftShift ?? 0))
    let current = ViewportRange(start: viewportStart, end: viewportEnd)
    let applied = firstBarPreviewReturn?.range ?? current
    let range: ViewportRange
    switch viewportMode {
    case .measure:
      let measureRange = ViewportRange(
        start: project.timing.seconds(at: measure.beat),
        end: project.timing.seconds(at: measure.end))
      range = measureRange.start < 0 ? measureRange : ViewportLayout.clipped(measureRange, limit: viewportLimit)
    case .loop:
      range = ViewportLayout.clipped(ViewportRange(start: project.a, end: project.b), limit: viewportLimit)
    case .loopZoom(let indices):
      let measures = project.measures
      if let bounds = measureRange(in: ViewportRange(start: project.a, end: project.b))?.indices {
        var visible = indices.clamped(to: bounds)
        if position != nil,
          let index = PlaybackTimeline.measureIndex(at: target, timing: project.timing, measures: measures),
          bounds.contains(index), !visible.contains(index) {
          let left = index - visible.count / 2
          visible = ViewportLayout.resizedMeasures(left...(left + visible.count - 1),
                                                  within: bounds, factor: 1)
        }
        if visible != indices { viewportMode = .loopZoom(visible) }
        range = ViewportRange(start: project.timing.seconds(at: measures[visible.lowerBound].beat),
                              end: project.timing.seconds(at: measures[visible.upperBound].end))
      } else {
        viewportMode = .loop
        range = ViewportLayout.clipped(ViewportRange(start: project.a, end: project.b), limit: viewportLimit)
      }
    case .manual(let span):
      range = ViewportLayout.following(position: target, current: applied, span: span, limit: viewportLimit)
    }
    if let draftShift {
      // 取消時回到新選取小節的正式取景。只將草稿取景送去載入能量圖。
      firstBarPreviewReturn?.range = range
      let previewRange = abs(current.span - applied.span) > 1e-7
        ? ViewportLayout.following(position: target,
            current: ViewportRange(start: current.start - draftShift, end: current.end - draftShift),
            span: current.span, limit: viewportLimit)
        : range
      applyViewport(ViewportRange(start: previewRange.start + draftShift, end: previewRange.end + draftShift),
                    refreshCache: refreshCache)
    } else {
      applyViewport(range, refreshCache: refreshCache)
    }
  }
  private func applyViewport(_ range: ViewportRange, refreshCache: Bool) {
    let changed = range.start != viewportStart || range.end != viewportEnd
    if changed { viewportStart = range.start; viewportEnd = range.end }
    if changed || refreshCache { restoreSpectrum() }
  }
  private var spectrumQuery: SpectrumCache.Query? {
    guard let asset = currentAsset else { return nil }
    return SpectrumCache.Query(
      sourceHash: asset.hash, offset: asset.offset, start: viewportStart, end: viewportEnd,
      minMIDI: project.minMIDI, maxMIDI: project.maxMIDI, binsPerOctave: project.binsPerOctave)
  }
  @discardableResult func restoreSpectrum() -> Task<Void, Never>? {
    spectrumLoad?.cancel()
    guard let query = spectrumQuery else {
      spectrumSegments = []
      spectrumContext = nil
      spectrumLoading = false
      return nil
    }
    let directory = folder.appendingPathComponent("derived/features")
    let compatible = spectrumContext.map { $0.directory == directory && $0.query.sameSource(as: query) } ?? false
    let existing = compatible ? spectrumSegments : []
    spectrumLoading = true
    spectrumSegments = existing.filter { $0.metadata.start < query.end && $0.metadata.end > query.start }
    let read = Task.detached(priority: .utility) {
      SpectrumCache.restore(in: directory, matching: query, reusing: existing)
    }
    spectrumLoad = Task {
      let restored = await withTaskCancellationHandler {
        await read.value
      } onCancel: {
        read.cancel()
      }
      // 快速切小節、換專案或開始分析後，較晚完成的讀取不可覆蓋新畫面。
      guard !Task.isCancelled, query == spectrumQuery,
        directory == folder.appendingPathComponent("derived/features")
      else { return }
      spectrumSegments = restored
      spectrumContext = (query, directory)
      spectrumLoading = false
    }
    return spectrumLoad
  }
  func setAnchor(end: Bool = false) {
    guard !busy else { return }
    transport.stop()
    do {
      var timing = project.timing
      try timing.set(beat: end ? measure.end : measure.beat, seconds: transport.position)
      edit {
        $0.timing = timing
        $0.reconcileEstimatedRegions()
      }
      refreshViewport(refreshCache: true)
      record(
        "第 \(measure.number) 小節\(end ? "結尾":"起點")已對齊至 \(String(format:"%.3f",transport.position)) 秒；舊分析標記為待更新"
      )
    } catch { self.error = error.localizedDescription }
  }
  func removeAnchor(_ id: String) {
    guard !busy else { return }
    transport.stop()
    edit {
      $0.timing.anchors.removeAll { $0.id == id }
      $0.timing.revision += 1
      $0.reconcileEstimatedRegions()
    }
    refreshViewport(refreshCache: true)
  }
  @discardableResult func setBPM(_ value: Double) -> Bool {
    guard !busy, value.isFinite, (20...400).contains(value) else { return false }
    guard project.timing.anchors.count < 2 else {
      error = "目前時間由多個錨點決定；請用兩點校正，或先清除錨點再修改 BPM。"
      return false
    }
    var timing = project.timing
    if timing.bpm != value { timing.bpm = value; timing.revision += 1 }
    return applyAlignment(timing)
  }
  @discardableResult func applyAlignment(_ timing: TimingMap) -> Bool {
    guard !busy else { return false }
    do { try timing.validate() } catch { self.error = error.localizedDescription; return false }
    transport.stop()
    if timing != project.timing {
      edit {
        $0.timing = timing
        $0.reconcileEstimatedRegions()
      }
    }
    selectedRegionID = regionsInMeasure.first?.id ?? ""
    refreshViewport(refreshCache: true)
    record("譜面／格線對齊已更新 · 自動分析需依新範圍更新，可復原")
    return true
  }
  /// 對齊面板一次驗證、一次 undo／保存；失敗前不改專案或停止播放。
  @discardableResult func applyAlignmentEditor(_ draft: AlignmentEditorDraft) -> Bool {
    applyAlignmentEditor(draft, btc: nil)
  }

  private func applyAlignmentEditor(_ draft: AlignmentEditorDraft, btc: BTCSong?) -> Bool {
    guard !busy else { return false }
    do {
      var revised = try draft.applying(to: project, asset: currentAsset)
      revised.confirmAlignment()
      transport.stop()
      // edit 會為音源變動統一使各譜失效，作用中譜只增加一次 revision。
      if revised.assets != project.assets { revised.timing.revision = project.timing.revision }
      let plan = btc.flatMap { song in
        revised.masterAsset.map { writeBTCEvidence(song, asset: $0, project: &revised) }
      }
      if revised != project { edit { $0 = revised } }
      else if saveFailed { persist() }
      if !saveFailed, let plan { reportBTC(plan, cached: btc?.cached == true) }
      if !saveFailed { initialGridBPM = nil }
      configureTransport()
      selectedRegionID = regionsInMeasure.first?.id ?? ""
      if firstBarPreview != nil { endFirstBarPreview(keepingViewport: true) }
      else { refreshViewport(refreshCache: true) }
      if saveFailed { return false }
      record("速度與時間對齊已確認，可復原")
      return true
    } catch { self.error = error.localizedDescription; return false }
  }
  @discardableResult func applyEstimatedGrid(_ input: GridInput) -> Bool {
    guard !busy else { return false }
    do {
      var revised = project
      try revised.applyEstimatedGrid(input)
      transport.stop()
      if revised != project { edit { $0 = revised } }
      selectedRegionID = regionsInMeasure.first?.id ?? ""
      refreshViewport(refreshCache: true)
      record("估算格線已套用 · \(project.measures.count) 小節 · 舊區間標註保留於歷史，可復原")
      return true
    } catch { self.error = error.localizedDescription; return false }
  }
  // MARK: - 區間及人工標註
  // 已鎖定的區間不可直接拆分，避免無法判斷人工確認應歸屬哪一半。
  func splitRegion() {
    guard !busy, let region = currentRegion,
      let i = project.regions.firstIndex(where: { $0.id == region.id })
    else { return }
    guard
      !region.annotation.rootLocked && !region.annotation.chordLocked
        && !region.annotation.firstLocked
    else {
      error = "請先解除此區間的確認，再拆分和聲區間。"
      return
    }
    let raw = project.timing.beat(at: transport.position)
    let split = (raw * 4).rounded() / 4
    guard split > region.startBeat + 0.05, split < region.endBeat - 0.05 else {
      error = "請把播放游標放在區間內的換和弦位置，再按拆分。"
      return
    }
    edit { p in
      p.regions[i].endBeat = split
      p.regions[i].evidence = nil
      p.regions.append(
        HarmonyRegion(measureID: region.measureID, startBeat: split, endBeat: region.endBeat))
    }
    record("已在小節內拆成兩個和聲區間")
  }
  func mergeRegions() {
    let regions = regionsInMeasure
    guard !busy, regions.count > 1 else { return }
    guard
      !regions.contains(where: {
        $0.annotation.rootLocked || $0.annotation.chordLocked || $0.annotation.firstLocked
          || $0.annotation.confirmed
      })
    else {
      error = "請先解除本小節區間的鎖定，再合併。"
      return
    }
    let id = measure.id
    let start = measure.beat
    let end = measure.end
    edit {
      $0.archivedRegions += regions
      $0.regions.removeAll { $0.measureID == id }
      $0.regions.append(HarmonyRegion(measureID: id, startBeat: start, endBeat: end))
    }
    selectedRegionID = regionsInMeasure.first?.id ?? ""
    record("已合併本小節和聲區間；舊標註保留於歷史")
  }
  func annotate(regionID: String? = nil, _ change: (inout HumanAnnotation) -> Void) {
    // 編輯結束時可能立刻恢復跟隨；操作仍寫回使用者當時正在編輯的區間。
    guard let id = regionID ?? currentRegion?.id,
      let i = project.regions.firstIndex(where: { $0.id == id })
    else { return }
    edit { change(&$0.regions[i].annotation) }
  }
  /// 對齊或分析來源更動後，舊 Evidence 可供追溯，但不能再充當目前的自動主標籤。
  func freshEvidence(_ region: HarmonyRegion) -> HarmonyEvidence? {
    region.evidence.flatMap { $0.timingRevision == project.timing.revision ? $0 : nil }
  }
  /// 鎖定空白也必須優先，不能因字串為空就退回自動和弦。
  func chordText(_ region: HarmonyRegion) -> String {
    let a = region.annotation
    return a.chordLocked || !a.chord.isEmpty ? a.chord : (freshEvidence(region)?.chord ?? "")
  }
  func accept(_ candidate: ChordCandidate, regionID: String? = nil) {
    annotate(regionID: regionID) {
      if !$0.rootLocked { $0.root = Pitch.pc(candidate.root) }
      if !$0.chordLocked { $0.chord = candidate.symbol }
    }
  }
  func reject(_ candidate: ChordCandidate, regionID: String? = nil) {
    annotate(regionID: regionID) {
      if !$0.rejected.contains(candidate.symbol) { $0.rejected.append(candidate.symbol) }
    }
  }
  func auditionNote(_ note: ScoreNote) {
    guard !busy else { return }
    selectedNoteID = note.id
    let start = max(0, project.timing.seconds(at: note.beat) - 0.06)
    let end = min(
      currentAsset.map { $0.duration + $0.offset } ?? .greatestFiniteMagnitude,
      project.timing.seconds(at: max(note.beat + 0.25, note.end)) + 0.08)
    guard setLoop(a: start, b: end, enable: true) else { return }
    seek(start)
    playPause(countIn: false)
  }
  private func assetPayload(_ a: MediaAsset) -> [String: Any] {
    [
      "path": folder.appendingPathComponent(a.pcmPath).path, "hash": a.hash, "offset": a.offset,
      "role": a.role,
    ]
  }
  // MARK: - 本機分析
  /// 先封鎖互動再停止播放，避免 stop 的位置通知改變已擷取的分析選取。
  private func beginAnalysis(_ kind: AnalysisKind) -> UUID? {
    guard !busy else { return nil }
    let token = UUID()
    job = token
    activeAnalysis = kind
    busy = true
    transport.stop()
    return token
  }

  private func requestBTC(asset: MediaAsset, token: UUID, tempo: TempoEstimate? = nil,
                          bpm: Double? = nil) async throws -> BTCSong {
    guard let btcInstallation, let btcWorker else {
      throw WorkbenchError.message("BTC 本機模型目前不可用。")
    }
    var payload: [String: Any] = [
      "op": "btc", "asset": assetPayload(asset), "checkout": btcInstallation.checkout,
      "cache": folder.appendingPathComponent("derived/features/btc").path,
    ]
    if let tempo, let bpm, let downbeats = tempo.downbeats {
      payload["timing"] = ["bpm": bpm, "beats": tempo.beats, "downbeats": downbeats,
        "start": tempo.start, "end": tempo.end]
    }
    let base = tempo == nil ? 0.0 : 0.35
    let data = try await btcWorker.request(payload, cacheRoot: folder.appendingPathComponent("derived/runtime")) {
      [weak self] value, message in
      Task { @MainActor in
        guard let self, self.job == token, self.analysisRunning else { return }
        self.progress = max(self.progress, base + (1 - base) * value)
        self.status = message
      }
    }
    let song = try JSONDecoder().decode(BTCSong.self, from: data)
    try song.validate(source: asset)
    return song
  }

  private func writeBTCEvidence(_ song: BTCSong, asset: MediaAsset, project revised: inout Project) -> AnalysisPlan {
    let bass = analysisSources?.bass ?? asset
    let plan = AnalysisPlan(project: revised, arrangement: asset, bass: asset, resume: false,
      method: AnalysisMethod.btcHarmony)
    let items = Dictionary(uniqueKeysWithValues: plan.batches.joined().map { ($0.regionID, $0) })
    let createdAt = ISO8601DateFormatter().string(from: Date())
    let revision = revised.timing.revision
    var regions = revised.regions
    for i in regions.indices {
      guard let item = items[regions[i].id] else { continue }
      let existing = regions[i].evidence.flatMap {
        $0.timingRevision == revision && $0.bassSource == bass.hash ? $0 : nil
      }
      regions[i].evidence = song.evidence(for: item, source: asset, revision: revision,
        bass: existing, createdAt: createdAt)
    }
    revised.regions = regions
    return plan
  }

  private func reportBTC(_ plan: AnalysisPlan, cached: Bool) {
    analysisExclusions = plan.excluded
    analysisSummary = "已分析 \(plan.total) 區間"
    record("全曲和弦已更新 · \(plan.total) 區間\(cached ? " · 重用音源快取" : "")")
  }

  private func analyzeBTCSong(asset: MediaAsset) -> Task<Void, Never>? {
    guard let token = beginAnalysis(.btcSong) else { return nil }
    let snapshot = (project.id, project.activeContextID, project.timing, folder)
    progress = 0
    record("準備全曲和弦分析")
    return Task {
      defer { finishAnalysis(token) }
      do {
        let song = try await requestBTC(asset: asset, token: token)
        guard job == token, snapshot == (project.id, project.activeContextID, project.timing, folder),
          asset == project.masterAsset else { return }
        var revised = project
        let plan = writeBTCEvidence(song, asset: asset, project: &revised)
        try ProjectStore.save(revised, to: folder)
        project = revised
        saveFailed = false
        progress = 1
        reportBTC(plan, cached: song.cached)
      } catch {
        if job == token { self.error = error.localizedDescription; record("全曲分析未完成") }
      }
    }
  }

  private func finishAnalysis(_ token: UUID) {
    guard job == token else { return }
    activeAnalysis = nil
    busy = false
  }

  private var pendingHarmony: [(index: Int, evidence: HarmonyEvidence, run: Data)] = []

  private func flushPendingHarmony() throws {
    guard !pendingHarmony.isEmpty else { return }
    var updated = project
    for result in pendingHarmony { updated.regions[result.index].evidence = result.evidence }
    do {
      try ProjectStore.save(updated, to: folder, analysisRuns: pendingHarmony.map(\.run))
    } catch {
      saveFailed = true
      throw WorkbenchError.message("結果尚未成功儲存，請檢查專案位置後重試。\n\(error.localizedDescription)")
    }
    project = updated
    saveFailed = false
    UserDefaults.standard.set(folder.path, forKey: "lastProject")
    pendingHarmony.removeAll(keepingCapacity: true)
  }

  private func featurePayload(asset: MediaAsset, start: Double, end: Double, cache: URL) -> [String: Any] {
    [
      "op": "features", "asset": assetPayload(asset), "start": start, "end": end,
      "pitchGuide": asset.role == "bass",
      "minMIDI": project.minMIDI, "maxMIDI": project.maxMIDI,
      "binsPerOctave": project.binsPerOctave, "cache": cache.path,
    ]
  }
  @discardableResult func analyzeCalibrationSpectrum() -> Task<Void, Never>? {
    guard !busy, firstBarPreview != nil, let asset = currentAsset else { return nil }
    let start = max(asset.offset, viewportStart)
    let end = min(asset.duration + asset.offset, viewportEnd)
    guard end - start >= 0.15, end - start <= 90 else {
      error = "請將校正範圍移到此音源內，並保留 0.15–90 秒的音訊。"
      return nil
    }
    guard let token = beginAnalysis(.calibrationSpectrum) else { return nil }
    let payload = featurePayload(asset: asset, start: start, end: end, cache: folder.appendingPathComponent("derived/features"))
    let runtime = folder.appendingPathComponent("derived/runtime")
    progress = 0
    record("計算校正範圍的音高能量")
    return Task {
      defer { finishAnalysis(token) }
      do {
        _ = try await worker.request(payload, cacheRoot: runtime) { [weak self] value, message in
          Task { @MainActor in
            if self?.job == token, self?.analysisRunning == true { self?.progress = value; self?.status = message }
          }
        }
        guard job == token else { return }
        await restoreSpectrum()?.value
        guard job == token else { return }
        progress = 1
        record("已更新校正範圍的音高能量")
      } catch {
        if job == token { self.error = error.localizedDescription }
      }
    }
  }

  /// 擷取當次來源、時間映射與 revision；結果僅替換 region.evidence，不碰 annotation。
  @discardableResult func analyze(fullSong: Bool = false, resume: Bool = true,
                                  globalTuning: Bool = false) -> Task<Void, Never>? {
    guard canAnalyze else { return nil }
    if fullSong && !globalTuning && btcAvailable, let original = project.masterAsset, original.role == "original" {
      return analyzeBTCSong(asset: original)
    }
    guard let (asset, arrangement, bass) = analysisSources else { return nil }
    let start = viewportStart, end = viewportEnd
    let featureStart = max(start, asset.offset)
    let featureEnd = min(end, asset.offset + asset.duration)
    guard fullSong || (featureEnd - featureStart >= 0.15 && featureEnd - featureStart <= 90) else {
      error = "請將範圍調到目前音源內，保留 0.15–90 秒的音訊，或選擇「分析全曲／續跑」。"
      return nil
    }
    project.reconcileEstimatedRegions()
    let method = fullSong ? (globalTuning ? AnalysisMethod.tunedHarmony : AnalysisMethod.sourceHarmony)
      : AnalysisMethod.harmony
    let plan = AnalysisPlan(project: project, arrangement: arrangement, bass: bass,
                            range: fullSong ? nil : start...end, resume: fullSong && resume,
                            method: method)
    guard fullSong || plan.pending <= 24 else {
      error = "請縮小至 24 個和聲區間內，或選擇「分析全曲／續跑」。"
      return nil
    }
    analysisExclusions = plan.excluded
    analysisSummary = "已完成 \(plan.reused)/\(plan.total) 區間 · 未分析 \(plan.excluded.count) 區間"
    guard !fullSong || plan.pending > 0 else {
      progress = plan.total > 0 ? 1 : 0
      record(plan.total > 0 ? "全曲可分析區間已有結果；來源與對齊相同，可直接核對。" : "沒有可分析區間，請檢查格線與來源涵蓋時間。")
      return nil
    }
    guard let token = beginAnalysis(fullSong ? .song : .range) else { return nil }
    progress = 0
    record(fullSong ? "全曲分批分析；已完成的區間會保留，可隨時取消後續跑" : "準備本機範圍分析")
    let directory = folder
    let cache = directory.appendingPathComponent("derived/features")
    let runtime = directory.appendingPathComponent("derived/runtime")
    let revision = project.timing.revision
    let contextID = project.activeContextID
    let query = spectrumQuery
    let payload = featurePayload(asset: asset, start: featureStart, end: featureEnd, cache: cache)
    let arrangementData = assetPayload(arrangement), bassData = assetPayload(bass)
    var completed = plan.reused
    let clock = ContinuousClock()
    var lastSave = clock.now
    var featurePending = !fullSong
    return Task {
      defer {
        if job == token { pendingHarmony.removeAll() }
        finishAnalysis(token)
      }
      do {
        if !fullSong {
          let data = try await worker.request(payload, cacheRoot: runtime) { [weak self] value, message in
            Task { @MainActor in
              if self?.job == token, featurePending { self?.progress = value * 0.4; self?.status = message }
            }
          }
          guard job == token, project.activeContextID == contextID else { return }
          featurePending = false
          let metadata = try JSONDecoder().decode(AnalysisFeatures.self, from: data)
          let bytes = try Data(contentsOf: URL(fileURLWithPath: metadata.binaryPath))
          guard metadata.rows > 0, metadata.rows <= 1000, metadata.columns > 0,
            metadata.columns <= 100_000, bytes.count == metadata.rows * metadata.columns * 4 else {
            throw WorkbenchError.message("音高圖快取長度不符，請清除快取後重算。")
          }
          let values = bytes.withUnsafeBytes { raw -> [Float] in
            var result = [Float](repeating: 0, count: metadata.rows * metadata.columns)
            _ = result.withUnsafeMutableBytes { raw.copyBytes(to: $0) }
            return result
          }
          guard values.allSatisfy({ $0.isFinite }) else {
            throw WorkbenchError.message("音高圖包含無效數值，請清除快取後重算。")
          }
          if let query, query == spectrumQuery {
            spectrumLoad?.cancel()
            spectrumLoading = false
            spectrumSegments = [SpectrumData(metadata: metadata, values: values)]
            spectrumContext = (query, cache)
          }
          try? ProjectStore.appendRun(data, to: directory)
        }
        try await regionAnalysis.run(plan, arrangement: arrangementData, bass: bassData,
                                     revision: revision, cache: cache, runtime: runtime,
                                     progress: { [weak self] value, message in
          guard let self, self.job == token else { return }
          self.progress = fullSong ? value : 0.4 + 0.6 * value
          self.status = message
        }, receive: { [self] item, evidence, data in
          guard job == token, project.activeContextID == contextID,
            project.timing.revision == revision, folder == directory,
            let index = project.regions.firstIndex(where: { $0.id == item.regionID }) else {
            throw CancellationError()
          }
          // 自動重算只更新 evidence；人工值、獨立鎖定與確認均不變。
          if fullSong {
            pendingHarmony.append((index, evidence, data))
            if pendingHarmony.count >= 8 || lastSave.duration(to: clock.now) >= .seconds(3) {
              try flushPendingHarmony()
              lastSave = clock.now
            }
          } else {
            project.regions[index].evidence = evidence
            persist()
            if saveFailed { throw WorkbenchError.message("結果尚未成功儲存，請檢查專案位置後重試。") }
            try? ProjectStore.appendRun(data, to: directory)
          }
          completed += 1
          let saved = completed - pendingHarmony.count
          analysisSummary = "已完成 \(saved)/\(plan.total) 區間 · 未分析 \(plan.excluded.count) 區間"
        })
        guard job == token else { return }
        try flushPendingHarmony()
        analysisSummary = "已完成 \(completed)/\(plan.total) 區間 · 未分析 \(plan.excluded.count) 區間"
        progress = 1
        record("\(fullSong ? "全曲分批" : "目前範圍")分析完成 · \(completed) 區間已有結果\(plan.excluded.isEmpty ? "" : "；另有 \(plan.excluded.count) 區間未涵蓋，請展開查看")")
      } catch is CancellationError {
        if job == token { record("已取消分析；已完成結果與人工標註均保留") }
      } catch {
        if job == token {
          var message = error.localizedDescription
          if !saveFailed {
            do { try flushPendingHarmony() }
            catch { message = error.localizedDescription }
          }
          self.error = message
          let saved = completed - pendingHarmony.count
          record("分析中止 · 已完成 \(max(plan.reused, saved))/\(plan.total) 區間；可按「分析全曲／續跑」繼續")
        }
      }
    }
  }

  @discardableResult func estimateTempo(
    using model: TempoEstimator? = nil, applyInitialBPM: Bool = false
  ) -> Task<Void, Never>? {
    estimateTempo(using: model, applyInitialBPM: applyInitialBPM, fallbackToLibrosa: false)
  }

  private func estimateTempo(using model: TempoEstimator?, applyInitialBPM: Bool,
                             fallbackToLibrosa: Bool) -> Task<Void, Never>? {
    guard !busy, let asset = project.masterAsset else { return nil }
    if let model, model != tempoEstimator {
      selectTempoEstimator(model)
      guard tempoEstimator == model else { return nil }
    }
    tempoEstimate = nil
    initialGridBPM = nil
    let automaticSong = applyInitialBPM && !fallbackToLibrosa && btcAvailable && small0Available
    guard let token = beginAnalysis(automaticSong ? .initialSong : .tempo) else { return nil }
    progress = 0
    record("本機估測 BPM／拍點")
    var selected = fallbackToLibrosa ? .librosa : automaticSong ? .small0 : tempoEstimator
    if selected == .small0 && !small0Available {
      selected = .librosa; tempoEstimator = .librosa
      tempoModelNotice = "small0 目前不可用，這次改用 librosa。"
    }
    var request: [String: Any] = ["op": "tempo", "asset": assetPayload(asset), "estimator": selected.rawValue]
    if selected == .small0 { request["checkpoint"] = small0Installation!.checkpoint }
    let estimatorWorker = selected == .small0 ? optionalTempoWorker! : worker
    let usedFallback = fallbackToLibrosa || tempoModelNotice != nil
    let runtime = folder.appendingPathComponent("derived/runtime")
    let projectID = project.id, sourceFolder = folder
    let contextID = project.activeContextID, timing = project.timing
    let applyOnCompletion = applyInitialBPM && freshProjectID == projectID && autoTempoAttempted
    return Task {
      var finished = false
      defer { if !finished { finishAnalysis(token) } }
      do {
        let data = try await estimatorWorker.request(request, cacheRoot: runtime) { [weak self] value, message in
          Task { @MainActor in
            if self?.job == token, self?.analysisRunning == true {
              self?.progress = value * (automaticSong ? 0.35 : 1)
              self?.status = message
            }
          }
        }
        guard job == token, project.id == projectID, folder == sourceFolder,
          project.masterAsset == asset else { return }
        let result = try JSONDecoder().decode(TempoEstimate.self, from: data)
        guard result.sourceHash == asset.hash else { throw WorkbenchError.message("估測來源與目前原音不同，請重新估測。") }
        if selected == .small0 {
          guard result.estimator == "small0", result.weightsHash == Small0Installation.weightsHash else {
            throw WorkbenchError.message("估測模型與請求不同，請重新估測。")
          }
        } else if let estimator = result.estimator, estimator != "librosa" {
          throw WorkbenchError.message("估測模型與請求不同，請重新估測。")
        }
        if result.preferredBPM != nil && !usedFallback && !automaticSong {
          tempoPreferences.set(selected.rawValue,forKey:"tempo.lastSuccessfulModel")
        }
        var song: BTCSong?
        var btcNotice: String?
        if automaticSong {
          record("本機估測第一小節起點與全曲和弦")
          do {
            song = try await requestBTC(asset: asset, token: token, tempo: result, bpm: result.preferredBPM)
          } catch {
            guard job == token else { return }
            btcNotice = "全曲分析未完成 · \(error.localizedDescription)"
          }
          guard job == token, project.id == projectID, folder == sourceFolder,
            project.masterAsset == asset else { return }
        }
        tempoEstimate = result
        tempoEstimateAsset = asset
        progress = 1
        finishAnalysis(token)
        finished = true
        if applyOnCompletion, project.activeContextID == contextID, project.timing == timing,
          project.timing.anchors.count < 2, let bpm = result.preferredBPM {
          let newGrid = project.score == nil && project.estimatedGrid == nil && project.requiresAlignmentConfirmation
          let firstMeasure = project.score?.measures.first
          let freshScore = automaticSong && project.requiresAlignmentConfirmation && !timing.calibrated
            && firstMeasure?.numerator == 4 && firstMeasure?.denominator == 4 && firstMeasure?.length == 4
          if newGrid || (freshScore && song?.firstBar != nil) {
            var draft = AlignmentEditorDraft()
            draft.reset(project: project, asset: currentAsset)
            draft.bpm = String(bpm)
            let offset = song?.firstBar.flatMap { value -> Double? in
              guard value.isFinite, value >= 0, value < (project.masterEnd ?? 0),
                draft.numerator == 4, draft.denominator == 4 else { return nil }
              return value
            }
            if let offset { draft.firstBar = String(offset) }
            if applyAlignmentEditor(draft, btc: offset == nil ? nil : song), !saveFailed {
              if newGrid { initialGridBPM = bpm }
              if let offset {
                record("已帶入估測 BPM、起點 \(offset.formatted(.number.precision(.fractionLength(3)))) 秒及和弦候選")
              } else {
                record("已套用估測 BPM 並建立初步小節格線；可核對速度、拍號與起點")
              }
            }
          } else if (!automaticSong || !timing.calibrated), setBPM(bpm) {
            record("已設定估測 BPM；可改選候選或手動輸入，再調整起點／偏移")
          }
        } else {
          record(result.preferredBPM == nil ? "拍點不足，請手動設定 BPM" : "BPM 候選已更新；目前校準保留")
        }
        if let btcNotice { record(btcNotice) }
        else if automaticSong, analysisSummary.isEmpty {
          record("請核對速度與第一小節起點，再按「分析全曲」更新和弦候選")
        }
        alignmentRevealRequest = AlignmentRevealRequest(initialEstimate: applyOnCompletion)
      } catch {
        guard job == token else { return }
        if automaticSong {
          record("Beat This! 未完成 · \(error.localizedDescription)")
          finishAnalysis(token)
          finished = true
          await estimateTempo(using: nil, applyInitialBPM: true, fallbackToLibrosa: true)?.value
        } else {
          self.error = error.localizedDescription
          record("BPM 估測未完成，可手動設定")
        }
      }
    }
  }
  /// 選候選即設定速度；保留目前起點、偏移、錨點與人工標註。
  @discardableResult func applyTempoCandidate(_ bpm: Double) -> Bool {
    guard !busy, bpm.isFinite, let estimate = currentTempoEstimate,
      estimate.buttonBPMS.contains(bpm) else { return false }
    return setBPM(bpm)
  }
  /// 先停止 Worker 並換掉 job；所有 await 後都會比對 job，取消的結果不會回寫。
  func cancel() {
    guard analysisRunning else { return }
    // 先使所有舊回呼失效，再喚醒舊請求；舊工作不可解鎖新工作。
    job = UUID()
    regionAnalysis.cancel()
    optionalTempoWorker?.cancel()
    btcWorker?.cancel()
    do {
      try flushPendingHarmony()
      if activeAnalysis == .song { analysisSummary = "已取消，已保存的區間可續跑" }
    } catch {
      self.error = error.localizedDescription
      analysisSummary = "已取消，請檢查專案的儲存位置"
    }
    pendingHarmony.removeAll()
    activeAnalysis = nil
    busy = false
    record("已取消本機分析，完整快取與人工標註保留")
  }
  func clearCache() {
    guard !busy else { return }
    spectrumLoad?.cancel()
    spectrumLoading = false
    worker.cancel()
    do {
      let cache = folder.appendingPathComponent("derived/features")
      if FileManager.default.fileExists(atPath: cache.path) {
        try FileManager.default.removeItem(at: cache)
      }
      spectrumSegments = []
      record("已清除可重建的分析快取；原檔與人工標註保留")
    } catch { self.error = error.localizedDescription }
  }
  // MARK: - 完整專案與匯出
  // .basswork 是包含原檔、SQLite 與 derived 的目錄套件；另存必須整包複製。
  func saveAs() {
    guard !busy else { return }
    persist()
    guard !saveFailed else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.bassProject]
    panel.nameFieldStringValue = project.title + ".basswork"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      if destination.standardizedFileURL != folder.standardizedFileURL {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
          throw WorkbenchError.message("目的地已存在，請選擇新名稱，避免覆寫另一份專案。")
        }
        try FileManager.default.copyItem(at: folder, to: destination)
        folder = destination
      }
      namedProject = true
      persist()
      record("專案已另存，音源與原譜均包含在專案內")
    } catch { self.error = error.localizedDescription }
  }
  func save() {
    guard !busy else { return }
    if namedProject {
      persist()
      record("專案已儲存")
    } else {
      saveAs()
    }
  }
  func chooseProject() {
    guard !busy else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.bassProject]
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.treatsFilePackagesAsDirectories = false
    if panel.runModal() == .OK, let url = panel.url { openProject(url) }
  }
  func openProject(_ url: URL) {
    guard !busy else { return }
    persist()
    do {
      let loaded = try ProjectStore.load(url)
      transport.unload()
      project = loaded
      freshProjectID = nil
      autoTempoAttempted = true
      project.reconcileEstimatedRegions()
      tempoEstimate = nil
      analysisSummary = ""
      analysisExclusions = []
      folder = url
      namedProject = true
      undoStack = []
      redoStack = []
      spectrumSegments = []
      waveform = nil
      selectedRegionID = regionsInMeasure.first?.id ?? ""
      scoreRefresh = UUID()
      configureTransport()
      zoomMeasure()
      if let asset = currentAsset { loadAsset(asset.id) }
      persist()
      record("已開啟專案 · 人工 Root／和弦／首音標註已恢復")
    } catch { self.error = error.localizedDescription }
  }
  func revealAutosave() {
    guard !busy else { return }
    persist()
    NSWorkspace.shared.activateFileViewerSelecting([folder])
  }
  func exportAnalysis() {
    guard !busy else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = project.title + "-分析與標註.json"
    if panel.runModal() == .OK, let url = panel.url {
      do {
        try Files.writeJSON(project, to: url)
        record("已匯出分析方法、候選與人工標註 JSON")
      } catch { self.error = error.localizedDescription }
    }
  }
  func exportCSV() {
    guard !busy else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.nameFieldStringValue = project.title + "-和聲.csv"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    func quote(_ text: String) -> String {
      "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    var lines = ["小節,起點秒,結尾秒,首音候選,推定Root,和弦候選,手動首音,手動Root,手動和弦,首音鎖定,Root鎖定,和弦鎖定,方法,待更新"]
    for r in project.regions.sorted(by: { $0.startBeat < $1.startBeat }) {
      let m = project.measures.first { $0.id == r.measureID }
      let e = r.evidence
      let row = [
        m?.number ?? "", String(project.timing.seconds(at: r.startBeat)),
        String(project.timing.seconds(at: r.endBeat)), e?.firstPitch.map(Pitch.name) ?? "",
        e?.root.map(Pitch.pc) ?? "", e?.chord ?? "", r.annotation.firstNote, r.annotation.root,
        r.annotation.chord, String(r.annotation.firstLocked), String(r.annotation.rootLocked),
        String(r.annotation.chordLocked), e?.method ?? "",
        String(e.map { $0.timingRevision != project.timing.revision } ?? false),
      ]
      lines.append(row.map(quote).joined(separator: ","))
    }
    do {
      try ("\u{FEFF}" + lines.joined(separator: "\n")).write(
        to: url, atomically: true, encoding: .utf8)
      record("已匯出逐區間和聲 CSV")
    } catch { self.error = error.localizedDescription }
  }
  func exportMusicXML() {
    guard !busy else { return }
    do {
      let data = try ScoreIO.annotatedXML(project, folder: folder)
      let panel = NSSavePanel()
      panel.allowedContentTypes = [UTType(filenameExtension: "musicxml") ?? .xml]
      panel.nameFieldStringValue = project.title + "-和聲標註.musicxml"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      try data.write(to: url, options: .atomic)
      record("已匯出完整 MusicXML 副本，僅新增已鎖定的和弦文字，保留原音符與 TAB")
    } catch { self.error = error.localizedDescription }
  }
  func editInMuseScore() {
    guard !busy, project.score != nil else { return }
    do {
      let copy = try prepareScoreEditingCopy()
      guard NSWorkspace.shared.open(copy) else { throw WorkbenchError.message("無法開啟樂譜編輯副本。") }
      record("已開啟編輯副本 · 儲存後可更新參考譜")
    } catch { self.error = error.localizedDescription }
  }
  func prepareScoreEditingCopy() throws -> URL {
    guard !busy, let score = project.score else { throw WorkbenchError.message("請先匯入樂譜。") }
    if let path = project.editingScorePath {
      let copy = folder.appendingPathComponent(path)
      if FileManager.default.isReadableFile(atPath: copy.path) { return copy }
    }
    let exports = folder.appendingPathComponent("exports")
    try Files.directory(exports)
    let name = URL(fileURLWithPath: score.originalName)
    let source = folder.appendingPathComponent(score.originalPath)
    let copy = exports.appendingPathComponent(
      "\(name.deletingPathExtension().lastPathComponent)-編輯副本-\(UUID().uuidString)"
    ).appendingPathExtension(source.pathExtension)
    try FileManager.default.copyItem(at: source, to: copy)
    var revised = project
    revised.editingScorePath = "exports/\(copy.lastPathComponent)"
    do { try ProjectStore.save(revised, to: folder) }
    catch {
      try? FileManager.default.removeItem(at: copy)
      throw error
    }
    project = revised
    return copy
  }
  func roleName(_ role: String) -> String {
    ["original": "原曲", "bass": "Bass stem", "accompaniment": "伴奏", "other": "其他 stem"][role] ?? role
  }
}
