import AppKit
import SwiftUI
import WebKit

/// 實際載入本機 OSMD，以合成 MusicXML 驗證可用寬度、弱起索引與原生點擊橋接。
@main struct ScorePreviewTests {
  static var assertions = 0
  static func check(_ value: Bool, _ message: String) throws {
    guard value else { throw WorkbenchError.message(message) }
    assertions += 1
  }
  @MainActor static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
  @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  @MainActor static func js(_ script: String, web: WKWebView) throws -> Any? {
    var result: Result<Any?, Error>?
    web.evaluateJavaScript(script) { value, error in result = error.map(Result.failure) ?? .success(value) }
    let deadline = Date().addingTimeInterval(10)
    while result == nil && Date() < deadline { settle() }
    guard let result else { throw WorkbenchError.message("Preview script timeout") }
    return try result.get()
  }
  @MainActor static func wait(_ script: String, web: WKWebView) throws {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      if (try? js(script, web: web)) as? Bool == true { return }
      settle()
    }
    throw WorkbenchError.message("Preview did not finish: \(try js("document.getElementById('message').textContent", web: web) ?? "")")
  }
  @MainActor static func state(_ web: WKWebView) throws -> [String: Any] {
    guard let value = try js("({...previewState})", web: web) as? [String: Any] else {
      throw WorkbenchError.message("Missing preview state")
    }
    print("Preview: \(value)")
    return value
  }
  @MainActor static func capture(_ web: WKWebView, _ url: URL) throws {
    print("Capture geometry: \(try js("JSON.stringify({scrollX:window.scrollX,bodyWidth:document.body.scrollWidth,paperWidth:document.getElementById('paper').clientWidth,paperLeft:document.getElementById('paper').getBoundingClientRect().left,scroll:document.getElementById('paper').scrollLeft})", web: web) ?? "")")
    try check(try js("window.scrollX===0 && document.body.scrollWidth<=window.innerWidth+1", web: web) as? Bool == true, "Only paper scrolls horizontally; status stays visible")
    var image: NSImage?, finished = false
    web.takeSnapshot(with: nil) { result, _ in image = result; finished = true }
    let deadline = Date().addingTimeInterval(10)
    while !finished && Date() < deadline { settle() }
    guard let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
      let png = bitmap.representation(using: .png, properties: [:]) else {
      throw WorkbenchError.message("Missing preview snapshot")
    }
    try png.write(to: url)
  }
  static func xml(bars: Int = 60, notes: Int = 1, pickup: Bool = false, tab: Bool = false) -> String {
    let measures = (0..<bars).map { i in
      let count = pickup && i == 0 ? 1 : notes
      let duration = pickup && i == 0 ? 4 : 16 / notes
      let music = (0..<count).map { n in
        "<note><pitch><step>\(n % 2 == 0 ? "E" : "G")</step><octave>2</octave></pitch><duration>\(duration)</duration><type>\(notes == 1 && !(pickup && i == 0) ? "whole" : notes == 16 ? "16th" : "quarter")</type><staff>1</staff></note>"
      }.joined()
      let attrs = i == 0 ? "<attributes><divisions>4</divisions><time><beats>4</beats><beat-type>4</beat-type></time>\(tab ? "<staves>2</staves>" : "")<clef number='1'><sign>F</sign><line>4</line></clef>\(tab ? "<clef number='2'><sign>TAB</sign><line>5</line></clef>" : "")</attributes>" : ""
      let tabMusic = tab ? "<backup><duration>\(count * duration)</duration></backup>" + music.replacingOccurrences(of: "<staff>1</staff>", with: "<staff>2</staff><notations><technical><string>4</string><fret>0</fret></technical></notations>") : ""
      return "<measure number='\(pickup ? i : i + 1)'\(pickup && i == 0 ? " implicit='yes'" : "")>\(attrs)<print new-system='yes'/>\(music)\(tabMusic)</measure>"
    }.joined()
    return "<?xml version='1.0' encoding='UTF-8'?>\n<score-partwise version='4.0'><part-list><score-part id='P1'><part-name>Bass</part-name></score-part></part-list><part id='P1'>\(measures)</part></score-partwise>"
  }
  @MainActor static func main() throws {
    setbuf(stdout, nil)
    guard let root = ProcessInfo.processInfo.environment["BASS_DATA_ROOT"] else { fatalError("Specify test root") }
    let folder = URL(fileURLWithPath: root)
    try Files.directory(folder)
    func rest(_ type: String, duration: Int, staff: Int, voice: Int = 1,
              attributes: String = "", dotted: Bool = false) -> String {
      "<note\(attributes)><rest/><duration>\(duration)</duration><voice>\(voice)</voice><type>\(type)</type>\(dotted ? "<dot/>" : "")<staff>\(staff)</staff></note>"
    }
    func onBothStaves(_ music: (Int) -> String) -> String {
      music(1) + "<backup><duration>16</duration></backup>" + music(2)
    }
    let mixed = onBothStaves { staff in
      rest("half", duration: 12, staff: staff, dotted: true)
        + rest("eighth", duration: 2, staff: staff)
        + rest("eighth", duration: 2, staff: staff, attributes: " print-object='no'")
    }
    let whole = onBothStaves { rest("whole", duration: 16, staff: $0) }
    let base = xml(bars: 4, tab: true)
    let barPrefix = base.components(separatedBy: "<print new-system='yes'/>")[0]
    let restScore = barPrefix + mixed + "</measure>"
      + "<measure number='2'><attributes><measure-style><multiple-rest>2</multiple-rest></measure-style></attributes>"
      + whole + "</measure><measure number='3'>" + whole + "</measure>"
      + "<measure number='4'>" + onBothStaves { staff in
        rest("whole", duration: 16, staff: staff)
          + "<backup><duration>16</duration></backup>"
          + rest("half", duration: 8, staff: staff, voice: 2)
          + rest("half", duration: 8, staff: staff, voice: 2)
      } + "</measure></part></score-partwise>"
    let fixtures = [("sparse", xml()), ("dense", xml(notes: 16)), ("pickup-tab", xml(pickup: true, tab: true)),
                    ("rests", restScore), ("headerless", xml(bars: 8).components(separatedBy: "\n").dropFirst().joined(separator: "\n"))]
    var docs: [String: ScoreDocument] = [:], originals: [URL: Data] = [:]
    for (name, text) in fixtures {
      let file = folder.appendingPathComponent(name + ".musicxml")
      let data = Data(text.utf8)
      try data.write(to: file)
      originals[file] = data
      docs[name] = try ScoreIO.parse(data, xmlPath: file.lastPathComponent, hash: Files.hash(file))
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.finishLaunching()
    let refresh = UUID()
    var clicked: Int?
    func view(_ name: String?, _ selected: Int) -> ScoreView {
      ScoreView(document: name.flatMap { docs[$0] }, folder: folder, selected: selected, refresh: refresh,
        onMeasure: { clicked = $0 }, onMeasureLoop: { _, _ in })
    }
    let host = NSHostingView(rootView: view("sparse", 10))
    let window = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 700, height: 260), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    host.layoutSubtreeIfNeeded()
    let webDeadline = Date().addingTimeInterval(10)
    while descendants(host).compactMap({ $0 as? WKWebView }).first == nil && Date() < webDeadline { settle() }
    guard let web = descendants(host).compactMap({ $0 as? WKWebView }).first else { throw WorkbenchError.message("Missing web") }
    func loaded(_ name: String, _ index: Int, width: Int = 700) throws {
      let revision = docs[name]!.revision
      try wait("typeof previewState!=='undefined' && !loading && previewState?.revision==='\(revision)' && previewState.current===\(index) && previewState.width===\(width - 12)", web: web)
    }
    func fit(_ label: String, allowOverflow: Bool = false) throws -> [String: Any] {
      let s = try state(web)
      try check(try js("document.getElementById('message').hidden && document.getElementById('paper').getBoundingClientRect().top===0", web: web) as? Bool == true, label + ": no hint text or empty hint row")
      let first = s["first"] as! Int, last = s["last"] as! Int, current = s["current"] as! Int
      try check(first == max(0, current - 1) && last >= current, label + ": previous/current included")
      try check(try js("osmd.Zoom===1 && osmd.EngravingRules.RenderSingleHorizontalStaffline", web: web) as? Bool == true, label + ": normal scale and single system")
      try check(try js("[...document.querySelectorAll('#hotspots button.selected')].every(b=>b.getAttribute('aria-label')==='第 '+(selected+1)+' 小節') && document.querySelectorAll('#hotspots button.selected').length>0", web: web) as? Bool == true, label + ": current highlight matches index")
      if !allowOverflow {
        try check(s["overflow"] as? Bool == false, label + ": complete bars fit")
        try check(try js("document.getElementById('paper').scrollWidth<=document.getElementById('paper').clientWidth+1", web: web) as? Bool == true, label + ": no horizontal clipping")
        if last + 1 < docs["sparse"]!.measures.count {
          // 用同一引擎實際試排下一個完整小節，再恢復畫面，驗證沒有浪費可放下的小節。
          let maximal = try js("(()=>{const s=previewState;if(s.last+1>=measureCount)return true;renderRange(s.first,s.last+1);const fits=rightEdge(s.last+1)<=s.width-1;renderRange(s.first,s.last);buildHotspots();return !fits})()", web: web) as? Bool == true
          try check(maximal, label + ": next complete bar does not fit")
        }
      }
      return s
    }
    try loaded("sparse", 10)
    let medium = try fit("700px sparse")
    try check(try js("""
      (() => {
        const button = document.querySelector('#hotspots button.selected');
        const enabled = button.getAttribute('aria-current') === 'true' &&
          getComputedStyle(button).cursor === 'pointer';
        setScoreInteractionEnabled(false);
        const disabled = button.disabled && getComputedStyle(button).cursor === 'default';
        setScoreInteractionEnabled(true);
        return enabled && disabled;
      })()
      """, web: web) as? Bool == true, "Score exposes current and disabled interaction states")
    try check(try js("""
      (() => {
        const button = document.querySelector('#hotspots button.selected');
        button.focus();
        if (document.activeElement !== button) return false;
        const measure = button.dataset.measure;
        buildHotspots();
        return document.activeElement !== button && document.activeElement.dataset.measure === measure;
      })()
      """, web: web) as? Bool == true, "Rebuilding score targets preserves focus")
    try check((medium["last"] as! Int) - (medium["first"] as! Int) + 1 > 3, "Sparse preview uses space beyond old three bars")
    try check(try js("new Set(osmd.GraphicSheet.MeasureList.slice(previewState.first,previewState.last+1).flat().map(m=>m.ParentMusicSystem.Id)).size===1", web: web) as? Bool == true, "Original XML system breaks ignored only in preview")
    try capture(web, folder.appendingPathComponent("sparse-700.png"))
    let last = medium["last"] as! Int
    _ = try js("void document.querySelector('#hotspots button[aria-label=\"第 \(last+1) 小節\"]').click()", web: web)
    settle()
    try check(clicked == last, "New future bars send correct native source index")
    let count = medium["layoutCount"] as! Int
    _ = try js("renderPreview();renderPreview();void 0", web: web)
    try check(try js("previewState.layoutCount", web: web) as? Int == count, "Unchanged size/selection does not re-layout")
    window.setContentSize(NSSize(width: 420, height: 260))
    try loaded("sparse", 10, width: 420)
    let narrow = try fit("420px sparse")
    try check((narrow["last"] as! Int) < last, "Narrow width shows fewer bars")
    try capture(web, folder.appendingPathComponent("sparse-420.png"))
    window.setContentSize(NSSize(width: 1000, height: 260))
    try loaded("sparse", 10, width: 1000)
    let wide = try fit("1000px sparse")
    try check((wide["last"] as! Int) > last, "Wide width shows more bars")
    for index in [0, 1, 59] {
      host.rootView = view("sparse", index)
      try loaded("sparse", index, width: 1000)
      let s = try fit("boundary \(index)")
      try check((s["last"] as! Int) < 60, "No bars invented after song end")
    }
    host.rootView = view("dense", 10)
    try loaded("dense", 10, width: 1000)
    let dense = try fit("dense", allowOverflow: true)
    try check((dense["last"] as! Int) < (wide["last"] as! Int), "Dense bars use more width")
    window.setContentSize(NSSize(width: 420, height: 260))
    try loaded("dense", 10, width: 420)
    let overflow = try fit("dense overflow", allowOverflow: true)
    try check(overflow["overflow"] as? Bool == true && overflow["last"] as? Int == 10, "Dense required pair preserves scale and permits horizontal scroll")
    try check(try js("document.getElementById('paper').scrollLeft>0", web: web) as? Bool == true, "Dense pair initially reveals current bar")
    try capture(web, folder.appendingPathComponent("dense-420.png"))
    window.setContentSize(NSSize(width: 700, height: 260))
    host.rootView = view("pickup-tab", 1)
    try loaded("pickup-tab", 1)
    _ = try fit("pickup TAB")
    try check(try js("previewState.first===0 && document.querySelectorAll('#hotspots button.selected').length===2 && document.querySelectorAll('#hotspots button').length===(previewState.last-previewState.first+1)*2", web: web) as? Bool == true, "Pickup source indices and both staff hit regions remain aligned")
    try capture(web, folder.appendingPathComponent("pickup-tab-700.png"))
    clicked = nil
    _ = try js("tell({type:'measure',index:2,revision:'stale'});tell({type:'measure',index:999,revision:xmlRevision});void 0", web: web)
    settle()
    try check(clicked == nil, "Stale document and invalid indices rejected by native bridge")
    _ = try js("void document.querySelector('#hotspots button.selected').click()", web: web)
    settle()
    try check(clicked == 1, "Pickup displayed bar maps to correct native index")
    host.rootView = view("dense", 5)
    settle()
    host.rootView = view("sparse", 20)
    settle()
    host.rootView = view("headerless", 3)
    try loaded("headerless", 3)
    _ = try fit("headerless XML")
    host.rootView = view("rests", 1)
    try loaded("rests", 1)
    try check(try js("document.querySelectorAll('.vf-tab-rest').length===7 && [...document.querySelectorAll('.vf-tab-rest')].every(g=>g.querySelector('path') && g.getBBox().width>0)", web: web) as? Bool == true,
              "Explicit TAB rests draw vector glyphs at their ghost-note positions")
    try check(try js("previewState.last>=2 && document.querySelectorAll('#hotspots button.selected').length===2", web: web) as? Bool == true,
              "Grouped rests preserve separate measure hit regions")
    try check(try js("""
      (()=>{const bars=osmd.GraphicSheet.MeasureList.slice(previewState.first,previewState.last+1);
      const tab=bars.flat().find(m=>m?.isTabMeasure), top=tab.stave.getYForLine(0);
      const bottom=tab.stave.getYForLine(tab.ParentStaff.StafflineCount-1);
      return [...document.querySelectorAll('.vf-tab-rest')].every(g=>{
        const b=g.getBBox();return b.y>=top && b.y+b.height<=bottom;
      });})()
      """, web: web) as? Bool == true, "TAB rest glyphs stay between the stave lines")
    try capture(web, folder.appendingPathComponent("rests-700.png"))
    window.setContentSize(NSSize(width: 420, height: 260))
    host.rootView = view("rests", 3)
    try loaded("rests", 3, width: 420)
    try check(try js("previewState.first===2 && previewState.last===3 && document.querySelectorAll('.vf-tab-rest').length===4", web: web) as? Bool == true,
              "Tail cropping keeps only rests from the displayed bars")
    host.rootView = view(nil, 0)
    try wait("!loading && osmd===null && previewState===null && document.querySelectorAll('#score svg,#hotspots button').length===0", web: web)
    try check(true, "No-score clears rendering and pending prior document")
    try check(try js("!document.getElementById('message').hidden && document.getElementById('message').textContent.startsWith('匯入')", web: web) as? Bool == true, "Empty-score import guidance is still visible")
    _ = try js("void loadScore({xml:'<broken',revision:'bad-xml',selected:0,measureCount:1})", web: web)
    try wait("!loading && !document.getElementById('message').hidden && document.getElementById('message').textContent.startsWith('樂譜顯示失敗')", web: web)
    try check(true, "Malformed score still shows an error rather than an empty preview")
    for (url, data) in originals { try check(try Data(contentsOf: url) == data, "Preview never rewrites \(url.lastPathComponent)") }
    print("PASS \(assertions) native score preview assertions")
  }
}
