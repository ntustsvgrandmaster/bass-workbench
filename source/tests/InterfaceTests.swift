import AVFoundation
import AppKit
import ApplicationServices
import Combine
import SwiftUI
import WebKit

/// 只操作本測試程序自己的 SwiftUI 視窗，不使用系統層滑鼠／鍵盤注入。
@main struct InterfaceTests {
  static var assertions = 0
  @MainActor static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    assertions += 1
    if try !value() { throw WorkbenchError.message("TEST FAILED: \(message)") }
  }
  @MainActor static func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
  }
  @MainActor static func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants($0) }
  }
  /// SwiftUI 在首次收到 AX client 請求前可能沒有建立虛擬節點；只要求本程序的視窗。
  @MainActor static func prepareAccessibility() {
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      let target = AXUIElementCreateApplication(getpid())
      AXUIElementSetMessagingTimeout(target, 2)
      var windows: CFTypeRef?
      _ = AXUIElementCopyAttributeValue(target, kAXWindowsAttribute as CFString, &windows)
      finished.signal()
    }
    let deadline = Date().addingTimeInterval(5)
    while finished.wait(timeout: .now()) != .success && Date() < deadline { settle() }
  }
  @MainActor static func axRead(_ element: NSObject, _ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    if element.responds(to: selector), let value = element.perform(selector)?.takeUnretainedValue() { return value }
    // SwiftUI 的虛擬節點也可能只提供傳統 AX attribute 介面。
    let attributes = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier",
                      "accessibilityLabel": "AXDescription", "accessibilityValue": "AXValue", "accessibilityHelp": "AXHelp"]
    let legacy = NSSelectorFromString("accessibilityAttributeValue:")
    guard let attribute = attributes[name], element.responds(to: legacy) else { return nil }
    return element.perform(legacy, with: attribute)?.takeUnretainedValue()
  }
  @MainActor static func accessibilityElements(_ root: Any) -> [NSObject] {
    var visited = Set<ObjectIdentifier>()
    func visit(_ value: Any) -> [NSObject] {
      guard let element = value as? NSObject,
        visited.insert(ObjectIdentifier(element)).inserted else { return [] }
      let children = axRead(element, "accessibilityChildren") as? [Any] ?? []
      let nativeChildren = (element as? NSView)?.subviews ?? []
      return [element] + (children + nativeChildren).flatMap(visit)
    }
    return visit(root)
  }
  @MainActor static func accessibilityFrame(_ id: String, in host: NSView) -> NSRect? {
    let selector = NSSelectorFromString("accessibilityFrame")
    guard let element = accessibilityElements(host).first(where: {
      axRead($0, "accessibilityIdentifier") as? String == id && $0.responds(to: selector)
    }) else { return nil }
    typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
    return unsafeBitCast(element.method(for: selector), to: Frame.self)(element, selector)
  }
  @MainActor static func press(_ id: String, matchingLabel: Bool = false, in host: NSObject) throws {
    let elements = accessibilityElements(host)
    let targets = elements.filter {
      axRead($0, matchingLabel ? "accessibilityLabel" : "accessibilityIdentifier") as? String == id
    }
    let selector = NSSelectorFromString("accessibilityPerformPress")
    typealias Action = @convention(c) (AnyObject, Selector) -> Bool
    for element in targets {
      for candidate in accessibilityElements(element) {
        if candidate.responds(to: selector) {
          let action = unsafeBitCast(candidate.method(for: selector), to: Action.self)
          if action(candidate, selector) { settle(); return }
        }
        let names = NSSelectorFromString("accessibilityActionNames")
        let perform = NSSelectorFromString("accessibilityPerformAction:")
        if candidate.responds(to: names), candidate.responds(to: perform),
          (candidate.perform(names)?.takeUnretainedValue() as? [String])?.contains("AXPress") == true {
          candidate.perform(perform, with: "AXPress")
          settle(); return
        }
      }
    }
    print(elements.map { "\(Swift.type(of: $0)): \(axRead($0, "accessibilityIdentifier") ?? "") \(axRead($0, "accessibilityLabel") ?? "")" }.joined(separator: "\n"))
    fflush(stdout)
    throw WorkbenchError.message("Cannot press control: \(id)")
  }
  @MainActor static func type(_ text: String, into field: NSTextField, window: NSWindow) {
    window.makeFirstResponder(field)
    field.stringValue = text
    if let editor = field.currentEditor() { editor.string = text }
    NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
    settle()
  }
  @MainActor static func capture(_ host: NSView, to url: URL) throws {
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw WorkbenchError.message("Cannot capture T06 layout")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: url)
  }
  @MainActor static func javascript(_ script: String, in web: WKWebView) throws -> Any? {
    var response: Result<Any?, Error>?
    web.evaluateJavaScript(script) { value, error in
      response = error.map { .failure($0) } ?? .success(value)
    }
    let deadline = Date().addingTimeInterval(5)
    while response == nil && Date() < deadline { settle() }
    guard let response else { throw WorkbenchError.message("WebKit script timed out") }
    return try response.get()
  }
  @MainActor static func waitForScore(_ web: WKWebView, measure: Int) throws {
    let deadline = Date().addingTimeInterval(15)
    let query =
      "document.querySelector('#hotspots button.selected')?.getAttribute('aria-label') === '第 \(measure) 小節'"
    while Date() < deadline {
      if (try? javascript(query, in: web)) as? Bool == true { return }
      settle()
    }
    let message = try? javascript("document.getElementById('message')?.textContent", in: web)
    throw WorkbenchError.message("Score did not render: \(message ?? "no message")")
  }
  @MainActor static func main() throws {
    guard let root = ProcessInfo.processInfo.environment["BASS_DATA_ROOT"], !root.isEmpty else {
      throw WorkbenchError.message("Specify BASS_DATA_ROOT for disposable test data")
    }
    let app = NSApplication.shared
    let interactive = CommandLine.arguments.contains("--interactive")
    let livePlayback = !CommandLine.arguments.contains("--no-playback")
    if !livePlayback { print("SKIP live playback assertions (--no-playback); real UI / WebKit remain enabled") }
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let analysisWorker = InterfaceAnalysisWorker()
    let store = try fixture(worker: analysisWorker)
    let host = NSHostingView(rootView: WorkbenchView(presentsErrors: false).environmentObject(store))
    let window = NSWindow(
      contentRect: NSRect(x: 30, y: 30, width: 1280, height: 920),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Bass Workbench · 合成資料介面測試"
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(nil)
    prepareAccessibility()
    defer { window.orderOut(nil) }
    let output = URL(fileURLWithPath: root).appendingPathComponent("results")
    try Files.directory(output)
    if CommandLine.arguments.contains("--playback-speed-only") {
      window.setContentSize(NSSize(width: 1120, height: 780))
      settle()
      store.project.timing.bpm = 190
      func openSpeedEditor() throws {
        try press("playback-rate-custom", in: host)
        prepareAccessibility()
      }
      let segmentIDs = ["playback-rate-1.0", "playback-rate-0.75", "playback-rate-0.5", "playback-rate-custom"]
      func segmentFrames() -> [NSRect] { segmentIDs.compactMap { accessibilityFrame($0, in: host) } }
      let initialFrame = segmentFrames()
      try check(initialFrame.count == 4 && Set(initialFrame.map(\.size.width)).count == 1
                  && Set(initialFrame.map(\.size.height)).count == 1,
                "All four segments have equal dimensions: \(initialFrame)")
      for id in segmentIDs.dropLast().reversed() {
        try press(id, in: host)
        try check(segmentFrames() == initialFrame, "Preset switch preserves all segment frames")
      }
      func input(_ title: String) throws -> NSTextField {
        guard let field = app.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(descendants)
          .compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == title }) else {
          throw WorkbenchError.message("Missing speed field: \(title)")
        }
        return field
      }
      func submit(_ field: NSTextField) {
        field.currentEditor()?.doCommand(by: NSSelectorFromString("insertNewline:"))
        settle()
      }
      func confirmSpeed() throws {
        let button = app.windows.filter(\.isVisible).compactMap(\.contentView).first {
          accessibilityFrame("playback-rate-confirm", in: $0) != nil
        }
        guard let button else { throw WorkbenchError.message("Missing playback speed confirmation") }
        try press("playback-rate-confirm", in: button)
      }
      try openSpeedEditor()
      let initialRate = try input("倍率")
      try check(initialRate.currentEditor() != nil && initialRate.focusRingType == .none,
                "Multiplier starts focused without the native ring")
      if let popup = initialRate.window, let content = popup.contentView {
        let bounds = popup.convertToScreen(content.convert(content.bounds, to: nil))
        try check(window.frame.insetBy(dx: -1, dy: -1).contains(bounds), "Popover fits inside the narrow window")
      }
      let bpm = try input("練習 BPM")
      type("120", into: bpm, window: bpm.window!)
      submit(bpm)
      try check(store.project.rate == Float(120.0 / 190) && store.transport.rate == store.project.rate,
                "BPM uses the full precision playback multiplier")
      try check(segmentFrames() == initialFrame, "Custom speed preserves all segment frames")
      try check(try ProjectStore.load(store.folder).rate == store.project.rate, "Custom multiplier is persisted")
      try openSpeedEditor()
      try check(try input("練習 BPM").doubleValue == 120, "Reopening rounds BPM from stored multiplier")
      let overflow = try input("練習 BPM")
      type("400", into: overflow, window: overflow.window!)
      try confirmSpeed()
      try check(store.project.rate == Float(120.0 / 190) && (try input("倍率").doubleValue) == 2,
                "First confirmation clamps the draft without changing playback")
      try confirmSpeed()
      try check(store.project.rate == 2 && store.transport.rate == 2, "Second confirmation applies the clamped value")
      try openSpeedEditor()
      let nearPreset = try input("練習 BPM")
      type("142.4", into: nearPreset, window: nearPreset.window!)
      submit(nearPreset)
      try check(store.project.rate == Float(142.4 / 190), "Nearby BPM stays a custom multiplier")
      try openSpeedEditor()
      let exactPreset = try input("練習 BPM")
      type("142.5", into: exactPreset, window: exactPreset.window!)
      submit(exactPreset)
      try check(store.project.rate == 0.75, "Exact BPM selects the matching preset")
      var unconfirmed = store.project
      unconfirmed.scoreContexts[unconfirmed.scoreContexts.firstIndex { $0.id == unconfirmed.activeContextID }!].alignmentConfirmed = false
      store.project = unconfirmed
      settle()
      try openSpeedEditor()
      try check(try !input("練習 BPM").isEnabled && input("倍率").isEnabled,
                "Unconfirmed tempo disables only practice BPM")
      print("PASS playback speed: \(assertions) assertions")
      return
    }
    if CommandLine.arguments.contains("--score-update-only") {
      guard let score = store.project.score,
        let web = descendants(host).compactMap({ $0 as? WKWebView }).first else {
        throw WorkbenchError.message("Score preview missing")
      }
      let copy = store.folder.appendingPathComponent("external-score.musicxml")
      try FileManager.default.copyItem(at: store.folder.appendingPathComponent(score.xmlPath), to: copy)
      store.project.scoreSourcePath = copy.path
      store.navigate(2)
      try waitForScore(web, measure: 3)
      let edited = try String(contentsOf: copy, encoding: .utf8)
        .replacingOccurrences(of: "<step>E</step>", with: "<step>G</step>")
      try edited.write(to: copy, atomically: true, encoding: .utf8)
      let active = store.project.activeContextID
      try press("update-reference-score", in: host)
      let deadline = Date().addingTimeInterval(5)
      while store.scoreUpdating && Date() < deadline { settle() }
      try check(store.error == nil && store.project.activeContextID == active
                && store.notes.first?.soundingPitch == 31, "preview button refreshes the same score and note list")
      try waitForScore(web, measure: 3)
      try check((try javascript("xmlRevision", in: web) as? String) == store.project.score?.revision,
                "WebKit receives the new score revision and retains the selected measure")
      print("PASS manual score update UI: \(assertions) assertions")
      return
    }
    if CommandLine.arguments.contains("--r09-only") {
      try verifyScoreLoop(window: window, host: host, store: store, output: output)
      print("PASS R09 score loop: \(assertions) assertions")
      return
    }
    if CommandLine.arguments.contains("--r04-r05-only") {
      let existing = store.project
      store.project = Project()
      window.setContentSize(NSSize(width: 1120, height: 780))
      settle()
      func has(_ id: String) -> Bool {
        accessibilityElements(host).contains { axRead($0, "accessibilityIdentifier") as? String == id }
      }
      try check(has("import-original-welcome") && !has("measure-navigation") && !has("analyze-range"),
                "Empty project exposes import and hides placeholder navigation and analysis")
      try capture(host, to: output.appendingPathComponent("hierarchy-empty.png"))
      store.project.assets = existing.assets
      store.project.selectedAsset = existing.selectedAsset
      store.project.reconcileEstimatedRegions()
      settle()
      try check(!has("measure-navigation") && has("analysis-unavailable-reason") && !store.canAnalyze,
                "Imported audio requires grid confirmation")
      try check(store.analyze() == nil && store.analyze(fullSong: true) == nil,
                "Both entry points reject unconfirmed timing")
      try press("toggle-time-alignment", in: host)
      let bpm = descendants(host).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "100" }
      try check(bpm.map { $0.convert($0.bounds, to: host).minX > 750 } == true, "BPM belongs to the right sidebar")
      try press("apply-alignment", in: host)
      try check(store.project.estimatedGrid != nil && has("measure-navigation") && store.canAnalyze,
                "Applying unchanged default values creates a real grid")
      try check(try ProjectStore.load(store.folder).estimatedGrid != nil, "Grid is saved")
      let rangeButton = accessibilityFrame("analyze-range", in: host)
      let songButton = accessibilityFrame("analyze-song", in: host)
      try check(rangeButton.map { $0.maxX < (songButton?.minX ?? 0) } == true,
                "Range analysis sits in the center to the left of full-song analysis")
      try check(has("analysis-result-empty") && !has("analysis-result-values") && has("annotation-Root"),
                "Compact empty analysis leaves manual annotation visible")
      try capture(host, to: output.appendingPathComponent("hierarchy-ready.png"))
      guard let regionIndex = store.project.regions.firstIndex(where: { $0.id == store.currentRegion?.id }) else {
        throw WorkbenchError.message("Missing region for analysis result layout")
      }
      let symbols = ["Em", "G", "C", "Am", "Dm"]
      let candidates = symbols.enumerated().map { index, symbol in
        ChordCandidate(root: index, quality: "majmin", symbol: symbol,
          score: 0.9 / Double(index + 1), support: [], conflict: [])
      }
      store.project.regions[regionIndex].evidence = HarmonyEvidence(firstPitch: 28, firstTime: 0.15,
        firstScore: 0.7, root: 4, chord: "Em", rootMargin: 0.2, candidates: candidates, chroma: [],
        warnings: [], arrangementSource: "synthetic", bassSource: "synthetic", method: AnalysisMethod.btcHarmony,
        timingRevision: store.project.timing.revision, createdAt: "")
      store.project.regions[regionIndex].annotation.rootLocked = true
      settle()
      try check(has("analysis-result-values") && !has("analysis-result-empty") && has("analyze-range"),
                "Results replace the empty status and preserve the chart action")
      try check(symbols.prefix(3).allSatisfy { has("adopt-chord-\($0)") }
                  && symbols.dropFirst(3).allSatisfy { !has("adopt-chord-\($0)") },
                "Only the three highest-ranked candidates are visible")
      try check(has("analyze-song") && !has("analyze-btc-song") && !has("annotation-首音"),
                "Full-song analysis has one action and keeps first note out of the main panel")
      let regionID = store.project.regions[regionIndex].id
      store.annotate(regionID: regionID) { $0.firstNote = "E1"; $0.firstLocked = true }
      settle()
      try check(accessibilityElements(host).contains { axRead($0, "accessibilityLabel") as? String == "既有首音標註" }
                  && !has("annotation-首音"), "Existing manual first note stays in a closed disclosure")
      try press("既有首音標註", matchingLabel: true, in: host)
      let legacyField = descendants(host).compactMap { $0 as? NSTextField }
        .first { $0.placeholderString == "手動標註" && $0.stringValue == "E1" }
      try check(legacyField?.isEnabled == false && store.project.regions[regionIndex].annotation.firstNote == "E1"
                  && store.project.regions[regionIndex].annotation.firstLocked, "Existing first note and lock are accessible")
      try check(accessibilityElements(host).contains {
        axRead($0, "accessibilityValue") as? String == "已鎖定空白"
          || axRead($0, "accessibilityLabel") as? String == "已鎖定空白"
      },
                "A locked empty field is visible even when analysis returns a candidate")
      try capture(host, to: output.appendingPathComponent("hierarchy-result.png"))
      store.project.regions[regionIndex].evidence = nil
      store.project.regions[regionIndex].annotation.rootLocked = false
      store.project.regions[regionIndex].annotation.firstNote = ""
      store.project.regions[regionIndex].annotation.firstLocked = false
      if let bpm { type("119", into: bpm, window: window) }
      settle()
      try check(!store.canAnalyze && store.analyze() == nil, "Unsaved draft blocks analysis")
      try press("cancel-alignment", in: host)
      try check(store.canAnalyze, "Cancel restores readiness")
      _ = store.project.addScore(existing.score!)
      settle()
      try check(!store.canAnalyze && has("measure-navigation"), "New score is visible before alignment confirmation")
      try press("toggle-time-alignment", in: host)
      try press("apply-alignment", in: host)
      let reopened = try ProjectStore.load(store.folder)
      try check(store.canAnalyze && !reopened.requiresAlignmentConfirmation,
                "Score confirmation survives reopening")
      let audio = store.folder.appendingPathComponent("synthetic.wav")
      for result in ["good", "poor", "empty"] {
        store.newProject()
        analysisWorker.fitStatus = result
        try check(store.importAudio(audio, role: "original") != nil && store.importingFirstOriginal,
                  "First import enters setup progress")
        let deadline = Date().addingTimeInterval(12)
        while analysisWorker.pending == nil && Date() < deadline { settle() }
        try check(analysisWorker.pending != nil && has("setup-progress-title")
                    && has("cancel-analysis") && !has("toggle-time-alignment"),
                  "Beat estimation displays only the setup controls")
        analysisWorker.finish(failing: false, empty: result == "empty")
        settle()
        try check(!has("setup-progress-title") && has("estimate-tempo"), "Result opens alignment controls")
        if result != "empty" {
          try check(store.canAnalyze && store.autoAppliedGridBPM == 120 && has("initial-tempo-applied"),
                    "Usable BPM builds a grid and shows the next step")
          try check(has("initial-tempo-review") == (result == "poor"), "Weak estimate calls for review")
          if result == "poor" {
            let button = accessibilityElements(host).first {
              axRead($0, "accessibilityIdentifier") as? String == "apply-alignment"
            }
            try check(button.flatMap { axRead($0, "accessibilityLabel") as? String } == "確認",
                      "Automatic panel offers a confirmation action")
            if let input = descendants(host).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "100" }) {
              type("nan", into: input, window: window)
              try press("apply-alignment", in: host)
              try check(has("estimate-tempo") && has("alignment-validation"), "Invalid confirmation leaves the panel open")
              try press("cancel-alignment", in: host)
            }
            try press("apply-alignment", in: host)
            try check(!has("estimate-tempo") && !has("initial-tempo-applied") && store.canAnalyze,
                      "Successful confirmation collapses the automatically opened panel")
            continue
          }
          try press("toggle-time-alignment", in: host)
          try check(!has("estimate-tempo"), "Alignment card can be collapsed")
          try press("review-initial-alignment", in: host)
          try check(has("estimate-tempo") && has("initial-tempo-applied"),
                    "Central guidance reopens alignment and stays visible until confirmation")
          try press("apply-alignment", in: host)
          try check(!has("initial-tempo-applied") && store.canAnalyze && store.project.timing.bpm == 120
                      && has("estimate-tempo"),
                    "Confirming a manually reopened panel dismisses the guide and keeps the panel open")
          if result == "good" {
            store.navigate(2); settle()
            let thirdBar = ViewportRange(start: store.viewportStart, end: store.viewportEnd)
            let position = store.transport.position
            try press("first-bar-later-tenth", in: host)
            try check(abs(store.viewportStart - (thirdBar.start + 0.1)) < 1e-7
                        && abs(store.viewportEnd - (thirdBar.end + 0.1)) < 1e-7
                        && store.previewMeasureStart == store.viewportStart
                        && store.project.selectedMeasure == 2 && store.transport.position == position,
                      "A tenth-second nudge rolls the third-bar viewport without selecting or seeking elsewhere")
            try press("measure-0", in: host)
            try check(abs(store.viewportStart - 0.1) < 1e-7 && store.firstBarPreview == 0.1,
                      "Switching to the first bar keeps the pending offset")
            try press("measure-2", in: host)
            let previewPosition = store.transport.position
            try check(abs(store.viewportStart - (thirdBar.start + 0.1)) < 1e-7
                        && abs(store.viewportEnd - (thirdBar.end + 0.1)) < 1e-7
                        && abs(previewPosition - store.viewportStart) < 1e-7
                        && store.project.timing.seconds(at: 0) == 0,
                      "Navigating to the third bar uses its draft view and audition time without applying")
            try press("first-bar-later-tenth", in: host)
            try check(abs(store.viewportStart - (thirdBar.start + 0.2)) < 1e-7
                        && abs(store.viewportEnd - (thirdBar.end + 0.2)) < 1e-7
                        && store.transport.position == previewPosition,
                      "A second nudge adds only 0.1 seconds to the existing draft view")
            try press("cancel-alignment", in: host)
            try check(store.firstBarPreview == nil && store.project.selectedMeasure == 2
                        && store.viewportStart == thirdBar.start && store.viewportEnd == thirdBar.end,
                      "Cancelling after navigation restores the current bar's applied view")
            try press("first-bar-later-tenth", in: host)
            try press("apply-alignment", in: host)
            try check(abs(store.viewportStart - (thirdBar.start + 0.1)) < 1e-7
                        && store.viewportMode == .measure && store.project.selectedMeasure == 2,
                      "Applying the nudge retains the third-bar viewport and its follow mode")
            store.undo()
            store.navigate(0)
            store.zoomMeasure()
            store.zoom(2)
            settle()
            let wide = ViewportRange(start: store.viewportStart, end: store.viewportEnd)
            let wideOrigin = store.project.timing.seconds(at: 0)
            guard let start = descendants(host).compactMap({ $0 as? NSTextField })
              .first(where: { $0.placeholderString == "小節起點" }) else {
              throw WorkbenchError.message("Missing origin field for negative pan")
            }
            type(String(wideOrigin - 0.1), into: start, window: window)
            try check(abs(store.viewportStart - (wide.start - 0.1)) < 1e-7
                        && abs((store.viewportEnd - store.viewportStart) - wide.span) < 1e-7,
                      "Negative nudge pads the intro without losing the zoomed span")
            try press("apply-alignment", in: host)
            try check(abs(store.viewportStart - (wide.start - 0.1)) < 1e-7
                        && abs((store.viewportEnd - store.viewportStart) - wide.span) < 1e-7,
                      "Applying negative offset keeps the padded view and span")
            try press("zoom-measure", in: host)
            try check(abs(store.viewportStart + 0.1) < 1e-7
                        && abs((store.viewportEnd - store.viewportStart) - thirdBar.span) < 1e-7,
                      "Current-bar view shows the full first bar including pre-audio padding")
            try press("measure-0", in: host)
            try check(store.transport.position == 0 && abs(store.project.timing.beat(at: 0) - 0.2) < 1e-7,
                      "A negative origin advances the grid relative to audio, which starts at file time zero")
          }
        } else {
          try check(!store.canAnalyze && store.project.estimatedGrid == nil && has("review-pending-alignment"),
                    "No BPM leaves timing for manual confirmation")
        }
      }
      print("PASS R04/R05: \(assertions) assertions")
      return
    }
    if CommandLine.arguments.contains("--alignment-only") {
      settle()
      try unifiedAlignmentInterfaceTests(window:window,host:host,store:store,output:output)
      print("PASS unified alignment interface: \(assertions) assertions")
      return
    }
    if CommandLine.arguments.contains("--practice-only") {
      settle()
      try practiceInterfaceTests(window:window,host:host,store:store,worker:analysisWorker,
        output:output,livePlayback:livePlayback)
      print("PASS practice interface: \(assertions) assertions")
      return
    }
    for (width, height) in [(1280, 920), (1120, 780)] {
      window.setContentSize(NSSize(width: width, height: height))
      store.zoomMeasure()
      host.layoutSubtreeIfNeeded()
      settle()
      window.makeFirstResponder(nil)
      settle()
      let initiallyCollapsed = !descendants(host).compactMap { $0 as? NSTextField }
        .contains { $0.placeholderString == "100" }
      try check(initiallyCollapsed, "time alignment starts collapsed at \(width)")
      try capture(host, to: output.appendingPathComponent("t06-collapsed-\(width).png"))
      try press("toggle-time-alignment", in: host)
      try tempoSplitControl(host: host, store: store, worker: analysisWorker, width: width)
      let fields = descendants(host).compactMap { $0 as? NSTextField }
      guard let a = fields.first(where: { $0.placeholderString == "起點秒數" }),
        let b = fields.first(where: { $0.placeholderString == "終點秒數" })
      else { throw WorkbenchError.message("A/B native input controls not found") }
      for field in [a, b] {
        let rect = field.convert(field.bounds, to: host)
        try check(host.bounds.contains(rect), "A/B field fits \(width)×\(height)")
        try check(field.enclosingScrollView == nil, "A/B controls stay outside scrolling content")
      }
      guard let bpm = fields.first(where: { $0.placeholderString == "100" }),
        let bias = fields.first(where: { $0.placeholderString == "小節起點" }) else {
        throw WorkbenchError.message("Alignment BPM/bias controls not found")
      }
      for field in [bpm, bias] {
        try check(host.bounds.contains(field.convert(field.bounds, to: host)),
                  "BPM/bias field fits \(width)×\(height)")
        try check(field.enclosingScrollView != nil, "alignment fields belong to scrollable editing content")
      }
      let timingBefore = store.project.timing
      type("-", into: bias, window: window)
      try check(store.editingPlaybackSelection && store.project.timing == timingBefore,
                "incomplete draft protects follow without writing alignment")
      try press("toggle-time-alignment", in: host)
      try check(store.project.timing == timingBefore && !store.editingPlaybackSelection,
                "collapse cancels draft and releases selection protection")
      try press("toggle-time-alignment", in: host)
      guard let reopenedBias = descendants(host).compactMap({ $0 as? NSTextField })
        .first(where: { $0.placeholderString == "小節起點" }) else {
        throw WorkbenchError.message("Reopened bias missing")
      }
      try check(Double(reopenedBias.stringValue) == timingBefore.bias, "reopening restores applied value")
      type("0.125", into: reopenedBias, window: window)
      try press("apply-alignment", in: host)
      try check(store.project.timing.bias == 0.125, "explicit apply still updates timing")
      try press("toggle-time-alignment", in: host)
      try check(store.project.timing.bias == 0.125 && !store.editingPlaybackSelection,
                "applied timing survives collapse")
      try check(accessibilityElements(host).contains { (axRead($0, "accessibilityValue") as? String)?.contains("+0.125") == true
                  || (axRead($0, "accessibilityLabel") as? String)?.contains("+0.125") == true }, "collapsed summary displays applied bias")
      _ = store.applyAlignment(timingBefore)
      try press("measure-legend", in: host)
      let popoverElements = NSApplication.shared.windows.flatMap { accessibilityElements($0) }
      try check(popoverElements.contains { (axRead($0, "accessibilityLabel") as? String)?.contains("半圓綠點") == true
                  || (axRead($0, "accessibilityValue") as? String)?.contains("半圓綠點") == true }, "legend explains partial confirmation")
      try press("measure-legend", in: host)
      try press("toggle-time-alignment", in: host)
      try press("two-point-alignment", in: host)
      var measuredTimes = descendants(host).compactMap { $0 as? NSTextField }
        .filter { $0.placeholderString == "實際秒數" }
      try check(measuredTimes.count == 2 && store.editingPlaybackSelection,
                "opening two-point controls protects playback selection")
      type("7.25", into: measuredTimes[0], window: window)
      try capture(host, to: output.appendingPathComponent("t06-expanded-\(width).png"))
      try press("toggle-time-alignment", in: host)
      try check(!store.editingPlaybackSelection && store.project.timing.bias == timingBefore.bias,
                "outer collapse cancels two-point input and releases both editing scopes")
      try press("toggle-time-alignment", in: host)
      try press("two-point-alignment", in: host)
      measuredTimes = descendants(host).compactMap { $0 as? NSTextField }
        .filter { $0.placeholderString == "實際秒數" }
      try check(measuredTimes.count == 2 && measuredTimes.allSatisfy { $0.stringValue.isEmpty },
                "reopened measured times do not retain canceled input")
      try press("two-point-alignment", in: host)
      try press("manual-alignment", in: host)
      guard let offset = descendants(host).compactMap({ $0 as? NSTextField })
        .first(where: { $0.placeholderString == "音源偏移" }) else {
        throw WorkbenchError.message("Source-offset input missing")
      }
      let appliedOffset = store.currentAsset!.offset
      type("0.125", into: offset, window: window)
      try check(store.currentAsset?.offset == appliedOffset, "typing source offset never writes asset")
      try press("toggle-time-alignment", in: host)
      try check(store.currentAsset?.offset == appliedOffset && !store.editingPlaybackSelection,
                "source-offset collapse discards without focus-loss commit")
      try press("toggle-time-alignment", in: host)
      try press("manual-alignment", in: host)
      guard let newOffset = descendants(host).compactMap({ $0 as? NSTextField })
        .first(where: { $0.placeholderString == "音源偏移" }) else {
        throw WorkbenchError.message("Reopened source-offset input missing")
      }
      try check(Double(newOffset.stringValue) == appliedOffset, "source draft reopens with applied value")
      type("0.125", into: newOffset, window: window)
      try press("apply-alignment", in: host)
      try check(store.currentAsset?.offset == 0.125, "source offset still supports explicit apply")
      try press("toggle-time-alignment", in: host)
      store.setAssetOffset(appliedOffset)
      _ = store.applyAlignment(timingBefore)
      let savedRegions = store.project.regions
      let firstMeasure = store.project.measures[0]
      store.project.regions.removeAll { $0.measureID == firstMeasure.id }
      var confirmedHalf = HarmonyRegion(measureID: firstMeasure.id, startBeat: firstMeasure.beat,
                                        endBeat: firstMeasure.beat + 2)
      confirmedHalf.annotation.confirmed = true
      store.project.regions += [confirmedHalf, HarmonyRegion(measureID: firstMeasure.id,
        startBeat: firstMeasure.beat + 2, endBeat: firstMeasure.end)]
      settle()
      try check(accessibilityElements(host).contains {
        axRead($0, "accessibilityIdentifier") as? String == "measure-0"
          && (axRead($0, "accessibilityValue") as? String)?.contains("1/2") == true
      }, "actual navigation cell describes partial confirmation")
      store.project.regions = savedRegions
      settle()
      // 收合後畫面空間可回復；以下保留原有 T01/T02/T03 的完整回歸。
      try check(
        !fields.contains(where: { $0.placeholderString == "專案名稱" }),
        "title remains text until Edit is pressed")
      guard let web = descendants(host).compactMap({ $0 as? WKWebView }).first else {
        throw WorkbenchError.message("Score WKWebView missing")
      }
      try waitForScore(web, measure: 1)
      store.setLoopEnabled(false)
      for outcome in ["success", "cancel", "failure"] {
        if livePlayback {
          store.playPause()
          try check(store.transport.playing, "playback starts before UI analysis test")
        }
        let task = store.estimateTempo()
        let deadline = Date().addingTimeInterval(5)
        while analysisWorker.pending == nil && Date() < deadline { settle() }
        try check(analysisWorker.pending != nil && store.analysisRunning && !store.transport.playing,
                  "UI analysis pauses and enters locked state")
        settle()
        try check((try javascript(
          "document.querySelectorAll('#hotspots button').length > 0 && Array.from(document.querySelectorAll('#hotspots button')).every(b => b.disabled)",
          in: web) as? Bool) == true, "real OSMD hotspots disabled during analysis at \(width)")
        let selected = store.project.selectedMeasure
        _ = try javascript("tell({type:'measure',index:2,revision:xmlRevision})", in: web)
        settle()
        try check(store.project.selectedMeasure == selected, "native bridge rejects direct message while disabled")
        if outcome == "cancel" { store.cancel() }
        else { analysisWorker.finish(failing: outcome == "failure") }
        let finishDeadline = Date().addingTimeInterval(5)
        while store.analysisRunning && Date() < finishDeadline { settle() }
        store.error = nil
        settle()
        try check(!store.busy && !store.analysisRunning && !store.transport.playing,
                  "UI \(outcome) unlocks without automatic playback")
        try check((try javascript(
          "Array.from(document.querySelectorAll('#hotspots button')).every(b => !b.disabled)",
          in: web) as? Bool) == true, "OSMD hotspots restore after \(outcome) at \(width)")
        _ = try javascript("document.querySelector('#hotspots button[aria-label=\"第 2 小節\"]').click()", in: web)
        settle()
        try check(store.project.selectedMeasure == 1, "score click works after analysis")
        store.navigate(0)
        try waitForScore(web, measure: 1)
        withExtendedLifetime(task) {}
      }
      try check(
        (try javascript("document.querySelectorAll('#hotspots button').length", in: web) as? Int
          ?? 0) > 0, "real score rendered at \(width)")
      if width == 1280 && livePlayback {
        store.navigate(1)
        try waitForScore(web, measure: 2)
        store.setLoop(a: 8, b: 12)
        store.followPlayback = false
        store.playPause()
        try check(store.transport.playing, "audio playing before score click")
        _ = try javascript(
          "document.querySelector('#hotspots button[aria-label=\"第 3 小節\"]').click()", in: web)
        settle()
        try check(
          store.project.selectedMeasure == 2 && !store.transport.playing
            && store.transport.position == 2,
          "actual score click crosses WK bridge, seeks and pauses")
        try check(
          store.project.a == 8 && store.project.b == 12,
          "score click preserves cross-measure loop bounds")
        store.followPlayback = true
      }
      let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
      guard let content = scrolls.max(by: { $0.frame.width < $1.frame.width }),
        let document = content.documentView
      else { throw WorkbenchError.message("Content scroll view not found") }
      try check(!accessibilityElements(host).contains { axRead($0, "accessibilityIdentifier") as? String == "manage-scores" }, "score management is inside collapsed source disclosure at \(width)")
      try press("分析來源與專案", matchingLabel: true, in: host)
      guard let inspector = scrolls.max(by: { $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX }) else {
        throw WorkbenchError.message("Inspector scroll view missing")
      }
      let sourceElements = accessibilityElements(inspector)
      try check(sourceElements.contains { axRead($0, "accessibilityIdentifier") as? String == "reference-score" }
                && sourceElements.contains { axRead($0, "accessibilityIdentifier") as? String == "manage-scores" }, "reference picker and manager are in right inspector at \(width)")
      let sourceText = sourceElements.flatMap { e in ["accessibilityLabel", "accessibilityValue"].compactMap { axRead(e, $0) as? String } }.joined(separator: "\n")
      try check(!sourceText.contains("歷史區間標註：") && !sourceText.contains("原譜與音源儲存在專案內；所有分析在本機執行。"), "removed source notes are absent at \(width)")
      try check(try javascript("document.getElementById('message').hidden && document.getElementById('paper').getBoundingClientRect().top===0", in: web) as? Bool == true, "preview has no range hint or empty hint row at \(width)")
      let inspectorEnd = max(0, (inspector.documentView?.bounds.height ?? 0) - inspector.contentView.bounds.height)
      inspector.contentView.scroll(to: NSPoint(x: 0, y: inspectorEnd))
      inspector.reflectScrolledClipView(inspector.contentView)
      settle()
      try capture(host, to: output.appendingPathComponent("t10-sources-\(width).png"))
      try press("分析來源與專案", matchingLabel: true, in: host)
      inspector.contentView.scroll(to: .zero)
      inspector.reflectScrolledClipView(inspector.contentView)
      let before = a.convert(a.bounds, to: host)
      let distance = max(0, document.bounds.height - content.contentView.bounds.height)
      try check(distance > 0, "test content actually overflows")
      content.contentView.scroll(to: NSPoint(x: 0, y: distance))
      content.reflectScrolledClipView(content.contentView)
      settle()
      try check(
        a.convert(a.bounds, to: host) == before, "scrolling content does not move transport fields")
      content.contentView.scroll(to: .zero)
      content.reflectScrolledClipView(content.contentView)
      store.transport.position = 130.25
      settle()
      try check(store.project.selectedMeasure == 130, "134-bar fixture follows playback near end")
      try waitForScore(web, measure: 131)
      try check(try javascript("previewState.current===130 && previewState.first===129 && previewState.last>=130", in: web) as? Bool == true, "adaptive score preview follows native playback selection at \(width)")
      guard
        let navigator = scrolls.min(by: {
          $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX
        })
      else { throw WorkbenchError.message("Measure navigator not found") }
      try check(
        navigator.contentView.bounds.origin.y > 0, "navigator actually scrolls to followed bar")
      host.displayIfNeeded()
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds),
        let png = { () -> Data? in
          host.cacheDisplay(in: host.bounds, to: bitmap)
          return bitmap.representation(using: .png, properties: [:])
        }()
      else { throw WorkbenchError.message("Cannot render layout evidence") }
      try png.write(to: output.appendingPathComponent("layout-\(width).png"))
      content.contentView.scroll(to: NSPoint(x: 0, y: distance))
      content.reflectScrolledClipView(content.contentView)
      settle()
      try capture(host, to: output.appendingPathComponent("t10-preview-\(width).png"))
      content.contentView.scroll(to: .zero)
      content.reflectScrolledClipView(content.contentView)

      // 故意將列表停在中段；檢查真實 NSScrollView 的位置，而非只比對 Store 旗標。
      let middle = max(0, (navigator.documentView!.bounds.height - navigator.contentView.bounds.height) / 2)
      navigator.contentView.scroll(to: NSPoint(x: 0, y: middle))
      navigator.reflectScrolledClipView(navigator.contentView)
      settle()
      let navigationOrigin = navigator.contentView.bounds.origin
      let loopBefore = (store.project.a, store.project.b, store.project.loop)
      store.navigate(60, scrollNavigation: false)
      settle()
      try check(store.project.selectedMeasure == 60 && store.transport.position == 60
                && !store.transport.playing, "sidebar action still selects, seeks and pauses")
      try check(navigator.contentView.bounds.origin == navigationOrigin,
                "sidebar selection preserves actual navigator offset at \(width)")
      store.navigate(90)  // 尚未繪製的上一個請求也應被隨後的手動點選撤銷。
      store.navigate(61, scrollNavigation: false)
      store.navigate(60, scrollNavigation: false)
      settle()
      try check(navigator.contentView.bounds.origin == navigationOrigin,
                "rapid/repeated sidebar selection cancels stale pending scroll")
      try check(store.project.a == loopBefore.0 && store.project.b == loopBefore.1
                && store.project.loop == loopBefore.2, "sidebar action preserves loop")
      store.zoom(2)
      let viewportBeforeAnalysis = ViewportRange(start: store.viewportStart, end: store.viewportEnd)
      let modeBeforeAnalysis = store.viewportMode
      let analysisTask = store.estimateTempo()
      let pendingDeadline = Date().addingTimeInterval(5)
      while analysisWorker.pending == nil && Date() < pendingDeadline { settle() }
      try check(analysisWorker.pending != nil, "analysis starts after stationary sidebar selection")
      analysisWorker.finish(failing: false)
      let finishedDeadline = Date().addingTimeInterval(5)
      while store.busy && Date() < finishedDeadline { settle() }
      settle()
      try check(!store.busy && navigator.contentView.bounds.origin == navigationOrigin,
                "analysis completion does not recenter manual sidebar selection")
      try check(store.viewportMode == modeBeforeAnalysis
                && ViewportRange(start: store.viewportStart, end: store.viewportEnd) == viewportBeforeAnalysis,
                "analysis completion preserves actual manual plot framing at \(width)")
      let timingBeforeChoice = store.project.timing
      let candidateControls = accessibilityElements(host)
      try check((0..<3).allSatisfy { i in candidateControls.contains { axRead($0, "accessibilityIdentifier") as? String == "tempo-option-\(i)" } },
                "three candidate buttons replace picker and fill at \(width)")
      let mainText = candidateControls.flatMap { e in ["accessibilityLabel", "accessibilityValue"].compactMap { axRead(e, $0) as? String } }.joined(separator: "\n")
      try check(!mainText.contains("P95") && !mainText.contains("量化前") && !mainText.contains("候選尚未套用")
                && !mainText.contains("收合會捨棄"), "technical and gray notes absent from main panel")
      try press("tempo-details", in: host)
      let detailsText = NSApplication.shared.windows.flatMap { accessibilityElements($0) }
        .flatMap { e in ["accessibilityLabel", "accessibilityValue"].compactMap { axRead(e, $0) as? String } }.joined(separator: "\n")
      try check(detailsText.contains("• P95") && detailsText.contains("95%") && detailsText.contains("• 前後漂移"),
                "on-demand details show bulleted values and short definitions")
      if let popup = NSApplication.shared.windows.first(where: { window in
        accessibilityElements(window).contains { axRead($0, "accessibilityIdentifier") as? String == "tempo-details-content" }
      }), let view = popup.contentView { try capture(view, to: output.appendingPathComponent("t07-details-\(width).png")) }
      try press("tempo-details", in: host)
      guard let biasDraft = descendants(host).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "小節起點" }) else {
        throw WorkbenchError.message("Bias draft missing")
      }
      type("0.333", into: biasDraft, window: window)
      window.makeFirstResponder(nil)
      settle()
      try press("tempo-option-0", in: host)
      try check(store.project.timing == timingBeforeChoice
                && biasDraft.stringValue == "0.333", "candidate only stages BPM and preserves origin draft at \(width)")
      try press("apply-alignment", in: host)
      try check(store.project.timing.bpm == 120 && store.project.timing.bias == 0.333,
                "later bias apply does not restore old BPM")
      guard let manualBPM = descendants(host).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "100" }) else {
        throw WorkbenchError.message("Direct BPM field missing")
      }
      type("nan", into: manualBPM, window: window)
      try press("apply-alignment", in: host)
      try check(store.project.timing.bpm == 120, "invalid manual input never changes BPM")
      type("0.444", into: biasDraft, window: window)
      type("191.401234567", into: manualBPM, window: window)
      try press("apply-alignment", in: host)
      try check(store.project.timing.bpm == 191.401234567, "manual BPM sets once at full precision")
      try check(Double(biasDraft.stringValue) == 0.444 && store.project.timing.seconds(at: 0) == 0.444,
                "shared apply commits BPM and origin together")
      try capture(host, to: output.appendingPathComponent("t07-integrated-\(width).png"))
      analysisWorker.fitStatus = "poor"
      let poorTask = store.estimateTempo()
      let poorDeadline = Date().addingTimeInterval(5)
      while analysisWorker.pending == nil && Date() < poorDeadline { settle() }
      try check(analysisWorker.pending != nil, "poor-quality UI fixture starts")
      analysisWorker.finish(failing: false)
      while store.busy && Date() < poorDeadline { settle() }
      settle()
      let poorElements = accessibilityElements(host)
      let poorText = poorElements.flatMap { e in ["accessibilityLabel", "accessibilityValue"].compactMap { axRead(e, $0) as? String } }.joined(separator: "\n")
      try check(store.project.timing.bpm == 191.401234567 && poorText.contains("需人工確認")
                && !poorText.contains("P95") && !poorText.contains("量化前"),
                "poor estimate preserves manual BPM and only shows concise review warning")
      try capture(host, to: output.appendingPathComponent("t07-review-\(width).png"))
      analysisWorker.fitStatus = "good"
      withExtendedLifetime(poorTask) {}
      _ = store.applyAlignment(timingBeforeChoice)
      store.navigate(60)
      try press("toggle-time-alignment", in: host)
      withExtendedLifetime(analysisTask) {}
      try waitForScore(web, measure: 61)
      _ = try javascript("document.querySelector('#hotspots button.selected').click()", in: web)
      settle()
      try check(store.navigationScrollRequest?.index == 60
                && navigator.contentView.bounds.origin != navigationOrigin,
                "actual score button retains navigator auto-scroll")
      let beforeNextNavigation = navigator.contentView.bounds.origin
      store.navigate(90)
      let scrollDeadline = Date().addingTimeInterval(2)
      while navigator.contentView.bounds.origin == beforeNextNavigation && Date() < scrollDeadline { settle() }
      try check(store.project.selectedMeasure == 90
                && navigator.contentView.bounds.origin != beforeNextNavigation,
                "previous/next-style navigation changes actual scroll offset")
      store.transport.position = 0
      settle()
      try waitForScore(web, measure: 1)
    }
    try practiceInterfaceTests(window: window, host: host, store: store, worker: analysisWorker,
                               output: output, livePlayback: livePlayback)
    try multiScoreInterfaceTests(window: window, host: host, store: store, output: output,
                                livePlayback: livePlayback)
    _ = store.selectScore(id: "grid")
    settle()
    try press("toggle-time-alignment", in: host)
    guard let start = descendants(host).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "小節起點" }),
      let gridBPM = descendants(host).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "100" }) else {
      throw WorkbenchError.message("Integrated grid controls missing")
    }
    type("1.25", into: start, window: window)
    window.makeFirstResponder(nil)
    settle()
    try press("tempo-option-0", in: host)
    try check(start.stringValue == "1.25" && gridBPM.stringValue == "120.0", "grid candidate stages BPM and preserves origin draft")
    try press("apply-alignment", in: host)
    try check(store.project.timing.bpm == 120 && store.project.timing.seconds(at: 0) == 1.25,
              "updating grid uses latest BPM instead of stale draft")
    type("130.125", into: gridBPM, window: window)
    gridBPM.currentEditor()?.doCommand(by: NSSelectorFromString("insertNewline:"))
    settle()
    try check(store.project.timing.bpm == 130.125, "Enter uses shared whole-panel apply in no-score panel")
    try capture(host, to: output.appendingPathComponent("t07-integrated-grid-1120.png"))
    try press("cancel-alignment", in: host)
    try check(store.project.timing.bpm == 130.125, "canceling grid draft does not undo directly set BPM")
    try press("toggle-time-alignment", in: host)
    try unifiedAlignmentInterfaceTests(window:window,host:host,store:store,output:output)
    print(
      "PASS interface layout: \(assertions) assertions (real controls / fixed transport / stationary sidebar / score and clock auto-scroll / two sizes)"
    )
    if interactive {
      window.makeKeyAndOrderFront(nil)
      app.activate(ignoringOtherApps: true)
      let publish: @MainActor @Sendable () -> Void = {
        let state: [String: Any] = [
          "title": store.project.title, "selectedMeasure": store.project.selectedMeasure,
          "playbackMeasure": store.playbackMeasure ?? -1, "a": store.project.a,
          "b": store.project.b,
          "playing": store.transport.playing, "editing": store.editingPlaybackSelection,
          "error": store.error ?? "", "folder": store.folder.path,
        ]
        if let data = try? JSONSerialization.data(
          withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
        {
          try? data.write(
            to: output.appendingPathComponent("interactive-state.json"), options: .atomic)
        }
      }
      let observation = store.objectWillChange.sink { _ in
        DispatchQueue.main.async(execute: publish)
      }
      publish()
      print("READY interactive fixture; automatically closes after 10 minutes")
      RunLoop.main.run(until: Date().addingTimeInterval(600))
      observation.cancel()
    }
  }
  @MainActor static func verifyScoreLoop(window: NSWindow, host: NSView, store: WorkbenchStore, output: URL) throws {
    guard let web = descendants(host).compactMap({ $0 as? WKWebView }).first else {
      throw WorkbenchError.message("Score WKWebView missing")
    }
    func click(_ measure: Int, modifiers: NSEvent.ModifierFlags = []) throws {
      guard let point = try javascript("""
        (() => {
          const bar = document.querySelector('#hotspots button[data-measure="\(measure)"]');
          const rect = bar.getBoundingClientRect();
          return [rect.x + rect.width / 2, rect.y + rect.height / 2];
        })()
        """, in: web) as? [Double], point.count == 2 else {
        throw WorkbenchError.message("Cannot locate score measure \(measure)")
      }
      let target = NSPoint(x: point[0], y: web.isFlipped ? point[1] : web.bounds.height - point[1])
      window.makeFirstResponder(web)
      let location = web.convert(target, to: nil)
      // Pass native mouse events to WebKit without posting to the user's desktop.
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
          throw WorkbenchError.message("Cannot create score click")
        }
        if type == .leftMouseDown { web.mouseDown(with: event) }
        else { web.mouseUp(with: event) }
      }
      settle()
    }
    func matches(_ a: Double, _ b: Double) -> Bool {
      store.project.a == a && store.project.b == b && store.project.loop
        && store.transport.a == a && store.transport.b == b && store.transport.loop
        && store.viewportMode == .loop && store.viewportStart == a && store.viewportEnd == b
    }
    func clickNavigation(_ measure: Int, modifiers: NSEvent.ModifierFlags = []) throws {
      guard let frame = accessibilityFrame("measure-\(measure)", in: host), !frame.isEmpty else {
        throw WorkbenchError.message("Cannot locate navigation measure \(measure)")
      }
      let location = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
          throw WorkbenchError.message("Cannot create navigation click")
        }
        window.sendEvent(event)
      }
      settle()
    }
    try waitForScore(web, measure: 1)
    try click(2, modifiers: .shift)
    try check(matches(0, 3) && store.project.selectedMeasure == 0,
      "One native Shift-click sets the loop and shared viewport from the current measure")
    let saved = try ProjectStore.load(store.folder)
    try check(saved.loop && saved.a == 0 && saved.b == 3, "Loop persists in the project")
    try click(2)
    try waitForScore(web, measure: 3)
    try check(store.project.selectedMeasure == 2 && matches(0, 3), "Plain click navigates and preserves the loop")
    try click(1, modifiers: .shift)
    try check(matches(1, 3) && store.project.selectedMeasure == 2, "Reverse selection includes both whole measures")
    try click(2, modifiers: .shift)
    try check(matches(2, 3), "Shift-click on the current measure creates a single-measure loop")
    store.navigate(15, scrollNavigation: false)
    try waitForScore(web, measure: 16)
    try click(17, modifiers: .shift)
    try check(matches(15, 18) && store.project.selectedMeasure == 15, "Sidebar navigation defines the new anchor")
    _ = try javascript("document.querySelector('#hotspots button[data-measure=\"14\"]').click()", in: web)
    settle()
    try check(store.project.selectedMeasure == 14 && matches(15, 18), "Keyboard activation still navigates")
    store.project.timing.bpm = 120
    store.loopMeasures(0, 133)
    try check(matches(15, 18) && store.error == nil, "Over-limit selection preserves loop and viewport without a message")
    store.project.timing.bpm = 240
    store.project.timing.biasSeconds = -0.25
    store.loopMeasures(0, 0)
    try check(matches(0, 0.75), "Pickup before audio is clipped at zero")
    store.project.timing.biasSeconds = 0.25
    store.loopMeasures(133, 133)
    try check(matches(133.25, 134), "Last measure is clipped at the end of the active source")
    store.project.timing.biasSeconds = 0
    store.project.score?.measures[0].number = "0"
    store.project.score?.measures[0].duration = Fraction(1)
    store.project.score?.measures[1].onset = Fraction(1)
    store.project.score?.measures[1].duration = Fraction(3, 2)
    store.project.score?.measures[1].numerator = 3
    store.project.score?.measures[1].denominator = 8
    store.loopMeasures(1, 0)
    try check(matches(0, 0.625), "Pickup and changed meter use actual score lengths")
    try clickNavigation(11)
    try check(store.project.selectedMeasure == 11, "Normal sidebar click selects the anchor")
    try clickNavigation(15, modifiers: .shift)
    try check(matches(11, 16) && store.project.selectedMeasure == 11, "Shift-click in sidebar sets the range and keeps the anchor")
    try check(store.analysisRangeTitle == "分析第 12–16 小節"
      && store.loopMeasureRange?.indices == 11...15, "Whole-bar loop drives both range descriptions")
    try check(accessibilityElements(host).contains {
      axRead($0, "accessibilityIdentifier") as? String == "measure-15"
        && (axRead($0, "accessibilityValue") as? String)?.contains("在 A–B 範圍內") == true
    }, "Sidebar exposes the highlighted range")
    try check(try javascript("""
      [...document.querySelectorAll('#hotspots button.in-loop')].map(b=>Number(b.dataset.measure))
        .join(',')==='11,12,13,14,15'
      """, in: web) as? Bool == true, "Score highlights the same visible measures")
    try check(try javascript("""
      (() => {
        const svg = document.querySelector('#score svg'), glyphs = svg.getBBox();
        const lowestGlyph = svg.getBoundingClientRect().top + glyphs.y + glyphs.height;
        const bars = [...document.querySelectorAll('#hotspots button.in-loop[data-underline]')];
        return bars.length > 0 && bars.every(b => getComputedStyle(b).borderTopWidth === '0px' &&
          b.getBoundingClientRect().top + parseFloat(getComputedStyle(b,'::after').top) > lowestGlyph);
      })()
      """, in: web) as? Bool == true, "A/B indicator renders below all notation, including ledger lines")
    try capture(host, to: output.appendingPathComponent("r09-measure-range.png"))
    store.loopMeasures(11, 19)
    let revision = store.project.timing.revision
    store.zoom(0.5)
    try check(store.viewportMode == .loopZoom(13...17) && store.viewportStart == 13
      && store.viewportEnd == 18 && store.project.a == 11 && store.project.b == 20
      && store.project.timing.revision == revision,
      "Half of nine bars frames five whole bars while retaining A/B and analysis revision")
    store.zoom(0.5)
    try check(store.viewportMode == .loopZoom(14...16) && store.viewportStart == 14 && store.viewportEnd == 17,
      "Successive zoom retains both bar edges")
    store.transport.position = 19.2
    try check(store.viewportMode == .loopZoom(17...19) && store.viewportStart == 17
      && store.viewportEnd == 20 && store.project.selectedMeasure == 19,
      "Playback pans zoomed A/B by whole bars")
    _ = store.setLoop(a: 11.25, b: 15.8)
    settle()
    try check(store.analysisRangeTitle == "分析目前範圍" && store.loopMeasureRange?.indices == 11...15,
      "Partial-bar edits retain coverage but omit the whole-bar analysis label")
    store.setLoopEnabled(false)
    settle()
    try check(store.loopMeasureRange == nil && store.viewportMode == .measure
      && (try javascript("!document.querySelector('#hotspots button.in-loop')", in: web)) as? Bool == true,
      "Disabling the loop clears its range styling")
  }

  @MainActor static func unifiedAlignmentInterfaceTests(window:NSWindow,host:NSView,
    store:WorkbenchStore,output:URL) throws {
    store.navigate(0); settle()
    func input(_ placeholder:String) throws -> NSTextField {
      guard let field = descendants(host).compactMap({$0 as? NSTextField}).first(where:{$0.placeholderString == placeholder}) else {
        throw WorkbenchError.message("Missing shared alignment input \(placeholder)")
      }
      return field
    }
    for (width,height) in [(1280,920),(1120,780)] {
      window.setContentSize(NSSize(width:width,height:height)); settle()
      store.project.regions[0].annotation.root = ""
      store.project.regions[0].annotation.rootLocked = true
      let baseline = store.project
      try press("toggle-time-alignment",in:host)
      let cancelSize = accessibilityFrame("cancel-alignment", in: host)?.size
      let applySize = accessibilityFrame("apply-alignment", in: host)?.size
      try check(cancelSize == applySize && (applySize?.width ?? 0) > 0 && (applySize?.height ?? 0) > 0,
                "Alignment actions share the same button dimensions at \(width)")
      let infoSize = accessibilityFrame("info-第一小節起點", in: host)?.size
      try check((infoSize?.width ?? 0) >= 28 && (infoSize?.height ?? 0) >= 28,
                "Alignment information icon has a larger desktop hit area at \(width)")
      try check(descendants(host).compactMap {$0 as? NSTextField}.filter {$0.placeholderString == "小節起點"}.count == 1,
        "only one origin input at \(width)")
      let originalViewport = ViewportRange(start: store.viewportStart, end: store.viewportEnd)
      let playhead = store.transport.position
      try press("preview-first-bar",in:host)
      try check(store.firstBarPreview == baseline.timing.seconds(at: 0)
                  && accessibilityElements(host).contains { axRead($0, "accessibilityIdentifier") as? String == "analyze-calibration-spectrum" },
                "Visual calibration opens on the first bar and offers spectrum analysis")
      try press("cancel-alignment",in:host)
      try check(store.firstBarPreview == nil && store.viewportStart == originalViewport.start
                  && store.viewportEnd == originalViewport.end, "Cancel restores the previous viewport")
      type("130.125",into:try input("100"),window:window)
      type("1.25",into:try input("小節起點"),window:window)
      let previewStart = store.viewportStart, previewEnd = store.viewportEnd
      try check(store.firstBarPreview == 1.25 && store.transport.position == playhead
                  && abs((previewEnd - previewStart) - originalViewport.span) < 0.00001,
                "Typed origin reframes both plots at the current zoom without seeking")
      try press("first-bar-earlier-fine",in:host)
      try check(abs(store.viewportStart - previewStart + 0.01) < 0.00001
                  && abs(store.viewportEnd - previewEnd + 0.01) < 0.00001
                  && store.transport.position == playhead && store.project == baseline,
                "Nudge pans both plots without changing the playback position or applying alignment")
      type("-",into:try input("小節起點"),window:window)
      try check(store.firstBarPreview == 1.24, "Incomplete origin keeps the last valid preview")
      store.dragFirstBarPreview(to: 1.1); settle()
      try check(try input("小節起點").doubleValue == 1.1 && store.transport.position == playhead,
                "Waveform drag updates the origin field and leaves the playhead in place")
      type("1.25",into:try input("小節起點"),window:window)
      try press("manual-alignment",in:host)
      type("0.2",into:try input("音源偏移"),window:window)
      window.makeFirstResponder(nil); settle()
      try check(store.project == baseline, "BPM / origin / source drafts do not partially commit")
      let identifiers = accessibilityElements(host).compactMap {axRead($0,"accessibilityIdentifier") as? String}
      try check(!identifiers.contains("set-tempo") && !identifiers.contains("apply-source-offset")
        && !identifiers.contains("apply-grid") && !identifiers.contains("calibrate-two-points"),
        "individual apply controls removed")
      type("nan",into:try input("音源偏移"),window:window)
      try press("apply-alignment",in:host)
      try check(store.project == baseline, "one invalid field blocks all pending values")
      type("0.2",into:try input("音源偏移"),window:window)
      try press("apply-alignment",in:host)
      try check(store.project.timing.bpm == 130.125 && store.project.timing.seconds(at:0) == 1.25
        && store.currentAsset?.offset == 0.2 && store.firstBarPreview == nil,
        "one shared apply commits all values and clears the draft guide")
      try check(store.project.timing.revision == baseline.timing.revision + 1, "combined source and timing use one revision")
      try check(store.project.regions[0].id == baseline.regions[0].id && store.project.regions[0].annotation.rootLocked,
        "shared apply preserves IDs and locked blank")
      try check(try ProjectStore.load(store.folder) == store.project, "shared apply persists whole batch")
      store.undo(); settle()
      var restored = store.project
      restored.selectedMeasure = baseline.selectedMeasure
      try check(restored == baseline && ProjectStore.load(store.folder) == baseline,
                "one undo restores all saved alignment settings")
      store.navigate(baseline.selectedMeasure); settle()
      try press("cancel-alignment",in:host)
      try press("two-point-alignment",in:host)
      let points = descendants(host).compactMap {$0 as? NSTextField}.filter {$0.placeholderString == "實際秒數"}
      try check(points.count == 2, "two point inputs remain available")
      type("1",into:points[0],window:window); type("65",into:points[1],window:window)
      try check(store.project == baseline, "two point correction is staged")
      try check(try input("小節起點").doubleValue == 1, "two point origin previews in unified main field")
      try press("two-point-alignment",in:host)
      try press("apply-alignment",in:host)
      try check(store.project.timing.anchors.count == 2 && store.project.timing.seconds(at:0) == 1,
        "collapsed two point panel participates in shared apply")
      store.undo(); settle()
      try check(store.project == baseline, "two point batch is one undo")
      // 手動錨點也只改草稿；取消／收合會丟棄。
      store.navigate(0); settle()
      try press("draft-anchor-start",in:host)
      try check(store.project.timing == baseline.timing, "anchor creation does not mutate project")
      try press("cancel-alignment",in:host)
      try check(store.project.timing == baseline.timing, "shared cancel discards staged anchor")
      try press("draft-anchor-start",in:host)
      try press("apply-alignment",in:host)
      try check(store.project.timing.anchors.contains {$0.beat == 0}, "shared apply commits pending manual anchor")
      store.undo(); settle()
      try check(store.project == baseline, "manual anchor batch is one undo")
      try capture(host,to:output.appendingPathComponent("t07-unified-\(width).png"))
      try press("toggle-time-alignment",in:host)
    }
    let scoreBaseline = store.project
    store.project.score = nil; store.project.timing.anchors = []; store.project.timing.bpm = 120
    store.project.reconcileEstimatedRegions(); store.configureTransport(); settle()
    let gridBaseline = store.project
    try press("toggle-time-alignment",in:host)
    guard let meter = descendants(host).compactMap({$0 as? NSPopUpButton}).first(where:{$0.itemTitles == (1...12).map(String.init)}) else {
      throw WorkbenchError.message("Grid meter picker missing")
    }
    meter.selectItem(withTitle:"3"); meter.menu?.performActionForItem(at:meter.indexOfSelectedItem); settle()
    type("150",into:try input("100"),window:window)
    type("-0.25",into:try input("小節起點"),window:window)
    try check(store.project == gridBaseline, "meter / BPM / origin all remain pending")
    try press("apply-alignment",in:host)
    try check(store.project.estimatedGrid?.numerator == 3 && store.project.timing.bpm == 150
      && store.project.timing.seconds(at:0) == -0.25, "meter / BPM / origin apply together")
    try check(store.project.archivedRegions.contains {$0.annotation.rootLocked}, "meter rebuild retains locked blanks in history")
    store.undo(); settle()
    try check(store.project == gridBaseline, "one undo restores grid identity and human data")
    try press("toggle-time-alignment",in:host)
    store.project = scoreBaseline; store.configureTransport(); settle()
  }

  @MainActor static func practiceInterfaceTests(window: NSWindow, host: NSView, store: WorkbenchStore,
    worker: InterfaceAnalysisWorker, output: URL, livePlayback: Bool) throws {
    try check(accessibilityElements(host).contains { axRead($0, "accessibilityIdentifier") as? String == "playback-volume" }, "volume button exists in fixed transport")
    try press("metronome-toggle", in: host)
    try check(store.project.practice.metronome, "actual metronome toggle sets preference")
    try check(NSImage(systemSymbolName:"metronome",accessibilityDescription:nil) != nil, "traditional metronome symbol available")
    let toggle = accessibilityElements(host).first { axRead($0, "accessibilityIdentifier") as? String == "metronome-toggle" }
    try check(toggle.flatMap { axRead($0, "accessibilityValue") as? String } == "開啟", "icon toggle exposes enabled state")
    for width in [1280,1120] {
      window.setContentSize(NSSize(width:width,height:width == 1120 ? 780 : 920)); settle()
      try press("playback-volume", in:host)
      prepareAccessibility(); settle()
      guard let panel = NSApplication.shared.windows.first(where: { w in
        w !== window && accessibilityElements(w).contains { axRead($0, "accessibilityIdentifier") as? String == "playback-volume-panel" }
      }), let panelView = panel.contentView else { throw WorkbenchError.message("Volume popover missing") }
      try capture(panelView, to:output.appendingPathComponent("t08-volume-\(width).png"))
      let elements = accessibilityElements(panel)
      for id in ["music-volume","metronome-volume"] {
        try check(elements.contains { axRead($0, "accessibilityIdentifier") as? String == id }, "independent \(id) slider at \(width)")
      }
      let sliders = descendants(panelView).compactMap { $0 as? NSSlider }
      try check(sliders.count == 2, "two native volume sliders")
      // SwiftUI 的原生 slider 可將值正規化為 0–1；以行的順序及範圍比例操作。
      for (slider,fraction) in zip(sliders,[0.25,1.0]) {
        slider.doubleValue = slider.minValue + fraction * (slider.maxValue - slider.minValue)
        slider.sendAction(slider.action, to:slider.target)
      }
      settle()
      try check(store.project.practice.musicVolume == 0.25 && store.project.practice.volume == 1.5,
        "native sliders update both levels including boosted maximum")
      // 原生 action 不模擬完整拖曳結束，明確保存後再驗證專案往返。
      store.persist()
      try check(try ProjectStore.load(store.folder).practice == store.project.practice, "volume settings save together")
      try capture(panelView, to:output.appendingPathComponent("t08-volume-\(width).png"))
      try press("playback-volume", in:host)
      try capture(host, to:output.appendingPathComponent("t08-icon-\(width).png"))
    }
    guard let picker = descendants(host).compactMap({ $0 as? NSPopUpButton }).first(where: {
      $0.itemTitles.contains(where: { $0.contains("無預備") })
    }) else { throw WorkbenchError.message("Native count-in picker missing") }
    guard let oneBar = picker.itemArray.first(where: { $0.title == "1 小節" }) else {
      throw WorkbenchError.message("Count-in menu entries: \(picker.itemTitles)")
    }
    picker.select(oneBar)
    picker.menu?.performActionForItem(at: picker.indexOfSelectedItem)
    settle()
    try check(store.project.practice.countInBars == 1, "actual picker selects one preparation bar")
    store.setMetronomeVolume(0.15)
    let saved = store.project.practice
    try check(try ProjectStore.load(store.folder).practice == saved, "practice settings persist in project")
    store.setCountInBars(4); store.setMetronomeVolume(.nan); store.setMetronomeVolume(1.51)
    store.setMusicVolume(-0.1); store.setMusicVolume(.nan)
    try check(store.project.practice == saved, "invalid practice preferences rejected")
    try capture(host, to: output.appendingPathComponent("t08-controls-1120.png"))
    if livePlayback {
      store.setLoopEnabled(false); store.navigate(0)
      try press("play-pause", in: host)
      try check(store.transport.countingIn && store.transport.position == 0, "UI play starts click-only preparation at held position")
      let status = accessibilityElements(host).filter { axRead($0, "accessibilityIdentifier") as? String == "count-in-status" }
      let statusText = status.flatMap { e in ["accessibilityValue","accessibilityLabel"].compactMap { axRead(e,$0) as? String } }.joined()
      try check(statusText.contains("預備中") && !statusText.contains("尚餘") && !statusText.contains("剩餘"), "preparation status has no remaining beat text")
      try capture(host, to: output.appendingPathComponent("t09-countdown-1120.png"))
      try press("play-pause", in: host)
      try check(!store.transport.playing && store.transport.resources.clickBuffersQueued == 0, "UI pause cancels preparation queues")
      try press("play-pause", in: host)
      let task = store.estimateTempo()
      let deadline = Date().addingTimeInterval(5)
      while worker.pending == nil && Date() < deadline { settle() }
      try check(store.analysisRunning && !store.transport.playing && !store.transport.countingIn,
                "analysis cancels preparation without starting music")
      store.cancel()
      while store.busy && Date() < deadline { settle() }
      settle()
      withExtendedLifetime(task) {}
      try press("play-pause", in: host)
      store.setPlaybackRate(0.75)
      try check(!store.transport.playing && !store.transport.countingIn, "rate change cancels preparation")
      store.setPlaybackRate(1)
    }
    picker.selectItem(withTitle: "無預備")
    picker.menu?.performActionForItem(at: picker.indexOfSelectedItem)
    settle()
    try press("metronome-toggle", in: host)
    try check(!store.project.practice.metronome && store.project.practice.countInBars == 0, "practice controls restore off / no preparation")
    store.setMusicVolume(1)
    // 取消估測會清掉候選；為後面的既有多譜／候選回歸重新建立其前置資料。
    let restored = store.estimateTempo()
    let deadline = Date().addingTimeInterval(5)
    while worker.pending == nil && Date() < deadline { settle() }
    worker.finish(failing: false)
    while store.busy && Date() < deadline { settle() }
    settle()
    withExtendedLifetime(restored) {}
  }

  @MainActor static func multiScoreInterfaceTests(window: NSWindow, host: NSView,
                                                  store: WorkbenchStore, output: URL,
                                                  livePlayback: Bool) throws {
    window.setContentSize(NSSize(width: 1280, height: 920))
    try press("分析來源與專案", matchingLabel: true, in: host)
    store.transport.stop()
    store.navigate(0)
    let a = store.project.activeContextID
    let aRevision = store.project.score!.revision
    let original = try String(contentsOf: store.folder.appendingPathComponent(store.project.score!.xmlPath), encoding: .utf8)
    let bFile = store.folder.appendingPathComponent("score.musicxml")
    try original.replacingOccurrences(of: "<step>E</step>", with: "<step>G</step>")
      .write(to: bFile, atomically: true, encoding: .utf8)
    var imported = false
    Task { await store.importScore(bFile)?.value; imported = true }
    let deadline = Date().addingTimeInterval(20)
    while !imported && Date() < deadline { settle() }
    try check(imported && store.error == nil, "second score actually imports into visible Store")
    let b = store.project.activeContextID
    let bRevision = store.project.score!.revision
    guard let web = descendants(host).compactMap({ $0 as? WKWebView }).first else {
      throw WorkbenchError.message("T10 WKWebView missing")
    }
    try waitForScore(web, measure: 1)
    try check((try javascript("xmlRevision", in: web) as? String) == bRevision,
              "actual renderer follows B reference")
    try check(store.firstScoreNote?.name == "G1", "visible score and first-note reference use B")
    try check(descendants(host).compactMap { $0 as? WKWebView }.count == 1,
              "one WKWebView serves all reference scores")
    _ = try javascript("void(window.oldScoreButton=document.querySelector('#hotspots button[aria-label=\"第 2 小節\"]'))", in: web)
    _ = store.selectScore(id: a)
    settle()
    try waitForScore(web, measure: 1)
    _ = try javascript("window.oldScoreButton.click();window.oldScoreButton=null", in: web)
    settle()
    try check(store.project.selectedMeasure == 0,
              "queued old DOM button retains its own revision and cannot seek a different score")
    _ = store.selectScore(id: b)
    if livePlayback {
      store.playPause()
      try check(store.transport.playing, "music plays before reference switch")
    }
    _ = store.selectScore(id: a)
    if livePlayback { try check(!store.transport.playing, "reference switch pauses actual audio") }
    for _ in 0..<8 {
      _ = store.selectScore(id: a)
      _ = store.selectScore(id: b)
    }
    settle()
    try waitForScore(web, measure: 1)
    try check((try javascript("xmlRevision", in: web) as? String) == bRevision,
              "rapid alternating references settle on latest document")
    _ = try javascript("tell({type:'measure',index:5,revision:'\(aRevision)'})", in: web)
    settle()
    try check(store.project.selectedMeasure == 0, "old document click cannot navigate new reference")
    try press("manage-scores", in: host)
    settle()
    guard let sheet = window.sheets.first, let sheetHost = sheet.contentView else {
      throw WorkbenchError.message("Score manager sheet missing")
    }
    prepareAccessibility()
    try capture(sheetHost, to: output.appendingPathComponent("t10-readable-names.png"))
    let labels = accessibilityElements(sheetHost).flatMap { element in
      ["accessibilityLabel", "accessibilityValue"].compactMap { axRead(element, $0) as? String }
    }.joined(separator: "\n")
    try check(labels.contains("score.musicxml") && labels.contains("score.musicxml（1）") && !labels.contains("score.musicxml（2）"),
              "actual manager displays readable same-name numbering: \(labels)")
    try check(labels.contains("匯入時間未記錄") && labels.contains("匯入於 "),
              "manager distinguishes legacy unknown date from genuinely new import")
    let currentHelp = store.project.referenceScoreHelp
    try check(accessibilityElements(host).contains { (axRead($0, "accessibilityHelp") as? String) == currentHelp },
              "reference picker exposes full current name and import date as help")
    try press("remove-score-\(a)", in: sheetHost)
    try check(store.project.activeContextID == b && store.project.removedScoreContexts.count == 1,
              "actual manager removes non-reference score without switching")
    try press("remove-score-\(b)", in: sheetHost)
    settle()
    try check(store.project.score == nil, "actual manager removes final score into grid")
    let clearDeadline = Date().addingTimeInterval(10)
    while ((try? javascript("osmd===null && document.querySelectorAll('#hotspots button').length===0", in: web)) as? Bool) != true,
      Date() < clearDeadline { settle() }
    try check((try javascript("osmd===null && xmlRevision==='' && document.querySelector('#score').children.length===0", in: web) as? Bool) == true,
              "staging last removal releases renderer, SVG and hotspots")
    try press("close-score-manager", in: sheetHost)
    try check(store.project.removedScoreContexts.count == 2 && window.sheets.count == 1,
              "Done asks before discarding staged work")
    try press("cancel-score-removal", in: sheetHost)
    try check(store.project.removedScoreContexts.count == 2 && window.sheets.count == 1,
              "cancel confirmation keeps pending data and manager open")
    try press("restore-score-\(a)", in: sheetHost)
    try press("select-score-\(a)", in: sheetHost)
    settle()
    try waitForScore(web, measure: 1)
    try check((try javascript("xmlRevision", in: web) as? String) == aRevision && store.firstScoreNote?.name == "E1",
              "cancel removal and select restores reference before final confirmation")
    try press("remove-score-\(a)", in: sheetHost)
    try press("close-score-manager", in: sheetHost)
    try capture(sheetHost, to: output.appendingPathComponent("t10-removal-confirmation-1280.png"))
    try press("confirm-score-removal", in: sheetHost)
    settle()
    try check(window.sheets.isEmpty && store.project.scoreContexts.count == 1
              && store.project.availableScoreContexts.isEmpty && store.project.removedScoreContexts.isEmpty,
              "confirmation closes manager and permanently drops both score work contexts")
    let reimport = store.folder.appendingPathComponent("reimport.musicxml")
    try original.write(to: reimport, atomically: true, encoding: .utf8)
    imported = false
    Task { await store.importScore(reimport)?.value; imported = true }
    let reimportDeadline = Date().addingTimeInterval(20)
    while !imported && Date() < reimportDeadline { settle() }
    settle()
    try waitForScore(web, measure: 1)
    try check(imported && store.project.activeContextID != a && store.firstScoreNote?.name == "E1"
              && store.project.regions.allSatisfy { $0.annotation == HumanAnnotation() && $0.evidence == nil },
              "reimport after confirmation displays a new clean reference")
    try capture(host, to: output.appendingPathComponent("t10-reference-1280.png"))
    window.setContentSize(NSSize(width: 1120, height: 780))
    settle()
    try press("manage-scores", in: host)
    settle()
    try check(window.sheets.first?.frame.width ?? 0 >= 500, "score manager fits minimum window")
    if let sheetHost = window.sheets.first?.contentView {
      try capture(sheetHost, to: output.appendingPathComponent("t10-manager-1120.png"))
      try press("close-score-manager", in: sheetHost)
    }
    settle()
    try check(window.sheets.isEmpty, "Done without pending removals closes without confirmation")
    print("PASS T10 actual UI manager / switch / restore / rapid loads / stale clicks / renderer release")
  }

  @MainActor static func tempoSplitControl(
    host: NSView, store: WorkbenchStore, worker: InterfaceAnalysisWorker, width: Int
  ) throws {
    func control(_ id: String, in root: NSObject) -> NSObject? {
      accessibilityElements(root).first { axRead($0, "accessibilityIdentifier") as? String == id }
    }
    func switchModel(to model: String, current: String) throws {
      try press("tempo-model", in: host)
      let id = "tempo-model-\(model)"
      let roots: [NSObject] = [host] + NSApplication.shared.windows.map { $0 as NSObject }
      guard let popup = roots.first(where: { control(id, in: $0) != nil }) else {
        for window in NSApplication.shared.windows {
          print("WINDOW \(window.isVisible) \(window.frame)")
          for element in accessibilityElements(window) {
            let identifier = axRead(element, "accessibilityIdentifier") ?? ""
            let label = axRead(element, "accessibilityLabel") ?? ""
            if "\(identifier) \(label)".contains("tempo") || "\(label)".contains("估測")
                || "\(label)".contains("small0") || "\(label)".contains("librosa") {
              print("AX \(Swift.type(of: element)) \(identifier) \(label)")
            }
          }
        }
        fflush(stdout)
        throw WorkbenchError.message("Model popover missing \(id)")
      }
      try check(control("tempo-current-model", in: popup) != nil
                  && control("tempo-model-\(current)", in: popup) == nil,
                "current model is marked and excluded from actions at \(width)")
      try press(id, in: popup)
      let deadline = Date().addingTimeInterval(3)
      while worker.pending == nil && Date() < deadline { settle() }
      try check(store.analysisRunning && worker.pending != nil && worker.estimator == model,
                "choosing another model starts its request at \(width), selected \(store.tempoEstimator), "
                + "busy \(store.busy), worker \(worker.estimator), status \(store.status)")
    }
    try switchModel(to: "small0", current: "librosa")
    settle()
    let hasTitle = control("setup-progress-title", in: host) != nil
    let hasCancel = control("cancel-analysis", in: host) != nil
    try check(store.showsSetupProgress && hasTitle && hasCancel,
              "estimation shows progress and cancellation at \(width), title \(hasTitle), cancel \(hasCancel)")
    worker.finish(failing: false)
    settle()
    try check(control("tempo-option-0", in: host) != nil
                && store.currentTempoEstimate?.estimator == "small0",
              "switched model result displays candidates at \(width)")
    try switchModel(to: "librosa", current: "small0")
    worker.finish(failing: false, empty: true)
    settle()
    try check(control("tempo-no-candidates", in: host) != nil && !store.busy,
              "completed estimate without candidates shows an explicit message at \(width)")
    try press("estimate-tempo", in: host)
    let deadline = Date().addingTimeInterval(3)
    while worker.pending == nil && Date() < deadline { settle() }
    try check(store.analysisRunning && worker.estimator == "librosa",
              "primary button repeats the current model at \(width)")
    worker.finish(failing: false)
    settle()
  }

  @MainActor static func fixture(worker: AnalysisRequesting = AnalysisWorker()) throws -> WorkbenchStore {
    let preference = UserDefaults(suiteName:"local.bassworkbench.interface.tempo")!
    preference.removeObject(forKey:"tempo.lastSuccessfulModel")
    let store = WorkbenchStore(worker:worker,optionalTempoWorker:worker,preferences:preference,
      installation:Small0Installation(python:"/usr/bin/true",checkpoint:"/dev/null"))
    let audio = store.folder.appendingPathComponent("synthetic.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050 * 134)!
    buffer.frameLength = buffer.frameCapacity
    buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
    do {
      let file = try AVAudioFile(forWriting: audio, settings: format.settings)
      try file.write(from: buffer)
    }
    let measures = (1...134).map {
      "<measure number='\($0)'>\($0 == 1 ? "<attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>F</sign><line>4</line></clef></attributes>" : "")<note><pitch><step>E</step><octave>1</octave></pitch><duration>4</duration><type>whole</type></note></measure>"
    }.joined()
    let xml =
      "<?xml version='1.0' encoding='UTF-8'?>\n<score-partwise version='4.0'><part-list><score-part id='P1'><part-name>Bass</part-name></score-part></part-list><part id='P1'>\(measures)</part></score-partwise>"
    try Files.directory(store.folder.appendingPathComponent("originals"))
    try Data(xml.utf8).write(to: store.folder.appendingPathComponent("originals/fixture.musicxml"))
    store.project.title = "介面回歸測試（合成音）"
    store.project.score = try ScoreIO.parse(Data(xml.utf8), xmlPath: "originals/fixture.musicxml")
    store.project.selectedStaff = store.project.score!.staves[0].id
    store.project.timing.bpm = 240
    let asset = MediaAsset(
      role: "original", name: "synthetic.wav", originalPath: "synthetic.wav",
      pcmPath: "synthetic.wav", hash: try Files.hash(audio), duration: 134, sampleRate: 22050,
      channels: 1)
    store.project.assets = [asset]
    store.project.selectedAsset = asset.id
    store.project.regions = store.project.measures.map {
      HarmonyRegion(measureID: $0.id, startBeat: $0.beat, endBeat: $0.end)
    }
    try store.transport.load(audio)
    store.waveform = WaveformData(peaks: Array(repeating: 0, count: 13400), duration: 134)
    store.configureTransport()
    store.zoomMeasure()
    store.persist()
    return store
  }
}

