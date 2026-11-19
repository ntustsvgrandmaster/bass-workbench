// 檔案與本機程序的小型工具；不負責音訊分析或人工標註。

import CryptoKit
import Foundation

enum Files {
  /// 串流計算內容 hash；快取與重新連結檔案都依內容判斷，不只比較檔名。
  static func hash(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  static func directory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }
  static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
  }
  /// 執行本機 MuseScore／unzip 等工具。acceptOutput 僅允許呼叫者在輸出存在時繼續驗證。
  static func run(
    _ executable: URL, _ args: [String], timeout: Double = 90, acceptOutput: URL? = nil
  ) throws -> Data {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = args
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
    let result = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    deadline.cancel()
    if process.terminationStatus != 0 {
      // 某些 MuseScore 版本已成功輸出卻在程序結束時回報失敗；稍後仍須真正解析 XML 才算匯入成功。
      let exists =
        acceptOutput.map { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }
        ?? false
      guard exists else {
        throw WorkbenchError.message(
          "本機轉檔失敗或逾時（\(process.terminationStatus)）。請用 MuseScore 手動匯出 MusicXML 再匯入。")
      }
    }
    return result
  }
}
