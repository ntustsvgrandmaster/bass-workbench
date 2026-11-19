import Foundation

struct AlignmentPoint: Equatable {
  var beat: Double
  var seconds: Double
}

extension TimingMap {
  /// 只描述已套用設定；多錨點時不把參考 BPM 說成整曲固定速度。
  var alignmentSummary: String {
    let tempo = String(format: "%.4f", bpm).replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
    let speed = anchors.count >= 2 ? "參考 \(tempo) BPM · 區段速度" : "\(tempo) BPM"
    return "\(speed) · 起點 \(String(format: "%+.3f", seconds(at: 0))) s · \(anchors.count) 錨點"
  }
  func validate() throws {
    guard bpm.isFinite, (20...400).contains(bpm), bias.isFinite, abs(bias) <= 3600,
      anchors.allSatisfy({ $0.beat.isFinite && $0.beat >= 0 && $0.seconds.isFinite }) else {
      throw WorkbenchError.message("對齊數值無效。")
    }
    let points = anchors.sorted { $0.beat < $1.beat }
    for (a, b) in zip(points, points.dropFirst()) {
      guard b.beat > a.beat, b.seconds > a.seconds else {
        throw WorkbenchError.message("錨點的拍數與時間須依序前進。")
      }
    }
  }
  mutating func setBias(_ seconds: Double) throws {
    guard seconds.isFinite, abs(seconds) <= 3600 else {
      throw WorkbenchError.message("整體偏移請輸入 -3600～3600 秒；正值往後、負值往前。")
    }
    guard seconds != bias else { return }
    biasSeconds = seconds == 0 ? nil : seconds
    revision += 1
  }

  /// 以相距較遠的兩個已知小節起點，同時估計速度與起點。取代舊錨點／偏移。
  func calibrated(from first: AlignmentPoint, to last: AlignmentPoint) throws -> TimingMap {
    guard first.beat.isFinite, last.beat.isFinite, first.seconds.isFinite, last.seconds.isFinite,
      first.beat >= 0, last.beat > first.beat, first.seconds >= 0,
      last.seconds > first.seconds + 0.04 else {
      throw WorkbenchError.message("請選兩個依序前進的小節起點，B 時間須晚於 A。")
    }
    let tempo = 60 * (last.beat - first.beat) / (last.seconds - first.seconds)
    guard tempo.isFinite, (20...400).contains(tempo) else {
      throw WorkbenchError.message("兩點換算的 BPM 超出 20～400，請檢查小節與秒數。")
    }
    var result = TimingMap(bpm: tempo)
    try result.set(beat: first.beat, seconds: first.seconds)
    try result.set(beat: last.beat, seconds: last.seconds)
    result.revision = revision + 1
    return result
  }
}

/// 譜面小節、拍線、音符、游標及點擊共用的主時間與畫面座標；不另外加顯示用偏移。
struct TimelineCoordinates {
  var start: Double
  var end: Double
  var width: Double
  var inset: Double = 0
  var span: Double { max(0.01, end - start) }
  var plotWidth: Double { max(1, width - inset) }
  func x(at seconds: Double) -> Double { inset + (seconds - start) / span * plotWidth }
  func seconds(at x: Double) -> Double {
    start + max(0, min(1, (x - inset) / plotWidth)) * span
  }
}

/// 畫面取景是暫態；不寫入專案，也不改變播放循環或譜音對齊。
enum ViewportMode: Equatable {
  case measure
  case manual(span: Double)
  case loop
  case loopZoom(ClosedRange<Int>)

  var isLoopView: Bool {
    switch self {
    case .loop, .loopZoom: return true
    default: return false
    }
  }
}

struct ViewportRange: Equatable {
  var start: Double
  var end: Double
  var span: Double { end - start }
}

struct MeasureRange {
  let indices: ClosedRange<Int>
  let first: String
  let last: String
  let includesWholeMeasures: Bool

  var numbers: String { indices.count == 1 ? first : "\(first)–\(last)" }
}

