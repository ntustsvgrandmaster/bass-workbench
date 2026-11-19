import Foundation

/// 純模型、輸入狀態與假 Worker 測試；不建立視窗、不啟動音訊引擎。
@main struct UnitTests {
  static var assertions = 0
  static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    assertions += 1
    if try !value() { throw WorkbenchError.message("TEST FAILED: \(message)") }
  }
  static func rejects(_ message: String, _ operation: () throws -> Void) throws {
    var failed = false
    do { try operation() } catch { failed = true }
    try check(failed, message)
  }
  static func fixture(duration: Double = 268) -> Project {
    var p = Project()
    p.timing.bpm = 120
    p.assets = [MediaAsset(role: "original", name: "synthetic", originalPath: "originals/source.wav",
                           pcmPath: "derived/source.wav", hash: "source", duration: duration,
                           sampleRate: 22050, channels: 1)]
    p.reconcileEstimatedRegions()
    return p
  }
  @MainActor static func main() async throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    try Files.directory(root)
    try gridTests(root)
    try planTests(root)
    try alignmentTests(root)
    try unifiedAlignmentTests()
    try navigationStateTests()
    try viewportTests()
    try draftTests()
    try tempoChoiceTests()
    try await runnerTests(root)
    print("PASS unit tests: \(assertions) assertions (grid / viewport / migration / drafts / batching / resume / cancellation / human data)")
  }
  static func unifiedAlignmentTests() throws {
    var p = fixture()
    p.regions[0].annotation.root = ""
    p.regions[0].annotation.rootLocked = true
    try p.timing.set(beat: 8, seconds: 5)
    try p.timing.setBias(0.25)
    func fresh() -> AlignmentEditorDraft {
      var d = AlignmentEditorDraft(); d.reset(project:p,asset:p.assets[0]); return d
    }
    var d = fresh()
    try check(!d.isModified && Double(d.firstBar) == 1.25, "origin includes existing anchor intercept and bias")
    try check(try d.applying(to:p,asset:p.assets[0]) == p, "opening / unchanged apply does not rewrite project")
    d.bpm = "150"; d.firstBar = "2.5"; d.sourceOffset = "0.3"
    try check(d.isModified && p.timing.bpm == 120 && p.assets[0].offset == 0, "all drafts remain separate from project")
    let result = try d.applying(to:p,asset:p.assets[0])
    try check(result.timing.bpm == 150 && abs(result.timing.seconds(at:0) - 2.5) < 1e-9
      && result.assets[0].offset == 0.3, "all fields produce one prospective project")
    try check(result.regions.first?.id == p.regions.first?.id && result.regions.first?.annotation.rootLocked == true,
      "BPM / origin changes preserve region IDs and locked blank")
    try check(result.timing.anchors == p.timing.anchors && result.timing.revision == p.timing.revision + 1,
      "origin translates existing anchor map with one revision")
    for (bpm,start,offset) in [("nan","1","0"),("130","inf","0"),("130","-","0"),("130","1","nan"),("130","1","3600"),("130","9999","0")] {
      var bad = fresh(); bad.bpm = bpm; bad.firstBar = start; bad.sourceOffset = offset
      try rejects("invalid batch rejected without partial update") { _ = try bad.applying(to:p,asset:p.assets[0]) }
    }
    d = fresh(); try d.nudge(0.1)
    try check(Double(d.firstBar) == 1.35 && p.timing.seconds(at:0) == 1.25, "nudge changes only unified origin draft")
    d = fresh(); d.numerator = 3
    let metered = try d.applying(to:p,asset:p.assets[0])
    try check(metered.estimatedGrid?.numerator == 3 && metered.regions[0].id != p.regions[0].id,
      "meter change alone rebuilds grid")
    try check(metered.archivedRegions.contains { $0.id == p.regions[0].id && $0.annotation.rootLocked },
      "rebuilt grid archives locked blank")
    try check(metered.timing.anchors == p.timing.anchors && metered.timing.seconds(at:0) == 1.25,
      "meter update does not discard calibrated anchor map or add origin twice")
    var other = p; other.timing.bpm = 130
    try rejects("external timing update rejects stale draft") { _ = try d.applying(to:other,asset:other.assets[0]) }
    other = p; other.assets[0].offset = 0.1
    try rejects("external source update rejects stale draft") { _ = try d.applying(to:other,asset:other.assets[0]) }
    d = fresh(); d.useTwoPoints = true; d.points.firstIndex = 0; d.points.lastIndex = 10
    d.points.firstSeconds = "2"; d.points.lastSeconds = "22"
    let two = try d.applying(to:p,asset:p.assets[0])
    try check(two.timing.bpm == 120 && two.timing.seconds(at:0) == 2 && two.timing.anchors.count == 2,
      "two-point mode replaces draft speed / origin / anchors together")
    d.points.lastSeconds = ""
    try rejects("incomplete active two-point input blocks whole batch") { _ = try d.applying(to:p,asset:p.assets[0]) }
    d = fresh(); try d.addAnchor(beat:16,seconds:9.5,project:p)
    try check(d.anchorTiming.anchors.count == 2 && p.timing.anchors.count == 1, "adding anchor is staged")
    d.bpm = "130"
    try rejects("multi-anchor tempo changes rejected") { _ = try d.applying(to:p,asset:p.assets[0]) }
    try d.clearAnchors(project:p)
    let cleared = try d.applying(to:p,asset:p.assets[0])
    try check(cleared.timing.anchors.isEmpty && cleared.timing.bpm == 130, "staged clear unlocks BPM in same apply")
    d = fresh(); try d.removeAnchor(p.timing.anchors[0].id,project:p)
    try check(p.timing.anchors.count == 1 && d.anchorTiming.anchors.isEmpty, "anchor removal is staged")
    print("PASS unified alignment draft / origin / all-field validation / stale guard / meter history / anchors")
  }
  static func tempoChoiceTests() throws {
    var estimate = TempoEstimate(bpm: 120, alternatives: [60, 120, 240, 300], beats: [],
      start: 0, end: 90, sourceHash: "synthetic", method: "test", warnings: [])
    try check(estimate.buttonBPMS == [120, 60, 240], "recommended first, deduplicated, at most three BPM buttons")
    try check(estimate.recommendedBPM == 120, "legacy candidate remains usable")
    estimate.alternatives = [.nan, 19, 401, 120, 120]
    try check(estimate.buttonBPMS == [120], "invalid or duplicate button values rejected")
    let fit = TempoFit(intercept: 0, medianMs: 40, p95Ms: 80, maxMs: 100, driftMs: 30,
      count: 20, span: 10, coverage: 1, outlierFraction: 0.5, status: "poor")
    estimate.candidates = [TempoCandidate(bpm: 120, originalBPM: 120.1, quantizedBPM: 120,
      usedFloat: true, multiplier: 1, fit: fit, quantizedFit: fit, originalFit: fit)]
    try check(estimate.preferredBPM == 120 && estimate.recommendedBPM == nil,
              "poor BPM is available for initial application without a recommendation badge")
    var alternative = estimate.candidates![0]
    alternative.bpm = 60
    alternative.fit.status = "good"
    estimate.alternatives.append(60)
    estimate.candidates!.append(alternative)
    try check(estimate.preferredBPM == 60 && estimate.recommendedBPM == 60,
              "a better supported alternative takes precedence over the primary")
    estimate.candidates!.removeLast()
    estimate.alternatives.removeLast()
    estimate.candidates![0].fit.status = "borderline"
    try check(estimate.recommendedBPM == 120, "accepted 20–30 ms boundary remains usable")
    estimate.bpm = nil
    try check(estimate.preferredBPM == 120 && estimate.recommendedBPM == 120,
              "an offered BPM with fit data is usable even without a primary")
    estimate.bpm = 120
    estimate.candidates = []
    try check(estimate.preferredBPM == 120 && estimate.recommendedBPM == nil,
              "a valid estimate without a matching fit is provisional")
    estimate.bpm = nil
    estimate.alternatives = [.nan, 19, 401]
    try check(estimate.preferredBPM == nil, "no valid BPM leaves the grid pending")
  }
  static func viewportTests() throws {
    try check(ViewportLayout.fitted(start: -2, span: 4, limit: 10) == ViewportRange(start: 0, end: 4),
              "manual viewport clamps at beginning without shrinking")
    try check(ViewportLayout.fitted(start: 8, span: 4, limit: 10) == ViewportRange(start: 6, end: 10),
              "manual viewport preserves width at end")
    try check(ViewportLayout.fitted(start: 2, span: 4, limit: 0.12) == ViewportRange(start: 0, end: 0.12),
              "very short source shows only its real duration")
    try check(ViewportLayout.clipped(ViewportRange(start: -2, end: 1), limit: 10)
              == ViewportRange(start: 0, end: 1), "negative measure start is clipped")
    try check(ViewportLayout.clipped(ViewportRange(start: 15, end: 17), limit: 10)
              == ViewportRange(start: 10, end: 10), "uncovered measure does not show fabricated final audio")
    try check(ViewportLayout.fitted(start: 0, span: 4, limit: 0) == ViewportRange(start: 0, end: 0),
              "no usable source duration gives empty viewport")
    try check(ViewportLayout.fitted(start: .nan, span: 4, limit: 10) == ViewportRange(start: 0, end: 0),
              "invalid viewport input stays finite")
    let current = ViewportRange(start: 2, end: 6)
    for position in [2.0, 3, 5.9, 6] {
      try check(ViewportLayout.following(position: position, current: current, span: 4, limit: 10) == current,
                "visible playhead never moves viewport: \(position)")
    }
    let advanced = ViewportLayout.following(position: 6.1, current: current, span: 4, limit: 10)
    try check(abs(advanced.span - 4) < 1e-9 && advanced.start < 6.1 && advanced.end > 6.1,
              "offscreen playhead pans without resetting zoom")
    try check(ViewportLayout.following(position: 0.5, current: current, span: 4, limit: 10)
              == ViewportRange(start: 0, end: 4), "loop rewind pans backward at same width")
    try check(ViewportLayout.following(position: 10, current: current, span: 4, limit: 10)
              == ViewportRange(start: 6, end: 10), "end position remains visible")
    let short = ViewportLayout.following(position: 1, current: current, span: 8, limit: 3)
    try check(short == ViewportRange(start: 0, end: 3), "short stem limits visible width")
    try check(ViewportLayout.following(position: 1, current: short, span: 8, limit: 20).span == 8,
              "returning to long source recovers requested zoom width")
    for position in [-100.0, 0, 3.5, 10, 100] {
      let range = ViewportLayout.following(position: position, current: current, span: 4, limit: 10)
      try check(range.start >= 0 && range.end <= 10 && range.span == 4,
                "pan preserves bounds/width for extreme position \(position)")
    }
  }

  static func navigationStateTests() throws {
    var project = fixture(duration: 12)
    let measure = project.measures[0]
    let original = project.regions
    func state() -> MeasureNavigationState { MeasureNavigationState(project: project, measureID: measure.id) }
    try check(state().marker == .unavailable && state().noteContent == .noScore,
              "no score is unknown note content, never reported as a rest")
    project.regions = []
    try check(state().confirmation == .none, "zero regions never means all confirmed")
    project.regions = [HarmonyRegion(measureID: measure.id, startBeat: 0, endBeat: 2),
                       HarmonyRegion(measureID: measure.id, startBeat: 2, endBeat: 4)]
    project.regions[0].annotation.confirmed = true
    project.regions[0].annotation.rootLocked = true
    project.regions[0].annotation.root = ""
    try check(state().confirmation == .partial && state().marker == .partial
              && state().description.contains("1/2"), "one of two regions is partial, including locked blank")
    project.regions[1].annotation.confirmed = true
    try check(state().confirmation == .complete && state().marker == .complete,
              "all regions explicitly confirmed yields full marker")
    project.regions[1].annotation.confirmed = false
    try check(state().confirmation == .partial, "unconfirm immediately returns to partial")
    project.regions = original
    let staff = ScoreStaff(id: "bass", partID: "P1", number: "1", name: "Bass", isTAB: false)
    let other = ScoreStaff(id: "other", partID: "P2", number: "1", name: "Other", isTAB: false)
    var note = ScoreNote(id: "n", partID: "P1", staffID: staff.id, voice: "1", measureID: measure.id,
                         onset: Fraction(0), duration: Fraction(4), soundingPitch: 28, writtenPitch: 40, kind: "note")
    project.score = ScoreDocument(originalPath: "", xmlPath: "", sourceHash: "fixture", originalName: "fixture",
                                  staves: [staff, other], measures: project.measures, notes: [note], warnings: [])
    project.selectedStaff = staff.id
    try check(state().marker == .notes && state().noteContent == .notes, "selected staff note gives gray marker")
    project.selectedStaff = other.id
    try check(state().marker == .empty, "notes on another staff do not populate selected staff")
    project.selectedStaff = "missing"
    try check(state().noteContent == .noStaff && state().marker == .unavailable,
              "invalid staff is unavailable, not a missing-note claim")
    project.selectedStaff = staff.id
    note.kind = "rest"; project.score!.notes = [note]
    try check(state().marker == .empty && state().description.contains("不代表漏譜"), "rest is explained without claiming omission")
    note.kind = "ghost"; project.score!.notes = [note]
    try check(state().marker == .notes, "unpitched non-rest note retains existing note-content semantics")
    var timing = TimingMap(bpm: 190)
    try check(timing.alignmentSummary.contains("190 BPM") && timing.alignmentSummary.contains("+0.000"),
              "summary keeps integer trailing zeros and signed applied offset")
    timing.bpm = 191.4062; try timing.setBias(-0.12)
    try check(timing.alignmentSummary.contains("191.4062") && timing.alignmentSummary.contains("-0.120"),
              "summary retains fractional BPM and negative offset")
    try timing.set(beat: 0, seconds: 0); try timing.set(beat: 4, seconds: 1.25)
    try check(timing.alignmentSummary.contains("區段速度") && timing.alignmentSummary.contains("2 錨點"),
              "multi-anchor summary does not imply a single fixed speed")
    var draft = AlignmentDraft(); draft.reset(from: timing)
    try check(!draft.isModified(from: timing), "fresh rounded draft is not dirty")
    draft.bias = "-"
    try check(draft.isModified(from: timing), "incomplete input remains visible as unapplied")
    draft.reset(from: timing)
    try check(!draft.isModified(from: timing), "reset removes incomplete draft")
    var points = TwoPointDraft(); points.reset(from: project)
    points.firstSeconds = "3"
    try check(points.hasInput, "two-point input marks pending state")
    points.reset(from: project)
    try check(!points.hasInput && points.validation == nil, "two-point cancel clears measured times and errors")
    print("PASS T06: partial/all confirmation / selected staff / no score / summary / pending drafts")
  }

  static func gridTests(_ root: URL) throws {
    var p = fixture()
    try check(p.measures.count == 134 && p.regions.count == 134, "audio-only grid covers 134 bars")
    try check(p.measures.last?.end == 536, "exact duration does not create a phantom bar")
    let ids = p.regions.map(\.id)
    p.reconcileEstimatedRegions()
    try check(p.regions.map(\.id) == ids, "reconciliation is idempotent")
    p.assets.append(MediaAsset(role: "bass", name: "stem", originalPath: "stem.wav", pcmPath: "stem.wav",
                               hash: "bass", duration: 9, sampleRate: 22050, channels: 1, offset: 5))
    p.selectedAsset = p.assets[1].id
    try check(p.measures.count == 134, "short stem selection never shrinks original grid")
    p.assets[0].duration = 268.3
    p.reconcileEstimatedRegions()
    try check(p.measures.count == 135 && p.regions.prefix(134).map(\.id) == ids,
              "partial last bar extends grid without losing prior regions")
    p.regions[0].annotation = HumanAnnotation(root: "", chord: "Cm", firstNote: "E1", rootLocked: true,
                                            chordLocked: false, firstLocked: true, rejected: ["C"], confirmed: true)
    let annotation = p.regions[0].annotation
    let old = p.regions
    try p.applyEstimatedGrid(GridInput(bpm: 120, numerator: 6, denominator: 8, firstBar: 1))
    try check(p.measures[0].length == 3 && p.measures.count == 179, "6/8 uses quarter-note beats and covers tail")
    try check(p.timing.seconds(at: 0) == 1 && p.timing.seconds(at: 3) == 2.5, "manual first bar maps to master seconds")
    try check(p.archivedRegions == old && p.archivedRegions[0].annotation == annotation,
              "regrid preserves locked blank and unlocked text in history")
    try check(p.regions.allSatisfy { $0.annotation == HumanAnnotation() }, "no silent reassignment to different bars")
    let unchanged = p
    try p.applyEstimatedGrid(GridInput(bpm: 120, numerator: 6, denominator: 8, firstBar: 1))
    try check(p == unchanged, "applying identical grid does not duplicate history")
    try ProjectStore.save(p, to: root.appendingPathComponent("grid.basswork"))
    try check(try ProjectStore.load(root.appendingPathComponent("grid.basswork")) == p,
              "grid, anchors and historical human data survive SQLite roundtrip")
    for input in [GridInput(bpm: .nan, numerator: 4, denominator: 4, firstBar: 0),
                  GridInput(bpm: 19, numerator: 4, denominator: 4, firstBar: 0),
                  GridInput(bpm: 401, numerator: 4, denominator: 4, firstBar: 0),
                  GridInput(bpm: 120, numerator: 0, denominator: 4, firstBar: 0),
                  GridInput(bpm: 120, numerator: 4, denominator: 3, firstBar: 0),
                  GridInput(bpm: 120, numerator: 4, denominator: 4, firstBar: -3601),
                  GridInput(bpm: 120, numerator: 4, denominator: 4, firstBar: 268.3)] {
      try rejects("invalid grid rejected") { try p.applyEstimatedGrid(input) }
      try check(p == unchanged, "invalid grid is atomic")
    }
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture())) as! [String: Any]
    legacy.removeValue(forKey: "estimatedGrid")
    let decoded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: legacy))
    try check(decoded.estimatedGrid == nil && decoded.measures.count == 134, "old projects decode without new optional fields")
    var extended = fixture(duration: 8)
    let firstID = extended.regions[0].id
    extended.regions[0].endBeat = 2
    extended.regions.append(HarmonyRegion(measureID: extended.measures[0].id, startBeat: 2, endBeat: 4))
    let splitID = extended.regions.last!.id
    extended.assets[0].duration = 2
    extended.reconcileEstimatedRegions()
    try check(extended.regions.map(\.id).contains(firstID) && extended.regions.map(\.id).contains(splitID),
              "reconciliation retains split regions")
    try check(extended.archivedRegions.count == 3, "removed tail is archived")
    var score = fixture()
    score.score = ScoreDocument(originalPath: "score.xml", xmlPath: "score.xml", sourceHash: "score",
                                originalName: "score", staves: [], measures: Array(score.measures.prefix(3)),
                                notes: [], bpm: 120, warnings: [])
    try check(score.measures.count == 3, "imported score controls measures")
    try rejects("estimated grid cannot replace imported score") {
      try score.applyEstimatedGrid(GridInput(bpm: 100, numerator: 4, denominator: 4, firstBar: 0))
    }
    var broken = fixture()
    broken.timing.bpm = .infinity
    try check(broken.measures.isEmpty, "invalid time arithmetic does not overflow")
    print("PASS estimated grid / meter / first-bar / tail / legacy decoding / human history")
  }

  static func alignmentTests(_ root: URL) throws {
    var truth = TimingMap(bpm: 191.4)
    try truth.setBias(0.6)
    let wrong = TimingMap(bpm: 190)
    try check(abs((TimingMap(bpm: 191.4).beat(at: 120) - wrong.beat(at: 120)) - 2.8) < 1e-10,
              "1.4 BPM error accumulates 2.8 quarter beats after two minutes")
    try check(wrong.seconds(at: 0) < truth.seconds(at: 0)
              && wrong.seconds(at: 512) > truth.seconds(at: 512),
              "offset plus wrong BPM crosses correct time once then diverges")
    let calibrated = try wrong.calibrated(from: AlignmentPoint(beat: 0, seconds: 0.6),
                                         to: AlignmentPoint(beat: 512, seconds: truth.seconds(at: 512)))
    try check(abs(calibrated.bpm - 191.4) < 1e-10, "two-point calibration recovers fractional BPM")
    try check([0.0, 1, 128, 256, 512, 800].allSatisfy {
      abs(calibrated.seconds(at: $0) - truth.seconds(at: $0)) < 1e-9
    }, "calibration corrects both endpoints and all intermediate/extrapolated beats")
    try check(calibrated.anchors.count == 2 && calibrated.bias == 0,
              "two-point result explicitly replaces prior anchors and bias")
    var shifted = calibrated
    try shifted.setBias(-0.25)
    try check([0.0, 128, 512].allSatisfy {
      abs(shifted.seconds(at: $0) - calibrated.seconds(at: $0) + 0.25) < 1e-10
    }, "negative bias shifts all anchors and notes equally")
    try check(abs((shifted.seconds(at: 512) - shifted.seconds(at: 0))
                  - (calibrated.seconds(at: 512) - calibrated.seconds(at: 0))) < 1e-10,
              "bias never changes segment duration or tempo")
    try check((-100...1000).allSatisfy { beat in
      abs(shifted.beat(at: shifted.seconds(at: Double(beat))) - Double(beat)) < 1e-9
    }, "piecewise time map remains invertible with signed bias")
    let actual = shifted.seconds(at: 128)
    try shifted.set(beat: 128, seconds: actual)
    try check(abs(shifted.seconds(at: 128) - actual) < 1e-9,
              "new anchors accept displayed master time, not raw pre-bias seconds")
    let stable = shifted
    for invalid in [Double.nan, .infinity, 3600.1, -3600.1] {
      try rejects("invalid bias rejected") { try shifted.setBias(invalid) }
      try check(shifted == stable, "invalid bias is atomic")
    }
    var negative = TimingMap(bpm: 120)
    try negative.setBias(-0.5)
    try check(negative.seconds(at: 0) == -0.5 && negative.beat(at: 0) == 1,
              "negative origin supports an audio crop or partial first bar")
    var p = fixture()
    p.regions[0].annotation = HumanAnnotation(root: "", chord: "manual", rootLocked: true, confirmed: true)
    let human = p.regions.map(\.annotation)
    let ids = p.regions.map(\.id)
    p.timing = shifted
    p.reconcileEstimatedRegions()
    try check(p.regions.first?.annotation == human[0] && p.regions.first?.id == ids[0],
              "timing correction keeps region IDs and locked blank instead of rebuilding human data")
    try ProjectStore.save(p, to: root.appendingPathComponent("alignment.basswork"))
    let saved = try ProjectStore.load(root.appendingPathComponent("alignment.basswork"))
    try check(saved.timing == shifted && saved.regions[0].annotation == human[0],
              "bias, anchors and manual data survive SQLite reopen")
    var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TimingMap(bpm: 190))) as! [String: Any]
    old.removeValue(forKey: "biasSeconds")
    let legacy = try JSONDecoder().decode(TimingMap.self, from: JSONSerialization.data(withJSONObject: old))
    try check(legacy.bias == 0 && legacy.seconds(at: 190) == 60, "old timing maps default to zero bias")
    var draft = AlignmentDraft(); draft.reset(from: calibrated)
    draft.bias = "0.125"
    try check(abs(try draft.timing(from: calibrated).bias - 0.125) < 1e-12,
              "bias draft works with existing two-point calibration")
    draft.bpm = "190"
    try rejects("BPM field cannot silently do nothing when two anchors control tempo") {
      _ = try draft.timing(from: calibrated)
    }
    var points = TwoPointDraft(); p = fixture(); points.reset(from: p)
    try check(points.firstSeconds.isEmpty && points.lastSeconds.isEmpty && points.lastIndex == 64,
              "calibration requires actual measured times, never prefilled guesses")
    points.firstIndex = 0; points.lastIndex = 64
    points.firstSeconds = "0.6"; points.lastSeconds = String(truth.seconds(at: 256))
    try check(abs(try points.timing(from: p).bpm - 191.4) < 1e-9, "manual bar numbers and times calibrate correct quarter-note distance")
    points.lastSeconds = "0.5"
    try rejects("reversed calibration times rejected") { _ = try points.timing(from: p) }
    points.lastSeconds = "9999"
    try rejects("calibration point outside source rejected") { _ = try points.timing(from: p) }
    for width in [580.0, 960] {
      let coordinates = TimelineCoordinates(start: 0, end: 4, width: width, inset: 44)
      let beat = 4.0
      let expectedSecond = calibrated.seconds(at: beat)
      let noteX = coordinates.x(at: expectedSecond)
      try check(abs(coordinates.seconds(at: noteX) - expectedSecond) < 1e-10,
                "note, grid and click coordinates roundtrip with axis inset")
      let samples = Int64((expectedSecond - 0.6) * 44100)
      let playSecond = PlaybackTimeline.seconds(start: 0.6, sampleTime: samples, sampleRate: 44100,
                                               loop: false, a: 0, b: 4)
      try check(abs(coordinates.x(at: playSecond) - noteX) < coordinates.plotWidth / coordinates.span / 44100 + 1e-9,
                "sample-clock playhead matches note/grid projection within one source sample")
      p.timing = calibrated
      let boundary = p.timing.seconds(at: p.measures[1].beat)
      try check(PlaybackTimeline.measureIndex(at: boundary - 0.0001, timing: p.timing, measures: p.measures) == 0
                && PlaybackTimeline.measureIndex(at: boundary, timing: p.timing, measures: p.measures) == 1,
                "following changes exactly at corrected drawn measure boundary")
    }
    try check(PlaybackTimeline.seconds(start: 2.5, sampleTime: 44100, sampleRate: 44100,
                                      loop: true, a: 2, b: 3) == 2.5,
              "sample-clock loop wraps on master timeline")
    var cropped = fixture(duration: 6)
    try cropped.applyEstimatedGrid(GridInput(bpm: 120, numerator: 4, denominator: 4, firstBar: -0.5))
    try check(cropped.timing.seconds(at: 0) == -0.5 && cropped.measures.count == 4,
              "manual negative first bar covers cropped start and final tail")
    print("PASS alignment: fractional BPM drift / signed bias / two points / timeline coordinates / sample clock / human data")
  }

  static func planTests(_ root: URL) throws {
    var p = fixture()
    let asset = p.assets[0]
    var plan = AnalysisPlan(project: p, arrangement: asset, bass: asset)
    try check(plan.pending == 134 && plan.batches.count == 6, "whole song exceeds previous 24-region limit via batches")
    for batch in plan.batches {
      try check(batch.count <= 24 && batch.last!.end - batch.first!.start <= 90, "batch memory bounds")
    }
    let items = plan.batches.flatMap { $0 }
    try check(Set(items.map(\.regionID)).count == 134 && items.last?.end == 268, "all regions exactly once including final bar")
    for item in items.prefix(2) {
      let index = p.regions.firstIndex { $0.id == item.regionID }!
      p.regions[index].evidence = evidence(start: item.start, key: item.contextKey)
    }
    plan = AnalysisPlan(project: p, arrangement: asset, bass: asset)
    try check(plan.reused == 2 && plan.pending == 132, "resume skips exactly completed contexts")
    try ProjectStore.save(p, to: root.appendingPathComponent("resume.basswork"))
    let reopened = try ProjectStore.load(root.appendingPathComponent("resume.basswork"))
    try check(AnalysisPlan(project: reopened, arrangement: asset, bass: asset).reused == 2, "resume survives project reopen")
    var moved = asset
    moved.pcmPath = "elsewhere.wav"
    try check(AnalysisPlan(project: p, arrangement: moved, bass: moved).reused == 2, "relocation does not invalidate content")
    moved.hash = "different"
    try check(AnalysisPlan(project: p, arrangement: moved, bass: asset).reused == 0, "source change invalidates resume")
    moved = asset; moved.offset = -1
    try check(AnalysisPlan(project: p, arrangement: moved, bass: asset).reused == 0, "offset change invalidates resume")
    moved = asset; moved.role = "bass"
    try check(AnalysisPlan(project: p, arrangement: asset, bass: moved).reused == 0, "source role change invalidates resume")
    p.timing.revision += 1
    try check(AnalysisPlan(project: p, arrangement: asset, bass: asset).reused == 0, "timing change invalidates resume")
    p = fixture()
    var short = asset; short.offset = 2; short.duration = 4
    plan = AnalysisPlan(project: p, arrangement: asset, bass: short)
    try check(plan.pending == 2 && plan.excluded.count == 132, "partial stem coverage is explicit, never called complete")
    plan = AnalysisPlan(project: p, arrangement: asset, bass: asset, range: 1...3, resume: false)
    try check(plan.pending == 2 && plan.batches[0][0].start == 0 && plan.batches[0][1].end == 4,
              "viewport selects complete regions; cropped edge is not a new first note")
    p.assets[0].duration = 268.3
    p.reconcileEstimatedRegions()
    plan = AnalysisPlan(project: p, arrangement: p.assets[0], bass: p.assets[0])
    try check(plan.pending == 135 && plan.batches.last?.last?.end == 268.3, "partial final bar clipped to song end")
    p.assets[0].duration = 268.05
    plan = AnalysisPlan(project: p, arrangement: p.assets[0], bass: p.assets[0])
    try check(plan.pending == 134 && plan.excluded.count == 1, "too-short tail is reported")
    p = fixture(duration: 800)
    p.timing.bpm = 20
    p.reconcileEstimatedRegions()
    plan = AnalysisPlan(project: p, arrangement: p.assets[0], bass: p.assets[0])
    try check(plan.batches.allSatisfy { $0.last!.end - $0.first!.start <= 90 }, "slow tempo respects 90 seconds before 24-region bound")
    print("PASS whole-song plan / bounded batches / exact context resume / offsets / tail exclusions")
  }

  @MainActor static func draftTests() throws {
    let target = DraftTarget(project: fixture(duration: 300))
    var loop = LoopDraft()
    loop.reset(a: 0, b: 4)
    loop.a = "8"
    try check(loop.validation == nil && target.commits == 0, "typing incomplete A>B neither validates nor commits")
    try check(!loop.apply(to: target) && target.commits == 0, "only submission reports invalid draft")
    loop.b = "12"
    try check(loop.apply(to: target) && target.project.a == 8 && target.project.b == 12,
              "complete pair commits atomically")
    for pair in [("NaN", "12"), ("8", "inf"), ("0", "181"), ("-1", "12"), ("8", "8.01"), ("", "9")] {
      loop.a = pair.0; loop.b = pair.1
      try check(!loop.apply(to: target) && target.project.a == 8 && target.project.b == 12, "invalid draft retains old pair")
    }
    loop.reset(a: target.project.a, b: target.project.b)
    try check(loop.a == "8.000" && loop.b == "12.000" && loop.validation == nil, "cancel resets draft")
    try check(LoopRange.validation(a: 0, b: 180, asset: target.project.assets[0]) == nil, "exact 180-second boundary")
    var offsetAsset = target.project.assets[0]; offsetAsset.offset = 5
    try check(LoopRange.validation(a: 0, b: 10, asset: offsetAsset) != nil, "loop respects stem offset")
    var title = ProjectTitleDraft()
    title.begin(in: target)
    try check(title.editing && target.editing, "explicit title edit protects selection")
    title.text = "discard"
    title.cancel(in: target)
    try check(!title.editing && !target.editing && target.project.title != "discard", "cancel leaves title intact")
    title.begin(in: target); title.text = " "
    try check(!title.save(to: target) && title.invalid && title.editing, "invalid title remains editable")
    title.text = " new title "
    try check(title.save(to: target) && !title.editing && !target.editing, "explicit save exits title editing")
    var grid = GridDraft(); grid.reset(from: target.project)
    grid.bpm = "abc"
    try rejects("grid draft accepts incomplete typing but validates on submit") { _ = try grid.input(masterEnd: 300) }
    grid.bpm = " 120 "; grid.firstBar = "1.25"; grid.numerator = 3
    try check(try grid.input(masterEnd: 300) == GridInput(bpm: 120, numerator: 3, denominator: 4, firstBar: 1.25), "grid draft commits all values together")
    print("PASS input drafts / explicit validation / cancel / offset bounds / edit lifecycle")
  }

  static func evidence(start: Double, key: String? = nil, revision: Int = 0) -> HarmonyEvidence {
    HarmonyEvidence(contextKey: key, firstPitch: 40, firstTime: start, firstScore: 0.7, bassCenter: 40,
                    bassStrongBeat: 40, root: 0, chord: "C", rootMargin: 0.1, candidates: [], chroma: [],
                    warnings: [], arrangementSource: "source", bassSource: "source", method: AnalysisMethod.harmony,
                    timingRevision: revision, createdAt: "synthetic")
  }

  @MainActor static func runnerTests(_ root: URL) async throws {
    var p = fixture(duration: 12)
    p.regions[0].annotation = HumanAnnotation(root: "", chord: "manual", rootLocked: true, rejected: ["D"], confirmed: true)
    let annotations = p.regions.map(\.annotation)
    let asset = p.assets[0]
    let source: [String: Any] = ["hash": asset.hash, "role": asset.role, "offset": 0]
    let worker = FakeWorker()
    worker.pauseAt = 3
    let runner = RegionAnalysis(worker: worker)
    let plan = AnalysisPlan(project: p, arrangement: asset, bass: asset)
    let task = Task { @MainActor in
      try await runner.run(plan, arrangement: source, bass: source, revision: 0, cache: root, runtime: root,
                           progress: { _, _ in }, receive: { item, evidence, _ in
        p.regions[p.regions.firstIndex { $0.id == item.regionID }!].evidence = evidence
      })
    }
    await worker.waitUntilPaused()
    try check(p.regions.filter { $0.evidence != nil }.count == 2, "completed results delivered before cancellation")
    runner.cancel()
    worker.finishPaused() // 故意在取消之後回傳，驗證結果失效，而非只測正常取消錯誤。
    do { try await task.value; try check(false, "cancel must throw") } catch is CancellationError { }
    try check(p.regions.filter { $0.evidence != nil }.count == 2 && !runner.running, "late result is rejected")
    let resumed = AnalysisPlan(project: p, arrangement: asset, bass: asset)
    try check(resumed.reused == 2 && resumed.pending == 4, "canceled job resumes remaining regions")
    worker.pauseAt = nil
    var progress: [Double] = []
    try await runner.run(resumed, arrangement: source, bass: source, revision: 0, cache: root, runtime: root,
                         progress: { value, _ in progress.append(value) }, receive: { item, evidence, _ in
      p.regions[p.regions.firstIndex { $0.id == item.regionID }!].evidence = evidence
    })
    try check(progress.last == 1 && p.regions.allSatisfy { $0.evidence != nil }, "resume reaches full completion")
    try check(p.regions.map(\.annotation) == annotations, "analysis preserves all human fields including locked blank")
    try check(AnalysisPlan(project: p, arrangement: asset, bass: asset).pending == 0, "third invocation has no redundant requests")
    try check(worker.requests.count == 7 && worker.requests.allSatisfy { $0["op"] as? String == "harmony" }, "whole-song execution never requests full-song CQT")
    try ProjectStore.save(p, to: root.appendingPathComponent("analyzed.basswork"))
    let saved = try ProjectStore.load(root.appendingPathComponent("analyzed.basswork"))
    try check(saved.regions.map(\.annotation) == annotations && AnalysisPlan(project: saved, arrangement: asset, bass: asset).reused == 6,
              "completed evidence and human data persist independently")
    let invalid = FakeWorker(); invalid.badMethod = true
    let badRunner = RegionAnalysis(worker: invalid)
    var writes = 0
    var rejected = false
    do {
      try await badRunner.run(plan, arrangement: source, bass: source, revision: 0, cache: root, runtime: root,
                              progress: { _, _ in }, receive: { _, _, _ in writes += 1 })
    } catch WorkbenchError.message { rejected = true }
    try check(rejected && writes == 0 && !badRunner.running, "mismatched worker result cannot be stamped current")
    print("PASS fake-worker execution / late cancellation / resume / method validation / immutable annotations")
  }
}

