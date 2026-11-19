import Foundation

struct PracticeSettings: Codable, Equatable, Sendable {
  static let maximumClickVolume: Float = 1.5
  static let defaultMusicVolume: Float = 0.5
  var metronome = false
  var volume: Float = 0.35
  var countInBars = 0
  var musicVolume: Float = Self.defaultMusicVolume
  var isValid: Bool {
    volume.isFinite && (0...Self.maximumClickVolume).contains(volume)
      && musicVolume.isFinite && (0...1).contains(musicVolume) && (0...3).contains(countInBars)
  }
  private enum CodingKeys: String, CodingKey { case metronome, volume, countInBars, musicVolume }
}

extension PracticeSettings {
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    metronome = try c.decode(Bool.self, forKey: .metronome)
    volume = try c.decode(Float.self, forKey: .volume)
    countInBars = try c.decode(Int.self, forKey: .countInBars)
    musicVolume = try c.decodeIfPresent(Float.self, forKey: .musicVolume) ?? Self.defaultMusicVolume
  }
}

struct MetronomeEvent: Equatable, Sendable {
  var seconds: Double
  var accent: Bool
}

/// 拍號分母為點拍單位；6/8 是六個八分音符，BPM 仍以四分音符計。
struct MetronomePlan: Sendable {
  var events: [MetronomeEvent]
  init(measures: [ScoreMeasure], timing: TimingMap) {
    let anchors = timing.anchors.sorted { $0.beat < $1.beat }
    func seconds(_ beat: Double) -> Double {
      guard let first = anchors.first else { return beat * 60 / timing.bpm + timing.bias }
      guard anchors.count > 1 else { return first.seconds + (beat - first.beat) * 60 / timing.bpm + timing.bias }
      var low = 0, high = anchors.count
      while low < high { let mid = (low + high) / 2; if anchors[mid].beat <= beat { low = mid + 1 } else { high = mid } }
      let i = min(max(0, low - 1), anchors.count - 2), a = anchors[i], b = anchors[i + 1]
      return a.seconds + (beat - a.beat) * (b.seconds - a.seconds) / (b.beat - a.beat) + timing.bias
    }
    events = []
    for (index, measure) in measures.enumerated() {
      guard measure.denominator > 0, measure.numerator > 0 else { continue }
      let step = 4.0 / Double(measure.denominator)
      let rawCount = ceil((measure.end - measure.beat) / step - 1e-9)
      guard rawCount.isFinite, rawCount > 0, rawCount <= 1000 else { continue }
      let count = Int(rawCount)
      let pickup = index == 0 ? max(0, Double(measure.numerator) - (measure.end - measure.beat) / step) : 0
      for pulse in 0..<count {
        events.append(MetronomeEvent(seconds: seconds(measure.beat + Double(pulse) * step),
          accent: abs((pickup + Double(pulse)).truncatingRemainder(dividingBy: Double(measure.numerator))) < 1e-7))
      }
    }
  }
}

struct CountInPlan: Sendable {
  var duration: Double = 0
  var pulseSeconds: Double = 0.5
  var targetBeat: Double = 1
  var pulsesPerBar = 4
  var events: [MetronomeEvent] = []
  static func make(bars: Int, start: Double, measures: [ScoreMeasure], timing: TimingMap) throws -> CountInPlan {
    guard (0...3).contains(bars), start.isFinite else { throw WorkbenchError.message("預備小節須為 0–3。") }
    guard bars > 0, let measure = measures.last(where: { $0.beat <= timing.beat(at: start) + 1e-8 }) ?? measures.first else { return CountInPlan() }
    guard measure.denominator > 0, measure.numerator > 0 else { throw WorkbenchError.message("拍號無效。") }
    let beat = timing.beat(at: start), step = 4.0 / Double(measure.denominator)
    let full = Double(measure.numerator) * step
    let pickup = measure.id == measures.first?.id ? max(0, full - (measure.end - measure.beat)) : 0
    var phase = (beat - measure.beat + pickup).truncatingRemainder(dividingBy: full)
    if phase < 0 { phase += full }
    // 取起播位置右側的局部速度；預備期間維持此拍號／速度，音樂開始後沿原錨點。
    let anchors = timing.anchors.sorted { $0.beat < $1.beat }
    let index = min(max(0, anchors.lastIndex(where: { $0.beat <= beat }) ?? 0), max(0, anchors.count - 2))
    let secondsPerBeat = anchors.count < 2 ? 60 / timing.bpm
      : (anchors[index + 1].seconds - anchors[index].seconds) / (anchors[index + 1].beat - anchors[index].beat)
    guard secondsPerBeat.isFinite, secondsPerBeat > 0 else { throw WorkbenchError.message("預備拍時間無效。") }
    var result = CountInPlan(duration: Double(bars) * full * secondsPerBeat,
      pulseSeconds: step * secondsPerBeat, targetBeat: phase / step + 1,
      pulsesPerBar: measure.numerator)
    let beginning = phase - Double(bars) * full
    let first = Int(ceil(beginning / step - 1e-8))
    let last = Int(ceil(phase / step - 1e-8))
    for k in first..<last {
      result.events.append(MetronomeEvent(seconds: (Double(k) * step - beginning) * secondsPerBeat,
        accent: ((k % measure.numerator) + measure.numerator) % measure.numerator == 0))
    }
    return result
  }
}

