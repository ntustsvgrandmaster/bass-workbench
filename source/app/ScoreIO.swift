// 樂譜匯入與匯出。完整 XML 是保存與匯出的依據，ScoreDocument 只是 UI 所需的唯讀索引。

import Foundation

enum ScoreIO {
  /// 先複製來源，再以本機 MuseScore 轉 MSCZ／MSCX，或讀取 MusicXML／MXL；不修改使用者原檔。
  static func importDocument(_ source: URL, project: URL) throws -> ScoreDocument {
    try readDocument(source, project: project, hash: Files.hash(source))
  }

  static func readUpdatedDocument(_ source: URL, project: URL, previousHash: String) throws -> ScoreDocument? {
    let hash = try Files.hash(source)
    guard hash != previousHash else { return nil }
    return try readDocument(source, project: project, hash: hash)
  }

  private static func readDocument(_ source: URL, project: URL, hash: String) throws -> ScoreDocument {
    let dir = project.appendingPathComponent("originals/score-\(hash.prefix(12))")
    try Files.directory(dir)
    let original = dir.appendingPathComponent(source.lastPathComponent)
    let xml = dir.appendingPathComponent("score.musicxml")
    if !FileManager.default.fileExists(atPath: original.path) {
      let snapshot = dir.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: snapshot) }
      try FileManager.default.copyItem(at: source, to: snapshot)
      guard try Files.hash(snapshot) == hash else {
        throw WorkbenchError.message("樂譜仍在寫入，請等外部編輯器儲存完成後再更新。")
      }
      try FileManager.default.moveItem(at: snapshot, to: original)
    }
    let ext = source.pathExtension.lowercased()
    if ["mscz", "mscx"].contains(ext) {
      let executables = [
        "/Applications/MuseScore 4.app/Contents/MacOS/mscore",
        "/Applications/MuseScore Studio 4.app/Contents/MacOS/mscore",
      ]
      guard
        let path = executables.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
      else { throw WorkbenchError.message("讀取 MSCZ 需要本機 MuseScore 4。也可先手動匯出 MusicXML 後匯入。") }
      if !FileManager.default.fileExists(atPath: xml.path) {
        _ = try Files.run(
          URL(fileURLWithPath: path), ["-o", xml.path, original.path], acceptOutput: xml)
      }
    } else if ext == "mxl" {
      let container = try Files.run(
        URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", original.path, "META-INF/container.xml"])
      let document = try XMLDocument(data: container, options: [.nodeLoadExternalEntitiesNever])
      guard
        let entry = try document.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?
          .stringValue, !entry.contains(".."), !entry.hasPrefix("/"), !entry.contains("*")
      else { throw WorkbenchError.message("MXL 內沒有有效的 MusicXML 路徑。") }
      try Files.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", original.path, entry]).write(
        to: xml, options: .atomic)
    } else {
      try Data(contentsOf: original).write(to: xml, options: .atomic)
    }
    return try parse(
      Data(contentsOf: xml), originalName: source.lastPathComponent,
      originalPath: "originals/\(dir.lastPathComponent)/\(original.lastPathComponent)",
      xmlPath: "originals/\(dir.lastPathComponent)/score.musicxml", hash: hash)
  }
  static func text(_ e: XMLElement, _ name: String) -> String? {
    e.elements(forName: name).first?.stringValue
  }
  static func parse(
    _ data: Data, originalName: String = "score.musicxml", originalPath: String = "",
    xmlPath: String = "", hash: String = "fixture"
  ) throws -> ScoreDocument {
    guard data.count < 50_000_000 else { throw WorkbenchError.message("請匯入 50 MB 內的樂譜檔。") }
    // 不載入外部 XML entities，避免樂譜要求讀取其他檔案或遠端資源。
    let doc = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    guard let root = doc.rootElement(), root.name == "score-partwise" else {
      throw WorkbenchError.message("目前支援 score-partwise MusicXML；請從 MuseScore 重新匯出。")
    }
    var names: [String: String] = [:]
    for p in root.elements(forName: "part-list").first?.elements(forName: "score-part") ?? [] {
      names[p.attribute(forName: "id")?.stringValue ?? ""] = text(p, "part-name") ?? "Bass"
    }
    var warnings: [String] = []
    if !(try doc.nodes(
      forXPath: "//repeat | //ending | //segno | //coda | //sound[@dacapo or @dalsegno]")).isEmpty
    {
      warnings.append("含反覆／跳躍記號：目前以書寫次序顯示，請以手動錨點核對。若音源展開反覆，先從 MuseScore 匯出展開版本。")
    }
    let tempo = (try doc.nodes(forXPath: "//sound/@tempo")).first?.stringValue.flatMap(Double.init)
    var staves: [ScoreStaff] = []
    var measures: [ScoreMeasure] = []
    var notes: [ScoreNote] = []
    for part in root.elements(forName: "part") {
      let partID = part.attribute(forName: "id")?.stringValue ?? "P\(staves.count+1)"
      var divisions = 1
      var num = 4
      var den = 4
      var beat = Fraction(0)
      var transpose: [String: Int] = [:]
      var staffNumbers: Set<String> = []
      var tabs: Set<String> = []
      for clef in try part.nodes(forXPath: ".//clef[sign='TAB']") {
        if let c = clef as? XMLElement {
          tabs.insert(c.attribute(forName: "number")?.stringValue ?? "1")
        }
      }
      for (mi, m) in part.elements(forName: "measure").enumerated() {
        let measureID = "\(hash.prefix(12))-m\(mi)"
        let measureNumber = m.attribute(forName: "number")?.stringValue ?? "\(mi+1)"
        // MusicXML 以 backup／forward 描述多聲部；cursor 不能當作每個音符單純累加的時間。
        var cursor = Fraction(0)
        var maximum = Fraction(0)
        var previous = Fraction(0)
        var noteIndex = 0
        for child in m.children ?? [] {
          guard let e = child as? XMLElement else { continue }
          switch e.name {
          case "attributes":
            if let d = text(e, "divisions").flatMap(Int.init), d > 0 { divisions = d }
            if let t = e.elements(forName: "time").first {
              if let value = text(t, "beats") {
                num = value.split(separator: "+").compactMap { Int($0) }.reduce(0, +)
              }
              den = text(t, "beat-type").flatMap(Int.init) ?? den
            }
            for t in e.elements(forName: "transpose") {
              let staff = t.attribute(forName: "number")?.stringValue ?? "all"
              transpose[staff] =
                (text(t, "chromatic").flatMap(Int.init) ?? 0) + 12
                * (text(t, "octave-change").flatMap(Int.init) ?? 0)
            }
          case "backup":
            cursor = cursor - Fraction(text(e, "duration").flatMap(Int.init) ?? 0, divisions)
          case "forward":
            cursor = cursor + Fraction(text(e, "duration").flatMap(Int.init) ?? 0, divisions)
            if cursor.value > maximum.value { maximum = cursor }
          case "note":
            let staff = text(e, "staff") ?? "1"
            let voice = text(e, "voice") ?? "1"
            let staffID = "\(partID):\(staff)"
            staffNumbers.insert(staff)
            let grace = !e.elements(forName: "grace").isEmpty
            let chord = !e.elements(forName: "chord").isEmpty
            let rest = !e.elements(forName: "rest").isEmpty
            // <chord/> 與前一音同時開始，不前進 cursor；裝飾音也不佔一般 duration。
            let duration = Fraction(text(e, "duration").flatMap(Int.init) ?? 0, divisions)
            let onset = chord ? previous : cursor
            var written: Int?
            if let p = e.elements(forName: "pitch").first {
              let values = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
              written =
                12 * ((text(p, "octave").flatMap(Int.init) ?? 3) + 1)
                + (values[text(p, "step") ?? "C"] ?? 0) + (text(p, "alter").flatMap(Int.init) ?? 0)
            }
            let head = text(e, "notehead") ?? ""
            let unpitched =
              !e.elements(forName: "unpitched").isEmpty
              || ["x", "cross", "circle-x"].contains(head)
            let ties = e.elements(forName: "tie").compactMap {
              $0.attribute(forName: "type")?.stringValue
            }
            let technical = e.elements(forName: "notations").first?.elements(forName: "technical")
              .first
            let sounding = written.map { $0 + (transpose[staff] ?? transpose["all"] ?? 0) }
            notes.append(
              ScoreNote(
                id: "\(hash.prefix(12))-\(partID)-\(staff)-\(mi)-\(noteIndex)", partID: partID,
                staffID: staffID, voice: voice, measureID: measureID, onset: beat + onset,
                duration: duration, soundingPitch: unpitched ? nil : sounding,
                writtenPitch: written,
                kind: rest ? "rest" : grace ? "grace" : unpitched ? "ghost" : "note",
                tieStart: ties.contains("start"), tieStop: ties.contains("stop"),
                stringNumber: technical.flatMap { text($0, "string").flatMap(Int.init) },
                fret: technical.flatMap { text($0, "fret").flatMap(Int.init) }))
            noteIndex += 1
            previous = onset
            if !chord && !grace { cursor = cursor + duration }
            if cursor.value > maximum.value { maximum = cursor }
          default: break
          }
        }
        guard num > 0, den > 0 else { throw WorkbenchError.message("樂譜含無效拍號。") }
        let nominal = Fraction(num * 4, den)
        let implicit = m.attribute(forName: "implicit")?.stringValue == "yes"
        let pickup = mi == 0 && maximum.value > 0 && maximum.value < nominal.value - 0.001
        // 弱起／implicit 小節使用實際內容長度；其他空小節仍保留拍號規定的時長。
        let length =
          (implicit || pickup) && maximum.value > 0
          ? maximum : (maximum.value > nominal.value ? maximum : nominal)
        if part === root.elements(forName: "part").first {
          measures.append(
            ScoreMeasure(
              id: measureID, index: mi, number: measureNumber, onset: beat, duration: length,
              numerator: num, denominator: den))
        }
        beat = beat + length
      }
      for number in staffNumbers.sorted() {
        staves.append(
          ScoreStaff(
            id: "\(partID):\(number)", partID: partID, number: number,
            name: "\(names[partID] ?? partID) · \(tabs.contains(number) ? "TAB":"五線譜")",
            isTAB: tabs.contains(number)))
      }
    }
    guard !measures.isEmpty else { throw WorkbenchError.message("樂譜中沒有可讀取的小節。") }
    // Different staves remain separate, even if they mostly duplicate the same performance.
    if staves.count > 1 { warnings.append("已保留所有譜表；比對與原譜首音只使用目前選取的譜表，不將 TAB 與五線譜音符相加。") }
    return ScoreDocument(
      revision: hash, originalPath: originalPath, xmlPath: xmlPath, sourceHash: hash,
      originalName: originalName, staves: staves, measures: measures, notes: notes, bpm: tempo,
      warnings: warnings)
  }
  /// 重新讀取完整原 XML，只加入已鎖定且非空白的和弦文字；未知記號與 TAB 不透過索引重建。
  static func annotatedXML(_ project: Project, folder: URL) throws -> Data {
    guard let score = project.score else { throw WorkbenchError.message("請先匯入樂譜。") }
    let original = try Data(contentsOf: folder.appendingPathComponent(score.xmlPath))
    let doc = try XMLDocument(
      data: original, options: [.nodeLoadExternalEntitiesNever, .nodePreserveAll])
    guard
      let part = doc.rootElement()?.elements(forName: "part").first(where: {
        $0.attribute(forName: "id")?.stringValue
          == score.staves.first(where: { $0.id == project.selectedStaff })?.partID
      }) ?? doc.rootElement()?.elements(forName: "part").first
    else { return original }
    var divisions = 1
    for (i, measure) in part.elements(forName: "measure").enumerated() {
      if let d = measure.elements(forName: "attributes").first.flatMap({ text($0, "divisions") })
        .flatMap(Int.init)
      {
        divisions = d
      }
      guard i < project.measures.count else { continue }
      let m = project.measures[i]
      for region in project.regions.filter({
        $0.measureID == m.id && $0.annotation.chordLocked && !$0.annotation.chord.isEmpty
      }) {
        let direction = XMLElement(name: "direction")
        direction.addAttribute(
          XMLNode.attribute(withName: "placement", stringValue: "above") as! XMLNode)
        let type = XMLElement(name: "direction-type")
        let words = XMLElement(name: "words", stringValue: region.annotation.chord)
        type.addChild(words)
        direction.addChild(type)
        // Region 使用四分音符拍；MusicXML 的 offset 要轉回當下 divisions 單位。
        direction.addChild(
          XMLElement(
            name: "offset",
            stringValue: String(Int(((region.startBeat - m.beat) * Double(divisions)).rounded()))))
        if let staff = score.staves.first(where: { $0.id == project.selectedStaff }),
          score.staves.filter({ $0.partID == staff.partID }).count > 1
        {
          direction.addChild(XMLElement(name: "staff", stringValue: staff.number))
        }
        let insertion =
          measure.children?.firstIndex(where: { $0.name != "attributes" && $0.name != "print" })
          ?? measure.childCount
        measure.insertChild(direction, at: insertion)
      }
    }
    return doc.xmlData(options: .nodePrettyPrint)
  }
}
