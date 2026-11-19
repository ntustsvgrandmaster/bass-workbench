// 音訊的兩條路徑：原音供聆聽；22.05 kHz 單聲道副本供 DSP。兩者不可混為同一份素材。

import AVFoundation
import Combine
import Foundation

enum AudioIO {
  /// 分批解碼，避免整首立體聲音訊一次載入記憶體；回傳來源格式資訊及分析副本的波形。
  static func decode(_ source: URL, to destination: URL) throws -> (
    Double, Double, Int, WaveformData
  ) {
    let file = try AVAudioFile(forReading: source)
    let sourceFormat = file.processingFormat
    let duration = Double(file.length) / sourceFormat.sampleRate
    guard duration > 0, duration <= 3600 else { throw WorkbenchError.message("請使用非空白且一小時內的音訊。") }
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1),
      let converter = AVAudioConverter(from: sourceFormat, to: format),
      let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 32768),
      let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384)
    else { throw WorkbenchError.message("無法建立本機音訊轉換器。") }
    converter.sampleRateConverterQuality = 127
    var settings = format.settings
    settings[AVLinearPCMIsNonInterleaved] = false
    let out = try AVAudioFile(
      forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32,
      interleaved: false)
    var eof = false
    var readError: Error?
    var peaks: [Float] = []
    var peak: Float = 0
    var bin = 0
    while true {
      var error: NSError?
      let result = converter.convert(to: output, error: &error) { packets, status in
        // 明確回報 EOF，否則部分壓縮音訊解碼器可能在最後一次讀取回報錯誤。
        if eof || file.framePosition >= file.length {
          status.pointee = .endOfStream
          return nil
        }
        do {
          try file.read(into: input, frameCount: min(packets, input.frameCapacity))
          if input.frameLength == 0 {
            eof = true
            status.pointee = .endOfStream
            return nil
          }
          status.pointee = .haveData
          return input
        } catch {
          readError = error
          eof = true
          status.pointee = .endOfStream
          return nil
        }
      }
      if let readError { throw readError }
      if let error { throw error }
      if output.frameLength > 0 {
        try out.write(from: output)
        if let samples = output.floatChannelData?[0] {
          for i in 0..<Int(output.frameLength) {
            peak = max(peak, abs(samples[i]))
            bin += 1
            if bin >= 220 {
              peaks.append(peak)
              peak = 0
              bin = 0
            }
          }
        }
      }
      if result == .endOfStream { break }
      if result == .error { throw WorkbenchError.message("音訊解碼失敗，請改用未加密的 WAV／M4A／FLAC。") }
    }
    if bin > 0 { peaks.append(peak) }
    return (
      duration, sourceFormat.sampleRate, Int(sourceFormat.channelCount),
      WaveformData(peaks: peaks, duration: duration)
    )
  }
  static func waveform(_ url: URL) throws -> WaveformData {
    let file = try AVAudioFile(forReading: url)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768)
    else { throw WorkbenchError.message("無法讀取音訊波形。") }
    var result: [Float] = []
    var peak: Float = 0
    var count = 0
    // 每秒約 100 個峰值供畫面縮放；這是峰值包絡，不是完整 PCM 或響度分析。
    let width = max(1, Int(file.processingFormat.sampleRate / 100))
    while file.framePosition < file.length {
      try file.read(into: buffer)
      if let values = buffer.floatChannelData?[0] {
        for i in 0..<Int(buffer.frameLength) {
          peak = max(peak, abs(values[i]))
          count += 1
          if count >= width {
            result.append(peak)
            peak = 0
            count = 0
          }
        }
      }
    }
    if count > 0 { result.append(peak) }
    return WaveformData(
      peaks: result, duration: Double(file.length) / file.processingFormat.sampleRate)
  }
}

