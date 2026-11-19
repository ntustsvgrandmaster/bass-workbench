import AVFoundation
import Combine
import Foundation

@main struct WorkbenchTests {
  static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw WorkbenchError.message("TEST FAILED: \(message)") }
  }

  @MainActor static func main() throws {
    guard let dataRoot = ProcessInfo.processInfo.environment["BASS_DATA_ROOT"], !dataRoot.isEmpty
    else {
      throw WorkbenchError.message("Specify BASS_DATA_ROOT for disposable test data")
    }
    let store = WorkbenchStore()
    defer { store.transport.stop() }
    try check(!store.project.loop, "new projects start with loop disabled")
    let audio = store.folder.appendingPathComponent("synthetic.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050 * 12)!
    buffer.frameLength = buffer.frameCapacity
    buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
    do {
      let file = try AVAudioFile(forWriting: audio, settings: format.settings)
      try file.write(from: buffer)
    }
    let asset = MediaAsset(
      role: "original", name: "synthetic.wav", originalPath: "synthetic.wav",
      pcmPath: "synthetic.wav", hash: try Files.hash(audio), duration: 12,
      sampleRate: 22050, channels: 1)
    store.project.assets = [asset]
    store.project.selectedAsset = asset.id
    store.project.timing.bpm = 240  // 每小節一秒，測試可以實際跨越多小節。
    store.project.regions = store.project.measures.map {
      HarmonyRegion(measureID: $0.id, startBeat: $0.beat, endBeat: $0.end)
    }
    let first = store.project.regions.removeFirst()
    store.project.regions.insert(
      contentsOf: [
        HarmonyRegion(measureID: first.measureID, startBeat: 0, endBeat: 2),
        HarmonyRegion(measureID: first.measureID, startBeat: 2, endBeat: 4),
      ], at: 0)
    store.project.regions[0].annotation = HumanAnnotation(
      root: "", chord: "Cm", firstNote: "E1", rootLocked: true, chordLocked: true,
      firstLocked: true, rejected: ["C"], confirmed: true)
    let originalAnnotations = store.project.regions.map(\.annotation)
    try store.transport.load(audio)
    try viewportTests(store)

    store.transport.position = 0.2
    try check(
      store.project.selectedMeasure == 0 && store.currentRegion?.id == store.project.regions[0].id,
      "first region follows position")
    store.transport.position = 0.5
    try check(
      store.currentRegion?.id == store.project.regions[1].id, "region follows inside a measure")
    store.transport.position = 1
    try check(
      store.project.selectedMeasure == 1 && store.viewportStart == 1,
      "exact measure boundary follows")
    store.transport.position = 3.5
    try check(
      store.project.selectedMeasure == 3 && store.playbackMeasure == 3, "seek updates measure")
    try check(store.navigationScrollRequest?.index == 3, "paused time seek requests navigator follow")
    try check(
      store.project.a == 0 && store.project.b == 4 && !store.project.loop,
      "following does not reset or enable loop")

    store.followPlayback = false
    store.transport.position = 4.5
    try check(
      store.project.selectedMeasure == 3 && store.playbackMeasure == 4,
      "follow off leaves inspection at selected measure")
    store.followPlayback = true
    try check(store.project.selectedMeasure == 4, "turning follow back on catches up")
    store.setEditing("annotation", active: true)
    store.setEditing("title", active: true)
    store.transport.position = 5.2
    try check(
      store.project.selectedMeasure == 4 && store.playbackMeasure == 5,
      "editing freezes inspector but not playback label")
    store.setEditing("annotation", active: false)
    try check(store.project.selectedMeasure == 4, "other editing scope still protects selection")
    store.setEditing("title", active: false)
    try check(store.project.selectedMeasure == 5, "finishing editing resumes follow")
    store.busy = true
    store.transport.position = 6.2
    try check(
      store.project.selectedMeasure == 5 && store.playbackMeasure == 6,
      "analysis keeps its viewport while playback label follows")
    store.busy = false
    try check(store.project.selectedMeasure == 6, "follow resumes after analysis")

    try store.project.timing.set(beat: 0, seconds: 1)
    try store.project.timing.set(beat: 4, seconds: 3)
    try store.project.timing.set(beat: 12, seconds: 5)
    store.transport.position = 3
    try check(store.project.selectedMeasure == 1, "follow uses calibrated anchors")
    store.transport.position = 5
    try check(store.project.selectedMeasure == 3, "follow handles variable tempo anchors")
    store.project.timing = TimingMap(bpm: 240)

    try check(store.setLoop(a: 2, b: 7, enable: true), "cross-measure loop accepted")
    store.navigate(3)
    try check(store.navigationScrollRequest?.index == 3, "score/previous/next navigation requests scroll")
    try check(
      !store.transport.playing && store.transport.position == 3,
      "manual score/sidebar navigation seeks and pauses")
    try check(
      store.project.a == 2 && store.project.b == 7 && store.project.loop,
      "navigation preserves multi-measure loop")
    let savedA = store.project.a
    let savedB = store.project.b
    try check(!store.setLoop(a: 8, b: 7), "invalid loop rejected atomically")
    try check(
      store.project.a == savedA && store.project.b == savedB,
      "invalid pair preserves both old endpoints")
    store.error = nil
    try check(store.loopValidation(a: .nan, b: 3) != nil, "reject non-finite time")
    try check(store.loopValidation(a: 0, b: 181) != nil, "preserve 180-second limit")
    try check(store.loopValidation(a: 0, b: 12.1) != nil, "reject loop beyond source")
    store.loopCurrentMeasure()
    try check(
      store.project.a == 3 && store.project.b == 4 && store.project.loop,
      "explicit current-measure loop")
    store.setLoopEnabled(false)
    try check(!store.project.loop, "loop can be disabled")

    let oldTitle = store.project.title
    try check(
      !store.renameProject(" \n ") && store.project.title == oldTitle, "empty title does not commit"
    )
    try check(
      store.renameProject("  階段一測試  ") && store.project.title == "階段一測試",
      "title saved as one trimmed edit")
    store.undo()
    try check(store.project.title == oldTitle, "one undo restores entire previous title")
    store.redo()
    try check(store.project.title == "階段一測試", "rename can be redone")
    try check(
      store.project.regions.map(\.annotation) == originalAnnotations,
      "following and transport preserve annotations including locked blank")
    let editedRegion = store.project.regions[2].id
    store.annotate(regionID: editedRegion) { $0.root = "D" }
    try check(
      store.project.regions[2].annotation.root == "D",
      "late editing action targets its original region after follow resumes")
    try check(
      store.currentRegion?.id != editedRegion && store.currentRegion?.annotation.root != "D",
      "late editing action does not write to new playback region")
    store.undo()
    store.project.loop = true
    store.persist()
    let restored = try ProjectStore.load(store.folder)
    try check(
      restored.loop && restored.title == "階段一測試", "existing loop flag and title survive save/reopen"
    )
    store.openProject(store.folder)
    try check(
      store.project.loop && store.transport.loop,
      "opening an existing project configures its saved loop state")
    try check(
      store.project.regions.map(\.annotation) == originalAnnotations,
      "actual reopen keeps independent locks and locked blank")

    // 真正啟動音訊引擎，驗證跟隨不會在小節邊界停止播放，並會跟著 A–B 回跳。
    try check(store.setLoop(a: 0.2, b: 3.4, enable: true), "prepare live loop")
    var visited: [Int] = []
    let observation = store.$playbackMeasure.compactMap { $0 }.removeDuplicates().sink {
      visited.append($0)
    }
    store.seek(0.2)
    store.playPause()
    RunLoop.main.run(until: Date().addingTimeInterval(3.7))
    try check(
      store.transport.playing,
      "following does not interrupt actual playback: \(store.error ?? "no error")")
    try check(
      visited.contains(1) && visited.contains(2) && visited.contains(3) && visited.last == 0,
      "live audio crosses measures then follows loop back to first")
    try check(store.project.a == 0.2 && store.project.b == 3.4, "live loop bounds stay unchanged")
    store.navigate(2, scrollNavigation: false)
    try check(
      !store.transport.playing && store.transport.position == 2,
      "clicking measure during playback pauses at requested position")
    try check(store.navigationScrollRequest == nil,
              "sidebar navigation suppresses stop/seek notifications and pending scroll")
    store.navigate(2, scrollNavigation: false)
    try check(store.navigationScrollRequest == nil, "repeated sidebar selection never requests scroll")
    observation.cancel()

    store.setLoopEnabled(false)
    store.project.rate = 0.5
    store.seek(0.75)
    store.playPause()
    RunLoop.main.run(until: Date().addingTimeInterval(0.9))
    try check(
      store.transport.playing && store.transport.position > 1 && store.transport.position < 1.5,
      "half-speed source time advances across measure boundary")
    try check(store.project.selectedMeasure == 1, "half-speed measure follows source time")
    try check(store.navigationScrollRequest?.index == 1, "actual playback resumes navigator follow")
    store.transport.stop()

    store.project.score = ScoreDocument(
      originalPath: "", xmlPath: "", sourceHash: "test", originalName: "pickup", staves: [],
      measures: [
        ScoreMeasure(
          id: "p", index: 0, number: "0", onset: Fraction(0), duration: Fraction(1), numerator: 4,
          denominator: 4),
        ScoreMeasure(
          id: "m", index: 1, number: "1", onset: Fraction(1), duration: Fraction(3), numerator: 3,
          denominator: 4),
        ScoreMeasure(
          id: "n", index: 2, number: "2", onset: Fraction(4), duration: Fraction(3), numerator: 6,
          denominator: 8),
      ], notes: [], bpm: 120, warnings: [])
    store.project.timing = TimingMap(bpm: 120)
    store.transport.position = 0.49
    try check(store.project.selectedMeasure == 0, "pickup duration is respected")
    store.transport.position = 0.5
    try check(store.project.selectedMeasure == 1, "3/4 follows pickup")
    store.transport.position = 2
    try check(store.project.selectedMeasure == 2, "6/8 follows actual score beat range")
    store.transport.position = 12
    try check(store.project.selectedMeasure == 2, "end of audio clamps to final score measure")
    print(
      "PASS workbench: live follow / seek / loop wrap / half speed / editing protection / variable meter / rename / persistence"
    )
  }

  @MainActor static func viewportTests(_ store: WorkbenchStore) throws {
    let original = store.project
    defer {
      store.transport.stop()
      store.project = original
      store.configureTransport()
      store.followPlayback = true
      store.zoomMeasure()
      store.seek(0)
    }
    store.zoomMeasure()
    store.seek(0.25)
    store.zoom(4)
    let initial = ViewportRange(start: store.viewportStart, end: store.viewportEnd)
    for time in [1.25, 2.25, 3.25] { store.transport.position = time }
    try check(store.viewportMode == .manual(span: 4) && store.viewportStart == initial.start
              && store.viewportEnd == initial.end, "crossing measures preserves manual zoom and visible range")
    store.transport.position = 4.25
    try check(store.viewportEnd - store.viewportStart == 4 && store.viewportStart > initial.start,
              "offscreen position pans at fixed span")
    try check(store.setLoop(a: 0.5, b: 3.5, enable: true), "prepare T03 playback loop")
    store.seek(0.5)
    store.playPause()
    RunLoop.main.run(until: Date().addingTimeInterval(3.3))
    try check(store.transport.playing && store.viewportEnd - store.viewportStart == 4
              && store.transport.position < 1.5, "actual playback crosses bars and loop rewind preserves zoom")
    store.transport.stop()
    store.navigate(8, scrollNavigation: false)
    try check(store.viewportMode == .manual(span: 4) && store.viewportEnd - store.viewportStart == 4
              && store.viewportStart <= 8 && store.viewportEnd >= 8,
              "manual navigation pans to selected measure without resetting zoom")
    try check(store.project.a == 0.5 && store.project.b == 3.5 && store.project.loop,
              "viewport changes preserve A/B endpoints and enable flag")
    store.followPlayback = false
    let frozen = store.viewportStart
    store.transport.position = 11
    try check(store.viewportStart == frozen, "follow off freezes manual viewport")
    store.followPlayback = true
    try check(store.viewportEnd == 12 && store.viewportEnd - store.viewportStart == 4,
              "follow on catches up at end without shrinking")
    store.zoomMeasure()
    store.zoom(1.5)
    let inspected = ViewportRange(start: store.viewportStart, end: store.viewportEnd)
    store.busy = true
    store.busy = false
    store.setEditing("viewport-test", active: true)
    store.setEditing("viewport-test", active: false)
    try check(ViewportRange(start: store.viewportStart, end: store.viewportEnd) == inspected,
              "analysis/editing cleanup does not pan paused manual inspection")
    store.seek(4)
    try check(store.viewportStart <= 4 && store.viewportEnd >= 4
              && store.viewportEnd - store.viewportStart == 1.5,
              "explicit paused seek still pans manual viewport")
    store.zoomLoop()
    store.navigate(2)
    store.transport.position = 8.25
    try check(store.viewportMode == .loop && store.viewportStart == 0.5 && store.viewportEnd == 3.5,
              "A/B view remains fixed across navigation and clock updates")
    try check(store.setLoop(a: 1, b: 5), "update A/B")
    try check(store.viewportStart == 1 && store.viewportEnd == 5, "A/B view reflects edited endpoints")
    store.navigate(2)
    store.zoomMeasure()
    try check(store.viewportMode == .measure && store.viewportStart == 2 && store.viewportEnd == 3,
              "explicit current-measure command restores measure framing")
    store.zoomLoop()
    try check(store.loopCurrentMeasure() && store.viewportMode == .measure,
              "switching from A/B to a single-measure loop restores measure framing")
    store.setLoopEnabled(false)
    store.transport.position = 3.25
    try check(store.project.selectedMeasure == 3 && store.viewportStart == 3 && store.viewportEnd == 4,
              "playback following selects and frames the next bar after leaving the loop")
    store.project.assets[0].duration = 0.12
    store.zoom(8)
    try check(store.viewportStart == 0 && store.viewportEnd == 0.12,
              "short source never displays beyond its duration")
    store.project.assets[0].duration = 12
    store.loadAsset(store.project.assets[0].id)
    try check(store.viewportEnd - store.viewportStart == 8, "source reload preserves requested manual span")
    store.setBPM(200)
    var timing = store.project.timing
    try timing.setBias(0.1)
    try check(store.applyAlignment(timing) && store.viewportEnd - store.viewportStart == 8,
              "BPM/bias adjustment does not reset manual zoom")
    try check(store.applyEstimatedGrid(GridInput(bpm: 200, numerator: 3, denominator: 4, firstBar: 0))
              && store.viewportMode == .manual(span: 8) && store.viewportEnd - store.viewportStart == 8,
              "applying a new grid preserves manual viewport mode and span")
    print("PASS T03: manual zoom / navigation / live loop / follow toggle / cleanup / A–B / short source / alignment")
  }
}
