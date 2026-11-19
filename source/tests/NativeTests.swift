import AVFoundation
import AppKit
import Foundation

@main struct NativeTests {
  static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw WorkbenchError.message("TEST FAILED: \(message)") }
  }
  @MainActor static func main() throws {
    if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--prepare" {
      try prepare(
        manifest: URL(fileURLWithPath: CommandLine.arguments[2]),
        destination: URL(fileURLWithPath: CommandLine.arguments[3]))
      return
    }
    if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--image" {
      let metadata = try JSONDecoder().decode(
        AnalysisFeatures.self,
        from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
      let bytes = try Data(contentsOf: URL(fileURLWithPath: metadata.binaryPath))
      let values = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
      let image = SpectrumData(metadata: metadata, values: values).render(contrast: 65)
      try check(image != nil, "CQT binary creates rendered image")
      print("PASS CQT image dimensions \(image!.width) × \(image!.height)")
      return
    }
    let dir = URL(
      fileURLWithPath: CommandLine.arguments.count > 1
        ? CommandLine.arguments[1] : "/tmp/BassHarmonyTests"
    ).standardizedFileURL
    try Files.directory(dir)
    try testSpectrumCache(in: dir)
    var timing = TimingMap(bpm: 120)
    try timing.set(beat: 0, seconds: 1)
    try timing.set(beat: 4, seconds: 3.1)
    try timing.set(beat: 12, seconds: 7.8)
    for i in -10...200 {
      let beat = Double(i) / 10
      try check(abs(timing.beat(at: timing.seconds(at: beat)) - beat) < 1e-6, "timing inverse")
    }
    do {
      try timing.set(beat: 8, seconds: 2)
      throw WorkbenchError.message("bad anchor accepted")
    } catch WorkbenchError.message(let s) {
      try check(s != "bad anchor accepted", "monotonic anchors")
    }
    try check(Fraction(2, 6) == Fraction(1, 3), "exact rational rhythm")
    print("PASS rational rhythm and piecewise timing inversion / invalid anchors")
    let xml = """
      <score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Bass</part-name></score-part><score-part id="P2"><part-name>Bass TAB</part-name></score-part></part-list><part id="P1"><measure number="0" implicit="yes"><attributes><divisions>3</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>F</sign><line>4</line></clef><transpose><diatonic>0</diatonic><chromatic>0</chromatic><octave-change>-1</octave-change></transpose></attributes><note><pitch><step>E</step><octave>2</octave></pitch><duration>3</duration><tie type="start"/><notations><slide type="start" number="1"/></notations></note></measure><measure number="1"><note><pitch><step>E</step><octave>2</octave></pitch><duration>1</duration><tie type="stop"/></note><note><rest/><duration>11</duration></note></measure></part><part id="P2"><measure number="0" implicit="yes"><attributes><divisions>3</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>TAB</sign><line>5</line></clef></attributes><note><pitch><step>E</step><octave>1</octave></pitch><duration>3</duration><notations><technical><string>4</string><fret>0</fret><hammer-on type="start">H</hammer-on></technical></notations></note></measure><measure number="1"><note><rest/><duration>12</duration></note></measure></part></score-partwise>
      """
    try Files.directory(dir.appendingPathComponent("originals"))
    try Data(xml.utf8).write(to: dir.appendingPathComponent("originals/score.musicxml"))
    let doc = try ScoreIO.parse(Data(xml.utf8), xmlPath: "originals/score.musicxml")
    try check(doc.staves.count == 2 && doc.staves[1].isTAB, "preserve notation and TAB separately")
    try check(
      doc.measures.count == 2 && doc.measures[0].length == 1 && doc.measures[1].length == 4,
      "pickup and full bar")
    try check(
      doc.notes[0].soundingPitch == 28 && doc.notes[1].duration == Fraction(1, 3),
      "octave transposition and triplet")
    try check(doc.notes.contains { $0.stringNumber == 4 && $0.fret == 0 }, "TAB technical data")
    var p = Project()
    p.score = doc
    p.selectedStaff = doc.staves[0].id
    p.regions = doc.measures.map {
      HarmonyRegion(measureID: $0.id, startBeat: $0.beat, endBeat: $0.end)
    }
    p.regions[0].annotation = HumanAnnotation(
      root: "C", chord: "C", firstNote: "E1", rootLocked: true, chordLocked: true,
      firstLocked: true, rejected: ["Em"], confirmed: true)
    let before = try Files.hash(dir.appendingPathComponent("originals/score.musicxml"))
    let exported = try ScoreIO.annotatedXML(p, folder: dir)
    let xd = try XMLDocument(data: exported)
    try check(try xd.nodes(forXPath: "//technical/string").count == 1, "preserve TAB in export")
    try check(
      try xd.nodes(forXPath: "//slide | //hammer-on").count == 2, "preserve expressive notation")
    try check(
      try xd.nodes(forXPath: "//direction/direction-type/words[text()='C']").count == 1,
      "only add confirmed chord text")
    try check(
      try Files.hash(dir.appendingPathComponent("originals/score.musicxml")) == before,
      "original score not modified")
    try ProjectStore.save(p, to: dir)
    var loaded = try ProjectStore.load(dir)
    try check(
      loaded.regions[0].annotation == p.regions[0].annotation,
      "SQLite locks and ignored candidates roundtrip")
    loaded.regions[0].evidence = HarmonyEvidence(
      firstPitch: 40, firstTime: 0, firstScore: 0.7, bassCenter: 40, bassStrongBeat: 40, root: 4,
      chord: "Em", rootMargin: 0.1, candidates: [], chroma: Array(repeating: 0, count: 12),
      warnings: [], arrangementSource: "test", bassSource: "test", method: "test",
      timingRevision: 0, createdAt: "")
    try ProjectStore.save(loaded, to: dir)
    loaded = try ProjectStore.load(dir)
    try check(
      loaded.regions[0].annotation.root == "C" && loaded.regions[0].annotation.chord == "C",
      "new automatic evidence cannot overwrite manual labels")
    print(
      "PASS MusicXML/TAB preservation, pickup, triplets, bass octave, confirmed-text export and immutable original"
    )
    print(
      "PASS SQLite save/reopen with independently locked root/chord/first-note and ignored candidates"
    )
    if ProcessInfo.processInfo.environment["BASS_TEST_UNIT_ONLY"] == "1" {
      print("SKIP audio decoding / live playback (unit-only run; set BASS_TEST_INTEGRATION=1)")
      return
    }
    let wave = dir.appendingPathComponent("synthetic.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132300)!
    buffer.frameLength = 132300
    for i in 0..<132300 {
      let sample = Float(0.15 * sin(2 * Double.pi * 41.2034 * Double(i) / 44100))
      buffer.floatChannelData![0][i] = sample
      buffer.floatChannelData![1][i] = sample
    }
    do {
      let file = try AVAudioFile(
        forWriting: wave,
        settings: format.settings.merging([AVLinearPCMIsNonInterleaved: false]) { _, v in v },
        commonFormat: .pcmFormatFloat32, interleaved: false)
      try file.write(from: buffer)
    }
    let decoded = try AudioIO.decode(wave, to: dir.appendingPathComponent("analysis.wav"))
    try check(
      abs(decoded.0 - 3) < 0.01 && decoded.1 == 44100 && decoded.2 == 2, "stereo source decode")
    let pcm = try AVAudioFile(forReading: dir.appendingPathComponent("analysis.wav"))
    try check(
      pcm.processingFormat.sampleRate == 22050 && pcm.processingFormat.channelCount == 1
        && abs(Double(pcm.length) / 22050 - 3) < 0.02, "high quality analysis resampling")
    let m4a = dir.appendingPathComponent("synthetic.m4a")
    _ = try Files.run(
      URL(fileURLWithPath: "/usr/bin/afconvert"), [wave.path, m4a.path, "-f", "m4af", "-d", "aac "])
    _ = try AudioIO.decode(m4a, to: dir.appendingPathComponent("m4a-analysis.wav"))
    print("PASS native WAV/M4A decode, stereo source preservation and 22.05 kHz analysis copy")
    let flac = dir.appendingPathComponent("synthetic.flac")
    let ffmpeg = URL(
      fileURLWithPath: "/Applications/Ultimate Vocal Remover.app/Contents/Frameworks/ffmpeg")
    if ProcessInfo.processInfo.environment["BASS_TEST_SKIP_FLAC"] == "1" {
      print("SKIP optional external FLAC conversion (BASS_TEST_SKIP_FLAC=1)")
    } else if FileManager.default.fileExists(atPath: ffmpeg.path) {
      _ = try Files.run(ffmpeg, ["-v", "error", "-y", "-i", wave.path, flac.path])
      let f = try AudioIO.decode(flac, to: dir.appendingPathComponent("flac-analysis.wav"))
      try check(abs(f.0 - 3) < 0.02, "FLAC native import")
      print("PASS FLAC native import")
    }
    let transport = Transport()
    try transport.load(wave)
    transport.a = 0.2
    transport.b = 0.8
    transport.loop = true
    try transport.seek(0.2)
    try transport.play()
    RunLoop.main.run(until: Date().addingTimeInterval(1.4))
    try check(
      transport.playing && transport.position >= 0.2 && transport.position < 0.8,
      "sample-buffer A–B repeats")
    transport.stop()
    transport.rate = 0.5
    transport.loop = false
    try transport.seek(0.2)
    try transport.play()
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    try check(
      transport.position > 0.35 && transport.position < 0.85, "half-speed source-time progression")
    transport.stop()
    print("PASS native audio-engine A–B loop and half-speed playback")
    print("All native core tests passed.")
  }
  @MainActor static func prepare(manifest: URL, destination: URL) throws {
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
    let audio = json["audio"] as! [String: Any]
    let score = json["score"] as! [String: Any]
    let audioURL = URL(fileURLWithPath: audio["path"] as! String)
    let scoreURL = URL(fileURLWithPath: score["path"] as! String)
    let beforeAudio = try Files.hash(audioURL)
    let beforeScore = try Files.hash(scoreURL)
    try Files.directory(destination)
    var p = Project()
    p.title = "合成音訊 · 首輪驗證"
    p.score = try ScoreIO.importDocument(scoreURL, project: destination)
    p.selectedStaff = p.score!.staves.first(where: { !$0.isTAB })!.id
    p.timing.bpm = p.score?.bpm ?? 100
    p.regions = p.measures.map {
      HarmonyRegion(measureID: $0.id, startBeat: $0.beat, endBeat: $0.end)
    }
    let original = "originals/audio-original/\(audioURL.lastPathComponent)"
    let pcm = "derived/audio/\(beforeAudio).wav"
    try Files.directory(destination.appendingPathComponent(original).deletingLastPathComponent())
    try Files.directory(destination.appendingPathComponent(pcm).deletingLastPathComponent())
    if !FileManager.default.fileExists(atPath: destination.appendingPathComponent(original).path) {
      try FileManager.default.copyItem(
        at: audioURL, to: destination.appendingPathComponent(original))
    }
    let d = try AudioIO.decode(
      destination.appendingPathComponent(original), to: destination.appendingPathComponent(pcm))
    let asset = MediaAsset(
      role: "original", name: audioURL.lastPathComponent, originalPath: original, pcmPath: pcm,
      hash: beforeAudio, duration: d.0, sampleRate: d.1, channels: d.2)
    p.assets = [asset]
    p.selectedAsset = asset.id
    p.harmonyAsset = asset.id
    p.a = 0
    p.b = min(4, d.0)
    p.warnings = ["尚未人工對齊，所有候選需核對。", "原譜兩譜表在書寫順序 16、38、61 小節有少數音高差異，均保留原狀。"]
    try ProjectStore.save(p, to: destination)
    try check(
      try Files.hash(audioURL) == beforeAudio && Files.hash(scoreURL) == beforeScore,
      "private source files untouched")
    try check(p.measures.count == 88 && p.score!.staves.count == 2, "real score structure")
    print("Prepared private, managed validation project: \(destination.path)")
    print(
      "Preserved 88 measures, notation + TAB, all original symbols, and source hashes. No alignment or note correctness assumed."
    )
  }
}

