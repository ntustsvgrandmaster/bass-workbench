import Foundation

@main struct EditingTests {
  static var assertions = 0
  static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    assertions += 1
    if try !value() { throw WorkbenchError.message("TEST FAILED: \(message)") }
  }
  @MainActor static func main() throws {
    guard let root = ProcessInfo.processInfo.environment["BASS_DATA_ROOT"], !root.isEmpty else {
      throw WorkbenchError.message("Specify BASS_DATA_ROOT for disposable test data")
    }
    let store = WorkbenchStore()
    store.project.assets = [
      MediaAsset(
        role: "original", name: "synthetic", originalPath: "synthetic.wav",
        pcmPath: "synthetic.wav", hash: "fixture", duration: 300, sampleRate: 22050, channels: 1)
    ]
    store.project.selectedAsset = store.project.assets[0].id
    store.project.timing.bpm = 120
    store.project.regions = store.project.measures.map {
      HarmonyRegion(measureID: $0.id, startBeat: $0.beat, endBeat: $0.end)
    }
    let annotations = store.project.regions.map(\.annotation)
    var loop = LoopDraft()
    loop.reset(a: store.project.a, b: store.project.b)
    loop.a = "8"
    try check(
      loop.validation == nil && store.error == nil, "intermediate A>B does not warn while typing")
    try check(store.project.a == 0 && store.project.b == 4, "typing never writes endpoints")
    loop.b = "12"
    try check(loop.apply(to: store), "A and B commit together after complete input")
    try check(store.project.a == 8 && store.project.b == 12, "valid pair replaces both endpoints")
    for pair in [
      ("", "12"), ("abc", "12"), ("9", "8"), ("-1", "12"),
      ("NaN", "12"), ("8", "inf"), ("8", "8.01"), ("0", "181"), ("299", "301"),
    ] {
      loop.a = pair.0
      loop.b = pair.1
      try check(
        !loop.apply(to: store) && loop.validation != nil,
        "invalid draft reports inline validation: \(pair)")
      try check(
        store.project.a == 8 && store.project.b == 12 && store.error == nil,
        "invalid draft preserves project without alert")
    }
    loop.reset(a: store.project.a, b: store.project.b)
    try check(
      loop.a == "8.000" && loop.b == "12.000" && loop.validation == nil,
      "cancel restores applied endpoints")
    loop.a = " 9.125 "
    loop.b = " 14.875 "
    try check(
      loop.apply(to: store) && store.project.a == 9.125 && store.project.b == 14.875,
      "decimal seconds and surrounding spaces accepted")
    store.setLoop(a: 0, b: 180)
    loop.reset(a: store.project.a, b: store.project.b)
    try check(loop.apply(to: store), "exact 180-second loop accepted")

    let original = store.project.title
    var title = ProjectTitleDraft()
    try check(!title.editing, "name starts as non-editable text")
    title.begin(in: store)
    try check(
      title.editing && title.text == original && store.editingPlaybackSelection,
      "edit begins with existing name and protects selection")
    title.text = "discard this"
    title.cancel(in: store)
    try check(
      !title.editing && !store.editingPlaybackSelection && store.project.title == original,
      "cancel discards draft and exits editing")
    title.begin(in: store)
    try check(title.text == original, "reopening editor does not retain canceled text")
    title.text = " \n "
    try check(
      !title.save(to: store) && title.invalid && title.editing,
      "empty name remains in editor with validation")
    try check(
      store.project.title == original && store.error == nil,
      "invalid name does not persist or alert")
    title.text = "  新名稱  "
    try check(title.save(to: store), "valid title commits")
    try check(
      store.project.title == "新名稱" && !title.editing && !store.editingPlaybackSelection,
      "save trims text and leaves editing mode")
    let saved = try ProjectStore.load(store.folder)
    try check(saved.title == "新名稱", "title saved to disk")
    store.undo()
    try check(store.project.title == original, "one undo restores full name")
    store.redo()
    try check(store.project.title == "新名稱", "redo restores saved name")
    title.begin(in: store)
    title.text = "not committed"
    store.busy = true
    try check(
      !title.save(to: store) && store.project.title == "新名稱", "busy state cannot commit a title")
    store.busy = false
    title.cancel(in: store)
    try check(
      store.project.regions.map(\.annotation) == annotations, "editing drafts preserve annotations")
    print(
      "PASS editing drafts: \(assertions) assertions (incomplete input / validation / cancel / commit / undo / disk save)"
    )
  }
}
