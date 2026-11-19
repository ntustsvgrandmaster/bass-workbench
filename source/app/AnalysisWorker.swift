// Swift 與 Python 的 JSONL 橋接器。一次只接受一個請求，避免兩次結果寫到同一個等待者。

import Darwin
import Foundation

protocol AnalysisRequesting: AnyObject {
  func request(_ values: [String: Any], cacheRoot: URL,
               progress: @escaping (Double, String) -> Void) async throws -> Data
  func cancel()
}

final class AnalysisWorker: AnalysisRequesting, @unchecked Sendable {
  private var process: Process?
  private var input: FileHandle?
  private var buffer = Data()
  // Process 讀取／結束回呼不保證在主執行緒；pending、buffer 與 generation 必須由同一把鎖保護。
  private let lock = NSLock()
  private var pending:
    (
      id: String, continuation: CheckedContinuation<Data, Error>, progress: (Double, String) -> Void
    )?
  private var generation = 0
  private let pythonOverride: URL?
  private let scriptOverride: URL?
  private let oneShot: Bool
  init(python: URL? = nil, script: URL? = nil, oneShot: Bool = false) {
    pythonOverride = python; scriptOverride = script; self.oneShot = oneShot
  }
  func request(
    _ values: [String: Any], cacheRoot: URL, progress: @escaping (Double, String) -> Void
  ) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      defer { lock.unlock() }
      guard pending == nil else {
        continuation.resume(throwing: WorkbenchError.message("已有本機分析執行中。"))
        return
      }
      let id = UUID().uuidString
      do {
        try start(cacheRoot)
        var payload = values
        payload["id"] = id
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(10)
        pending = (id, continuation, progress)
        try input?.write(contentsOf: data)
      } catch {
        pending = nil
        continuation.resume(throwing: error)
      }
    }
  }
  private func start(_ cache: URL) throws {
    if process?.isRunning == true { return }
    let resources =
      Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let python =
      pythonOverride ?? ProcessInfo.processInfo.environment["BASS_WORKER_PYTHON"].map { URL(fileURLWithPath: $0) }
      ?? resources.appendingPathComponent("python/bin/python3.12")
    let script =
      scriptOverride ?? ProcessInfo.processInfo.environment["BASS_WORKER_SCRIPT"].map { URL(fileURLWithPath: $0) }
      ?? resources.appendingPathComponent("worker/main.py")
    guard FileManager.default.isExecutableFile(atPath: python.path),
      FileManager.default.fileExists(atPath: script.path)
    else { throw WorkbenchError.message("App 缺少本機分析環境，請使用完整的應用程式套件。") }
    try Files.directory(cache)
    let p = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    p.executableURL = python
    p.arguments = ["-u", script.path]
    p.standardInput = stdin
    p.standardOutput = stdout
    let log = cache.appendingPathComponent("worker.log")
    if !FileManager.default.fileExists(atPath: log.path) {
      FileManager.default.createFile(atPath: log.path, contents: nil)
    }
    let errors = try FileHandle(forWritingTo: log)
    try errors.seekToEnd()
    p.standardError = errors
    // Python／Numba 快取放在專案 derived，不改寫已簽章的 app，也不使用使用者 site-packages。
    var environment = ProcessInfo.processInfo.environment
    environment["PYTHONNOUSERSITE"] = "1"
    environment["PYTHONPYCACHEPREFIX"] = cache.appendingPathComponent("pycache").path
    environment["NUMBA_CACHE_DIR"] = cache.appendingPathComponent("numba").path
    environment["NUMBA_NUM_THREADS"] = "2"
    environment["OMP_NUM_THREADS"] = "2"
    environment["OPENBLAS_NUM_THREADS"] = "2"
    p.environment = environment
    // generation 區分不同程序生命週期：取消後，舊程序遲到的輸出不能完成新請求。
    generation += 1
    let token = generation
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if !data.isEmpty { self?.receive(data, token: token) }
    }
    p.terminationHandler = { [weak self] _ in
      try? errors.close()
      self?.ended(token)
    }
    try p.run()
    process = p
    input = stdin.fileHandleForWriting
    buffer = Data()
  }
  private func receive(_ data: Data, token: Int) {
    lock.lock()
    guard token == generation else {
      lock.unlock()
      return
    }
    // Pipe 一次讀到的 bytes 不一定是一整行；先累積至換行再解析 JSON。
    buffer.append(data)
    var lines: [Data] = []
    while let newline = buffer.firstIndex(of: 10) {
      lines.append(Data(buffer[..<newline]))
      buffer.removeSubrange(...newline)
    }
    lock.unlock()
    for line in lines {
      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        let id = object["id"] as? String
      else { continue }
      lock.lock()
      guard let p = pending, p.id == id else {
        lock.unlock()
        continue
      }
      switch object["type"] as? String {
      // 回呼與 continuation.resume 在解鎖後執行，避免外層回呼再次進入時死鎖。
      case "progress":
        lock.unlock()
        p.progress(object["progress"] as? Double ?? 0, object["message"] as? String ?? "")
      case "result":
        pending = nil
        lock.unlock()
        if oneShot { cancel() }
        do {
          p.continuation.resume(
            returning: try JSONSerialization.data(withJSONObject: object["result"] ?? [:]))
        } catch { p.continuation.resume(throwing: error) }
      case "error":
        pending = nil
        lock.unlock()
        if oneShot { cancel() }
        p.continuation.resume(
          throwing: WorkbenchError.message(object["message"] as? String ?? "本機分析失敗。"))
      default: lock.unlock()
      }
    }
  }
  private func ended(_ token: Int) {
    lock.lock()
    defer { lock.unlock() }
    guard token == generation else { return }
    if let p = pending {
      pending = nil
      p.continuation.resume(
        throwing: WorkbenchError.message("本機分析程序已結束；可重新分析。紀錄保存於 worker.log。"))
    }
  }
  /// 先使請求失效並喚醒等待者，再終止程序；逾時強制結束的對象仍是同一個 Process。
  func cancel() {
    lock.lock()
    let p = process
    generation += 1
    process = nil
    input = nil
    buffer = Data()
    let continuation = pending?.continuation
    pending = nil
    lock.unlock()
    continuation?.resume(throwing: CancellationError())
    if let p, p.isRunning {
      p.terminate()
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
      }
    }
  }
  deinit { cancel() }
}