@MainActor final class DraftTarget: DraftEditing {
  var project: Project
  var commits = 0
  var editing = false
  init(project: Project) { self.project = project }
  func loopValidation(a: Double, b: Double) -> String? { LoopRange.validation(a: a, b: b, asset: project.assets.first) }
  func setLoop(a: Double?, b: Double?, enable: Bool?) -> Bool {
    project.a = a ?? project.a; project.b = b ?? project.b; commits += 1
    return true
  }
  func renameProject(_ title: String) -> Bool {
    let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return false }
    project.title = value
    return true
  }
  func setEditing(_ scope: String, active: Bool) { editing = active }
}

final class FakeWorker: AnalysisRequesting, @unchecked Sendable {
  private let lock = NSLock()
  var pauseAt: Int?
  var badMethod = false
  private(set) var requests: [[String: Any]] = []
  private var pending: (CheckedContinuation<Data, Error>, [String: Any])?
  private var paused: CheckedContinuation<Void, Never>?
  func request(_ values: [String: Any], cacheRoot: URL, progress: @escaping (Double, String) -> Void) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      requests.append(values)
      if requests.count == pauseAt {
        pending = (continuation, values)
        let waiting = paused; paused = nil
        lock.unlock()
        waiting?.resume()
      } else {
        lock.unlock()
        continuation.resume(with: Result { try result(values) })
      }
    }
  }
  func result(_ values: [String: Any]) throws -> Data {
    var e = UnitTests.evidence(start: values["start"] as! Double, revision: values["timingRevision"] as! Int)
    if badMethod { e.method = "stale-method" }
    return try JSONEncoder().encode(e)
  }
  func waitUntilPaused() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if pending != nil { lock.unlock(); continuation.resume() }
      else { paused = continuation; lock.unlock() }
    }
  }
  func finishPaused() {
    lock.lock(); let p = pending; pending = nil; lock.unlock()
    if let p { p.0.resume(with: Result { try result(p.1) }) }
  }
  func cancel() { /* 保留 continuation，讓測試明確送出遲到結果。 */ }
}
