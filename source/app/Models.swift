// 共用資料模型。閱讀重點：所有音符時間以「四分音符拍」表示，播放與分析則使用秒。

import CoreGraphics
import Foundation

enum WorkbenchError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let s) = self { return s }
    return nil
  }
}

/// 用有理數保存 MusicXML 時值，避免三連音等節奏在反覆換算中累積浮點誤差。
struct Fraction: Codable, Hashable, Sendable {
  var n: Int
  var d: Int
  init(_ n: Int, _ d: Int = 1) {
    func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? max(1, abs(a)) : gcd(b, a % b) }
    let safe = d == 0 ? 1 : d
    let g = gcd(n, safe)
    self.n = n / g * (safe < 0 ? -1 : 1)
    self.d = abs(safe / g)
  }
  var value: Double { Double(n) / Double(d) }
  static func + (a: Self, b: Self) -> Self { Self(a.n * b.d + b.n * a.d, a.d * b.d) }
  static func - (a: Self, b: Self) -> Self { Self(a.n * b.d - b.n * a.d, a.d * b.d) }
}
struct ScoreNote: Codable, Identifiable, Equatable, Sendable {
  var id: String
  var partID: String
  var staffID: String
  var voice: String
  var measureID: String
  var onset: Fraction
  var duration: Fraction
  // MIDI 音高：soundingPitch 是實際發聲音高；writtenPitch 是譜面音高，Bass 移調時可能相差八度。
  var soundingPitch: Int?
  var writtenPitch: Int?
  var kind: String  // note, rest, ghost, grace
  var tieStart: Bool = false
  var tieStop: Bool = false
  var stringNumber: Int?
  var fret: Int?
  var beat: Double { onset.value }
  var end: Double { onset.value + duration.value }
  var name: String { soundingPitch.map(Pitch.name) ?? (kind == "rest" ? "休止" : "無固定音高") }
}
enum Pitch {
  static let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
  static func name(_ midi: Int) -> String { "\(names[(midi%12+12)%12])\(midi/12-1)" }
  static func pc(_ midi: Int) -> String { names[(midi % 12 + 12) % 12] }
}
struct ScoreMeasure: Codable, Identifiable, Equatable, Sendable {
  var id: String
  var index: Int
  var number: String
  var onset: Fraction
  var duration: Fraction
  var numerator: Int
  var denominator: Int
  var beat: Double { onset.value }
  var length: Double { duration.value }
  var end: Double { beat + length }
}
struct ScoreStaff: Codable, Identifiable, Equatable, Sendable {
  var id: String
  var partID: String
  var number: String
  var name: String
  var isTAB: Bool
}

