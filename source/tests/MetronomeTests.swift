import AVFoundation
import Foundation

@main struct MetronomeTests {
  static var assertions = 0
  static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    assertions += 1
    if try !value() { throw WorkbenchError.message("FAIL metronome: \(message)") }
  }
  static func measures(_ n: Int = 4, _ d: Int = 4, count: Int = 20) -> [ScoreMeasure] {
    (0..<count).map { i in ScoreMeasure(id: "m\(i)", index: i, number: "\(i+1)",
      onset: Fraction(i*n*4,d), duration: Fraction(n*4,d), numerator: n, denominator: d) }
  }
  @MainActor static func main() throws {
    try model()
    if !CommandLine.arguments.contains("--model-only") {
      guard let root = ProcessInfo.processInfo.environment["BASS_DATA_ROOT"] else { fatalError("Disposable data root required") }
      try offline(URL(fileURLWithPath: root))
      if CommandLine.arguments.contains("--live") { try live(URL(fileURLWithPath: root)) }
    }
    print("PASS metronome / count-in: \(assertions) assertions")
  }
  static func model() throws {
    let timing = TimingMap(bpm: 120)
    for (n,d) in [(4,4),(3,4),(6,8)] {
      let events = MetronomePlan(measures: measures(n,d,count:2), timing: timing).events
      try check(events.count == n*2, "denominator pulses \(n)/\(d)")
      try check(events[0].accent && events[n].accent && !events[1].accent, "bar accents")
      try check(abs(events[1].seconds - 2/Double(d)) < 1e-9, "quarter BPM versus denominator")
      let prep = try CountInPlan.make(bars: 3, start: 0.75, measures: measures(n,d), timing: timing)
      try check(abs(prep.duration - Double(n*3)*2/Double(d)) < 1e-8, "three bars at local meter")
    }
    var changed = measures(4,4,count:1)
    changed += [ScoreMeasure(id:"b",index:1,number:"2",onset:Fraction(4),duration:Fraction(3),numerator:3,denominator:4),
      ScoreMeasure(id:"c",index:2,number:"3",onset:Fraction(7),duration:Fraction(3),numerator:6,denominator:8)]
    let mixed = MetronomePlan(measures: changed,timing:timing).events
    try check(mixed.count == 13 && mixed[4].seconds == 2 && mixed[7].seconds == 3.5 && mixed[8].seconds == 3.75, "meter changes preserve exact boundaries")
    let partial = try CountInPlan.make(bars:1,start:0.75,measures:measures(),timing:timing)
    try check(partial.targetBeat == 2.5 && partial.duration == 2 && partial.events.first?.seconds == 0.25, "mid-beat start preserves phase")
    var pickup = measures(4,4,count:1)
    pickup[0].duration = Fraction(1)
    let pickupEvents = MetronomePlan(measures:pickup,timing:timing).events
    try check(!pickupEvents[0].accent, "pickup is final beat, not a fabricated downbeat")
    try check(try CountInPlan.make(bars:1,start:0,measures:pickup,timing:timing).targetBeat == 4, "pickup target phase")
    var anchored = TimingMap(bpm:120)
    anchored.anchors = [Anchor(beat:0,seconds:0),Anchor(beat:4,seconds:2),Anchor(beat:8,seconds:6)]
    anchored.biasSeconds = -0.25
    let mapped = MetronomePlan(measures:measures(count:3),timing:anchored).events
    try check(mapped[0].seconds == -0.25 && mapped[5].seconds == 2.75, "negative origin and piecewise anchors")
    try check(abs((try CountInPlan.make(bars:1,start:1.75,measures:measures(),timing:anchored)).duration - 4) < 1e-6, "count-in uses right local slope at anchor")
    for bars in [0,1,2,3] { try check(try CountInPlan.make(bars:bars,start:0,measures:measures(),timing:timing).events.count == bars*4, "0–3 selection") }
    for bars in [-1,4] {
      var rejected = false
      do { _ = try CountInPlan.make(bars:bars,start:0,measures:measures(),timing:timing) } catch { rejected = true }
      try check(rejected, "out-of-range count-in rejected")
    }
    let events = MetronomePlan(measures:measures(count:100),timing:timing).events
    let plan = ClickRenderPlan(events:events,preparation:partial,sampleRate:22050,offset:0,
      start:16538,end:110250,loopStart:11025,enabled:true)
    let all = plan.samples(from:0,count:400000)
    var chunks:[Float] = []
    for i in stride(from:0,to:400000,by:7919) { chunks += plan.samples(from:Int64(i),count:min(7919,400000-i)) }
    try check(all == chunks, "buffer seams neither duplicate nor lose click tails")
    let period = Int64(110250-11025)
    try check(plan.samples(from:plan.countInFrames + 110250-16538,count:5000)
      == plan.samples(from:plan.countInFrames + 110250-16538 + period*1000,count:5000), "1000 loops have no accumulated frame drift")
    var p=Project(); p.practice = PracticeSettings(metronome:true,volume:1.5,countInBars:3,musicVolume:0.4)
    let bytes=try JSONEncoder().encode(p)
    try check(try JSONDecoder().decode(Project.self,from:bytes).practice == p.practice, "settings round-trip")
    var json=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
    var legacyPractice = json["practice"] as! [String:Any]
    legacyPractice.removeValue(forKey:"musicVolume")
    json["practice"] = legacyPractice
    let migrated = try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:json))
    try check(PracticeSettings().musicVolume == 0.5
      && migrated.practice.musicVolume == 0.5 && migrated.practice.volume == 1.5,
      "new and unset music levels default to half without changing the click level")
    try check(!PracticeSettings(volume:1.51).isValid && !PracticeSettings(musicVolume:-0.1).isValid
      && !PracticeSettings(musicVolume:.nan).isValid, "invalid music and boosted click levels rejected")
    json.removeValue(forKey:"practice")
    try check(try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:json)).practice == PracticeSettings(), "old project defaults off / zero")
    print("PASS rhythm plans / pickup / anchors / phase / bounded chunks / exact loop frames / settings")
  }
  @MainActor static func spin(_ seconds: Double = 0.001) {
    let deadline=Date().addingTimeInterval(seconds)
    let timer=Timer(fire:deadline,interval:0,repeats:false){_ in}
    RunLoop.main.add(timer,forMode:.default); RunLoop.main.run(until:deadline); timer.invalidate()
  }
  static func fixture(_ root:URL, sampleRate: Double = 22050) throws -> URL {
    try Files.directory(root)
    let url=root.appendingPathComponent("stereo-click-truth-\(Int(sampleRate)).wav"), sr=sampleRate
    let format=AVAudioFormat(standardFormatWithSampleRate:sr,channels:2)!
    let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(sr*14))!
    buffer.frameLength=buffer.frameCapacity
    for ch in 0..<2 { buffer.floatChannelData![ch].initialize(repeating:0,count:Int(buffer.frameLength)) }
    for k in 0..<28 {
      let first=Int(Double(k)*sr*0.5), frequency=k%4 == 0 ? 1760.0 : 1100.0
      for i in 0..<Int(sr*0.022) {
        buffer.floatChannelData![0][first+i] = Float(0.35*sin(2 * .pi * frequency * Double(i)/sr)*exp(-Double(i)/(sr*0.004)))
      }
    }
    let file=try AVAudioFile(forWriting:url,settings:format.settings.merging([AVLinearPCMIsNonInterleaved:false]) { _, value in value })
    try file.write(from:buffer)
    return url
  }
  @MainActor static func render(_ transport:Transport, seconds:Double) throws -> ([Float],[Float]) {
    let total=Int(seconds*transport.renderingFormat.sampleRate)
    let buffer=AVAudioPCMBuffer(pcmFormat:transport.renderingFormat,frameCapacity:1024)!
    var left:[Float]=[],right:[Float]=[], attempts=0
    while left.count < total {
      let status=try transport.renderOffline(AVAudioFrameCount(min(1024,total-left.count)),to:buffer)
      if status == .success {
        let n=Int(buffer.frameLength)
        left += Array(UnsafeBufferPointer(start:buffer.floatChannelData![0],count:n))
        right += Array(UnsafeBufferPointer(start:buffer.floatChannelData![1],count:n))
        attempts=0
      } else { attempts += 1; if attempts > 100 { throw WorkbenchError.message("Offline rendering stalled: \(status.rawValue)") } }
      spin()
    }
    return (left,right)
  }
  @MainActor static func offline(_ root:URL) throws {
    let audio=try fixture(root)
    try volumeBalance(audio)
    for sr in [22050.0, 44100.0, 48000.0] {
    let audio=try fixture(root, sampleRate:sr)
    for rate:Float in [1,0.75,0.5] {
      let t=Transport(offline:true)
      t.measures=measures(); t.timing=TimingMap(bpm:120)
      t.practice=PracticeSettings(metronome:true,volume:0.6,countInBars:1)
      t.rate=rate
      try t.load(audio)
      let probe = InputProbe()
      t.observeInput { buffer, time in probe.receive(buffer, time) }
      try t.play()
      let (l,r)=try render(t,seconds:Double(6/rate))
      let music=zip(l,r).map(-)
      let firstPrep = r.firstIndex { abs($0) > 0.005 }!
      let before=firstPrep + Int((2/Double(rate))*sr)
      try check(probe.musicIsSilent(before: t.musicStartFrame), "no music input during preparation at \(rate)")
      if rate == 1 { try check(music.prefix(before-Int(ceil(sr*64/22050))).allSatisfy{abs($0)<0.0001}, "unity-rate preparation output has no music") }
      print("OUTPUT pre-ringing peak at \(rate): \(music.prefix(before-Int(ceil(sr*64/22050))).map{abs($0)}.max()!)")
      var errors:[Int]=[]
      for k in 0..<7 {
        let expected=firstPrep + Int((2+Double(k)*0.5)/Double(rate)*sr)
        let window=max(0,expected-2048)..<min(l.count,expected+4096)
        // 兩軌振幅不同，使用各自峰值的 10% 定義起音，避免固定振幅門檻造成假偏差。
        let musicThreshold = window.map { abs(music[$0]) }.max()! * 0.1
        let clickThreshold = window.map { abs(r[$0]) }.max()! * 0.1
        let m=window.first{abs(music[$0])>musicThreshold}
        let c=window.first{abs(r[$0])>clickThreshold}
        try check(m != nil && c != nil, "music and metronome pulses rendered \(rate), \(k)")
        errors.append(abs(m!-c!))
      }
      // 允差固定為 64/22050 秒（2.9 ms），按輸出取樣率換算 sample 數。
      try check(errors.max()! <= Int(ceil(sr*64/22050)), "shared path synchrony <=2.90 ms: \(errors)")
      print("OFFLINE sr \(sr), rate \(rate): maximum music/click onset difference \(errors.max()!) samples")
      fflush(stdout)
      t.stop()
      try check(!t.resources.engineRunning && !t.resources.positionUpdatesActive && t.resources.clickBuffersQueued == 0, "offline stop releases all queues")
      try t.seek(0.75); try t.play()
      try check(abs(t.countInTargetBeat - 2.5) < 0.001, "real scheduler uses mid-beat target within source-frame rounding")
      t.stop()
    }
    }
    let t=Transport(offline:true)
    try t.load(audio); t.measures=measures(); t.timing=TimingMap(bpm:120)
    t.practice=PracticeSettings(metronome:false,volume:0.6,countInBars:1)
    try t.play()
    let (l,r)=try render(t,seconds:5)
    try check(r.prefix(40000).contains{abs($0)>0.005}, "preparation clicks even with regular metronome off")
    try check(r.dropFirst(50000).allSatisfy{abs($0)<0.0001}, "regular clicks stop exactly after preparation")
    try check(zip(l,r).dropFirst(50000).contains{abs($0-$1)>0.005}, "music continues after click-only preparation")
    t.stop()
    let long = Transport(offline: true)
    try long.load(audio)
    long.measures = measures(); long.timing = TimingMap(bpm: 120)
    long.practice = PracticeSettings(metronome: true, volume: 0.6, countInBars: 2)
    long.a = 1.25; long.b = 5.25; long.loop = true
    try long.seek(2); try long.play(countIn: false)
    let (_, longClicks) = try render(long, seconds: 80)
    let firstCycle = Int((3.25 * 22050).rounded()), cycle = 4 * 22050
    let earlier = longClicks[firstCycle..<(firstCycle + cycle)]
    let later = longClicks[(firstCycle + 17 * cycle)..<(firstCycle + 18 * cycle)]
    try check(zip(earlier, later).allSatisfy { abs($0 - $1) < 0.00001 },
      "80-second real engine loop waveform has no cumulative click drift")
    try check(!long.countingIn && long.resources.clickBuffersQueued <= 2,
      "rolling queue remains bounded and loops do not retrigger preparation")
    long.stop()
    try check(long.resources.clickBuffersQueued == 0, "long-render queue releases on stop")
    let invalid = Transport(offline: true)
    try invalid.load(audio, offset: -1)
    invalid.a = -0.25; invalid.b = 0.75; invalid.loop = true
    var rejected = false
    do { try invalid.play() } catch { rejected = true }
    try check(rejected && !invalid.resources.engineRunning && invalid.resources.clickBuffersQueued == 0,
      "negative loop start stays invalid even for a negative-offset source")
    try long.play()
    long.interruptOfflineRendering()
    spin(0.05)
    try check(!long.playing && !long.countingIn && !long.resources.positionUpdatesActive
      && long.resources.clickBuffersQueued == 0, "engine interruption cancels preparation and all resources")
    let held = long.position
    try long.play(countIn: false)
    _ = try render(long, seconds: 0.25)
    try check(long.playing && long.resources.engineRunning && abs(long.position - held) > 0.05,
      "explicit playback and source clock recover after interrupted engine")
    long.stop()
    print("PASS actual offline AVAudioEngine / count-in music silence / shared TimePitch rates / frame synchrony")
  }
  @MainActor static func volumeBalance(_ audio: URL) throws {
    let t = Transport(offline: true)
    try t.load(audio)
    t.measures = measures(); t.timing = TimingMap(bpm: 120)
    func peak(_ values: [Float]) -> Float { values.map { abs($0) }.max() ?? 0 }
    func levels(click: Float, music: Float) throws -> (Float, Float) {
      t.stop(); try t.seek(0)
      t.practice = PracticeSettings(metronome: true, volume: click, musicVolume: music)
      try t.play(countIn: false)
      // 排除 TimePitch 啟動暫態，再取至少一個完整 4/4 小節的強弱拍峰值。
      _ = try render(t, seconds: 1)
      let (l,r) = try render(t, seconds: 2.5)
      return (peak(zip(l,r).map(-)), peak(r))
    }
    let base = try levels(click: 1, music: 1)
    let boosted = try levels(click: 1.5, music: 0.25)
    print("GAIN base \(base), boosted \(boosted)"); fflush(stdout)
    try check(abs(boosted.0 / base.0 - 0.25) < 0.001, "music attenuation reaches actual engine output")
    try check(abs(boosted.1 / base.1 - 1.5) < 0.001, "150% click output exceeds prior maximum by 50%")
    try check(boosted.1 < 1, "isolated boosted click remains below full scale")
    let mutedMusic = try levels(click: 1.5, music: 0)
    try check(mutedMusic.0 < 0.000001 && mutedMusic.1 > 0.1, "music mute leaves clicks audible")
    let mutedClick = try levels(click: 0, music: 1)
    try check(mutedClick.0 > 0.1 && mutedClick.1 < 0.000001, "click mute leaves music audible")
    // 不重排播放：更新既有引擎中的兩個增益，下一個拍點即反映新比例。
    t.practice.musicVolume = 0.25; t.practice.volume = 1.5
    let position = t.position
    // 音訊單元可保留先前增益的處理尾端；等過此尾端後量測下一批完整拍音。
    _ = try render(t, seconds: 0.25)
    let (l,r) = try render(t, seconds: 2.5)
    print("GAIN live music \(peak(zip(l,r).map(-)) / base.0), click \(peak(r) / base.1)"); fflush(stdout)
    try check(t.playing && t.position > position, "live gain changes do not restart or pause the transport")
    try check(abs(peak(zip(l,r).map(-)) / base.0 - 0.25) < 0.001
      && abs(peak(r) / base.1 - 1.5) < 0.001, "both independent gains update during playback")
    t.stop()
    print("PASS actual engine independent music / boosted click gain / mute / live adjustment")
  }
  @MainActor static func live(_ root:URL) throws {
    let audio=try fixture(root)
    let t=Transport(); try t.load(audio)
    t.measures=measures(); t.timing=TimingMap(bpm:240)
    t.practice=PracticeSettings(metronome:true,volume:0.15,countInBars:1)
    t.a=0.25; t.b=1.25; t.loop=true
    try t.seek(0.25); try t.play()
    spin(0.15)
    try check(t.countingIn && abs(t.position - 0.25) <= 1/22050.0, "live count-in holds original position within one source sample")
    spin(1.5)
    try check(t.playing && !t.countingIn && t.position >= 0.25 && t.position < 1.25, "live transition and loop")
    spin(1.2)
    try check(!t.countingIn, "loop never redoes preparation")
    t.stop(); try t.play(); spin(0.1); try t.seek(0.6)
    try check(!t.playing && !t.countingIn && abs(t.position-0.6)<0.001, "seek cancels preparation")
    for _ in 0..<5 { try t.play(); spin(0.02); t.stop() }
    spin(0.05)
    try check(!t.resources.engineRunning && t.resources.clickBuffersQueued == 0 && !t.resources.positionUpdatesActive, "cancel / late callbacks never revive playback")
    print("PASS live count-in / holding position / loop / seek cancel / repeated cancellation")
  }
}

/// 只在離線測試的 tap 使用鎖；產品的即時音訊路徑沒有此探針。
final class InputProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var differences: [(Int64, Float)] = []
  func receive(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
    lock.lock(); defer { lock.unlock() }
    for i in 0..<Int(buffer.frameLength) {
      differences.append((time.sampleTime + Int64(i), buffer.floatChannelData![0][i] - buffer.floatChannelData![1][i]))
    }
  }
  func musicIsSilent(before frame: Int64) -> Bool {
    lock.lock(); defer { lock.unlock() }
    let prefix = differences.filter { $0.0 < frame }
    let observedMusic = differences.contains { $0.0 >= frame && abs($0.1) > 0.005 }
    return observedMusic && !prefix.isEmpty && prefix.allSatisfy { abs($0.1) < 0.000001 }
  }
}