enum ViewportLayout {
  static func resizedMeasures(_ visible: ClosedRange<Int>, within bounds: ClosedRange<Int>,
                              factor: Double) -> ClosedRange<Int> {
    let count = Int(min(Double(bounds.count), max(1, (Double(visible.count) * factor).rounded())))
    let centered = visible.lowerBound + (visible.count - count) / 2
    let start = max(bounds.lowerBound, min(bounds.upperBound - count + 1, centered))
    return start...(start + count - 1)
  }

  static func clipped(_ range: ViewportRange, limit: Double) -> ViewportRange {
    guard limit.isFinite, limit > 0, range.start.isFinite, range.end.isFinite else {
      return ViewportRange(start: 0, end: 0)
    }
    let start = min(limit, max(0, range.start))
    return ViewportRange(start: start, end: min(limit, max(start, range.end)))
  }

  static func fitted(start: Double, span: Double, limit: Double) -> ViewportRange {
    guard start.isFinite, span.isFinite, span > 0, limit.isFinite, limit > 0 else {
      return ViewportRange(start: 0, end: 0)
    }
    let width = min(span, limit)
    let left = max(0, min(limit - width, start))
    return ViewportRange(start: left, end: left + width)
  }

  /// 游標仍在畫面內時完全不動；離開後才置於中央，避免每個音訊 tick 都平移／讀快取。
  static func following(position: Double, current: ViewportRange, span: Double,
                        limit: Double) -> ViewportRange {
    let range = fitted(start: current.start, span: span, limit: limit)
    guard position.isFinite,
      position < range.start - 1e-7 || position > range.end + 1e-7 else { return range }
    return fitted(start: position - range.span / 2, span: span, limit: limit)
  }
}

enum PlaybackTimeline {
  static func measureIndex(at second: Double, timing: TimingMap, measures: [ScoreMeasure]) -> Int? {
    guard second.isFinite, !measures.isEmpty else { return nil }
    let beat = timing.beat(at: second)
    return measures.lastIndex(where: { $0.beat <= beat + 1e-7 }) ?? 0
  }
  static func seconds(start: Double, sampleTime: Int64, sampleRate: Double,
                      loop: Bool, a: Double, b: Double) -> Double {
    guard sampleRate > 0, sampleRate.isFinite else { return start }
    var second = start + Double(sampleTime) / sampleRate
    if loop, b > a, second >= b { second = a + (second - b).truncatingRemainder(dividingBy: b - a) }
    return max(0, second)
  }
}

struct AlignmentDraft {
  var bpm = "100"
  var bias = "0"
  var validation: String?
  func isModified(from timing: TimingMap) -> Bool {
    var applied = AlignmentDraft()
    applied.reset(from: timing)
    return Double(bpm.trimmingCharacters(in: .whitespacesAndNewlines)) != Double(applied.bpm)
      || Double(bias.trimmingCharacters(in: .whitespacesAndNewlines)) != Double(applied.bias)
  }
  mutating func reset(from timing: TimingMap) {
    bpm = String(format: "%.6f", timing.bpm)
    bias = String(format: "%.6f", timing.bias)
    validation = nil
  }
  func timing(from current: TimingMap) throws -> TimingMap {
    guard let tempo = Double(bpm.trimmingCharacters(in: .whitespacesAndNewlines)),
      tempo.isFinite, (20...400).contains(tempo),
      let offset = Double(bias.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      throw WorkbenchError.message("BPM 須為 20～400，整體偏移請輸入有效秒數。")
    }
    let changesTempo = abs(tempo - current.bpm) > 1e-6
    if current.anchors.count >= 2, changesTempo {
      throw WorkbenchError.message("目前時間由多個錨點決定；請用兩點校正速度，或先清除錨點再修改 BPM。")
    }
    var result = current
    try result.setBias(offset)
    if changesTempo { result.bpm = tempo; result.revision = current.revision + 1 }
    return result
  }
}