/// 導覽的人工確認與譜面資訊分開判斷；空集合不能被當成「全部確認」。
struct MeasureNavigationState: Equatable {
  enum Confirmation { case none, partial, complete }
  enum NoteContent { case notes, empty, noScore, noStaff }
  enum Marker { case notes, empty, unavailable, partial, complete }
  let confirmedCount: Int
  let regionCount: Int
  let noteContent: NoteContent
  var confirmation: Confirmation {
    guard confirmedCount > 0 else { return .none }
    return confirmedCount == regionCount ? .complete : .partial
  }
  var marker: Marker {
    switch confirmation {
    case .partial: return .partial
    case .complete: return .complete
    case .none:
      switch noteContent {
      case .notes: return .notes
      case .empty: return .empty
      case .noScore, .noStaff: return .unavailable
      }
    }
  }
  var description: String {
    let annotation: String
    switch confirmation {
    case .none: annotation = "尚未人工確認"
    case .partial: annotation = "部分區間已確認（\(confirmedCount)/\(regionCount)）"
    case .complete: annotation = "全部區間已確認（\(regionCount)/\(regionCount)）"
    }
    let score: String
    switch noteContent {
    case .notes: score = "目前譜表有音符"
    case .empty: score = "目前譜表沒有一般音符，可能是休止，不代表漏譜"
    case .noScore: score = "尚未匯入樂譜，無譜面音符資訊"
    case .noStaff: score = "尚未選取有效譜表，無譜面音符資訊"
    }
    return "\(annotation)；\(score)"
  }
  init(project: Project, measureID: String) {
    var total = 0, confirmed = 0
    for region in project.regions where region.measureID == measureID {
      total += 1
      if region.annotation.confirmed { confirmed += 1 }
    }
    regionCount = total
    confirmedCount = confirmed
    if let score = project.score {
      if !score.staves.contains(where: { $0.id == project.selectedStaff }) {
        noteContent = .noStaff
      } else {
        noteContent = score.notes.contains {
          $0.measureID == measureID && $0.staffID == project.selectedStaff && $0.kind != "rest"
        } ? .notes : .empty
      }
    } else { noteContent = .noScore }
  }
}
struct ScoreDocument: Codable, Equatable, Sendable {
  var revision = UUID().uuidString
  var originalPath: String
  var xmlPath: String
  var sourceHash: String
  var originalName: String
  var staves: [ScoreStaff]
  var measures: [ScoreMeasure]
  var notes: [ScoreNote]
  var bpm: Double?
  var warnings: [String]
}
struct Anchor: Codable, Identifiable, Equatable, Sendable {
  var id = UUID().uuidString
  var beat: Double
  var seconds: Double
}
/// 手動錨點決定 beat ↔ seconds。錨點之間線性內插，兩端沿最近一段外推。
/// 尚未展開反覆或跳躍記號；只有一個錨點時，速度仍沿用 BPM。
struct TimingMap: Codable, Equatable, Sendable {
  var bpm: Double = 100
  // nil 與 0 相同，讓舊專案可直接解碼。正值把譜面／格線移到較晚的原音時間。
  var biasSeconds: Double?
  var anchors: [Anchor] = []
  var revision = 0
  var bias: Double { biasSeconds ?? 0 }
  var calibrated: Bool { !anchors.isEmpty || bias != 0 }
  func seconds(at beat: Double) -> Double { map(beat, reverse: false) + bias }
  func beat(at second: Double) -> Double { map(second - bias, reverse: true) }
  func seconds(of anchor: Anchor) -> Double { anchor.seconds + bias }
  private func map(_ value: Double, reverse: Bool) -> Double {
    let a = anchors.sorted { $0.beat < $1.beat }
    guard let first = a.first else { return reverse ? value * bpm / 60 : value * 60 / bpm }
    let x: (Anchor) -> Double = reverse ? { $0.seconds } : { $0.beat }
    let y: (Anchor) -> Double = reverse ? { $0.beat } : { $0.seconds }
    if a.count == 1 { return y(first) + (value - x(first)) * (reverse ? bpm / 60 : 60 / bpm) }
    // 外推也使用第一／最後一段斜率，因此正反映射一致；新增錨點會檢查秒數嚴格遞增。
    let i = min(a.lastIndex(where: { x($0) <= value }) ?? 0, a.count - 2)
    return y(a[i]) + (value - x(a[i])) * (y(a[i + 1]) - y(a[i])) / (x(a[i + 1]) - x(a[i]))
  }
  mutating func set(beat: Double, seconds: Double) throws {
    guard beat.isFinite, seconds.isFinite, bias.isFinite, beat >= 0 else {
      throw WorkbenchError.message("對齊拍數須為非負數，時間須為有效數字。")
    }
    var a = anchors.filter { abs($0.beat - beat) > 0.0001 }
    // 錨點保存偏移前的時間；新增點仍以使用者看到的主時間輸入。
    a.append(Anchor(beat: beat, seconds: seconds - bias))
    a.sort { $0.beat < $1.beat }
    for (l, r) in zip(a, a.dropFirst()) {
      guard r.seconds > l.seconds else { throw WorkbenchError.message("錨點時間必須依小節順序遞增，請先移除衝突的錨點。") }
    }
    anchors = a
    revision += 1
  }
}
struct MediaAsset: Codable, Identifiable, Equatable, Sendable {
  var id = UUID().uuidString
  var role: String
  var name: String
  var originalPath: String
  var pcmPath: String
  var hash: String
  var duration: Double
  var sampleRate: Double
  var channels: Int
  // 主時間 = 音檔內時間 + offset；正值表示此 stem 比原曲主時間較晚開始。
  var offset: Double = 0  // positive: asset starts later on master timeline
}
struct ChordCandidate: Codable, Identifiable, Equatable, Sendable {
  var root: Int
  var quality: String
  var symbol: String
  var score: Double
  var support: [String]
  var conflict: [String]
  var id: String { symbol }
}
/// 可重算的自動證據。首音與和聲根音來自不同分析步驟，nil 表示證據不足。
/// timingRevision 用來辨認對齊／分析來源變更後的過期結果。
struct HarmonyEvidence: Codable, Equatable, Sendable {
  // 舊專案沒有此欄；全曲續跑只略過來源、時間與方法均相同的結果。
  var contextKey: String?
  var firstPitch: Int?
  var firstTime: Double?
  var firstScore: Double
  var bassCenter: Int?
  var bassStrongBeat: Int?
  var root: Int?
  var chord: String?
  var rootMargin: Double
  var tuningCents: Double?
  var candidates: [ChordCandidate]
  var chroma: [Double]
  var warnings: [String]
  var arrangementSource: String
  var bassSource: String
  var method: String
  var timingRevision: Int
  var createdAt: String
}
/// 人工資料獨立於 Evidence；三個欄位各自鎖定，且「鎖定空字串」有保留未知的意義。
struct HumanAnnotation: Codable, Equatable, Sendable {
  var root: String = ""
  var chord: String = ""
  var firstNote: String = ""
  var rootLocked = false
  var chordLocked = false
  var firstLocked = false
  var rejected: [String] = []
  var confirmed = false
}
struct HarmonyRegion: Codable, Identifiable, Equatable, Sendable {
  var id = UUID().uuidString
  var measureID: String
  var startBeat: Double
  var endBeat: Double
  var evidence: HarmonyEvidence?
  var annotation = HumanAnnotation()
}
/// 各參考譜的工作資料；無譜格線也有自己的 context。完整 XML 留在 originals，
/// 此處只保存解析索引與工作資料；Swift 值型別陣列讓未修改的 undo 快照共用儲存。
struct ScoreContext: Codable, Identifiable, Equatable, Sendable {
  var id = UUID().uuidString
  var score: ScoreDocument?
  var scoreSourcePath: String?
  var editingScorePath: String?
  // nil 表示舊資料尚未記錄；不能以開啟專案的時間冒充匯入時間。
  var importedAt: Date?
  var displayNumber: Int?
  var estimatedGrid: EstimatedGrid?
  var timing = TimingMap()
  var alignmentConfirmed: Bool?
  var regions: [HarmonyRegion] = []
  var archivedRegions: [HarmonyRegion] = []
  var selectedMeasure = 0
  var selectedStaff = ""
  var removed = false
  var name: String { score?.originalName ?? "無譜格線" }
  private static let importTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "yyyy/MM/dd HH:mm"
    return formatter
  }()
  var importTimeDescription: String {
    guard let importedAt, importedAt.timeIntervalSince1970.isFinite else { return "匯入時間未記錄" }
    let text = Self.importTimeFormatter.string(from: importedAt)
    return text.isEmpty ? "匯入時間未記錄" : "匯入於 \(text)"
  }
}

