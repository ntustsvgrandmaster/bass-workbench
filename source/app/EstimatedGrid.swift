import Foundation

/// 無譜時只建立時間格線，不產生音符或替代完整原譜。拍號由使用者決定。
struct EstimatedGrid: Codable, Equatable, Sendable {
  var id = UUID().uuidString
  var numerator = 4
  var denominator = 4
  var isValid: Bool { (1...12).contains(numerator) && [2, 4, 8, 16].contains(denominator) }

  static func measures(for project: Project) -> [ScoreMeasure] {
    let grid = project.estimatedGrid ?? EstimatedGrid(id: "legacy")
    guard grid.isValid else { return [] }
    let length = Fraction(grid.numerator * 4, grid.denominator)
    let endBeat = project.timing.beat(at: project.masterEnd ?? (16 * length.value * 60 / project.timing.bpm))
    // 先檢查有限數值再轉 Int，避免損壞專案或尚未驗證的資料造成溢位。
    guard endBeat.isFinite, endBeat <= 400_000 else { return [] }
    let count = max(1, Int(ceil(max(0, endBeat) / length.value - 1e-9)))
    guard count <= 100_000 else { return [] }
    return (0..<count).map { i in
      ScoreMeasure(
        id: project.estimatedGrid == nil ? "empty-\(i)" : "grid-\(grid.id)-\(i)", index: i,
        number: "\(i + 1)", onset: Fraction(i * length.n, length.d), duration: length,
        numerator: grid.numerator, denominator: grid.denominator)
    }
  }
}

extension Project {
  // 切換聆聽 stem 不應改變全曲格線；以原曲（沒有原曲時為第一個素材）為主時間長度。
  var masterAsset: MediaAsset? { assets.first(where: { $0.role == "original" }) ?? assets.first }
  var masterEnd: Double? {
    guard let asset = masterAsset, asset.duration.isFinite, asset.offset.isFinite,
      asset.duration > 0, asset.duration + asset.offset > 0 else { return nil }
    return asset.duration + asset.offset
  }

  /// 延伸／縮短末端時保留既有區間（包含拆分）；移出的區間存入歷史。
  mutating func reconcileEstimatedRegions() {
    guard score == nil, !assets.isEmpty else { return }
    let measures = self.measures
    let ids = Set(measures.map(\.id))
    archivedRegions += regions.filter { !ids.contains($0.measureID) }
    regions.removeAll { !ids.contains($0.measureID) }
    let existing = Set(regions.map(\.measureID))
    regions += measures.filter { !existing.contains($0.id) }.map {
      HarmonyRegion(measureID: $0.id, startBeat: $0.beat, endBeat: $0.end)
    }
    selectedMeasure = min(max(0, selectedMeasure), max(0, measures.count - 1))
  }

  mutating func applyEstimatedGrid(_ input: GridInput) throws {
    guard score == nil else { throw WorkbenchError.message("已匯入樂譜，請使用譜面對齊。") }
    try input.validate(masterEnd: masterEnd)
    let grid = estimatedGrid ?? EstimatedGrid(id: "legacy")
    let unchanged = estimatedGrid != nil && grid.numerator == input.numerator && grid.denominator == input.denominator
      && timing.bpm == input.bpm && abs(timing.seconds(at: 0) - input.firstBar) < 1e-9
      && timing.anchors.count <= 1
    guard !unchanged else { reconcileEstimatedRegions(); return }
    archivedRegions += regions
    regions = []
    estimatedGrid = EstimatedGrid(numerator: input.numerator, denominator: input.denominator)
    timing.bpm = input.bpm
    timing.biasSeconds = nil
    timing.anchors = [Anchor(beat: 0, seconds: input.firstBar)]
    timing.revision += 1
    reconcileEstimatedRegions()
  }
}

struct GridInput: Equatable {
  var bpm: Double
  var numerator: Int
  var denominator: Int
  var firstBar: Double
  func validate(masterEnd: Double?) throws {
    guard bpm.isFinite, (20...400).contains(bpm),
      EstimatedGrid(numerator: numerator, denominator: denominator).isValid,
      firstBar.isFinite, firstBar >= -3600, firstBar < (masterEnd ?? .greatestFiniteMagnitude)
    else { throw WorkbenchError.message("BPM 須為 20–400、拍號須為 1–12／2、4、8 或 16；起點須早於音檔結尾，且不可小於 -3600 秒。") }
  }
}

