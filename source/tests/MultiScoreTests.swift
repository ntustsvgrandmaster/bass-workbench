import Foundation
import AVFoundation
import SQLite3
import Darwin

/// 合成譜／可控 Worker；不讀私人歌曲，也不啟動真實播放或 DSP。
@main struct MultiScoreTests {
  static var assertions = 0
  static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    assertions += 1
    if try !value() { throw WorkbenchError.message("TEST FAILED: \(message)") }
  }
  static func rejects(_ message: String, _ body: () throws -> Void) throws {
    var failed = false
    do { try body() } catch { failed = true }
    try check(failed, message)
  }
  static func xml(pitch: String = "E", measures: Int = 8) -> String {
    let bars = (1...measures).map { index in
      "<measure number='\(index)'>\(index == 1 ? "<attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>F</sign></clef></attributes>" : "")<note><pitch><step>\(pitch)</step><octave>2</octave></pitch><duration>4</duration><type>whole</type></note></measure>"
    }.joined()
    return "<score-partwise version='4.0'><part-list><score-part id='P1'><part-name>Bass</part-name></score-part></part-list><part id='P1'>\(bars)</part></score-partwise>"
  }
  static func document(hash: String, pitch: String = "E", measures: Int = 8) throws -> ScoreDocument {
    try ScoreIO.parse(Data(xml(pitch: pitch, measures: measures).utf8), originalName: "same.musicxml",
                      originalPath: "originals/\(hash).musicxml", xmlPath: "originals/\(hash).musicxml", hash: hash)
  }
  static func fixture() -> Project {
    var p = Project()
    let asset = MediaAsset(role: "original", name: "synthetic", originalPath: "synthetic.wav",
                           pcmPath: "synthetic.wav", hash: "audio", duration: 120, sampleRate: 22050, channels: 1)
    p.assets = [asset]; p.selectedAsset = asset.id; p.harmonyAsset = asset.id
    p.timing.bpm = 120
    p.reconcileEstimatedRegions()
    return p
  }
  static func sql(_ folder: URL, _ statement: String, text: String? = nil) throws {
    var db: OpaquePointer?
    guard sqlite3_open(folder.appendingPathComponent("project.sqlite").path, &db) == SQLITE_OK,
      let db else { throw WorkbenchError.message("test sqlite open") }
    defer { sqlite3_close(db) }
    if let text {
      var stmt: OpaquePointer?
      guard sqlite3_prepare_v2(db, statement, -1, &stmt, nil) == SQLITE_OK else { throw WorkbenchError.message("test sqlite prepare") }
      defer { sqlite3_finalize(stmt) }
      sqlite3_bind_text(stmt, 1, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      guard sqlite3_step(stmt) == SQLITE_DONE else { throw WorkbenchError.message("test sqlite step") }
    } else if sqlite3_exec(db, statement, nil, nil, nil) != SQLITE_OK {
      throw WorkbenchError.message("test sqlite: \(String(cString: sqlite3_errmsg(db)))")
    }
  }
  @MainActor static func main() async throws {
    guard let path = ProcessInfo.processInfo.environment["BASS_DATA_ROOT"] else { fatalError("Specify disposable BASS_DATA_ROOT") }
    let root = URL(fileURLWithPath: path)
    try Files.directory(root)
    if CommandLine.arguments.contains("--memory") { try memoryProbe(); return }
    try modelTests(root)
    try migrationTests(root)
    try scoreIdentityTests(root)
    try forgetModelTests(root)
    let modelOnly = CommandLine.arguments.contains("--model-only")
    if !modelOnly {
      try await storeTests(root)
      try await finalizationStoreTests(root)
      try await scoreUpdateTests(root)
      try await linkedScoreUpdateTests(root)
    }
    print("PASS T10: \(assertions) assertions (\(modelOnly ? "model / file / migration / rollback" : "contexts / migration / scoped annotations / rollback / Store / stale results / originals"))")
  }
  @MainActor static func scoreUpdateTests(_ root: URL) async throws {
    let store = WorkbenchStore()
    let source = root.appendingPathComponent("\(UUID().uuidString).musicxml")
    try Data(xml().utf8).write(to: source)
    await store.importScore(source)?.value
    let original = try Files.hash(source)
    let context = store.project.activeContextID
    store.project.selectedMeasure = 3
    store.project.timing.bpm = 110
    try store.project.timing.setBias(0.4)
    try store.project.timing.set(beat: 12, seconds: 7)
    store.project.regions[3].annotation = HumanAnnotation(chord: "確認", rootLocked: true, chordLocked: true)
    let copy = try store.prepareScoreEditingCopy()
    try check(try store.prepareScoreEditingCopy() == copy, "same score reuses its editing copy")
    let initial = store.project
    try check(try ProjectStore.load(store.folder).editingScorePath == initial.editingScorePath, "editing copy survives reload")
    await store.updateReferenceScore(copy)?.value
    try check(store.project == initial, "identical file leaves the project intact")

    try Data(xml(pitch: "G").utf8).write(to: copy, options: .atomic)
    let oldRefresh = store.scoreRefresh
    let update = store.updateReferenceScore(copy)
    try check(store.scoreUpdating && store.updateReferenceScore(copy) == nil, "rejects overlapping update")
    await update?.value
    try check(store.error == nil && !store.scoreUpdating && store.scoreRefresh != oldRefresh,
              "compatible update refreshes preview")
    try check(store.project.activeContextID == context && store.project.availableScoreContexts.count == 1
              && store.project.editingScorePath == initial.editingScorePath,
              "same score and editing copy remain linked")
    try check(store.notes.first?.soundingPitch == 43 && store.project.selectedMeasure == 3
              && store.project.timing == initial.timing && store.project.regions == initial.regions,
              "new notes display in the same measure with calibration and locked blanks preserved")
    try check(try Files.hash(source) == original, "external original remains unchanged")
    let revised = store.project
    store.undo()
    try check(store.project == initial && store.notes.first?.soundingPitch == 40, "undo restores old score snapshot")
    store.redo()
    try check(store.project == revised && store.notes.first?.soundingPitch == 43, "redo restores updated score")
    try check(try ProjectStore.load(store.folder) == revised, "new reference and annotations persist")

    try Data(xml(pitch: "A", measures: 9).utf8).write(to: copy, options: .atomic)
    await store.updateReferenceScore(copy, confirmNewScore: { false })?.value
    try check(store.project == revised, "cancelling structural update retains old score")
    await store.updateReferenceScore(copy, confirmNewScore: { true })?.value
    let added = store.project
    try check(added.activeContextID != context && added.measures.count == 9
              && added.editingScorePath == revised.editingScorePath,
              "structural update adds independent score and moves editing copy")
    let previous = added.scoreContexts.first { $0.id == context }
    try check(previous?.regions == revised.regions && previous?.timing == revised.timing
              && previous?.editingScorePath == nil && added.regions.allSatisfy { !$0.annotation.rootLocked },
              "structural update preserves existing work without moving its annotations")
    try Data("<invalid/>".utf8).write(to: copy, options: .atomic)
    await store.updateReferenceScore(copy)?.value
    try check(store.project == added && store.error != nil, "failed update keeps last readable score")
    print("PASS manual score updates / stable calibration and annotations / undo and redo")
  }
  @MainActor static func linkedScoreUpdateTests(_ root: URL) async throws {
    let source = root.appendingPathComponent("\(UUID().uuidString).musicxml")
    try Data(xml().utf8).write(to: source)
    let store = WorkbenchStore()
    await store.importScore(source)?.value
    let folder = store.folder
    let context = store.project.activeContextID
    let reopened = WorkbenchStore()
    reopened.openProject(folder)
    try check(reopened.project.scoreSourcePath == source.standardizedFileURL.path, "import remembers the score's source across reopen")
    try Data(xml(pitch: "G").utf8).write(to: source, options: .atomic)
    await reopened.requestScoreUpdate()?.value
    try check(reopened.notes.first?.soundingPitch == 43 && reopened.project.activeContextID == context,
              "update action reloads the saved external score in place")

    // Simulate a score imported before the source path was recorded.
    reopened.project.scoreSourcePath = nil
    try check(reopened.requestScoreUpdate() == nil && reopened.error?.contains("連結參考譜來源") == true,
              "legacy score explains how to link without opening a chooser")
    reopened.error = nil
    await reopened.updateReferenceScore(source)?.value
    try check(try ProjectStore.load(folder).scoreSourcePath == source.standardizedFileURL.path,
              "linking identical content persists the source")
    try FileManager.default.removeItem(at: source)
    try check(reopened.requestScoreUpdate() == nil && reopened.notes.first?.soundingPitch == 43 && reopened.error != nil,
              "a missing source leaves the last loaded score visible")
    print("PASS direct refresh of imported source / reopen / legacy relink / missing file")
  }
  static func scoreIdentityTests(_ root: URL) throws {
    var p = fixture()
    let firstTime = Date(timeIntervalSince1970: 1_793_340_000)
    let secondTime = firstTime.addingTimeInterval(86_400)
    let aDoc = try document(hash: "identity-a")
    let a = p.addScore(aDoc, importedAt: firstTime)
    let first = p.scoreContexts.last!
    try check(p.referenceScoreName == "same.musicxml" && first.displayNumber == 0,
              "first import keeps original display name")
    let b = p.addScore(try document(hash: "identity-b", pitch: "G"), importedAt: secondTime)
    let second = p.scoreContexts.last!
    try check(p.scoreDisplayName(first) == "same.musicxml" && p.referenceScoreName == "same.musicxml（1）",
              "second import starts at one without renaming first")
    try check(first.importedAt == firstTime && second.importedAt == secondTime,
              "each genuinely new score records its own first import time")
    try check(second.importTimeDescription.hasPrefix("匯入於 ") && p.referenceScoreHelp.contains("same.musicxml（1）\n匯入於 "),
              "tooltip includes full name and local import time")
    let beforeDuplicate = p.scoreContexts
    _ = p.addScore(aDoc, importedAt: secondTime)
    try check(p.scoreContexts == beforeDuplicate, "same-content import does not replace time, number or work")
    _ = p.removeScoreContext(a)
    _ = p.addScore(aDoc, importedAt: secondTime)
    try check(p.scoreContexts.first { $0.id == a } == first, "cancelled removal/reimport restores original identity")
    let legacyBaseline = p
    p.forgetScoreContexts([a])
    try check(p.scoreContexts.first { $0.id == b } == second && p.referenceScoreName == "same.musicxml（1）",
              "forgetting first preserves second number and timestamp")
    let folder = root.appendingPathComponent("identity-\(UUID().uuidString).basswork")
    try ProjectStore.save(p, to: folder)
    p = try ProjectStore.load(folder)
    try check(p.scoreContexts.first { $0.id == b } == second && p.referenceScoreName == "same.musicxml（1）",
              "remaining suffix and date survive reopen after deletion")
    let c = p.addScore(try document(hash: "identity-c"), importedAt: secondTime)
    try check(p.referenceScoreName == "same.musicxml（2）", "new score continues saved numbering after first deletion")
    p.forgetScoreContexts([c])
    _ = p.addScore(try document(hash: "identity-d"), importedAt: secondTime)
    try check(p.referenceScoreName == "same.musicxml（3）", "deleted highest suffix is not reused")
    p.forgetScoreContexts(Set(p.availableScoreContexts.map(\.id)))
    try ProjectStore.save(p, to: folder)
    p = try ProjectStore.load(folder)
    _ = p.addScore(aDoc, importedAt: secondTime)
    try check(p.referenceScoreName == "same.musicxml（4）" && p.scoreContexts.last!.importedAt == secondTime,
              "fresh import after completed removals has new date and number")
    var otherName = try document(hash: "different-name")
    otherName.originalName = "other.musicxml"
    _ = p.addScore(otherName, importedAt: firstTime)
    try check(p.referenceScoreName == "other.musicxml", "different filenames each start with original name")
    _ = p.selectScoreContext("grid")
    try check(p.referenceScoreHelp == "無譜格線", "grid tooltip does not claim a score import")

    // 模擬實際舊 v3：沒有新欄位，連移除中的譜也依原保存順序補固定編號。
    var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyBaseline)) as! [String: Any]
    legacyJSON.removeValue(forKey: "nextScoreNumber")
    var contexts = legacyJSON["scoreContexts"] as! [[String: Any]]
    for i in contexts.indices {
      contexts[i].removeValue(forKey: "displayNumber")
      contexts[i].removeValue(forKey: "importedAt")
    }
    legacyJSON["scoreContexts"] = contexts
    var legacy = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
    let legacyScores = legacy.availableScoreContexts
    try check(legacyScores.map { legacy.scoreDisplayName($0) } == ["same.musicxml", "same.musicxml（1）"],
              "old v3 migrates once to original-name then suffix one")
    try check(legacyScores.allSatisfy { $0.importedAt == nil && $0.importTimeDescription == "匯入時間未記錄" },
              "legacy dates remain unknown instead of using project/open time")
    try check(legacy.regions == legacyBaseline.regions && legacy.timing == legacyBaseline.timing,
              "identity migration preserves human work and calibration")
    try ProjectStore.save(legacy, to: folder)
    legacy = try ProjectStore.load(folder)
    try check(legacy.availableScoreContexts.allSatisfy { $0.importedAt == nil }
              && legacy.availableScoreContexts.map(\.displayNumber) == [0, 1], "unknown dates and migrated numbering persist")
    let oldDates = legacy.scoreContexts.map(\.importedAt)
    _ = legacy.addScore(aDoc, importedAt: secondTime)
    try check(legacy.scoreContexts.map(\.importedAt) == oldDates, "deduplicating old score does not invent import time")
    print("PASS fixed score names / import dates / old-v3 migration / post-removal numbering")
  }
  static func modelTests(_ root: URL) throws {
    var p = fixture()
    let gridID = p.activeContextID
    p.selectedMeasure = 5
    p.regions[0].annotation = HumanAnnotation(rootLocked: true, chordLocked: true, confirmed: true)
    try p.timing.setBias(0.15)
    let grid = p.scoreContexts[0]
    let aDoc = try document(hash: "a")
    let a = p.addScore(aDoc)
    try check(p.timing.seconds(at: 0) == grid.timing.seconds(at: 0) && p.timing.anchors.isEmpty,
              "first reference score inherits calibrated grid origin")
    p.timing.bpm = 119.5
    try p.timing.setBias(0.3)
    try p.timing.set(beat: 0, seconds: 0.8)
    p.selectedMeasure = 3
    p.regions[0].id = "same-region"
    p.regions[0].annotation = HumanAnnotation(root: "", chord: "unfinished A", firstNote: "E1", rootLocked: true)
    var history = HarmonyRegion(measureID: p.measures[0].id, startBeat: 0, endBeat: 1)
    history.annotation = HumanAnnotation(chord: "archived A", chordLocked: true)
    p.archivedRegions = [history]
    let savedA = p.scoreContexts.last!
    let bDoc = try document(hash: "b", pitch: "G", measures: 12)
    let b = p.addScore(bDoc)
    p.timing.bpm = 200
    try p.timing.setBias(-0.1)
    p.selectedMeasure = 7
    p.regions[0].id = "same-region"
    p.regions[0].annotation = HumanAnnotation(chord: "B only", firstLocked: true, confirmed: true)
    let savedB = p.scoreContexts.last!
    try check(p.availableScoreContexts.count == 2 && a != b, "same names with distinct content are separate")
    try check(p.scoreDisplayName(savedA) == "same.musicxml"
              && p.scoreDisplayName(savedB) == "same.musicxml（1）", "same-name labels use human-readable import order")
    try check(p.selectScoreContext(a) && p.scoreContexts.first { $0.id == a } == savedA,
              "A calibration, anchors, index, staff and annotation untouched after B")
    try check(p.addScore(aDoc) == a && p.availableScoreContexts.count == 2
              && p.scoreContexts.first { $0.id == a } == savedA, "duplicate import retains context and all edits")
    let snapshot = p
    try check(!p.selectScoreContext("missing") && !p.removeScoreContext(gridID) && p == snapshot,
              "invalid selection and grid removal do not mutate")
    try check(p.removeScoreContext(b) && p.activeContextID == a, "remove inactive keeps active")
    try check(p.scoreDisplayName(savedA) == "same.musicxml"
              && p.scoreDisplayName(savedB) == "same.musicxml（1）", "temporary removal does not renumber names")
    try check(p.removeScoreContext(a) && p.activeContextID == gridID, "last removal returns to grid")
    try check(p.scoreContexts[0] == grid, "grid independent calibration, selection and locked blank restored")
    let directory = root.appendingPathComponent("contexts-\(UUID().uuidString).basswork")
    try ProjectStore.save(p, to: directory)
    var loaded = try ProjectStore.load(directory)
    try check(loaded == p, "all removed/inactive/active/history annotations survive SQLite")
    try check(loaded.scoreDisplayName(savedA) == "same.musicxml"
              && loaded.scoreDisplayName(savedB) == "same.musicxml（1）", "display numbering survives save and reopen")
    try check(loaded.restoreScoreContext(b) && loaded.selectScoreContext(b)
              && loaded.scoreContexts.first { $0.id == b } == savedB, "restore after reopen preserves B work")
    try check(loaded.addScore(aDoc) == a && loaded.scoreContexts.first { $0.id == a } == savedA,
              "reimport removed content restores original A instead of duplicate")
    try ProjectStore.save(loaded, to: directory)
    let baseline = loaded
    try sql(directory, "CREATE TRIGGER fail_context_save BEFORE INSERT ON context_annotations BEGIN SELECT RAISE(ABORT,'injected failure'); END;")
    loaded.title = "must roll back"
    loaded.regions[0].annotation.chord = "must roll back"
    try rejects("injected annotation write fails") { try ProjectStore.save(loaded, to: directory) }
    try check(try ProjectStore.load(directory) == baseline, "failed save rolls back metadata and all annotations")
    try sql(directory, "DROP TRIGGER fail_context_save;")
    let missing = root.appendingPathComponent("missing-annotations-\(UUID().uuidString).basswork")
    try FileManager.default.copyItem(at: directory, to: missing)
    let inactiveID = baseline.scoreContexts.first { $0.id != baseline.activeContextID && $0.score != nil }!.id
    try sql(missing, "DELETE FROM context_annotations WHERE context_id=?", text: inactiveID)
    try rejects("missing inactive annotation rows fail rather than silently clearing human data") {
      _ = try ProjectStore.load(missing)
    }
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(baseline)) as! [String: Any]
    try check(json["score"] == nil && json["regions"] == nil && json["timing"] == nil,
              "encoded project has only one authoritative context collection")
    json["activeContextID"] = "missing"
    try rejects("bad active reference rejected") {
      _ = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
    }
    var bad = baseline
    let inactive = bad.scoreContexts.firstIndex { $0.id != bad.activeContextID && $0.score != nil }!
    bad.scoreContexts[inactive].score!.xmlPath = "../outside.xml"
    try ProjectStore.save(bad, to: directory)
    try rejects("inactive score path validated too") { _ = try ProjectStore.load(directory) }
    bad = baseline; bad.scoreContexts[inactive].timing.bpm = 1
    try ProjectStore.save(bad, to: directory)
    try rejects("inactive timing validated too") { _ = try ProjectStore.load(directory) }
    print("PASS T10 model / scoped SQLite / rollback / inactive validation")
  }
  /// 真正寫入 v2 的平面 JSON 與舊 annotations 表，再由新版遷移。
  static func migrationTests(_ root: URL) throws {
    for withScore in [false, true] {
      var old = fixture()
      if withScore { _ = old.addScore(try document(hash: "legacy")) }
      try old.timing.setBias(-0.25)
      old.selectedMeasure = 2
      old.regions[0].annotation = HumanAnnotation(chord: "legacy text", rootLocked: true, firstLocked: true)
      var h = HarmonyRegion(measureID: "historic", startBeat: 0, endBeat: 1)
      h.annotation = HumanAnnotation(chordLocked: true, confirmed: true)
      old.archivedRegions = [h]
      let directory = root.appendingPathComponent("legacy-\(UUID().uuidString).basswork")
      try ProjectStore.save(old, to: directory)
      var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
      json["version"] = 2; json.removeValue(forKey: "scoreContexts"); json.removeValue(forKey: "activeContextID"); json.removeValue(forKey: "nextScoreNumber")
      let contextJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old.scoreContexts.first { $0.id == old.activeContextID }!)) as! [String: Any]
      for key in ["score", "estimatedGrid", "timing", "regions", "archivedRegions", "selectedMeasure", "selectedStaff"] {
        json[key] = contextJSON[key]
      }
      try sql(directory, "UPDATE project SET json=? WHERE id=1", text: String(decoding: JSONSerialization.data(withJSONObject: json), as: UTF8.self))
      for region in old.regions + old.archivedRegions {
        let value = String(decoding: try JSONEncoder().encode(region.annotation), as: UTF8.self)
        // Fixture IDs are generated locally and contain no quote; production uses bound parameters.
        try sql(directory, "INSERT OR REPLACE INTO annotations(region_id,json) VALUES('\(region.id)',?)", text: value)
      }
      let loaded = try ProjectStore.load(directory)
      try check(loaded.version == 3 && loaded.score == old.score && loaded.timing == old.timing
                && loaded.regions == old.regions && loaded.archivedRegions == old.archivedRegions
                && loaded.selectedMeasure == 2, "v2 \(withScore ? "score" : "grid") keeps complete active work")
      try check(loaded.scoreContexts.filter { $0.score == nil }.count == 1, "migration provides exactly one grid")
      try check(loaded.availableScoreContexts.allSatisfy { $0.importedAt == nil && $0.displayNumber == 0 }, "v2 score has base name and unknown import time")
      try ProjectStore.save(loaded, to: directory)
      try check(try rowCount(directory, "SELECT count(*) FROM annotations") == 0,
                "v3 save clears obsolete annotation copies after migration backup")
      let backup = directory.appendingPathComponent("project-v2-backup.sqlite")
      try check(FileManager.default.fileExists(atPath: backup.path), "migration keeps v2 database backup")
      let restore = root.appendingPathComponent("backup-read-\(UUID().uuidString).basswork")
      try Files.directory(restore)
      try FileManager.default.copyItem(at: backup, to: restore.appendingPathComponent("project.sqlite"))
      let original = try ProjectStore.load(restore)
      try check(original.regions == old.regions && original.archivedRegions == old.archivedRegions
                && original.timing == old.timing, "v2 backup is readable with all pre-migration human data")
      try check(try ProjectStore.load(directory) == loaded, "migrated scoped annotations survive next save/reopen")
    }
    print("PASS real v2 SQLite migration (single score / grid / locked blanks / history)")
  }
  @MainActor static func storeTests(_ root: URL) async throws {
    let worker = MultiScoreWorker()
    let store = WorkbenchStore(worker: worker)
    store.project = fixture()
    let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050 * 120)!
    buffer.frameLength = buffer.frameCapacity
    buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
    do {
      let file = try AVAudioFile(forWriting: store.folder.appendingPathComponent("synthetic.wav"), settings: format.settings)
      try file.write(from: buffer)
    }
    let input = root.appendingPathComponent("input-\(UUID().uuidString)")
    let inputB = input.appendingPathComponent("b")
    try Files.directory(inputB)
    let aFile = input.appendingPathComponent("same.musicxml")
    let bFile = inputB.appendingPathComponent("same.musicxml")
    try Data(xml().utf8).write(to: aFile)
    try Data(xml(pitch: "G", measures: 12).utf8).write(to: bFile)
    let originalHash = try Files.hash(aFile)
    let gridID = store.project.activeContextID
    await store.importScore(aFile)?.value
    try check(store.error == nil && store.project.availableScoreContexts.count == 1, "actual import adds first score")
    let a = store.project.activeContextID
    var alignment = AlignmentEditorDraft()
    alignment.reset(project: store.project, asset: store.currentAsset)
    alignment.firstBar = "0.4"
    try check(store.applyAlignmentEditor(alignment) && store.canAnalyze, "calibrate and confirm A")
    store.navigate(3, scrollNavigation: false)
    store.annotate { $0.chord = "human A"; $0.chordLocked = true; $0.rootLocked = true }
    let savedA = store.project.scoreContexts.first { $0.id == a }!
    await store.importScore(bFile)?.value
    let b = store.project.activeContextID
    try check(a != b && store.project.availableScoreContexts.count == 2, "actual same-name distinct XML adds B")
    store.navigate(7)
    store.annotate { $0.chord = "human B"; $0.chordLocked = true; $0.firstLocked = true }
    let savedB = store.project.scoreContexts.first { $0.id == b }!
    try check(store.selectScore(id: a) && store.project.scoreContexts.first { $0.id == a } == savedA
              && store.project.selectedMeasure == 3 && abs(store.transport.position - 6.4) < 1e-9,
              "switch A restores selection/calibration and seeks own bar")
    try check(store.firstScoreNote?.name == "E2", "first-note reference follows A")
    let exportA = String(decoding: try ScoreIO.annotatedXML(store.project, folder: store.folder), as: UTF8.self)
    try check(exportA.contains("human A") && !exportA.contains("human B"), "export adds A annotations to complete A XML only")
    try check(store.selectScore(id: b) && store.firstScoreNote?.name == "G2"
              && store.project.scoreContexts.first { $0.id == b } == savedB, "switch B restores its own note reference and work")
    let exportB = String(decoding: try ScoreIO.annotatedXML(store.project, folder: store.folder), as: UTF8.self)
    try check(exportB.contains("human B") && !exportB.contains("human A"), "export follows B reference and annotations")
    await store.importScore(aFile)?.value
    try check(store.project.availableScoreContexts.count == 2 && store.project.activeContextID == a
              && store.project.regions.contains { $0.annotation.chord == "human A" }, "actual duplicate import selects preserved A")
    try check(store.removeScore(id: a) && store.project.activeContextID == b, "active removal selects remaining score")
    store.undo()
    try check(store.project.activeContextID == a && store.project.availableScoreContexts.count == 2,
              "undo removal restores active reference and list")
    store.redo()
    try check(store.project.activeContextID == b && store.project.removedScoreContexts.count == 1,
              "redo removal restores exact removed state")
    try check(store.removeScore(id: b) && store.project.activeContextID == gridID, "remove final score returns grid")
    let directory = store.folder
    store.openProject(directory)
    try check(store.project.removedScoreContexts.count == 2 && store.project.activeContextID == gridID,
              "reopen preserves removed list and active grid")
    try check(store.restoreScore(id: a) && store.selectScore(id: a)
              && store.project.regions.contains { $0.annotation.chord == "human A" }, "restore via Store after reopening")
    try check(try Files.hash(aFile) == originalHash && Files.hash(directory.appendingPathComponent(store.project.score!.originalPath)) == originalHash,
              "import/switch/remove/reopen leave source and project original immutable")
    try check(store.restoreScore(id: b), "restore B")
    let before = store.project
    let invalidFile = input.appendingPathComponent("invalid.musicxml")
    try Data("<not-a-score/>".utf8).write(to: invalidFile)
    await store.importScore(invalidFile)?.value
    try check(!store.busy && store.error != nil && store.project == before, "failed score parse preserves all contexts")
    store.error = nil
    try sql(directory, "CREATE TRIGGER fail_switch BEFORE INSERT ON context_annotations BEGIN SELECT RAISE(ABORT,'switch failure'); END;")
    try check(!store.selectScore(id: b) && store.project == before, "failed switch save leaves active and all work unchanged")
    try check(try ProjectStore.load(directory) == before, "failed switch leaves persistent state unchanged")
    try sql(directory, "DROP TRIGGER fail_switch;")
    store.error = nil
    let analysis = store.analyze(fullSong: true, resume: false)!
    while worker.pending == nil { await Task.yield() }
    try check(!store.selectScore(id: b) && !store.removeScore(id: a) && !store.restoreScore(id: a)
              && store.importScore(bFile) == nil, "analysis blocks all score mutations")
    store.cancel()
    let afterCancel = store.project
    try check(store.selectScore(id: b), "switch after cancellation is allowed")
    worker.finish()
    await analysis.value
    try check(store.project.regions.allSatisfy { $0.evidence == nil }
              && store.project.scoreContexts.first { $0.id == a } == afterCancel.scoreContexts.first { $0.id == a },
              "late cancelled result cannot write to old or newly active score")
    let oldRevisions = store.project.scoreContexts.map { $0.timing.revision }
    store.edit { $0.harmonyAsset = "different-source" }
    try check(zip(oldRevisions, store.project.scoreContexts).allSatisfy { $1.timing.revision > $0 },
              "shared analysis source change invalidates inactive contexts too")
    try check(store.error == nil, "no hidden Store save error")
    print("PASS T10 Store / actual import / selection / undo / reopening / busy / late cancellation / shared sources")
  }
  static func forgetModelTests(_ root: URL) throws {
    var p = fixture()
    let grid = p.activeContextID
    p.regions[0].annotation = HumanAnnotation(chord: "grid remains", rootLocked: true)
    let a = p.addScore(try document(hash: "forget-a"))
    p.regions[0].annotation = HumanAnnotation(chord: "delete A", chordLocked: true)
    let aActiveSnapshot = p
    let b = p.addScore(try document(hash: "forget-b", pitch: "G"))
    p.regions[0].annotation = HumanAnnotation(chord: "keep B", firstLocked: true)
    let bContext = p.scoreContexts.first { $0.id == b }!
    p.forgetScoreContexts([a, grid, "missing"])
    try check(!p.scoreContexts.contains { $0.id == a } && p.scoreContexts.first { $0.id == b } == bContext,
              "forget deletes only targeted score work, never grid or other score")
    var snapshot = aActiveSnapshot
    snapshot.forgetScoreContexts([a])
    try check(snapshot.activeContextID == grid && snapshot.score == nil
              && snapshot.regions[0].annotation.chord == "grid remains", "sanitized old active snapshot returns to its own grid")
    let directory = root.appendingPathComponent("forgotten-\(UUID().uuidString).basswork")
    try ProjectStore.save(p, to: directory)
    try check(try ProjectStore.load(directory) == p, "forgotten contexts remain absent after saving")
  }
  static func rowCount(_ folder: URL, _ statement: String) throws -> Int {
    var db: OpaquePointer?
    guard sqlite3_open(folder.appendingPathComponent("project.sqlite").path, &db) == SQLITE_OK,
      let db else { throw WorkbenchError.message("row count open failed") }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, statement, -1, &stmt, nil) == SQLITE_OK else { throw WorkbenchError.message("row count prepare failed") }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { throw WorkbenchError.message("row count failed") }
    return Int(sqlite3_column_int(stmt, 0))
  }
  @MainActor static func finalizationStoreTests(_ root: URL) async throws {
    let store = WorkbenchStore()
    store.project = fixture()
    let grid = store.project.activeContextID
    let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050 * 120)!
    buffer.frameLength = buffer.frameCapacity
    buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
    do {
      let file = try AVAudioFile(forWriting: store.folder.appendingPathComponent("synthetic.wav"), settings: format.settings)
      try file.write(from: buffer)
    }
    let input = root.appendingPathComponent("confirm-input-\(UUID().uuidString)")
    try Files.directory(input)
    let sourceA = input.appendingPathComponent("A.musicxml")
    let sourceB = input.appendingPathComponent("B.musicxml")
    try Data(xml().utf8).write(to: sourceA)
    try Data(xml(pitch: "G").utf8).write(to: sourceB)
    let sourceHash = try Files.hash(sourceA)
    await store.importScore(sourceA)?.value
    let a = store.project.activeContextID
    let original = store.folder.appendingPathComponent(store.project.score!.originalPath)
    store.annotate { $0.chord = "discarded human"; $0.rootLocked = true; $0.firstLocked = true }
    var timing = store.project.timing
    try timing.setBias(0.8)
    try timing.set(beat: 0, seconds: 1.2)
    _ = store.applyAlignment(timing)
    store.edit {
      var historical = HarmonyRegion(measureID: $0.measures[0].id, startBeat: 0, endBeat: 1)
      historical.annotation.chord = "discarded history"
      $0.archivedRegions = [historical]
      $0.regions[0].evidence = HarmonyEvidence(firstPitch: 40, firstTime: 0, firstScore: 0.9,
        rootMargin: 0.1, candidates: [], chroma: [], warnings: [], arrangementSource: "audio", bassSource: "audio",
        method: "synthetic", timingRevision: $0.timing.revision, createdAt: "synthetic")
    }
    await store.importScore(sourceB)?.value
    let b = store.project.activeContextID
    store.annotate { $0.chord = "keep B"; $0.chordLocked = true }
    let bBefore = store.project.scoreContexts.first { $0.id == b }!
    let untouched = store.project
    try check(!store.finalizeScoreRemovals([b]) && store.project == untouched,
              "finalize refuses a score that has not been marked for removal")
    store.error = nil
    try check(store.removeScore(id: a), "stage removal without discarding work")
    store.renameProject("unrelated history remains")
    store.undo() // preserve both undo and redo stacks while A remains pending.
    let pending = store.project
    try check(pending.scoreContexts.first { $0.id == a }?.regions[0].annotation.chord == "discarded human",
              "marking removal still retains data before confirmation")
    store.busy = true
    try check(!store.finalizeScoreRemovals([a]), "analysis/busy guard covers permanent finalization")
    store.busy = false
    let directory = store.folder
    try sql(directory, "CREATE TRIGGER fail_finalize BEFORE INSERT ON context_annotations BEGIN SELECT RAISE(ABORT,'finalize failure'); END;")
    try sql(directory, "INSERT OR REPLACE INTO annotations(region_id,json) VALUES('legacy-copy',?)",
            text: String(decoding: JSONEncoder().encode(HumanAnnotation(chord: "obsolete copy")), as: UTF8.self))
    try check(!store.finalizeScoreRemovals([a]) && store.project == pending,
              "failed deletion transaction preserves in-memory pending work")
    try check(try ProjectStore.load(directory) == pending, "failed deletion transaction preserves persisted work")
    try check(try rowCount(directory, "SELECT count(*) FROM annotations") == 1,
              "failed save also rolls back obsolete annotation cleanup")
    try sql(directory, "DROP TRIGGER fail_finalize;")
    store.error = nil
    let manifest = directory.appendingPathComponent("manifest.json")
    let savedManifest = try Data(contentsOf: manifest)
    try FileManager.default.removeItem(at: manifest)
    try Files.directory(manifest)
    try check(!store.finalizeScoreRemovals([a]) && store.project == pending,
              "manifest failure does not publish deletion")
    try check(try ProjectStore.load(directory) == pending,
              "manifest failure rolls back database deletion too")
    try FileManager.default.removeItem(at: manifest)
    try savedManifest.write(to: manifest)
    store.error = nil
    try check(store.finalizeScoreRemovals([a]) && !store.project.scoreContexts.contains { $0.id == a },
              "confirmed removal drops whole context")
    try check(store.project.scoreContexts.first { $0.id == b } == bBefore,
              "confirmed removal preserves unrelated score calibration and human data")
    try check(try rowCount(directory, "SELECT count(*) FROM context_annotations WHERE context_id='\(a)'") == 0,
              "confirmed removal deletes scoped annotation rows")
    try check(try rowCount(directory, "SELECT count(*) FROM annotations") == 0,
              "confirmed removal leaves no obsolete legacy annotation copies in current database")
    try check(try Files.hash(original) == sourceHash && Files.hash(sourceA) == sourceHash,
              "project original copy and external source remain available for reimport")
    var traversed = 0
    while store.canUndo {
      store.undo(); traversed += 1
      try check(!store.project.scoreContexts.contains { $0.id == a }, "undo cannot restore discarded score work")
    }
    while store.canRedo {
      store.redo(); traversed += 1
      try check(!store.project.scoreContexts.contains { $0.id == a }, "redo cannot restore discarded score work")
    }
    try check(traversed > 4, "permanent removal sanitizes real multi-step history rather than clearing all history")
    await store.importScore(sourceA)?.value
    let fresh = store.project.activeContextID
    try check(fresh != a && store.project.regions.allSatisfy { $0.annotation == HumanAnnotation() && $0.evidence == nil }
              && store.project.archivedRegions.isEmpty && store.project.timing.anchors.isEmpty && store.project.timing.bias == 0,
              "reimport creates clean calibration, annotations, history and evidence")
    store.followPlayback = true
    store.zoomMeasure()
    store.transport.position = store.project.timing.seconds(at: store.project.measures[2].beat) + 0.01
    try check(store.project.selectedMeasure == 2 && store.playbackMeasure == 2,
              "following playback selects the new score's measure after deletion and reimport")
    _ = store.removeScore(id: fresh)
    _ = store.removeScore(id: b)
    try check(store.project.activeContextID == grid, "staging final score returns to grid")
    store.openProject(directory)
    try check(store.project.removedScoreContexts.count == 2,
              "opening a legacy pending removal does not silently discard work")
    try check(store.finalizeScoreRemovals([fresh, b]) && store.project.scoreContexts.count == 1
              && store.project.activeContextID == grid, "batch confirmation removes all pending scores, retaining grid")
    store.openProject(directory)
    try check(store.project.removedScoreContexts.isEmpty && store.project.availableScoreContexts.isEmpty,
              "confirmed removals remain absent after reopen")
    try check(store.error == nil, "no hidden finalization error")
    print("PASS confirmed removal / manifest and SQLite rollback / sanitized undo and redo / originals / clean reimport / legacy pending")
  }
  static func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
  }
  /// 同程序模型增量，不是完整 app／WebKit 的耗能或記憶體上限保證。
  static func memoryProbe() throws {
    var project = fixture()
    let start = residentBytes()
    var snapshots: [Project] = []
    for i in 1...50 {
      let doc = try autoreleasepool { try document(hash: "memory-\(i)", measures: 300) }
      _ = project.addScore(doc)
      if [1, 10, 50].contains(i) {
        print("MEMORY contexts=\(i), notes=\(i * 300), RSS_delta_MiB=\(Double(residentBytes() - min(start, residentBytes())) / 1048576)")
      }
    }
    let beforeUndo = residentBytes()
    for i in 0..<40 {
      snapshots.append(project)
      project.regions[0].annotation.chord = "edit \(i)"
    }
    print("MEMORY 40_undo_snapshots_RSS_delta_MiB=\(Double(residentBytes() - min(beforeUndo, residentBytes())) / 1048576), notes=15000")
    try check(snapshots.first!.regions[0].annotation.chord.isEmpty && project.regions[0].annotation.chord == "edit 39",
              "copy-on-write snapshots retain independent human edits")
    withExtendedLifetime((project, snapshots)) {}
  }
}

final class MultiScoreWorker: AnalysisRequesting {
  var pending: CheckedContinuation<Data, Error>?
  func request(_ values: [String: Any], cacheRoot: URL, progress: @escaping (Double, String) -> Void) async throws -> Data {
    try await withCheckedThrowingContinuation { pending = $0 }
  }
  // 模擬取消後才到達的回傳；Store 的 job 仍必須擋住它。
  func cancel() {}
  func finish() {
    let continuation = pending; pending = nil
    continuation?.resume(returning: Data("{}".utf8))
  }
}
