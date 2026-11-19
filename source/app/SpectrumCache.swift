import CryptoKit
import Foundation

/// 只讀已完成的特徵快取；切換畫面不啟動 Python，也不重新計算和聲。
enum SpectrumCache {
  // 與 worker/analysis.py 的 METHOD 一致；方法升版後不採用舊圖。
  static let method = "librosa-0.11-cqt-chroma-template-v3"

  struct Query: Equatable, Sendable {
    var sourceHash: String
    var offset: Double
    var start: Double
    var end: Double
    var minMIDI: Int
    var maxMIDI: Int
    var binsPerOctave: Int

    func sameSource(as other: Query) -> Bool {
      sourceHash == other.sourceHash && offset == other.offset &&
        minMIDI == other.minMIDI && maxMIDI == other.maxMIDI &&
        binsPerOctave == other.binsPerOctave
    }
  }

  static func restore(in directory: URL, matching query: Query, reusing existing: [SpectrumData] = []) -> [SpectrumData] {
    guard query.start.isFinite, query.end.isFinite, query.offset.isFinite,
      query.end > query.start,
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return [] }

    let decoder = JSONDecoder()
    let candidates = files.filter { $0.pathExtension == "json" }.compactMap {
      url -> AnalysisFeatures? in
      guard let bytes = try? Data(contentsOf: url),
        let metadata = try? decoder.decode(AnalysisFeatures.self, from: bytes),
        metadata.cacheKey == url.deletingPathExtension().lastPathComponent,
        metadata.method == method, metadata.sourceHash == query.sourceHash,
        metadata.minMIDI == query.minMIDI, metadata.maxMIDI == query.maxMIDI,
        metadata.binsPerOctave == query.binsPerOctave,
        metadata.start.isFinite, metadata.end.isFinite,
        metadata.start < query.end, metadata.end > query.start,
        metadata.end > metadata.start, metadata.end - metadata.start <= 90,
        metadata.sampleRate == 22050, metadata.hop == 256,
        metadata.frameOrigin.isFinite,
        abs(metadata.frameOrigin - max(metadata.start, query.offset)) <= Double(metadata.hop) / metadata.sampleRate,
        metadata.frameOrigin <= metadata.end,
        metadata.rows == (query.maxMIDI - query.minMIDI) * query.binsPerOctave / 12 + 1,
        metadata.rows > 0, metadata.rows <= 256, metadata.columns > 0,
        metadata.columns <= Int(
          ceil((metadata.end - metadata.start) * metadata.sampleRate / Double(metadata.hop))) + 2,
        matchesKey(metadata, offset: query.offset)
      else { return nil }
      return metadata
    }.sorted {
      let leftCovers = $0.start <= query.start && $0.end >= query.end
      let rightCovers = $1.start <= query.start && $1.end >= query.end
      if leftCovers != rightCovers { return leftCovers }
      let left = $0.end - $0.start
      let right = $1.end - $1.start
      return left == right ? $0.cacheKey < $1.cacheKey : left < right
    }

    var remaining = [query.start..<query.end]
    var segments: [SpectrumData] = []
    for var metadata in candidates {
      if Task.isCancelled { return [] }
      let step = Double(metadata.hop) / metadata.sampleRate
      let first = max(metadata.start, metadata.frameOrigin - step / 2)
      let last = min(metadata.end, metadata.frameOrigin + (Double(metadata.columns) - 0.5) * step)
      guard first < last else { continue }
      let coverage = first..<last
      guard remaining.contains(where: { $0.overlaps(coverage) }) else { continue }
      // 以目前專案內的路徑讀取，專案搬家／另存後不沿用舊的絕對路徑。
      let binary = directory.appendingPathComponent(metadata.cacheKey + ".f32")
      if let loaded = existing.first(where: {
        $0.metadata.cacheKey == metadata.cacheKey && $0.metadata.binaryPath == binary.path &&
          $0.metadata.cacheHit && $0.metadata.pitchTrace == metadata.pitchTrace
      }) {
        segments.append(loaded)
      } else {
        guard let bytes = try? Data(contentsOf: binary),
          bytes.count == metadata.rows * metadata.columns * 4
        else { continue }
        let values = bytes.withUnsafeBytes { raw -> [Float] in
          var values = [Float](repeating: 0, count: metadata.rows * metadata.columns)
          _ = values.withUnsafeMutableBytes { raw.copyBytes(to: $0) }
          return values
        }
        guard values.allSatisfy({ $0.isFinite }) else { continue }
        metadata.binaryPath = binary.path
        metadata.cacheHit = true
        segments.append(SpectrumData(metadata: metadata, values: values))
      }
      remaining = remaining.flatMap { gap -> [Range<Double>] in
        guard gap.overlaps(coverage) else { return [gap] }
        var uncovered: [Range<Double>] = []
        if gap.lowerBound < coverage.lowerBound {
          uncovered.append(gap.lowerBound..<coverage.lowerBound)
        }
        if coverage.upperBound < gap.upperBound {
          uncovered.append(coverage.upperBound..<gap.upperBound)
        }
        return uncovered
      }
      if remaining.isEmpty { break }
    }
    return segments
  }

  private static func matchesKey(_ metadata: AnalysisFeatures, offset: Double) -> Bool {
    // 舊快取未另外記錄 offset，因此重算 Python 的 SHA256 key 來核對來源偏移。
    // JSONL 可能把整數值傳為 0 或 0.0；兩者的 Python JSON key 都需相容。
    func numbers(_ value: Double) -> [String] {
      var result = [String(value)]
      if value.rounded() == value, abs(value) < 1_000_000 {
        result.append(String(Int(value)))
      }
      return result
    }
    func quoted(_ value: String) -> String {
      let data = try! JSONSerialization.data(
        withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
      return String(decoding: data, as: UTF8.self)
    }
    for start in numbers(metadata.start) {
      for end in numbers(metadata.end) {
        for sourceOffset in numbers(offset) {
          let json =
            "{\"binsPerOctave\":\(metadata.binsPerOctave),\"end\":\(end),\"hash\":\(quoted(metadata.sourceHash)),\"maxMIDI\":\(metadata.maxMIDI),\"method\":\(quoted(metadata.method)),\"minMIDI\":\(metadata.minMIDI),\"offset\":\(sourceOffset),\"start\":\(start)}"
          let key = SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
          if key == metadata.cacheKey { return true }
        }
      }
    }
    return false
  }
}
