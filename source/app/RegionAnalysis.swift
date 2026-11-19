import Foundation

/// 不依賴播放或畫面，可用假 Worker 驗證取消、續跑與遲到結果。
@MainActor final class RegionAnalysis {
  private let worker: AnalysisRequesting
  private var generation = UUID()
  private var activeRequest: UUID?
  private(set) var running = false

  init(worker: AnalysisRequesting) { self.worker = worker }

  func cancel() {
    generation = UUID()
    activeRequest = nil
    running = false
    worker.cancel()
  }

  func run(_ plan: AnalysisPlan, arrangement: [String: Any], bass: [String: Any],
           revision: Int, cache: URL, runtime: URL,
           progress: @escaping (Double, String) -> Void,
           receive: (AnalysisItem, HarmonyEvidence, Data) throws -> Void) async throws {
    guard !running else { throw WorkbenchError.message("已有全曲分析執行中。") }
    let token = UUID()
    generation = token
    running = true
    defer { if generation == token { running = false } }
    var completed = plan.reused
    for (batchIndex, batch) in plan.batches.enumerated() {
      for item in batch {
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        let base = completed
        let requestID = UUID()
        activeRequest = requestID
        let prefix = "第 \(batchIndex + 1)/\(plan.batches.count) 批 · \(completed)/\(plan.total) 區間"
        let request: [String: Any] = [
          "op": "harmony", "arrangement": arrangement, "bass": bass,
          "start": item.start, "end": item.end, "timingRevision": revision, "cache": cache.path,
          "method": plan.method,
        ]
        let data = try await worker.request(request, cacheRoot: runtime) { [weak self] value, message in
          Task { @MainActor in
            guard self?.generation == token, self?.running == true,
              self?.activeRequest == requestID else { return }
            progress((Double(base) + min(1, max(0, value))) / Double(max(1, plan.total)),
                     "\(prefix) · \(message)")
          }
        }
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        activeRequest = nil
        var evidence = try JSONDecoder().decode(HarmonyEvidence.self, from: data)
        guard evidence.timingRevision == revision, evidence.method == plan.method,
          evidence.arrangementSource == arrangement["hash"] as? String,
          evidence.bassSource == bass["hash"] as? String else {
          throw WorkbenchError.message("分析回傳的來源或版本不符，已保留先前完成的結果。")
        }
        evidence.contextKey = item.contextKey
        try receive(item, evidence, data)
        completed += 1
        progress(Double(completed) / Double(max(1, plan.total)),
                 "第 \(batchIndex + 1)/\(plan.batches.count) 批 · \(completed)/\(plan.total) 區間")
      }
    }
  }
}