struct TwoPointDraft {
  var firstIndex = 0
  var lastIndex = 0
  var firstSeconds = "0"
  var lastSeconds = "0"
  var validation: String?
  var hasInput: Bool { !firstSeconds.isEmpty || !lastSeconds.isEmpty }
  mutating func reset(from project: Project) {
    let measures = project.measures
    guard !measures.isEmpty else { return }
    firstIndex = min(max(0, project.selectedMeasure), max(0, measures.count - 1))
    lastIndex = min(firstIndex + 64, max(0, measures.count - 1))
    // 不能拿目前預測時間當作量測真值，否則只是把原本的偏差重新確認一次。
    firstSeconds = ""
    lastSeconds = ""
    validation = nil
  }
  func timing(from project: Project) throws -> TimingMap {
    let measures = project.measures
    guard measures.indices.contains(firstIndex), measures.indices.contains(lastIndex),
      let a = Double(firstSeconds.trimmingCharacters(in: .whitespacesAndNewlines)),
      let b = Double(lastSeconds.trimmingCharacters(in: .whitespacesAndNewlines)),
      b <= (project.masterEnd ?? .greatestFiniteMagnitude) else {
      throw WorkbenchError.message("請輸入音源內的小節起點秒數。")
    }
    return try project.timing.calibrated(from: AlignmentPoint(beat: measures[firstIndex].beat, seconds: a),
                                       to: AlignmentPoint(beat: measures[lastIndex].beat, seconds: b))
  }
}

/// 整個對齊區的工作副本。驗證全部欄位後才產生一份 Project，不逐欄寫回。
struct AlignmentEditorDraft {
  var bpm = "100"
  var firstBar = "0"
  var numerator = 4
  var denominator = 4
  var sourceOffset = "0"
  var useTwoPoints = false
  var points = TwoPointDraft()
  var validation: String?
  private(set) var anchorTiming = TimingMap()
  private var projectID = ""
  private var contextID = ""
  private var scoreRevision: String?
  private var baseTiming = TimingMap()
  private var baseGrid: EstimatedGrid?
  private var baseAsset: MediaAsset?
  private var baseMaster: MediaAsset?