struct Project: Codable, Equatable, Sendable {
  var practice = PracticeSettings()
  var version = 3
  var id = UUID().uuidString
  var title = "未命名採譜專案"
  var assets: [MediaAsset] = []
  var scoreContexts = [ScoreContext(id: "grid")]
  // 各原始檔名下一個可用編號；完成移除後也不讓新匯入占用舊版編號。
  var nextScoreNumber: [String: Int] = [:]
  var activeContextID = "grid"
  // 既有編輯／分析皆透過這些存取器讀寫作用中 context，沒有第二份作用中資料副本。
  private var contextIndex: Int { scoreContexts.firstIndex { $0.id == activeContextID } ?? 0 }
  var score: ScoreDocument? {
    get { scoreContexts[contextIndex].score }
    set {
      if score == nil, newValue != nil {
        var context = scoreContexts[contextIndex]
        context.id = UUID().uuidString
        context.score = newValue
        scoreContexts.append(context)
        activeContextID = context.id
      } else { scoreContexts[contextIndex].score = newValue }
      registerScoreNames()
    }
  }
  var editingScorePath: String? {
    get { scoreContexts[contextIndex].editingScorePath }
    set { scoreContexts[contextIndex].editingScorePath = newValue }
  }
  var scoreSourcePath: String? {
    get { scoreContexts[contextIndex].scoreSourcePath }
    set { scoreContexts[contextIndex].scoreSourcePath = newValue }
  }

