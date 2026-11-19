import CryptoKit
import Foundation

/// 與 Python HARMONY_METHOD 同步；改方法後舊結果仍保存，但不可被全曲續跑直接略過。
enum AnalysisMethod {
  static let harmony = "librosa-0.11-cqt-chroma-template-v3 / bass-salience-octave-v2"
  static let sourceHarmony = harmony + " / source-tiles-v1"
  static let tunedHarmony = sourceHarmony + " / global-tuning-v1"
  static let btcHarmony = "btc-ismir19-majmin-v1"
}

/// BTC frames live in the original file's clock. Mapping them to regions is independent of inference.
struct BTCSong: Decodable, Sendable {
  let method: String
  let sourceHash: String
  let duration: Double
  let step: Double
  let firstBar: Double?
  let cached: Bool
  let scores: [[Double]]

  func validate(source: MediaAsset) throws {
    guard sourceHash == source.hash, method == AnalysisMethod.btcHarmony,
      abs(duration - source.duration) <= 0.01, abs(step - 10.0 / 108) < 1e-9,
      abs(Double(scores.count) - ceil(duration / step - 1e-9)) < 1,
      scores.allSatisfy({ $0.count == 25 && $0.allSatisfy { (0...1).contains($0) } })
    else { throw WorkbenchError.message("BTC 結果與目前音源不符，請重新分析。") }
  }

  func evidence(for item: AnalysisItem, source: MediaAsset, revision: Int, bass: HarmonyEvidence?,
                createdAt: String) -> HarmonyEvidence {
    let start = max(0, item.start - source.offset)
    let end = min(duration, item.end - source.offset)
    let first = min(scores.count, Int(floor(start / step)))
    let last = max(first, min(scores.count, Int(ceil(end / step))))
    var totals = Array(repeating: 0.0, count: 25)
    for frame in first..<last {
      let overlap = max(0, min(end, Double(frame + 1) * step) - max(start, Double(frame) * step))
      for label in totals.indices { totals[label] += scores[frame][label] * overlap }
    }
    if end > start { totals = totals.map { $0 / (end - start) } }
    let roots = (0..<12).map { totals[$0 * 2] + totals[$0 * 2 + 1] }
    let rankedRoots = roots.indices.sorted { roots[$0] > roots[$1] }
    let ranked = (0..<24).sorted { totals[$0] > totals[$1] }
    let winner = ranked[0], root = rankedRoots[0]
    let hasChord = totals[winner] > totals[24]
    let candidates: [ChordCandidate] = hasChord ? ranked.prefix(5).filter { totals[$0] > 0 }.map { label in
      let pitch = label / 2
      let minor = label % 2 == 1
      return ChordCandidate(root: pitch, quality: minor ? "minor" : "major",
        symbol: Pitch.pc(pitch) + (minor ? "m" : ""), score: totals[label],
        support: ["BTC 區間模型分數"], conflict: [])
    } : []
    return HarmonyEvidence(
      contextKey: item.contextKey, firstPitch: bass?.firstPitch, firstTime: bass?.firstTime,
      firstScore: bass?.firstScore ?? 0, bassCenter: bass?.bassCenter, bassStrongBeat: bass?.bassStrongBeat,
      root: hasChord ? root : nil, chord: candidates.first?.symbol,
      rootMargin: hasChord ? roots[root] - roots[rankedRoots[1]] : 0,
      tuningCents: nil, candidates: candidates, chroma: [],
      warnings: hasChord ? [] : ["BTC 在這個區間未給出可用和弦。"],
      arrangementSource: source.hash, bassSource: bass?.bassSource ?? "",
      method: method, timingRevision: revision, createdAt: createdAt)
  }
}

struct AnalysisItem: Equatable, Sendable {
  var regionID: String
  var start: Double
  var end: Double
  var contextKey: String
}

struct AnalysisPlan: Sendable {
  let method: String
  var batches: [[AnalysisItem]] = []
  var reused = 0
  var excluded: [String] = []
  var pending: Int { batches.reduce(0) { $0 + $1.count } }
  var total: Int { reused + pending }

  init(project: Project, arrangement: MediaAsset, bass: MediaAsset,
       range: ClosedRange<Double>? = nil, resume: Bool = true, method: String = AnalysisMethod.harmony) {
    self.method = method
    var batch: [AnalysisItem] = []
    let names = Dictionary(project.measures.map { ($0.id, $0.number) }, uniquingKeysWith: { a, _ in a })
    for region in project.regions.sorted(by: { $0.startBeat < $1.startBeat }) {
      let rawStart = project.timing.seconds(at: region.startBeat)
      let rawEnd = project.timing.seconds(at: region.endBeat)
      if let range, !(rawEnd > range.lowerBound && rawStart < range.upperBound) { continue }
      let start = max(0, rawStart)
      // 最後一小節可能不完整；只裁掉原曲結束後的部分，不裁成任意視窗的「首音」。
      let end = min(rawEnd, project.masterEnd ?? rawEnd)
      let label = "第 \(names[region.measureID] ?? "?") 小節"
      guard rawStart.isFinite, rawEnd.isFinite, end - start >= 0.15,
        end - start <= 90 else {
        excluded.append("\(label)：區間須為 0.15–90 秒且位於原曲內。")
        continue
      }
      guard [arrangement, bass].allSatisfy({
        start >= max(0, $0.offset) - 1e-7 && end <= $0.offset + $0.duration + 1e-7
      }) else {
        excluded.append("\(label)：和聲或 Bass 來源未涵蓋完整區間。")
        continue
      }
      let context: [String: String] = [
        "method": method, "start": String(start), "end": String(end),
        "revision": String(project.timing.revision),
        "arrangement": arrangement.hash, "arrangementOffset": String(arrangement.offset),
        "arrangementRole": arrangement.role, "bass": bass.hash,
        "bassOffset": String(bass.offset), "bassRole": bass.role,
      ]
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      let key = SHA256.hash(data: (try? encoder.encode(context)) ?? Data()).map {
        String(format: "%02x", $0)
      }.joined()
      if resume, let evidence = region.evidence, evidence.contextKey == key,
        evidence.method == method,
        evidence.arrangementSource == arrangement.hash, evidence.bassSource == bass.hash,
        evidence.timingRevision == project.timing.revision {
        reused += 1
        continue
      }
      let item = AnalysisItem(regionID: region.id, start: start, end: end, contextKey: key)
      // 序列執行，單批最多 24 區間、90 秒；全曲不配置一張大型 CQT。
      if let first = batch.first, batch.count >= 24 || item.end - first.start > 90 {
        batches.append(batch)
        batch = []
      }
      batch.append(item)
    }
    if !batch.isEmpty { batches.append(batch) }
  }
}
