import AVFoundation
import Foundation

@main struct PublicDemoTests {
  static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let manifest = try JSONSerialization.jsonObject(
      with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
    let events = manifest["bass_events"] as! [[String: Any]]
    let score = try ScoreIO.parse(Data(contentsOf: root.appendingPathComponent("bass.musicxml")))
    precondition(score.measures.count == 16 && score.staves.count == 2 && score.bpm == 120)
    precondition(score.measures.allSatisfy { $0.duration.value == 4 })
    precondition(score.staves.filter { $0.isTAB }.count == 1)
    for staff in score.staves {
      let notes = score.notes.filter { $0.staffID == staff.id }
      precondition(notes.count == events.count)
      for (note, event) in zip(notes, events) {
        precondition(note.onset.value == (event["beat"] as! Double))
        precondition(note.duration.value == (event["duration"] as! Double))
        precondition(note.soundingPitch == event["midi"] as? Int)
        if let midi = note.soundingPitch {
          precondition(note.writtenPitch == midi + 12)
          if staff.isTAB {
            let strings = [43, 38, 33, 28, 23]
            precondition(strings[note.stringNumber! - 1] + note.fret! == midi)
          }
        }
      }
    }
    var waves: [String: [Int32]] = [:]
    for name in ["mix", "bass", "harmony", "drums"] {
      let url = root.appendingPathComponent("\(name).wav")
      let f = try AVAudioFile(forReading: url)
      precondition(f.length == 1_433_250 && f.processingFormat.sampleRate == 44100)
      precondition(f.processingFormat.channelCount == 1)
      let data = try Data(contentsOf: url)
      // Generated WAV uses the standard 44-byte PCM header.
      precondition(String(data: data[0..<4], encoding: .ascii) == "RIFF")
      precondition(String(data: data[36..<40], encoding: .ascii) == "data")
      let y = stride(from: 44, to: data.count, by: 2).map {
        Int32(Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8))
      }
      precondition(y.count == Int(f.length))
      precondition(y.contains { $0 != 0 } && y.allSatisfy { abs($0) < 32767 })
      waves[name] = y
    }
    for i in waves["mix"]!.indices {
      let sum = waves["bass"]![i] + waves["harmony"]![i] + waves["drums"]![i]
      precondition(abs(sum - waves["mix"]![i]) <= 2)
    }
    let hashes = manifest["sha256"] as! [String: String]
    for (name, expected) in hashes {
      let actual = try Files.hash(root.appendingPathComponent(name))
      precondition(actual == expected)
    }
    print("PASS public demo: native MusicXML parser, 16 measures, both staves, all note timings/pitches, TAB, AVFoundation WAV decode, synchronized stem sum, no clipping and SHA-256")
  }
}