  /// 相同小節格線可沿用小節身分，人工區間、分析證據與時間錨點不用重新掛接。
  mutating func updateReferenceScore(_ document: ScoreDocument) -> Bool {
    guard let previous = score, previous.measures.count == document.measures.count else { return false }
    var revised = document
    var measureIDs: [String: String] = [:]
    for i in revised.measures.indices {
      let newID = revised.measures[i].id
      revised.measures[i].id = previous.measures[i].id
      guard revised.measures[i] == previous.measures[i] else { return false }
      measureIDs[newID] = revised.measures[i].id
    }
    for i in revised.notes.indices {
      if let id = measureIDs[revised.notes[i].measureID] { revised.notes[i].measureID = id }
    }
    revised.originalName = previous.originalName
    scoreContexts[contextIndex].score = revised
    if !revised.staves.contains(where: { $0.id == selectedStaff }) {
      selectedStaff = revised.staves.first(where: { !$0.isTAB })?.id ?? revised.staves.first?.id ?? ""
    }
    return true
  }
  var estimatedGrid: EstimatedGrid? {
    get { scoreContexts[contextIndex].estimatedGrid }
    _modify { yield &scoreContexts[contextIndex].estimatedGrid }
  }
  var requiresAlignmentConfirmation: Bool {
    let context = scoreContexts[contextIndex]
    if let confirmed = context.alignmentConfirmed { return !confirmed }
    if score != nil || estimatedGrid != nil || timing.calibrated { return false }
    return !regions.contains { $0.evidence != nil || $0.annotation != HumanAnnotation() }
  }
  mutating func confirmAlignment() {
    if requiresAlignmentConfirmation { scoreContexts[contextIndex].alignmentConfirmed = true }
  }
  var timing: TimingMap {
    get { scoreContexts[contextIndex].timing }
    _modify { yield &scoreContexts[contextIndex].timing }
  }
  var regions: [HarmonyRegion] {
    get { scoreContexts[contextIndex].regions }
    _modify { yield &scoreContexts[contextIndex].regions }
  }
  var archivedRegions: [HarmonyRegion] {
    get { scoreContexts[contextIndex].archivedRegions }
    _modify { yield &scoreContexts[contextIndex].archivedRegions }
  }
  var selectedMeasure: Int {
    get { scoreContexts[contextIndex].selectedMeasure }
    _modify { yield &scoreContexts[contextIndex].selectedMeasure }
  }
  var selectedStaff: String {
    get { scoreContexts[contextIndex].selectedStaff }
    _modify { yield &scoreContexts[contextIndex].selectedStaff }
  }
  var selectedAsset = ""
  var harmonyAsset = ""
  var bassAsset = ""
  var a: Double = 0
  var b: Double = 4
  var loop = false
  var rate: Float = 1
  var minMIDI = 23
  var maxMIDI = 60
  var binsPerOctave = 24
  var contrast: Double = 65
  var createdAt = ISO8601DateFormatter().string(from: Date())
  var warnings: [String] = []
  var measures: [ScoreMeasure] {
    score?.measures ?? EstimatedGrid.measures(for: self)
  }
  init() {}

  var availableScoreContexts: [ScoreContext] { scoreContexts.filter { !$0.removed && $0.score != nil } }
  var removedScoreContexts: [ScoreContext] { scoreContexts.filter { $0.removed } }

