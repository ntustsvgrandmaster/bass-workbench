import AVFoundation
import Combine
import CoreAudio
import Darwin
import Foundation

/// 僅量測自己的 Transport 與合成音；不啟動 UI／Python，也不碰使用者專案。
@main struct TransportResourceTests {
  @MainActor static func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw WorkbenchError.message("FAIL audio resources: \(message)") }
  }
  @MainActor static func spin(_ seconds: Double) {
    // 即使產品已無 Timer，也要有一次性測試 deadline，避免空 RunLoop 提早返回後忙迴圈。
    let deadline = Date().addingTimeInterval(seconds)
    let timeout = Timer(fire: deadline, interval: 0, repeats: false) { _ in }
    RunLoop.main.add(timeout, forMode: .default)
    RunLoop.main.run(until: deadline)
    timeout.invalidate()
  }
  static func emit(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
  }
  static func number(_ flag: String, default value: Double) -> Double {
    guard let index = CommandLine.arguments.firstIndex(of: flag),
      CommandLine.arguments.indices.contains(index + 1),
      let result = Double(CommandLine.arguments[index + 1]), result.isFinite, result >= 0
    else { return value }
    return result
  }
  static func taskInfo<T>(_ value: inout T, flavor: task_flavor_t) -> kern_return_t {
    var count = mach_msg_type_number_t(MemoryLayout<T>.size / MemoryLayout<integer_t>.size)
    let capacity = Int(count)
    return withUnsafeMutablePointer(to: &value) {
      $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
        task_info(mach_task_self_, flavor, $0, &count)
      }
    }
  }
  struct Metrics {
    var time: Double
    var cpu: Double
    var wakeups: UInt64?
    var footprint: UInt64?
    static func read() -> Metrics {
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      var power = task_power_info()
      let powerOK = taskInfo(&power, flavor: task_flavor_t(TASK_POWER_INFO)) == KERN_SUCCESS
      var vm = task_vm_info_data_t()
      let vmOK = taskInfo(&vm, flavor: task_flavor_t(TASK_VM_INFO)) == KERN_SUCCESS
      return Metrics(time: ProcessInfo.processInfo.systemUptime,
        cpu: Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
          + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000,
        wakeups: powerOK ? power.task_interrupt_wakeups : nil,
        footprint: vmOK ? vm.phys_footprint : nil)
    }
  }
  static func outputDevice() -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var device: AudioDeviceID = 0
    var size = UInt32(MemoryLayout.size(ofValue: device))
    return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                      &size, &device) == noErr ? device : nil
  }
  /// coreaudiod 是共享程序；只保留 Created for PID 確實對應本測試的 assertion 區塊。
  static func ownAssertions() throws -> [String] {
    let dump = String(decoding: try Files.run(URL(fileURLWithPath: "/usr/bin/pmset"),
                                             ["-g", "assertions"]), as: UTF8.self)
    let pid = ProcessInfo.processInfo.processIdentifier
    var current: [String] = [], matching: [String] = []
    func append() {
      if current.contains(where: { $0.contains("Created for PID: \(pid).") }) {
        matching.append(current.joined(separator: "\n"))
      }
    }
    for line in dump.components(separatedBy: .newlines) {
      if line.trimmingCharacters(in: .whitespaces).isEmpty { append(); current = []; continue }
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("pid ") { append(); current = [] }
      current.append(line)
    }
    append()
    return matching
  }
  @MainActor static func fixture(_ root: URL) throws -> URL {
    try Files.directory(root)
    let url = root.appendingPathComponent("silence.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050 * 6)!
    buffer.frameLength = buffer.frameCapacity
    buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
  }
  @MainActor static func main() throws {
    guard let path = ProcessInfo.processInfo.environment["BASS_DATA_ROOT"] else {
      throw WorkbenchError.message("Specify disposable BASS_DATA_ROOT")
    }
    let audio = try fixture(URL(fileURLWithPath: path))
    if CommandLine.arguments.contains("--measure") || CommandLine.arguments.contains("--probe") {
      try measure(audio)
    } else { try lifecycle(audio) }
  }
  @MainActor static func measure(_ audio: URL) throws {
    var ticks = 0
    let transport = Transport(positionUpdates: { action in
      Timer.publish(every: 0.035, on: .main, in: .common).autoconnect().sink { _ in
        ticks += 1
        action()
      }
    })
    #if BASS_PRACTICE_METRICS
    if CommandLine.arguments.contains("--metronome") {
      transport.practice = PracticeSettings(metronome: true, volume: 0.15, countInBars: 0)
      transport.measures = Project().measures
      transport.timing = TimingMap(bpm: 120)
    }
    #endif
    defer { transport.unload() }
    let probe = CommandLine.arguments.contains("--probe")
    let seconds = number("--seconds", default: probe ? 3 : 120)
    let warmup = number("--warmup", default: probe ? 0 : 30)
    try emit(["phase": "created", "resources": try JSONSerialization.jsonObject(with: JSONEncoder().encode(transport.resources)),
              "pid": ProcessInfo.processInfo.processIdentifier,
              "os": ProcessInfo.processInfo.operatingSystemVersionString,
              "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
              "audioHash": try Files.hash(audio), "device": outputDevice() as Any? ?? NSNull(),
              "metronome": CommandLine.arguments.contains("--metronome")])
    try transport.load(audio)
    transport.a = 0.2; transport.b = 4.2; transport.loop = true
    let start = ProcessInfo.processInfo.systemUptime
    try transport.play()
    let startup = ProcessInfo.processInfo.systemUptime - start
    try check(transport.playing, "measurement playback starts")
    let activeStart = Metrics.read()
    spin(3)
    let activeEnd = Metrics.read()
    try emit(["phase": "playing", "cpuPercent": (activeEnd.cpu - activeStart.cpu) / (activeEnd.time - activeStart.time) * 100,
              "startupSeconds": startup, "assertions": try ownAssertions()])
    transport.stop()
    spin(5)
    try emit(["phase": "stopped-5s", "resources": try JSONSerialization.jsonObject(with: JSONEncoder().encode(transport.resources)),
              "assertions": try ownAssertions()])
    spin(warmup)
    let thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
    let deviceBefore = outputDevice()
    let before = Metrics.read(), ticksBefore = ticks
    try emit(["phase": "sampling", "seconds": seconds])
    spin(seconds)
    let after = Metrics.read()
    let elapsed = after.time - before.time
    try emit(["phase": "result", "seconds": elapsed,
      "cpuSeconds": after.cpu - before.cpu, "cpuPercent": (after.cpu - before.cpu) / elapsed * 100,
      "timerCallbacks": ticks - ticksBefore,
      "interruptWakeups": before.wakeups.flatMap { a in after.wakeups.map { $0 - a } } as Any? ?? NSNull(),
      "footprintStart": before.footprint as Any? ?? NSNull(), "footprintEnd": after.footprint as Any? ?? NSNull(),
      "thermalStart": thermalBefore, "thermalEnd": ProcessInfo.processInfo.thermalState.rawValue,
      "deviceStable": deviceBefore == outputDevice(), "assertions": try ownAssertions(),
      "resources": try JSONSerialization.jsonObject(with: JSONEncoder().encode(transport.resources))])
  }
  @MainActor static func lifecycle(_ audio: URL) throws {
    let scheduler = ManualPositionUpdates()
    let transport = Transport(positionUpdates: scheduler.start)
    try check(!transport.resources.engineRunning && scheduler.active == 0, "created transport is idle")
    try transport.load(audio)
    try check(!transport.resources.engineRunning && scheduler.active == 0, "loading does not start audio or clock")
    for _ in 0..<20 {
      transport.a = 0.2; transport.b = 0.8; transport.loop = true
      try transport.seek(0.2); try transport.play()
      try check(transport.resources.engineRunning && scheduler.active == 1, "one clock while playing")
      scheduler.fire()
      try transport.seek(0.3)
      try check(transport.playing && scheduler.active == 1, "playing seek restarts exactly one clock")
      transport.stop()
      let held = transport.position
      scheduler.fire()
      try check(!transport.resources.engineRunning && scheduler.active == 0 && transport.position == held,
                "pause cancels clock and engine without changing held position")
    }
    transport.loop = false
    try transport.seek(5.85); try transport.play()
    let deadline = Date().addingTimeInterval(5)
    while transport.playing && Date() < deadline { spin(0.05) }
    try check(!transport.playing && transport.position == 6 && !transport.resources.engineRunning
              && scheduler.active == 0, "natural end releases engine and clock, preserving exact endpoint")
    try transport.seek(0.5); try transport.play(); transport.unload()
    try check(!transport.resources.engineRunning && scheduler.active == 0 && transport.position == 0,
              "unload releases playback resources")
    try transport.load(audio, offset: 1)
    transport.a = 0.5; transport.b = 2; transport.loop = true
    try transport.seek(1)
    var rejected = false
    do { try transport.play() } catch { rejected = true }
    try check(rejected && !transport.resources.engineRunning && scheduler.active == 0,
              "error after engine setup does not retain resources")
    try transport.load(audio)
    transport.loop = false
    try transport.seek(0); try transport.play()
    try check(transport.playing && scheduler.active == 1, "playback recovers after failure")
    transport.stop()
    spin(5)
    try check(try ownAssertions().isEmpty, "owned audio sleep assertion released within five seconds")
    var disposable: Transport? = Transport(positionUpdates: scheduler.start)
    weak var released = disposable
    try disposable?.load(audio); try disposable?.play()
    disposable = nil
    try check(released == nil && scheduler.active == 0, "transport and timer release together")
    print("PASS audio resources: deterministic clock cancellation / 20 restarts / live seek / natural end / unload / error / deinit / sleep assertion")
  }
}

@MainActor final class ManualPositionUpdates {
  private var actions: [UUID: () -> Void] = [:]
  var active: Int { actions.count }
  func start(_ action: @escaping () -> Void) -> AnyCancellable {
    let id = UUID(); actions[id] = action
    return AnyCancellable { [weak self] in self?.actions[id] = nil }
  }
  func fire() { for action in Array(actions.values) { action() } }
}