/// 以整數來源 sample frame 定義拍音。分塊及 A–B 回跳不累加浮點週期誤差。
struct ClickRenderPlan: Sendable {
  struct Pulse: Sendable { var frame: Int64; var accent: Bool }
  var sampleRate: Double
  var start: Int64
  var end: Int64
  var loopStart: Int64?
  var countInFrames: Int64
  var leadInFrames: Int64
  var countIn: CountInPlan
  var enabled: Bool
  private var pulses: [Pulse]
  private var preparation: [Pulse]
  private var strong: [Float]
  private var weak: [Float]
  init(events: [MetronomeEvent], preparation: CountInPlan, sampleRate: Double, offset: Double,
       start: Int64, end: Int64, loopStart: Int64?, enabled: Bool, leadInFrames: Int64 = 0) {
    self.sampleRate = sampleRate; self.start = start; self.end = end; self.loopStart = loopStart
    self.countIn = preparation; self.countInFrames = Int64((preparation.duration * sampleRate).rounded())
    self.enabled = enabled
    self.leadInFrames = leadInFrames
    pulses = events.map { Pulse(frame: Int64((($0.seconds - offset) * sampleRate).rounded()), accent: $0.accent) }
    self.preparation = preparation.events.map { Pulse(frame: Int64(($0.seconds * sampleRate).rounded()), accent: $0.accent) }
    let count = max(1, Int(sampleRate * 0.022))
    let gain = Double(PracticeSettings.maximumClickVolume)
    strong = (0..<count).map { i in Float(gain * 0.65 * sin(2 * .pi * 1760 * Double(i) / sampleRate) * exp(-Double(i) / (sampleRate * 0.004))) }
    weak = (0..<count).map { i in Float(gain * 0.4 * sin(2 * .pi * 1100 * Double(i) / sampleRate) * exp(-Double(i) / (sampleRate * 0.004))) }
  }
  var totalFrames: Int64? { loopStart == nil ? leadInFrames + countInFrames + end - start : nil }
  func sourceFrame(at elapsed: Int64) -> Int64 {
    let music = max(0, elapsed - leadInFrames - countInFrames), first = end - start
    if let loopStart, music >= first { return loopStart + (music - first) % (end - loopStart) }
    return min(end, start + music)
  }
  func samples(from first: Int64, count: Int) -> [Float] {
    var result = [Float](repeating: 0, count: count)
    var cursor = first
    let limit = first + Int64(count)
    while cursor < limit {
      if cursor < leadInFrames { cursor = min(limit, leadInFrames); continue }
      let isPreparation = cursor < leadInFrames + countInFrames
      let source = isPreparation ? cursor - leadInFrames : sourceFrame(at: cursor)
      if !isPreparation && source >= end { break }
      let boundary = isPreparation ? leadInFrames + countInFrames : cursor + end - source
      let length = min(limit, boundary) - cursor
      if isPreparation || enabled {
        let events = isPreparation ? preparation : pulses
        var low = 0, high = events.count
        while low < high {
          let mid = (low + high) / 2
          if events[mid].frame < source - Int64(strong.count) + 1 { low = mid + 1 } else { high = mid }
        }
        var i = low
        while i < events.count && events[i].frame < source + length {
          let pulse = events[i], waveform = pulse.accent ? strong : weak
          let a = max(source, pulse.frame), b = min(source + length, pulse.frame + Int64(waveform.count))
          if a < b {
            for frame in a..<b { result[Int(cursor - first + frame - source)] += waveform[Int(frame - pulse.frame)] }
          }
          i += 1
        }
      }
      cursor += length
    }
    return result
  }
}