  /// 第一份保留原名，後續為（1）、（2）；已保存的編號不因其他譜移除而重排。
  func scoreDisplayName(_ context: ScoreContext) -> String {
    let number = context.displayNumber ?? 0
    return number > 0 ? "\(context.name)（\(number)）" : context.name
  }
  var referenceScoreName: String {
    scoreDisplayName(scoreContexts[contextIndex])
  }
  var referenceScoreHelp: String {
    let context = scoreContexts[contextIndex]
    return context.score == nil ? referenceScoreName : "\(referenceScoreName)\n\(context.importTimeDescription)"
  }

  /// 舊專案按現存順序補固定編號，時間維持 nil；也接納既有直接設定 score 的呼叫。
  private mutating func registerScoreNames() {
    var used: [String: Set<Int>] = [:]
    for i in scoreContexts.indices where scoreContexts[i].score != nil {
      let name = scoreContexts[i].name
      if let number = scoreContexts[i].displayNumber, number >= 0,
        used[name, default: []].insert(number).inserted {
        nextScoreNumber[name] = max(nextScoreNumber[name] ?? 0, number < Int.max ? number + 1 : number)
      } else { scoreContexts[i].displayNumber = nil }
    }
    for i in scoreContexts.indices where scoreContexts[i].score != nil && scoreContexts[i].displayNumber == nil {
      let name = scoreContexts[i].name
      var number = max(0, nextScoreNumber[name] ?? 0)
      while used[name, default: []].contains(number) { number = number < Int.max ? number + 1 : 0 }
      scoreContexts[i].displayNumber = number
      used[name, default: []].insert(number)
      nextScoreNumber[name] = number < Int.max ? number + 1 : number
    }
  }

  /// 同內容只存在一份；重新匯入已移除譜時恢復其原工作資料。
  @discardableResult mutating func addScore(_ document: ScoreDocument, importedAt: Date = Date()) -> String {
    registerScoreNames()
    if let index = scoreContexts.firstIndex(where: { $0.score?.sourceHash == document.sourceHash }) {
      scoreContexts[index].removed = false
      activeContextID = scoreContexts[index].id
    } else {
      // 測試／舊呼叫可能直接設定 score；仍確保有獨立的無譜 context。
      if !scoreContexts.contains(where: { $0.score == nil }) {
        scoreContexts.append(ScoreContext(id: "grid"))
      }
      var context = ScoreContext(score: document)
      context.alignmentConfirmed = false
      context.importedAt = importedAt
      context.selectedStaff = document.staves.first(where: { !$0.isTAB })?.id
        ?? document.staves.first?.id ?? ""
      context.regions = document.measures.map {
        HarmonyRegion(measureID: $0.id, startBeat: $0.beat, endBeat: $0.end)
      }
      context.timing.bpm = document.bpm.flatMap { (20...400).contains($0) ? $0 : nil } ?? timing.bpm
      if score == nil && !scoreContexts.contains(where: { $0.score != nil }) {
        // 首份參考譜沿用無譜時已校準的第一小節起點。兩份格線的小節可不同，
        // 因此只帶入起點，不複製個別錨點或人工區間。
        let origin = timing.seconds(at: 0)
        if origin != 0 { context.timing.biasSeconds = origin }
      }
      scoreContexts.append(context)
      activeContextID = context.id
      registerScoreNames()
    }
    return activeContextID
  }

  @discardableResult mutating func selectScoreContext(_ id: String) -> Bool {
    guard let context = scoreContexts.first(where: { $0.id == id }), !context.removed else { return false }
    activeContextID = id
    selectedMeasure = min(max(0, selectedMeasure), max(0, measures.count - 1))
    reconcileEstimatedRegions()
    return true
  }

  @discardableResult mutating func removeScoreContext(_ id: String) -> Bool {
    guard let index = scoreContexts.firstIndex(where: { $0.id == id }),
      scoreContexts[index].score != nil, !scoreContexts[index].removed else { return false }
    scoreContexts[index].removed = true
    if activeContextID == id {
      let next = availableScoreContexts.first?.id ?? scoreContexts.first(where: { $0.score == nil })?.id
      if let next { _ = selectScoreContext(next) }
    }
    return true
  }

