// SQLite 專案保存。自動分析可重建，人工標註不可因重算而遺失，所以使用獨立資料表。

import Foundation
import SQLite3

enum ProjectStore {
  // SQLITE_TRANSIENT：SQLite 複製綁定字串，避免 Swift 暫時字串結束後留下失效指標。
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  private static func open(_ folder: URL) throws -> OpaquePointer {
    try Files.directory(folder)
    var db: OpaquePointer?
    guard sqlite3_open(folder.appendingPathComponent("project.sqlite").path, &db) == SQLITE_OK,
      let db
    else { throw WorkbenchError.message("無法開啟專案資料庫。") }
    sqlite3_busy_timeout(db, 3000)
    do {
      try sql(
        db,
        "PRAGMA journal_mode=DELETE; CREATE TABLE IF NOT EXISTS project(id INTEGER PRIMARY KEY CHECK(id=1),json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS annotations(region_id TEXT PRIMARY KEY,json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS context_annotations(context_id TEXT NOT NULL,region_id TEXT NOT NULL,json TEXT NOT NULL,PRIMARY KEY(context_id,region_id)); CREATE TABLE IF NOT EXISTS analysis_runs(id TEXT PRIMARY KEY,json TEXT NOT NULL);"
      )
    } catch {
      sqlite3_close(db)
      throw error
    }
    return db
  }
  private static func sql(_ db: OpaquePointer, _ text: String) throws {
    guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else {
      throw WorkbenchError.message("專案資料庫錯誤：\(String(cString:sqlite3_errmsg(db)))")
    }
  }
  private static func write(_ db: OpaquePointer, _ statement: String, _ values: [String]) throws {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, statement, -1, &stmt, nil) == SQLITE_OK else {
      throw WorkbenchError.message("無法準備專案寫入。")
    }
    defer { sqlite3_finalize(stmt) }
    for (i, s) in values.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), s, -1, transient) }
    guard sqlite3_step(stmt) == SQLITE_DONE else { throw WorkbenchError.message("無法寫入專案。") }
  }
  /// 首次升級保存前，透過 SQLite backup API 留下可回讀的 v2 資料庫，
  /// 不複製正在寫入的資料庫檔，也不覆蓋先前的備份。
  private static func preserveLegacyDatabase(_ db: OpaquePointer, in folder: URL) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT json FROM project WHERE id=1", -1, &statement, nil) == SQLITE_OK else {
      throw WorkbenchError.message("無法檢查舊版專案備份。")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0),
      let json = try JSONSerialization.jsonObject(with: Data(String(cString: bytes).utf8)) as? [String: Any],
      json["version"] as? Int == 2 else { return }
    let target = folder.appendingPathComponent("project-v2-backup.sqlite")
    guard !FileManager.default.fileExists(atPath: target.path) else { return }
    var destination: OpaquePointer?
    guard sqlite3_open(target.path, &destination) == SQLITE_OK, let destination else {
      if let destination { sqlite3_close(destination) }
      throw WorkbenchError.message("無法建立舊版專案備份，未升級保存。")
    }
    var complete = false
    if let backup = sqlite3_backup_init(destination, "main", db, "main") {
      let step = sqlite3_backup_step(backup, -1)
      let finish = sqlite3_backup_finish(backup)
      complete = step == SQLITE_DONE && finish == SQLITE_OK
    }
    sqlite3_close(destination)
    guard complete else {
      try? FileManager.default.removeItem(at: target)
      throw WorkbenchError.message("舊版專案備份未完成，未升級保存。")
    }
  }
  static func save(_ project: Project, to folder: URL, analysisRuns: [Data] = []) throws {
    let db = try open(folder)
    defer { sqlite3_close(db) }
    try preserveLegacyDatabase(db, in: folder)
    let encoder = JSONEncoder()
    // metadata 先移除人工欄位；context_annotations 才是人工值與鎖定的權威來源。
    var metadata = project
    for context in metadata.scoreContexts.indices {
      for i in metadata.scoreContexts[context].regions.indices {
        metadata.scoreContexts[context].regions[i].annotation = HumanAnnotation()
      }
      for i in metadata.scoreContexts[context].archivedRegions.indices {
        metadata.scoreContexts[context].archivedRegions[i].annotation = HumanAnnotation()
      }
    }
    let manifest: [String: String] = [
      "format": "BassWorkbench", "version": "3", "id": project.id, "title": project.title,
      "database": "project.sqlite", "network": "none",
    ]
    let manifestURL = folder.appendingPathComponent("manifest.json")
    let previousManifest = try? Data(contentsOf: manifestURL)
    var manifestChanged = false
    // 同一交易更新專案與標註，避免關閉／錯誤時只存到一半。
    try sql(db, "BEGIN IMMEDIATE;")
    do {
      try write(
        db, "INSERT OR REPLACE INTO project(id,json) VALUES(1,?)",
        [String(decoding: try encoder.encode(metadata), as: UTF8.self)])
      try sql(db, "DELETE FROM context_annotations;")
      // v2 已先備份；v3 不再讀舊表，避免移除後仍在目前資料庫留下舊人工值副本。
      try sql(db, "DELETE FROM annotations;")
      for context in project.scoreContexts {
        for region in context.regions + context.archivedRegions {
          try write(
            db, "INSERT INTO context_annotations(context_id,region_id,json) VALUES(?,?,?)",
            [context.id, region.id, String(decoding: try encoder.encode(region.annotation), as: UTF8.self)])
        }
      }
      for run in analysisRuns { try insertRun(run, db: db) }
      // manifest 寫入也在 COMMIT 前；其失敗不能讓永久移除只完成資料庫那一半。
      try Files.writeJSON(manifest, to: manifestURL)
      manifestChanged = true
      try sql(db, "COMMIT;")
    } catch {
      try? sql(db, "ROLLBACK;")
      if manifestChanged {
        if let previousManifest { try? previousManifest.write(to: manifestURL, options: .atomic) }
        else { try? FileManager.default.removeItem(at: manifestURL) }
      }
      throw error
    }
  }
  static func load(_ folder: URL) throws -> Project {
    guard
      FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.sqlite").path)
    else { throw WorkbenchError.message("這個資料夾不是 Bass Workbench 專案。") }
    let db = try open(folder)
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT json FROM project WHERE id=1", -1, &stmt, nil) == SQLITE_OK
    else { throw WorkbenchError.message("專案資料庫無法讀取。") }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else {
      throw WorkbenchError.message("專案沒有有效資料。")
    }
    let data = Data(String(cString: text).utf8)
    let legacy = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? Int == 2
    var project = try JSONDecoder().decode(Project.self, from: data)
    // 讀回資料後先檢查格式、有限數值與相對路徑，避免錯誤專案導致畫面或檔案讀取異常。
    for context in project.scoreContexts {
      let timing = context.timing
      guard timing.bpm.isFinite, (20...400).contains(timing.bpm), timing.bias.isFinite,
        abs(timing.bias) <= 3600, context.estimatedGrid?.isValid != false,
        context.score?.measures.isEmpty != true else {
        throw WorkbenchError.message("專案樂譜或校準內容無效。")
      }
      var checked = TimingMap(bpm: timing.bpm, biasSeconds: timing.biasSeconds)
      for anchor in timing.anchors {
        try checked.set(beat: anchor.beat, seconds: timing.seconds(of: anchor))
      }
      if let score = context.score {
        for path in [score.originalPath, score.xmlPath] {
          guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw WorkbenchError.message("專案樂譜路徑無效。")
          }
        }
      }
      if let path = context.editingScorePath {
        let components = path.components(separatedBy: "/")
        guard components.count == 2, components[0] == "exports",
          !["", ".", ".."].contains(components[1]) else {
          throw WorkbenchError.message("專案的樂譜編輯副本路徑無效。")
        }
      }
    }
    guard !project.measures.isEmpty else { throw WorkbenchError.message("專案時間格線無效。") }
    guard project.minMIDI >= 12, project.maxMIDI <= 96, project.minMIDI < project.maxMIDI,
      [12, 24, 36].contains(project.binsPerOctave), project.a.isFinite, project.b.isFinite,
      project.a >= 0, project.b > project.a, project.rate.isFinite, project.rate >= 0.25,
      project.rate <= 2
    else { throw WorkbenchError.message("專案播放或音域設定無效。") }
    for asset in project.assets {
      guard !asset.originalPath.hasPrefix("/"),
        !asset.originalPath.split(separator: "/").contains(".."), !asset.pcmPath.hasPrefix("/"),
        !asset.pcmPath.split(separator: "/").contains(".."), asset.duration.isFinite,
        asset.offset.isFinite
      else { throw WorkbenchError.message("專案資產路徑無效。") }
    }
    var annotations: OpaquePointer?
    guard
      sqlite3_prepare_v2(db, legacy ? "SELECT '',region_id,json FROM annotations"
                        : "SELECT context_id,region_id,json FROM context_annotations", -1, &annotations, nil)
        == SQLITE_OK
    else { throw WorkbenchError.message("人工標註無法讀取。") }
    defer { sqlite3_finalize(annotations) }
    var values: [String: [String: HumanAnnotation]] = [:]
    var result = sqlite3_step(annotations)
    while result == SQLITE_ROW {
      if let context = sqlite3_column_text(annotations, 0), let a = sqlite3_column_text(annotations, 1),
        let b = sqlite3_column_text(annotations, 2) {
        values[String(cString: context), default: [:]][String(cString: a)] = try JSONDecoder().decode(
          HumanAnnotation.self, from: Data(String(cString: b).utf8))
      }
      result = sqlite3_step(annotations)
    }
    guard result == SQLITE_DONE else { throw WorkbenchError.message("人工標註未能完整讀取。") }
    // 將獨立保存的人工值覆蓋回模型；不可用新的 Evidence 取代它們。
    for context in project.scoreContexts.indices {
      let saved = values[legacy ? "" : project.scoreContexts[context].id] ?? [:]
      for i in project.scoreContexts[context].regions.indices {
        guard legacy || saved[project.scoreContexts[context].regions[i].id] != nil else {
          throw WorkbenchError.message("專案缺少部分樂譜的人工資料，已停止讀取以免覆寫。")
        }
        project.scoreContexts[context].regions[i].annotation =
          saved[project.scoreContexts[context].regions[i].id] ?? HumanAnnotation()
      }
      for i in project.scoreContexts[context].archivedRegions.indices {
        guard legacy || saved[project.scoreContexts[context].archivedRegions[i].id] != nil else {
          throw WorkbenchError.message("專案缺少部分歷史人工資料，已停止讀取以免覆寫。")
        }
        project.scoreContexts[context].archivedRegions[i].annotation =
          saved[project.scoreContexts[context].archivedRegions[i].id] ?? HumanAnnotation()
      }
    }
    return project
  }
  /// 保存當次分析證據與方法，供追溯；不寫入 annotations 表。
  static func appendRun(_ data: Data, to folder: URL) throws {
    let db = try open(folder)
    defer { sqlite3_close(db) }
    try insertRun(data, db: db)
  }
  private static func insertRun(_ data: Data, db: OpaquePointer) throws {
    try write(
      db, "INSERT INTO analysis_runs(id,json) VALUES(?,?)",
      [UUID().uuidString, String(decoding: data, as: UTF8.self)])
  }
}