extension NativeTests {
  static func testSpectrumCache(in directory: URL) throws {
    let cache = directory.appendingPathComponent("spectrum-cache-\(UUID().uuidString)")
    try Files.directory(cache)
    defer { try? FileManager.default.removeItem(at: cache) }
    // 由 Python json.dumps(sort_keys=True, separators=(",", ":")) 產生的舊版 key。
    // start=0、end=8.0、offset=0：刻意混用整數／小數以驗證既有快取相容。
    var metadata = AnalysisFeatures(
      cacheKey: "730437049955759405f28ef0dddc4a3ec6765989f7f6d9a4689871ea88e6b9bc",
      method: SpectrumCache.method, sampleRate: 22050, hop: 256, start: 0, end: 8,
      frameOrigin: 0, binsPerOctave: 24, minMIDI: 23, maxMIDI: 60, rows: 75, columns: 690,
      binaryPath: "/old-project-location/missing.f32", onsets: [1, 3, 6], lowWindowSeconds: 1,
      tuningCents: 0, elapsed: 0.1, cacheHit: false, warnings: [], sourceHash: "fixture-source")
    let values = [Float](repeating: -40, count: metadata.rows * metadata.columns)
    let binary = values.withUnsafeBytes { Data($0) }
    func writeFixture() throws {
      try JSONEncoder().encode(metadata).write(
        to: cache.appendingPathComponent(metadata.cacheKey + ".json"))
      try binary.prefix(metadata.rows * metadata.columns * 4).write(
        to: cache.appendingPathComponent(metadata.cacheKey + ".f32"))
    }
    try writeFixture()
    var query = SpectrumCache.Query(
      sourceHash: "fixture-source", offset: 0, start: 2, end: 4,
      minMIDI: 23, maxMIDI: 60, binsPerOctave: 24)
    let restored = SpectrumCache.restore(in: cache, matching: query).first
    try check(restored?.values == values, "restore covering cache with legacy Python key")
    try check(restored?.metadata.cacheHit == true, "restored graph marked as cached")
    try check(
      restored?.metadata.binaryPath.hasPrefix(cache.path) == true,
      "use moved project's local binary")
    try check(restored?.render(contrast: 65) != nil, "restored matrix renders")
    query.end = 9
    try check(
      SpectrumCache.restore(in: cache, matching: query).first?.metadata.end == 8,
      "preserve partial cache at its original end time")
    let originalMetadata = metadata
    metadata.cacheKey = "f76b5ef7b44f2ac3c5f7a920f1ee2b2e9e96d94a43f2f68fecaf30893187de4c"
    metadata.start = 9
    metadata.end = 10
    metadata.frameOrigin = 9
    metadata.columns = 86
    try JSONEncoder().encode(metadata).write(to: cache.appendingPathComponent(metadata.cacheKey + ".json"))
    try binary.prefix(metadata.rows * metadata.columns * 4).write(
      to: cache.appendingPathComponent(metadata.cacheKey + ".f32"))
    query.end = 10
    let separated = SpectrumCache.restore(in: cache, matching: query)
    try check(separated.map { $0.metadata.start }.sorted() == [0, 9]
      && separated.map { $0.metadata.end }.sorted() == [8, 10],
      "restore two compatible caches without filling the gap")
    metadata = originalMetadata
    query.end = 4
    query.offset = 1.25
    try check(
      SpectrumCache.restore(in: cache, matching: query).first == nil,
      "source offset must match hidden legacy cache key")
    query.offset = 0
    query.sourceHash = "different-source"
    try check(
      SpectrumCache.restore(in: cache, matching: query).first == nil, "source identity must match")
    query.sourceHash = "fixture-source"
    query.binsPerOctave = 12
    try check(SpectrumCache.restore(in: cache, matching: query).first == nil, "resolution must match")
    query.binsPerOctave = 24
    query.minMIDI = 28
    try check(SpectrumCache.restore(in: cache, matching: query).first == nil, "pitch range must match")
    query.minMIDI = 23
    metadata.method = "old-method"
    try writeFixture()
    try check(SpectrumCache.restore(in: cache, matching: query).first == nil, "method version must match")
    metadata.method = SpectrumCache.method
    try writeFixture()
    try Data([0, 1]).write(to: cache.appendingPathComponent(metadata.cacheKey + ".f32"))
    try check(
      SpectrumCache.restore(in: cache, matching: query).first == nil,
      "reject truncated matrix without crashing")
    try writeFixture()
    var invalidValues = values
    invalidValues[0] = .nan
    try invalidValues.withUnsafeBytes { Data($0) }.write(
      to: cache.appendingPathComponent(metadata.cacheKey + ".f32"))
    try check(
      SpectrumCache.restore(in: cache, matching: query).first == nil,
      "reject non-finite matrix before rendering")
    metadata.frameOrigin = 0.5
    try writeFixture()
    try check(
      SpectrumCache.restore(in: cache, matching: query).first == nil,
      "reject inconsistent frame time origin")
    metadata.frameOrigin = 0
    metadata.columns = Int.max
    try JSONEncoder().encode(metadata).write(
      to: cache.appendingPathComponent(metadata.cacheKey + ".json"))
    try check(
      SpectrumCache.restore(in: cache, matching: query).first == nil,
      "reject unreasonable matrix dimensions without allocation")
    metadata.columns = 690
    try Data("not json".utf8).write(to: cache.appendingPathComponent("broken.json"))
    try writeFixture()
    try check(
      SpectrumCache.restore(in: cache, matching: query).first != nil, "ignore unrelated corrupt metadata")
    try FileManager.default.removeItem(
      at: cache.appendingPathComponent(metadata.cacheKey + ".json"))
    try FileManager.default.removeItem(at: cache.appendingPathComponent(metadata.cacheKey + ".f32"))
    metadata.cacheKey = "dd22bf268196881fbadaa042907e39e66a7a65d029a121805f6c67dac129641b"
    metadata.frameOrigin = 1.25
    metadata.columns = 582
    try writeFixture()
    query.offset = 1.25
    try check(
      SpectrumCache.restore(in: cache, matching: query).first != nil, "restore nonzero-offset cache")
    try FileManager.default.removeItem(at: cache.appendingPathComponent(metadata.cacheKey + ".f32"))
    try check(
      SpectrumCache.restore(in: cache, matching: query).first == nil, "missing binary remains unanalyzed")
    print(
      "PASS spectrum cache restoration, source/offset/settings validation, moved paths and corrupt cache"
    )
  }
}