  @discardableResult mutating func restoreScoreContext(_ id: String) -> Bool {
    guard let index = scoreContexts.firstIndex(where: { $0.id == id && $0.removed }) else { return false }
    scoreContexts[index].removed = false
    return true
  }

  /// 僅供完成確認及清理舊快照：忘記指定譜的整份工作資料，永遠保留無譜格線。
  mutating func forgetScoreContexts(_ ids: Set<String>) {
    registerScoreNames()
    scoreContexts.removeAll { ids.contains($0.id) && $0.score != nil }
    if !scoreContexts.contains(where: { $0.id == activeContextID && !$0.removed }) {
      let next = availableScoreContexts.first?.id ?? scoreContexts.first(where: { $0.score == nil })!.id
      _ = selectScoreContext(next)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case version, id, title, assets, scoreContexts, activeContextID, nextScoreNumber
    case score, estimatedGrid, timing, regions, archivedRegions, selectedMeasure, selectedStaff
    case selectedAsset, harmonyAsset, bassAsset, a, b, loop, rate, minMIDI, maxMIDI, binsPerOctave
    case contrast, createdAt, warnings, practice
  }

  init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let format = try c.decode(Int.self, forKey: .version)
    guard [2, 3].contains(format) else { throw WorkbenchError.message("不支援的專案版本。") }
    id = try c.decode(String.self, forKey: .id)
    title = try c.decode(String.self, forKey: .title)
    assets = try c.decode([MediaAsset].self, forKey: .assets)
    selectedAsset = try c.decode(String.self, forKey: .selectedAsset)
    harmonyAsset = try c.decode(String.self, forKey: .harmonyAsset)
    bassAsset = try c.decode(String.self, forKey: .bassAsset)
    a = try c.decode(Double.self, forKey: .a)
    b = try c.decode(Double.self, forKey: .b)
    loop = try c.decode(Bool.self, forKey: .loop)
    rate = try c.decode(Float.self, forKey: .rate)
    practice = try c.decodeIfPresent(PracticeSettings.self, forKey: .practice) ?? PracticeSettings()
    guard practice.isValid else { throw WorkbenchError.message("節拍器／預備小節設定無效。") }
    minMIDI = try c.decode(Int.self, forKey: .minMIDI)
    maxMIDI = try c.decode(Int.self, forKey: .maxMIDI)
    binsPerOctave = try c.decode(Int.self, forKey: .binsPerOctave)
    contrast = try c.decode(Double.self, forKey: .contrast)
    createdAt = try c.decode(String.self, forKey: .createdAt)
    warnings = try c.decode([String].self, forKey: .warnings)
    nextScoreNumber = format == 3 ? try c.decodeIfPresent([String: Int].self, forKey: .nextScoreNumber) ?? [:] : [:]
    if format == 3 {
      scoreContexts = try c.decode([ScoreContext].self, forKey: .scoreContexts)
      activeContextID = try c.decode(String.self, forKey: .activeContextID)
      guard !scoreContexts.isEmpty,
        Set(scoreContexts.map(\.id)).count == scoreContexts.count,
        scoreContexts.filter({ $0.score == nil && !$0.removed }).count == 1,
        scoreContexts.contains(where: { $0.id == activeContextID && !$0.removed }) else {
        throw WorkbenchError.message("專案參考譜清單無效。")
      }
    } else {
      var context = ScoreContext(id: "grid")
      context.score = try c.decodeIfPresent(ScoreDocument.self, forKey: .score)
      context.estimatedGrid = try c.decodeIfPresent(EstimatedGrid.self, forKey: .estimatedGrid)
      context.timing = try c.decode(TimingMap.self, forKey: .timing)
      context.regions = try c.decode([HarmonyRegion].self, forKey: .regions)
      context.archivedRegions = try c.decode([HarmonyRegion].self, forKey: .archivedRegions)
      context.selectedMeasure = try c.decode(Int.self, forKey: .selectedMeasure)
      context.selectedStaff = try c.decode(String.self, forKey: .selectedStaff)
      if context.score != nil {
        context.id = UUID().uuidString
        scoreContexts = [ScoreContext(id: "grid"), context]
      } else { scoreContexts = [context] }
      activeContextID = context.id
    }
    registerScoreNames()
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(version, forKey: .version)
    try c.encode(id, forKey: .id)
    try c.encode(title, forKey: .title)
    try c.encode(assets, forKey: .assets)
    try c.encode(scoreContexts, forKey: .scoreContexts)
    try c.encode(activeContextID, forKey: .activeContextID)
    try c.encode(nextScoreNumber, forKey: .nextScoreNumber)
    try c.encode(selectedAsset, forKey: .selectedAsset)
    try c.encode(harmonyAsset, forKey: .harmonyAsset)
    try c.encode(bassAsset, forKey: .bassAsset)
    try c.encode(a, forKey: .a)
    try c.encode(b, forKey: .b)
    try c.encode(loop, forKey: .loop)
    try c.encode(rate, forKey: .rate)
    try c.encode(practice, forKey: .practice)
    try c.encode(minMIDI, forKey: .minMIDI)
    try c.encode(maxMIDI, forKey: .maxMIDI)
    try c.encode(binsPerOctave, forKey: .binsPerOctave)
    try c.encode(contrast, forKey: .contrast)
    try c.encode(createdAt, forKey: .createdAt)
    try c.encode(warnings, forKey: .warnings)
  }
}
struct PitchTracePoint: Codable, Equatable, Sendable {
  var time: Double
  var midi: Double
}