/// 僅控制估測回傳時機；譜面與播放仍使用真正的 WebKit／AVAudioEngine。
final class InterfaceAnalysisWorker: AnalysisRequesting {
  var pending: CheckedContinuation<Data, Error>?
  var estimator = "librosa"
  var sourceHash = "synthetic"
  var fitStatus = "good"
  func request(_ values: [String: Any], cacheRoot: URL,
               progress: @escaping (Double, String) -> Void) async throws -> Data {
    sourceHash = (values["asset"] as? [String: Any])?["hash"] as? String ?? "synthetic"
    estimator = values["estimator"] as? String ?? "librosa"
    return try await withCheckedThrowingContinuation { pending = $0 }
  }
  func finish(failing: Bool, empty: Bool = false) {
    let continuation = pending
    pending = nil
    if failing { continuation?.resume(throwing: WorkbenchError.message("可控估測失敗")) }
    else {
      continuation?.resume(with: Result {
        let poor = fitStatus == "poor"
        let fit = TempoFit(intercept: 0.5, medianMs: poor ? 40 : 4, p95Ms: poor ? 80 : 8,
          maxMs: poor ? 95 : 12, driftMs: poor ? 50 : 1,
          count: 20, span: 10, coverage: 1, outlierFraction: poor ? 0.5 : 0, status: fitStatus)
        let candidate = TempoCandidate(bpm: 120, originalBPM: poor ? 120 : 120.04, quantizedBPM: 120,
          usedFloat: poor, multiplier: 1, fit: fit, quantizedFit: fit, originalFit: fit)
        var estimate = TempoEstimate(bpm: empty ? nil : 120, alternatives: empty ? [] : [60, 120, 240], beats: [],
          start: 0, end: 12, sourceHash: sourceHash, method: "ui-probe", warnings: [], candidates: empty ? [] : [candidate])
        estimate.estimator = estimator
        if estimator == "small0" { estimate.weightsHash = Small0Installation.weightsHash }
        return try JSONEncoder().encode(estimate)
      })
    }
  }
  func cancel() {
    let continuation = pending
    pending = nil
    continuation?.resume(throwing: CancellationError())
  }
}
