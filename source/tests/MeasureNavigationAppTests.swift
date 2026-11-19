import AppKit
import AVFoundation
import SwiftUI

/// 與產品相同的 SwiftUI App／StateObject 生命週期；NSHostingView 測試無法重現的格子刷新問題。
@main struct MeasureNavigationAppTests: App {
  @StateObject private var store = WorkbenchStore()
  @State private var started = false

  var body: some Scene {
    Window("小節導覽 · 完整 App 回歸", id: "navigation-app-test") {
      WorkbenchView().environmentObject(store).onAppear {
        guard !started else { return }
        started = true
        Task { @MainActor in
          do {
            try await verify()
            print("PASS navigation App: selection pixels / BPM / bias / grid / undo / playback / T03 viewport / two sizes")
            fflush(stdout)
            exit(0)
          } catch {
            print("FAIL navigation App: \(error.localizedDescription)")
            fflush(stdout)
            exit(1)
          }
        }
      }
    }.defaultSize(width: 1280, height: 920).commands {
      CommandMenu("測試") {
        Button("暫停") { store.transport.stop() }.disabled(store.busy)
      }
    }
  }

  @MainActor private func settle() async throws {
    try await Task.sleep(nanoseconds: 200_000_000)
  }
  @MainActor private func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw WorkbenchError.message(message) }
  }
  @MainActor private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants($0) }
  }

  /// 檢查實際繪製的薄荷綠外框，不把 selectedMeasure 或 accessibility 回報當成畫面驗收。
  @MainActor private func outline(_ name: String, output: URL) throws -> CGRect {
    guard let content = NSApplication.shared.windows.first(where: { $0.isVisible })?.contentView,
      let navigator = descendants(content).compactMap({ $0 as? NSScrollView }).min(by: {
        $0.convert($0.bounds, to: content).minX < $1.convert($1.bounds, to: content).minX
      })
    else { throw WorkbenchError.message("Navigator scroll view missing") }
    let clip = navigator.contentView
    clip.displayIfNeeded()
    guard let bitmap = clip.bitmapImageRepForCachingDisplay(in: clip.bounds) else {
      throw WorkbenchError.message("Cannot capture navigator")
    }
    clip.cacheDisplay(in: clip.bounds, to: bitmap)
    let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
    // 統一色彩／alpha 格式；NSBitmapImageRep.colorAt 對 layer-backed 快取的格式並不一致。
    guard let image = bitmap.cgImage,
      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    else { throw WorkbenchError.message("Cannot read navigator pixels") }
    context.setFillColor(CGColor(red: 0.05, green: 0.08, blue: 0.10, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    if let rendered = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) {
      try png.write(to: output.appendingPathComponent(name + ".png"))
    }
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
      for x in 0..<width {
        let offset = (y * width + x) * 4
        let r = Double(pixels[offset]), g = Double(pixels[offset + 1]), b = Double(pixels[offset + 2])
        if g > 153, b > 100, g > r * 1.5, g > b * 1.1 {
          minX = min(minX, x); maxX = max(maxX, x)
          minY = min(minY, y); maxY = max(maxY, y)
        }
      }
    }
    try check(maxX >= minX && maxY >= minY, "No green selection outline: \(name)")
    let scale = CGFloat(bitmap.pixelsHigh) / clip.bounds.height
    return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                  width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
  }

  @MainActor private func verify() async throws {
    guard let root = ProcessInfo.processInfo.environment["BASS_DATA_ROOT"], !root.isEmpty else {
      throw WorkbenchError.message("Specify disposable BASS_DATA_ROOT")
    }
    let output = URL(fileURLWithPath: root).appendingPathComponent("results")
    try Files.directory(output)
    let audio = store.folder.appendingPathComponent("synthetic.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050 * 210)!
    buffer.frameLength = buffer.frameCapacity
    buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
    do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
    let asset = MediaAsset(role: "original", name: "synthetic.wav", originalPath: "synthetic.wav",
      pcmPath: "synthetic.wav", hash: try Files.hash(audio), duration: 210, sampleRate: 22050, channels: 1)
    store.project.assets = [asset]
    store.project.selectedAsset = asset.id
    try store.transport.load(audio)
    store.configureTransport()
    store.waveform = WaveformData(peaks: Array(repeating: 0, count: 2100), duration: 210)
    store.project.reconcileEstimatedRegions()
    store.zoomMeasure()
    try await settle()
    let uncalibratedFirst = try outline("uncalibrated-first", output: output)
    store.navigate(3, scrollNavigation: false)
    try await settle()
    let uncalibratedFourth = try outline("uncalibrated-fourth", output: output)
    try check(abs(abs(uncalibratedFourth.midY - uncalibratedFirst.midY) - 39) < 2,
              "Outline stuck before any BPM/bias adjustment")
    store.navigate(0)
    try check(store.applyEstimatedGrid(GridInput(bpm: 191.4062, numerator: 4, denominator: 4,
                                                firstBar: 0.044)), "Apply initial grid")
    var timing = store.project.timing
    try timing.setBias(-0.044)
    try check(store.applyAlignment(timing), "Apply initial bias")
    store.project.regions[0].annotation = HumanAnnotation(root: "", rootLocked: true)
    let annotations = store.project.regions.map(\.annotation)
    try await settle()

    for (width, height) in [(1280, 920), (1120, 780)] {
      NSApplication.shared.windows.first(where: { $0.isVisible })?.setContentSize(NSSize(width: width, height: height))
      store.navigate(0)
      try await settle()
      let first = try outline("\(width)-first", output: output)
      for index in [3, 6, 9, 3] {
        store.navigate(index, scrollNavigation: false)
        try await settle()
        let selected = try outline("\(width)-selected-\(index)", output: output)
        try check(store.project.selectedMeasure == index, "Model target differs: \(index)")
        try check(abs(abs(selected.midY - first.midY) - CGFloat(index / 3) * 39) < 2
                  && abs(selected.midX - first.midX) < 2 && selected.height < 36,
                  "Green outline stuck or duplicated after selecting \(index + 1): first=\(first) selected=\(selected)")
      }
      for bpm in [190.0, 191.4062] {
        store.setBPM(bpm)
        var changed = store.project.timing
        try changed.setBias(changed.bias + 0.01)
        try check(store.applyAlignment(changed), "BPM/bias change accepted")
        store.navigate(6, scrollNavigation: false)
        try await settle()
        let selected = try outline("\(width)-bpm-\(bpm)", output: output)
        try check(abs(abs(selected.midY - first.midY) - 78) < 2 && selected.height < 36,
                  "Outline differs after BPM/bias change")
      }
      store.undo()
      store.navigate(3, scrollNavigation: false)
      try await settle()
      let undone = try outline("\(width)-undo", output: output)
      try check(abs(abs(undone.midY - first.midY) - 39) < 2, "Outline differs after undo")
      let gridID = store.project.estimatedGrid?.id
      try check(store.applyEstimatedGrid(GridInput(bpm: 191.4062, numerator: 3, denominator: 4,
                                                  firstBar: 0)), "Replace meter/grid")
      try check(store.project.estimatedGrid?.id != gridID, "Grid identity actually changes")
      store.navigate(3, scrollNavigation: false)
      try await settle()
      let replaced = try outline("\(width)-new-grid", output: output)
      try check(abs(abs(replaced.midY - first.midY) - 39) < 2, "Outline differs after new grid")
      store.undo()
      store.seek(store.project.timing.seconds(at: store.project.measures[6].beat) + 0.1)
      store.playPause()
      try await settle()
      store.transport.stop()
      try await settle()
      let played = try outline("\(width)-playback", output: output)
      try check(store.project.selectedMeasure == 6 && abs(abs(played.midY - first.midY) - 78) < 2,
                "Outline does not follow actual playback")
    }
    // 實際 SwiftUI App 中播放跨小節，同時保留手動取景；留一張完整畫面供核對時間刻度。
    store.navigate(0)
    store.zoomMeasure()
    store.zoom(4)
    let manualWidth = store.viewportEnd - store.viewportStart
    let manualStart = store.viewportStart
    store.seek(0.25)
    store.playPause()
    try await Task.sleep(nanoseconds: 1_600_000_000)
    try check(store.transport.playing && store.project.selectedMeasure > 0,
              "T03 actual App playback crosses a measure")
    try check(store.viewportMode == .manual(span: manualWidth)
              && abs(store.viewportEnd - store.viewportStart - manualWidth) < 1e-7
              && store.viewportStart == manualStart,
              "T03 actual App preserves zoom and framing across measure boundary")
    store.transport.stop()
    if let content = NSApplication.shared.windows.first(where: { $0.isVisible })?.contentView,
      let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
      content.cacheDisplay(in: content.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(
        to: output.appendingPathComponent("t03-manual-after-bar.png"))
    }
    store.zoomLoop()
    let pinned = ViewportRange(start: store.viewportStart, end: store.viewportEnd)
    store.seek(10)
    try await settle()
    try check(ViewportRange(start: store.viewportStart, end: store.viewportEnd) == pinned,
              "T03 actual App A/B framing remains pinned on seek")
    store.zoomMeasure()
    try check(store.viewportMode == .measure, "T03 actual App returns to measure mode")
    try check(store.project.regions.map(\.annotation) == annotations, "Navigation changes annotations")
    store.persist()
    let saved = try ProjectStore.load(store.folder)
    try check(saved.regions.map(\.annotation) == annotations, "Locked blank not preserved")
    store.transport.unload()
  }
}