/// 音樂與拍音先混合、再共用 TimePitch；所有開始／循環以來源 sample frame 排程。
@MainActor final class Transport: ObservableObject {
  typealias PositionUpdates = (@escaping () -> Void) -> AnyCancellable
  struct Resources: Codable, Equatable {
    let engineRunning: Bool
    let positionUpdatesActive: Bool
    let clickBuffersQueued: Int
  }
  @Published var position: Double = 0
  @Published var playing = false
  @Published private(set) var countInRemaining = 0
  @Published private(set) var countInTargetBeat: Double = 1
  var countingIn: Bool { countInRemaining > 0 }
  var a: Double = 0, b: Double = 4, loop = false, offset: Double = 0
  var rate: Float = 1 { didSet { unit.rate = rate } }
  var practice = PracticeSettings() { didSet { applyVolumes() } }
  var measures: [ScoreMeasure] = []
  var timing = TimingMap()
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private let clickNode = AVAudioPlayerNode()
  private let mix = AVAudioMixerNode()
  private let unit = AVAudioUnitTimePitch()
  private var file: AVAudioFile?
  private var clock: AnyCancellable?
  private var configurationChanges: AnyCancellable?
  private var loopBuffer: AVAudioPCMBuffer?
  private var generation = 0
  private let positionUpdates: PositionUpdates
  private let offline: Bool
  private var clickPlan: ClickRenderPlan?
  private var nextClickFrame: Int64 = 0
  private var queued = 0
  private var startPosition: Double = 0
  private func applyVolumes() {
    // 拍音 PCM 預留 1.5 倍峰值，player 音量仍在 0–1；舊專案音量比例保持一致。
    clickNode.volume = practice.volume / PracticeSettings.maximumClickVolume
    node.volume = practice.musicVolume
  }
  var resources: Resources {
    Resources(engineRunning: engine.isRunning, positionUpdatesActive: clock != nil, clickBuffersQueued: queued)
  }
  init(positionUpdates: PositionUpdates? = nil, offline: Bool = false) {
    self.offline = offline
    self.positionUpdates = positionUpdates ?? { action in
      Timer.publish(every: 0.035, on: .main, in: .common).autoconnect().sink { _ in action() }
    }
    for component in [node, clickNode, mix, unit] as [AVAudioNode] { engine.attach(component) }
    unit.overlap = 32
    configurationChanges = NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange, object: engine)
      .receive(on: DispatchQueue.main).sink { [weak self] _ in
        guard let self, self.playing, !self.engine.isRunning else { return }
        self.stop()
      }
  }
  deinit {
    clock?.cancel()
    node.stop(); clickNode.stop(); engine.stop()
  }
  private func startPositionUpdates() {
    guard clock == nil else { return }
    clock = positionUpdates { [weak self] in self?.updatePosition() }
  }
  func load(_ url: URL, offset: Double = 0) throws {
    let current = position
    stop()
    if engine.isInManualRenderingMode { engine.disableManualRenderingMode() }
    file = try AVAudioFile(forReading: url)
    self.offset = offset
    let format = file!.processingFormat
    if offline { try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096) }
    for component in [node, clickNode, mix, unit] as [AVAudioNode] { engine.disconnectNodeOutput(component) }
    engine.connect(node, to: mix, fromBus: 0, toBus: 0, format: format)
    let clickFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
    engine.connect(clickNode, to: mix, fromBus: 0, toBus: 1, format: clickFormat)
    engine.connect(mix, to: unit, format: format)
    engine.connect(unit, to: engine.mainMixerNode, format: format)
    unit.rate = rate
    applyVolumes()
    position = current
  }
  func unload() { stop(); file = nil; position = 0 }
  func seek(_ second: Double) throws {
    let resume = playing && !countingIn
    stop()
    position = max(0, second)
    if resume { try play(countIn: false) }
  }
  func stop() {
    if engine.isRunning { updatePosition() }
    clock?.cancel(); clock = nil
    generation += 1
    node.stop(); clickNode.stop(); engine.stop()
    playing = false
    countInRemaining = 0
    loopBuffer = nil; clickPlan = nil; queued = 0; nextClickFrame = 0
  }
  func play(countIn: Bool = true) throws {
    guard let file else { throw WorkbenchError.message("請先匯入音源。") }
    stop()
    var didStart = false
    defer { if !didStart { stop() } }
    guard practice.isValid, rate.isFinite, (0.25...2).contains(rate) else { throw WorkbenchError.message("播放設定無效。") }
    try timing.validate()
    let sr = file.processingFormat.sampleRate
    let masterEnd = Double(file.length) / sr + offset
    if loop {
      guard a >= 0, a >= offset, b > a + 0.04, b <= masterEnd + 0.02, b - a <= 180 else {
        throw WorkbenchError.message("A–B 須在此音源內、B 大於 A，且不超過三分鐘。")
      }
      if position < a || position >= b { position = a }
    } else if position >= masterEnd { position = 0; return }
    guard position >= offset else { throw WorkbenchError.message("目前位置早於此 stem 的起點。") }
    let startFrame = max(0, Int64(((position - offset) * sr).rounded()))
    let endFrame = min(file.length, Int64((((loop ? b : masterEnd) - offset) * sr).rounded()))
    guard endFrame > startFrame else { throw WorkbenchError.message("播放區段超出音源範圍。") }
    let loopStart = loop ? max(0, Int64(((a - offset) * sr).rounded())) : nil
    startPosition = offset + Double(startFrame) / sr
    let preparation = try CountInPlan.make(bars: countIn ? practice.countInBars : 0,
      start: startPosition, measures: measures, timing: timing)
    let events = practice.metronome ? MetronomePlan(measures: measures, timing: timing).events : []
    let plan = ClickRenderPlan(events: events,
      preparation: preparation, sampleRate: sr, offset: offset, start: startFrame,
      end: endFrame, loopStart: loopStart, enabled: practice.metronome,
      leadInFrames: rate == 1 || preparation.duration == 0 ? 0 : Int64((max(0.15, unit.auAudioUnit.latency * 2) * sr).rounded()))
    clickPlan = plan
    countInTargetBeat = preparation.targetBeat
    countInRemaining = Int(ceil(Double(plan.countInFrames) / sr / preparation.pulseSeconds))
    generation += 1
    let token = generation
    let musicStart = AVAudioTime(sampleTime: plan.leadInFrames + plan.countInFrames, atRate: sr)
    if let loopStart {
      guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(endFrame - loopStart)) else { throw WorkbenchError.message("無法建立循環緩衝。") }
      file.framePosition = loopStart
      try file.read(into: buffer, frameCount: buffer.frameCapacity)
      loopBuffer = buffer
      if startFrame > loopStart {
        node.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(endFrame - startFrame), at: musicStart)
        node.scheduleBuffer(buffer, at: nil, options: .loops)
      } else { node.scheduleBuffer(buffer, at: musicStart, options: .loops) }
    } else {
      node.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(endFrame - startFrame),
        at: musicStart, completionCallbackType: .dataPlayedBack) { [weak self] _ in
        Task { @MainActor in
          guard let self, self.generation == token else { return }
          self.stop(); self.position = masterEnd
        }
      }
    }
    queueClicks(token)
    queueClicks(token)
    engine.prepare()
    try engine.start()
    // 同一 host time 啟動兩條 player timeline；manual rendering 從 sample 0 開始。
    let when = offline ? nil : AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.04))
    node.play(at: when)
    clickNode.play(at: when)
    playing = true
    startPositionUpdates()
    didStart = true
  }
  /// 兩個八秒來源塊的有限佇列；完成回呼只補後續塊，不在 UI Timer 上打拍。
  private func queueClicks(_ token: Int) {
    guard token == generation, let plan = clickPlan else { return }
    let remaining = plan.totalFrames.map { max(0, $0 - nextClickFrame) } ?? Int64.max
    let frames = Int(min(remaining, Int64(plan.sampleRate * 8)))
    guard frames > 0, let format = AVAudioFormat(standardFormatWithSampleRate: plan.sampleRate, channels: 1),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
    let samples = plan.samples(from: nextClickFrame, count: frames)
    buffer.frameLength = AVAudioFrameCount(frames)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: frames) }
    nextClickFrame += Int64(frames)
    queued += 1
    clickNode.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.generation == token else { return }
        self.queued -= 1
        self.queueClicks(token)
      }
    }
  }
  private func updatePosition() {
    guard playing else { return }
    guard engine.isRunning else { stop(); return }
    guard let file, let plan = clickPlan, let render = clickNode.lastRenderTime,
      render.isSampleTimeValid || render.isHostTimeValid,
      let time = clickNode.playerTime(forNodeTime: render), time.isSampleTimeValid else { return }
    let elapsed = max(0, time.sampleTime)
    let remaining = min(plan.countInFrames, max(0, plan.leadInFrames + plan.countInFrames - elapsed))
    let pulses = Int(ceil(Double(remaining) / plan.sampleRate / plan.countIn.pulseSeconds))
    if countInRemaining != pulses { countInRemaining = pulses }
    let second = remaining > 0 ? startPosition : offset + Double(plan.sourceFrame(at: elapsed)) / file.processingFormat.sampleRate
    position = second
  }
  // 離線驗證使用相同產品引擎／排程，不需要輸出裝置或另建測試混音器。
  var renderingFormat: AVAudioFormat { engine.manualRenderingFormat }
  var musicStartFrame: Int64 { (clickPlan?.leadInFrames ?? 0) + (clickPlan?.countInFrames ?? 0) }
  /// 僅離線驗證可觀測變速器前的訊號，區分檔案提前播放與 FFT 前振鈴。
  func observeInput(_ block: @escaping AVAudioNodeTapBlock) {
    precondition(offline)
    mix.installTap(onBus: 0, bufferSize: 256, format: nil, block: block)
  }
  func interruptOfflineRendering() {
    precondition(offline)
    engine.stop()
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
  }
  func renderOffline(_ frames: AVAudioFrameCount, to buffer: AVAudioPCMBuffer) throws -> AVAudioEngineManualRenderingStatus {
    let result = try engine.renderOffline(frames, to: buffer)
    updatePosition()
    return result
  }
}