struct GridDraft {
  var bpm = "100"
  var numerator = 4
  var denominator = 4
  var firstBar = "0"
  var validation: String?
  mutating func reset(from project: Project) {
    bpm = String(format: "%.4f", project.timing.bpm)
    numerator = project.estimatedGrid?.numerator ?? 4
    denominator = project.estimatedGrid?.denominator ?? 4
    firstBar = String(format: "%.4f", project.timing.seconds(at: 0))
    validation = nil
  }
  func input(masterEnd: Double?) throws -> GridInput {
    guard let tempo = Double(bpm.trimmingCharacters(in: .whitespacesAndNewlines)),
      let start = Double(firstBar.trimmingCharacters(in: .whitespacesAndNewlines))
    else { throw WorkbenchError.message("BPM 與起點請輸入有效數字。") }
    let result = GridInput(bpm: tempo, numerator: numerator, denominator: denominator, firstBar: start)
    try result.validate(masterEnd: masterEnd)
    return result
  }
}

struct TempoEstimate: Codable, Equatable, Sendable {
  var bpm: Double?
  var alternatives: [Double]
  var beats: [Double]
  var start: Double
  var end: Double
  var sourceHash: String
  var method: String
  var warnings: [String]
  var candidates: [TempoCandidate]? = nil
  var rawBPM: Double? = nil
  var resolutionMs: Double? = nil
  var elapsed: Double? = nil
  var estimator: String? = nil
  var weightsHash: String? = nil
  var downbeats: [Double]? = nil

  /// Tracker 的主假設置前；殘差不代表可跨半／倍速比較的正確機率。
  var buttonBPMS: [Double] {
    var values: [Double] = []
    for value in [bpm].compactMap({ $0 }) + alternatives {
      if value.isFinite, (20...400).contains(value), !values.contains(value) { values.append(value) }
    }
    return Array(values.prefix(3))
  }
  func fit(for bpm: Double) -> TempoFit? {
    candidates?.first(where: { $0.bpm == bpm })?.fit
  }
  var preferredBPM: Double? {
    let quality = ["good", "borderline", "poor", "insufficient"]
    func rank(_ bpm: Double) -> Int {
      fit(for: bpm).flatMap { quality.firstIndex(of: $0.status) } ?? quality.count
    }
    // 同級保留估測器排序。半速的殘差較小，未必代表它是正確的拍層級。
    return buttonBPMS.min { rank($0) < rank($1) }
  }
  var recommendedBPM: Double? {
    guard let bpm = preferredBPM,
      candidates == nil || ["good", "borderline"].contains(fit(for: bpm)?.status ?? "") else { return nil }
    return bpm
  }
}

struct TempoCandidate: Codable, Equatable, Sendable {
  var bpm: Double
  var originalBPM: Double
  var quantizedBPM: Double
  var usedFloat: Bool
  var multiplier: Double
  var fit: TempoFit
  var quantizedFit: TempoFit
  var originalFit: TempoFit
}

struct TempoFit: Codable, Equatable, Sendable {
  var intercept: Double
  var medianMs: Double
  var p95Ms: Double
  var maxMs: Double
  var driftMs: Double
  var count: Int
  var span: Double
  var coverage: Double
  var outlierFraction: Double
  var status: String
}

/// App 全域估測偏好，不隨專案或參考譜切換；舊資料預設 librosa。
enum TempoEstimator: String, CaseIterable, Identifiable {
  case librosa, small0
  var id: String { rawValue }
  var title: String { self == .librosa ? "librosa" : "Beat This! small0" }
}
struct Small0Installation: Codable, Equatable {
  var python: String
  var checkpoint: String
  static let weightsHash = "6074be2c4d490c5f6101fcc374a1ec72ae93456e23bb6019783b849f5dc7d47b"
  var available: Bool {
    FileManager.default.isExecutableFile(atPath: python)
      && FileManager.default.fileExists(atPath: checkpoint)
  }
  static func discover() -> Small0Installation? {
    let url = ProcessInfo.processInfo.environment["BASS_SMALL0_CONFIG"].map { URL(fileURLWithPath:$0) }
      ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        .appendingPathComponent("BassHarmony/models/small0.json")
    guard let data = try? Data(contentsOf:url) else { return nil }
    return try? JSONDecoder().decode(Self.self,from:data)
  }
}

struct BTCInstallation: Codable {
  var python: String
  var checkout: String

  var available: Bool {
    let root = URL(fileURLWithPath: checkout)
    return FileManager.default.isExecutableFile(atPath: python)
      && ["btc_model.py", "run_config.yaml", "test/btc_model.pt"].allSatisfy {
        FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
      }
  }

  static func discover() -> Self? {
    let configured = ProcessInfo.processInfo.environment["BASS_BTC_CONFIG"].map { URL(fileURLWithPath: $0) }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("BassHarmony/models/btc.json")
    let bundled = Bundle.main.url(forResource: "btc-local", withExtension: "json")
    for url in [configured, support, bundled].compactMap({ $0 }) {
      if let data = try? Data(contentsOf: url),
        let model = try? JSONDecoder().decode(Self.self, from: data), model.available { return model }
    }
    return nil
  }
}