  var isModified: Bool {
    Double(bpm.trimmingCharacters(in: .whitespacesAndNewlines)) != baseTiming.bpm
      || Double(firstBar.trimmingCharacters(in: .whitespacesAndNewlines)) != baseTiming.seconds(at: 0)
      || numerator != (baseGrid?.numerator ?? 4) || denominator != (baseGrid?.denominator ?? 4)
      || Double(sourceOffset.trimmingCharacters(in: .whitespacesAndNewlines)) != (baseAsset?.offset ?? 0)
      || anchorTiming != baseTiming || useTwoPoints || points.hasInput
  }
  mutating func reset(project: Project, asset: MediaAsset?) {
    projectID = project.id; contextID = project.activeContextID; scoreRevision = project.score?.revision
    baseTiming = project.timing; anchorTiming = project.timing; baseGrid = project.estimatedGrid
    baseAsset = asset; baseMaster = project.masterAsset
    bpm = String(project.timing.bpm); firstBar = String(project.timing.seconds(at: 0))
    numerator = project.estimatedGrid?.numerator ?? 4; denominator = project.estimatedGrid?.denominator ?? 4
    sourceOffset = String(asset?.offset ?? 0); useTwoPoints = false
    points.reset(from: project); validation = nil
  }
  func matches(project: Project, asset: MediaAsset?) -> Bool {
    project.id == projectID && project.activeContextID == contextID && project.score?.revision == scoreRevision
      && project.timing == baseTiming && project.estimatedGrid == baseGrid
      && asset == baseAsset && project.masterAsset == baseMaster
  }
  private func shiftedProject(_ project: Project) throws -> Project {
    guard let asset = baseAsset, let index = project.assets.firstIndex(where: { $0.id == asset.id }),
      let offset = Double(sourceOffset.trimmingCharacters(in: .whitespacesAndNewlines)),
      offset.isFinite, abs(offset) < 3600 else {
      throw WorkbenchError.message("音源偏移請輸入大於 -3600、小於 3600 的有效秒數。")
    }
    var result = project
    result.assets[index].offset = offset
    return result
  }
  func proposedMeasures(project: Project) -> [ScoreMeasure] {
    guard project.score == nil else { return project.measures }
    var projected = project
    projected.estimatedGrid = EstimatedGrid(id: baseGrid?.id ?? "legacy", numerator: numerator, denominator: denominator)
    return projected.measures
  }
  func timing(project: Project) throws -> TimingMap {
    let shifted = try shiftedProject(project)
    let result: TimingMap
    if useTwoPoints {
      var projected = shifted
      if projected.score == nil {
        projected.estimatedGrid = EstimatedGrid(id: baseGrid?.id ?? "legacy", numerator: numerator, denominator: denominator)
      }
      result = try points.timing(from: projected)
    } else {
      guard let tempo = Double(bpm.trimmingCharacters(in: .whitespacesAndNewlines)),
        tempo.isFinite, (20...400).contains(tempo),
        let start = Double(firstBar.trimmingCharacters(in: .whitespacesAndNewlines)), start.isFinite else {
        throw WorkbenchError.message("BPM 須為 20～400，第一小節起點請輸入有效秒數。")
      }
      guard anchorTiming.anchors.count < 2 || tempo == baseTiming.bpm else {
        throw WorkbenchError.message("區段速度由錨點決定；請用兩點校正，或在草稿中清除錨點後修改 BPM。")
      }
      var value = anchorTiming
      value.bpm = tempo
      // 起點是最終主時間；透過 bias 平移既有錨點，不重設／堆加另一個起點。
      let shift = start - value.seconds(at: 0)
      try value.setBias(value.bias + shift)
      result = value
    }
    try result.validate()
    let start = result.seconds(at: 0)
    guard start >= -3600, start < (shifted.masterEnd ?? .greatestFiniteMagnitude) else {
      throw WorkbenchError.message("第一小節起點須早於音檔結尾，且不可小於 -3600 秒。")
    }
    return result
  }
  func applying(to project: Project, asset: MediaAsset?) throws -> Project {
    guard matches(project: project, asset: asset) else {
      throw WorkbenchError.message("對齊或來源已變更；請按取消重新讀取設定後再修改。")
    }
    var result = try shiftedProject(project)
    var mapped = try timing(project: project)
    let meterChanged = project.score == nil && (numerator != (baseGrid?.numerator ?? 4)
      || denominator != (baseGrid?.denominator ?? 4))
    let createsGrid = project.score == nil && baseGrid == nil && project.requiresAlignmentConfirmation
    if project.score == nil {
      let input = GridInput(bpm: mapped.bpm, numerator: numerator, denominator: denominator,
        firstBar: mapped.seconds(at: 0))
      try input.validate(masterEnd: result.masterEnd)
      if meterChanged || createsGrid {
        try result.applyEstimatedGrid(input)
      }
    }
    // 多筆草稿操作只形成一個對齊版本；無變更則不新增 revision／undo。
    mapped.revision = baseTiming.revision
    if mapped != baseTiming || result.assets != project.assets || meterChanged || createsGrid {
      mapped.revision = baseTiming.revision + 1
    }
    result.timing = mapped
    result.reconcileEstimatedRegions()
    return result
  }
  mutating func nudge(_ seconds: Double) throws {
    guard let start = Double(firstBar.trimmingCharacters(in: .whitespacesAndNewlines)), start.isFinite else {
      throw WorkbenchError.message("第一小節起點請輸入有效秒數。")
    }
    firstBar = String(((start + seconds) * 1e9).rounded() / 1e9)
    validation = nil
  }
  mutating func addAnchor(beat: Double, seconds: Double, project: Project) throws {
    var value = try timing(project: project)
    try value.set(beat: beat, seconds: seconds)
    adopt(value)
  }
  mutating func removeAnchor(_ id: String, project: Project) throws {
    var value = try timing(project: project)
    value.anchors.removeAll { $0.id == id }
    adopt(value)
  }
  mutating func clearAnchors(project: Project) throws {
    // 先保留現有起點，再清除錨點；可讓使用者解開 BPM 欄位。
    anchorTiming.anchors = []
    validation = nil
  }
  private mutating func adopt(_ timing: TimingMap) {
    anchorTiming = timing; bpm = String(timing.bpm); firstBar = String(timing.seconds(at: 0))
    useTwoPoints = false; points.firstSeconds = ""; points.lastSeconds = ""; validation = nil
  }
}