struct AnalysisFeatures: Codable, Sendable {
  var cacheKey: String
  var method: String
  var sampleRate: Double
  var hop: Int
  var start: Double
  var end: Double
  var frameOrigin: Double
  var binsPerOctave: Int
  var minMIDI: Int
  var maxMIDI: Int
  var rows: Int
  var columns: Int
  var binaryPath: String
  var onsets: [Double]
  var lowWindowSeconds: Double
  var tuningCents: Double
  var elapsed: Double
  var cacheHit: Bool
  var warnings: [String]
  var sourceHash: String
  var pitchTrace: [PitchTracePoint]? = nil
}
/// 一次分析得到的頻率列 × 時間欄矩陣。只在主介面呼叫 render；影像快取依對比更新。
/// @unchecked Sendable 只是跨任務傳回資料的承諾，不表示可並行修改 imageCache。
final class SpectrumData: @unchecked Sendable {
  let metadata: AnalysisFeatures
  let values: [Float]
  init(metadata: AnalysisFeatures, values: [Float]) {
    self.metadata = metadata
    self.values = values
  }
  private var imageCache: (Double, CGImage)?
  func render(contrast: Double) -> CGImage? {
    if let cached = imageCache, cached.0 == contrast { return cached.1 }
    let data = self
    let rows = data.metadata.rows
    let columns = data.metadata.columns
    guard rows > 0, columns > 0, data.values.count == rows * columns else { return nil }
    var pixels = [UInt8](repeating: 0, count: rows * columns * 4)
    // Worker 的列由低音往高音排列，影像座標由上往下，所以繪製時反轉列順序。
    for row in 0..<rows {
      for column in 0..<columns {
        let value = Double(data.values[(rows - row - 1) * columns + column])
        let t = max(0, min(1, (value + contrast) / contrast))
        let i = (row * columns + column) * 4
        let red = t < 0.6 ? 0.04 + t * 0.12 : 0.11 + (t - 0.6) * 2.0
        let green = t < 0.6 ? 0.08 + t * 0.95 : 0.65 + (t - 0.6) * 0.7
        let blue = t < 0.6 ? 0.13 + t * 0.65 : 0.52 - (t - 0.6) * 0.65
        pixels[i] = UInt8(max(0, min(255, red * 255)))
        pixels[i + 1] = UInt8(max(0, min(255, green * 255)))
        pixels[i + 2] = UInt8(max(0, min(255, blue * 255)))
        pixels[i + 3] = 255
      }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    let image = CGImage(
      width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    if let image { imageCache = (contrast, image) }
    return image
  }

}
struct WaveformData: Sendable {
  var peaks: [Float]
  var duration: Double
}
