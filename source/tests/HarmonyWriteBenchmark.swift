import Foundation

private struct Capture: Decodable {
  struct Entry: Decodable { let id: String; let result: HarmonyEvidence }
  let results: [Entry]
}

@main private struct BassHarmonyWriteBenchmark {
  static func main() throws {
    let args = CommandLine.arguments
    guard args.count == 4 else {
      print("Usage: harmony-write-benchmark <project-copy> <new-output-directory> <worker-capture>")
      return
    }
    let input = URL(fileURLWithPath: args[1])
    let output = URL(fileURLWithPath: args[2])
    guard !FileManager.default.fileExists(atPath: output.path) else {
      throw CocoaError(.fileWriteFileExists)
    }
    let entries = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: URL(fileURLWithPath: args[3]))).results
    let project = try ProjectStore.load(input)
    let encoder = JSONEncoder()
    let items = try entries.map { entry in (entry, try encoder.encode(entry.result)) }
    let clock = ContinuousClock()
    for run in 0..<3 {
      for group in (run % 2 == 0 ? [1, 8] : [8, 1]) {
        let directory = output.appendingPathComponent("\(run)-\(group)")
        try Files.directory(directory)
        try ProjectStore.save(project, to: directory)
        var current = project
        var transactions = 0
        let begin = clock.now
        for i in stride(from: 0, to: items.count, by: group) {
          let batch = items[i..<min(i+group,items.count)]
          for (entry, _) in batch {
            let index = current.regions.firstIndex(where: { $0.id == entry.id })!
            current.regions[index].evidence = entry.result
          }
          if group == 1 {
            try ProjectStore.save(current, to: directory)
            try ProjectStore.appendRun(batch.first!.1, to: directory)
          } else {
            try ProjectStore.save(current, to: directory, analysisRuns: batch.map { $0.1 })
          }
          transactions += group == 1 ? 2 : 1
        }
        let time = begin.duration(to: clock.now).components
        let restored = try ProjectStore.load(directory)
        precondition(restored.regions.count == entries.count
          && restored.regions.map(\.annotation) == project.regions.map(\.annotation))
        print("group \(group) writes \(transactions) seconds \(Double(time.seconds) + Double(time.attoseconds) / 1e18)")
      }
    }
  }
}
