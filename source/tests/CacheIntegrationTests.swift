import Foundation

@main struct CacheIntegrationTests {
  static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw WorkbenchError.message("TEST FAILED: \(message)") }
  }

  @MainActor static func main() async throws {
    guard let dataRoot = ProcessInfo.processInfo.environment["BASS_DATA_ROOT"], !dataRoot.isEmpty,
      CommandLine.arguments.count == 2
    else { throw WorkbenchError.message("Specify BASS_DATA_ROOT and synthetic fixture directory") }
    let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
    let store = WorkbenchStore()
    let original = store.folder.appendingPathComponent("original.wav")
    try FileManager.default.copyItem(
      at: fixture.appendingPathComponent("synthetic.wav"), to: original)
    let sourceHash = try Files.hash(original)
    let cache = store.folder.appendingPathComponent("derived/features")
    try Files.directory(cache.deletingLastPathComponent())
    try FileManager.default.copyItem(at: fixture.appendingPathComponent("features"), to: cache)
    let asset = MediaAsset(
      role: "original", name: "synthetic.wav", originalPath: "original.wav",
      pcmPath: "original.wav", hash: sourceHash, duration: 6, sampleRate: 22050, channels: 1)
    store.project.assets = [asset]
    store.project.selectedAsset = asset.id
    store.project.timing.bpm = 120
    store.project.regions = store.project.measures.map {
      HarmonyRegion(measureID: $0.id, startBeat: $0.beat, endBeat: $0.end)
    }
    store.project.regions[0].annotation = HumanAnnotation(
      root: "", chord: "Cm", firstNote: "E1", rootLocked: true, chordLocked: true,
      firstLocked: true, rejected: ["C"], confirmed: true)
    let annotations = store.project.regions.map(\.annotation)
    try store.transport.load(original)
    store.navigate(0)
    await store.restoreSpectrum()?.value
    try check(
      store.spectrum?.metadata.sourceHash == sourceHash, "real worker cache restores first measure")
    store.navigate(1)
    await store.restoreSpectrum()?.value
    try check(
      store.spectrum != nil && store.viewportStart == 2, "covering cache restores adjacent measure")
    store.navigate(2)
    await store.restoreSpectrum()?.value
    try check(store.spectrum == nil, "uncovered range does not show old graph")
    store.navigate(0)
    await store.restoreSpectrum()?.value
    try check(store.spectrum != nil, "returning restores graph without reanalysis")

    store.project.confirmAlignment()
    store.project.assets[0].duration = 100
    store.viewportEnd = 100
    let loading = store.restoreSpectrum()
    try check(store.canAnalyze && store.analyze() == nil && store.error != nil,
              "over-limit analysis reports its constraint before running")
    await loading?.value
    try check(store.spectrum != nil && !store.spectrumLoading, "rejected analysis leaves cache restore running")
    store.error = nil
    store.project.assets[0].duration = 6
    store.zoomMeasure()
    await store.restoreSpectrum()?.value

    let visible = store.spectrum
    store.zoom(0.5)
    try check(store.spectrum === visible && visible != nil, "compatible zoom retains the visible tile during load")
    store.seek(1.75)
    await store.restoreSpectrum()?.value
    try check(store.viewportMode == .manual(span: 1) && store.spectrum != nil,
              "manual pan restores actual covering cache")
    store.seek(5)
    await store.restoreSpectrum()?.value
    try check(store.viewportEnd - store.viewportStart == 1 && store.spectrum == nil,
              "uncovered manual pan keeps zoom but does not stretch old graph")
    store.navigate(0)
    await store.restoreSpectrum()?.value
    try check(store.spectrum != nil && store.viewportMode == .manual(span: 1),
              "manual return restores cache without resetting zoom")
    store.zoomMeasure()
    await store.restoreSpectrum()?.value

    try check(store.setLoop(a: 1.5, b: 5.5), "set a loop extending beyond cached analysis")
    store.zoomLoop()
    await store.restoreSpectrum()?.value
    try check(store.viewportStart == 1.5 && store.viewportEnd == 5.5
      && store.spectrum?.metadata.start == 0 && store.spectrum?.metadata.end == 4,
      "loop viewport and partial cache retain their independent time bounds")
    try check(store.setLoop(a: 1.5, b: 5.5, enable: true), "enable partially analyzed loop")
    store.seek(5.3)
    store.playPause()
    try check(store.transport.playing, "start real playback near loop end")
    let deadline = Date().addingTimeInterval(3)
    while store.transport.position > 2.5 && Date() < deadline {
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    try check(store.transport.playing && store.transport.position <= 2.5
      && store.viewportStart == 1.5 && store.viewportEnd == 5.5 && store.spectrum != nil,
      "loop wraps while partial spectrum and viewport stay in place")
    store.playPause()
    store.setLoopEnabled(false)
    store.navigate(0)

    store.zoomMeasure()
    await store.restoreSpectrum()?.value

    store.project.binsPerOctave = 12
    await store.restoreSpectrum()?.value
    try check(store.spectrum == nil, "resolution change hides mismatched graph")
    store.project.binsPerOctave = 24
    store.project.assets[0].offset = 1.25
    let changedSource = store.restoreSpectrum()
    try check(store.spectrum == nil, "offset changes drop incompatible tiles before load")
    await changedSource?.value
    try check(store.spectrum == nil, "source offset change hides mismatched graph")
    store.project.assets[0].offset = 0.45
    await store.restoreSpectrum()?.value
    try check(store.spectrum?.metadata.start == 0 && store.spectrum?.metadata.frameOrigin == 0.45,
              "positive offset cache restores even when the viewport starts before the stem")
    store.project.assets[0].offset = 0
    store.project.assets[0].hash = "different-source"
    await store.restoreSpectrum()?.value
    try check(store.spectrum == nil, "another audio source cannot reuse graph")
    store.project.assets[0].hash = sourceHash
    await store.restoreSpectrum()?.value
    try check(store.spectrum != nil, "original source/settings recover graph")
    try check(
      store.project.regions.map(\.annotation) == annotations,
      "restoration preserves all human values and locked blank")
    try check(
      !FileManager.default.fileExists(
        atPath: store.folder.appendingPathComponent("derived/runtime/worker.log").path),
      "navigation never starts analysis worker")
    store.persist()

    let moved = URL(fileURLWithPath: dataRoot).appendingPathComponent(
      "moved-\(UUID().uuidString).basswork")
    try FileManager.default.copyItem(at: store.folder, to: moved)
    store.openProject(moved)
    await store.restoreSpectrum()?.value
    try check(
      store.spectrum?.metadata.binaryPath.hasPrefix(moved.path) == true,
      "moved project restores from local cache path")
    try check(
      store.project.regions.map(\.annotation) == annotations, "reopen preserves annotations")
    store.zoom(2)
    let pending = store.restoreSpectrum()
    store.newProject()
    await pending?.value
    try check(
      store.spectrum == nil && store.project.assets.isEmpty && store.viewportMode == .measure,
      "late cache completion cannot write into new project")
    store.zoom(0.5)
    store.openProject(moved)
    await store.restoreSpectrum()?.value
    try check(store.spectrum != nil && store.viewportMode == .measure,
              "opening project resets transient framing and restores existing graph")
    store.clearCache()
    await store.restoreSpectrum()?.value
    try check(store.spectrum == nil, "clear cache cannot resurrect previous graph")
    try check(
      try Files.hash(moved.appendingPathComponent("original.wav")) == sourceHash,
      "clearing cache preserves original audio")
    try check(
      store.project.regions.map(\.annotation) == annotations, "clearing cache preserves annotations"
    )
    print(
      "PASS cache integration: real Python features / navigation / settings / moved project / late result / clear cache / originals and locks"
    )
  }
}
