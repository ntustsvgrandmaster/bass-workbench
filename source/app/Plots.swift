// 自訂波形與音高能量圖。座標換算必須與 Worker 的秒／MIDI／每八度格數一致。

import AppKit
import CoreGraphics
import SwiftUI

enum Palette {
  static let background = Color(red: 0.047, green: 0.067, blue: 0.086)
  static let panel = Color(red: 0.075, green: 0.102, blue: 0.13)
  static let mint = Color(red: 0.44, green: 0.91, blue: 0.75)
  static let amber = Color(red: 1, green: 0.72, blue: 0.38)
  static let muted = Color(red: 0.57, green: 0.65, blue: 0.71)
}
enum WorkbenchPointer: Equatable {
  case arrow, action, text, range, grab, grabbing

  @available(macOS 15, *)
  var style: PointerStyle {
    switch self {
    case .arrow: return .default
    case .action: return .link
    case .text: return .horizontalText
    case .range: return .rectSelection
    case .grab: return .grabIdle
    case .grabbing: return .grabActive
    }
  }

  var cursor: NSCursor {
    switch self {
    case .arrow: return .arrow
    case .action: return .pointingHand
    case .text: return .iBeam
    case .range: return .crosshair
    case .grab: return .openHand
    case .grabbing: return .closedHand
    }
  }
}

struct DesktopPointer: ViewModifier {
  @Environment(\.isEnabled) private var enabled
  @State private var hovering = false
  let pointer: WorkbenchPointer

  func body(content: Content) -> some View {
    if #available(macOS 15, *) {
      content.pointerStyle(enabled ? pointer.style : .default)
    } else {
      content.onHover { inside in
        hovering = inside
        if inside { (enabled ? pointer.cursor : NSCursor.arrow).set() }
        else { restore(pointer) }
      }
      .onChange(of: enabled) { if hovering { (enabled ? pointer.cursor : NSCursor.arrow).set() } }
      .onChange(of: pointer) { _, value in if hovering && enabled { value.cursor.set() } }
      .onDisappear { if hovering { restore(pointer) } }
    }
  }

  private func restore(_ previous: WorkbenchPointer) {
    if NSCursor.current == previous.cursor { NSCursor.arrow.set() }
  }
}

struct ButtonFeedback: ViewModifier {
  enum Kind { case secondary, primary, navigation, icon, field, drag }

  @Environment(\.isEnabled) private var enabled
  @Environment(\.isFocused) private var focused
  @State private var hovering = false
  var border = Palette.mint
  var cornerRadius: CGFloat = 6
  var kind: Kind = .secondary
  var selected = false
  var dragging = false

  func body(content: Content) -> some View {
    content.onHover { hovering = $0 }
      .overlay {
        if enabled {
          let shape = RoundedRectangle(cornerRadius: cornerRadius)
          if focused {
            shape.strokeBorder(.white, lineWidth: 2)
              .padding(2)
              .background { shape.strokeBorder(Palette.background, lineWidth: 2) }
              .allowsHitTesting(false).accessibilityHidden(true)
          } else if hovering && !selected {
            if kind == .field {
              shape.strokeBorder(border.opacity(0.75), lineWidth: 1)
                .allowsHitTesting(false).accessibilityHidden(true)
            } else {
              shape.fill(border.opacity(hoverOpacity))
                .allowsHitTesting(false).accessibilityHidden(true)
            }
          }
        }
      }
      .modifier(DesktopPointer(pointer: pointer))
  }

  private var pointer: WorkbenchPointer {
    switch kind {
    case .field: return .text
    case .drag: return dragging ? .grabbing : .grab
    default: return .action
    }
  }
  private var hoverOpacity: Double {
    switch kind {
    case .primary: return 0.25
    case .navigation, .icon: return 0.17
    case .secondary, .drag: return 0.10
    case .field: return 0
    }
  }
}

extension View {
  func controlFeedback(_ kind: ButtonFeedback.Kind = .secondary, dragging: Bool = false) -> some View {
    modifier(ButtonFeedback(kind: kind, dragging: dragging))
  }
}

/// 在按鈕標籤內提供固定的辨識線索與命中區。
struct IconButtonFace: ViewModifier {
  @Environment(\.isEnabled) private var enabled
  var size: CGFloat = 28
  func body(content: Content) -> some View {
    content.frame(minWidth: size, minHeight: size)
      .background(.white.opacity(enabled ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 6))
      .contentShape(Rectangle())
  }
}

/// 保留原生按鈕的點擊、鍵盤與預設按鈕行為，只疊加指標回饋。
struct HoverButton<Base: PrimitiveButtonStyle>: PrimitiveButtonStyle {
  var base: Base
  var border = Palette.mint
  var kind: ButtonFeedback.Kind = .secondary
  var selected = false

  func makeBody(configuration: Configuration) -> some View {
    base.makeBody(configuration: configuration)
      .modifier(ButtonFeedback(border: border, kind: kind, selected: selected))
  }
}
struct ActionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) var enabled
  var primary = true

  func makeBody(configuration: Configuration) -> some View {
    let fill = primary ? Palette.mint : .white.opacity(0.10)
    let text = primary ? Palette.background : .white.opacity(0.85)
    return configuration.label.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).padding(
      .vertical, 8
    ).foregroundStyle(text.opacity(enabled ? 1 : 0.55)).background(
      fill.opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.2),
      in: RoundedRectangle(cornerRadius: 7))
      .modifier(ButtonFeedback(border: primary ? .white : Palette.mint, cornerRadius: 7,
                               kind: primary ? .primary : .secondary))
  }
}
/// 播放游標獨立觀察 Transport，讓高頻畫面更新不必重新計算整張 CQT。
struct Playhead: View {
  @ObservedObject var transport: Transport
  var start: Double, end: Double
  var body: some View {
    GeometryReader { geo in
      if transport.position >= start && transport.position <= end {
        Rectangle().fill(.white.opacity(0.85)).frame(width: 1).offset(
          x: TimelineCoordinates(start: start, end: end, width: geo.size.width).x(at: transport.position))
      }
    }.allowsHitTesting(false)
  }
}
private struct FirstBarGuide: View {
  var second: Double?
  var start: Double, end: Double
  var body: some View {
    Canvas { context, size in
      guard let second, second >= start, second <= end else { return }
      let x = TimelineCoordinates(start: start, end: end, width: size.width).x(at: second)
      var line = Path()
      line.move(to: CGPoint(x: x, y: 0))
      line.addLine(to: CGPoint(x: x, y: size.height))
      context.stroke(line, with: .color(.purple), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
    }.allowsHitTesting(false).accessibilityHidden(true)
  }
}
/// 短點擊定位。水平拖曳在起點草稿中移動取景，平時選取 A–B。
private func drawLoopBand(_ range: ViewportRange, in context: GraphicsContext,
                          coordinates: TimelineCoordinates, height: CGFloat) {
  let left = max(coordinates.inset, min(coordinates.width, coordinates.x(at: range.start)))
  let right = max(coordinates.inset, min(coordinates.width, coordinates.x(at: range.end)))
  let shade = Color.black.opacity(0.36)
  context.fill(Path(CGRect(x: coordinates.inset, y: 0, width: left - coordinates.inset, height: height)),
               with: .color(shade))
  context.fill(Path(CGRect(x: right, y: 0, width: coordinates.width - right, height: height)),
               with: .color(shade))
  if right > left {
    context.fill(Path(CGRect(x: left, y: 0, width: right - left, height: 2)),
                 with: .color(Palette.mint.opacity(0.75)))
  }
}

struct WaveformView: View {
  @Environment(\.isEnabled) private var enabled
  var waveform: WaveformData?
  var start: Double, end: Double, offset: Double, a: Double, b: Double
  var loop: ViewportRange?
  var audioEnd: Double
  @ObservedObject var transport: Transport
  var onSelect: (Double, Double) -> Void
  var onSeek: (Double) -> Void
  var firstBarPreview: Double?
  var previewMeasureStart: Double?
  var onDragFirstBar: (Double) -> Void
  @State private var calibrationStart: Double?
  @GestureState private var dragging = false
  @GestureState private var draggedLoop: ViewportRange?
  @State private var hoveringHandle = false
  var body: some View {
    GeometryReader { geo in
      ZStack {
        Canvas { context, size in
          let coordinates = TimelineCoordinates(start: start, end: end, width: size.width)
          let span = coordinates.span
          let displayedLoop = firstBarPreview == nil ? draggedLoop ?? loop : nil
          if let waveform, !waveform.peaks.isEmpty {
            let count = waveform.peaks.count
            var path = Path()
            for x in 0..<max(1, Int(size.width)) {
              let first = max(
                0,
                Int(
                  ((start - offset) + Double(x) / size.width * span) / waveform.duration
                    * Double(count)))
              let last = min(
                count,
                Int(
                  ((start - offset) + Double(x + 1) / size.width * span) / waveform.duration
                    * Double(count)))
              if first >= last { continue }
              var peak: Float = 0
              for i in first..<last { peak = max(peak, waveform.peaks[i]) }
              let height = min(size.height * 0.45, CGFloat(peak) * size.height * 0.7)
              path.move(to: CGPoint(x: CGFloat(x), y: size.height / 2 - height))
              path.addLine(to: CGPoint(x: CGFloat(x), y: size.height / 2 + height))
            }
            context.stroke(path, with: .color(Palette.mint.opacity(0.65)), lineWidth: 1)
          }
          if let displayedLoop { drawLoopBand(displayedLoop, in: context, coordinates: coordinates, height: size.height) }
          for (time, label) in [(displayedLoop?.start ?? a, "A"), (displayedLoop?.end ?? b, "B")]
            where time >= start && time <= end {
            let x = coordinates.x(at: time)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(Palette.amber), lineWidth: 1)
            let handleX = handleCenter(x, width: size.width)
            if displayedLoop != nil {
              context.fill(Path(roundedRect: CGRect(x: handleX - 9, y: 2, width: 18, height: 15), cornerRadius: 3),
                           with: .color(Palette.amber))
            }
            context.draw(Text(label).font(.system(size: 9, weight: .bold))
              .foregroundStyle(displayedLoop == nil ? Palette.amber : Palette.background),
              at: CGPoint(x: handleX, y: 9))
          }
        }
        Playhead(transport: transport, start: start, end: end)
        FirstBarGuide(second: previewMeasureStart, start: start, end: end)
        if loop == nil || firstBarPreview != nil {
          Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(6).allowsHitTesting(false).accessibilityHidden(true)
        }
      }.contentShape(Rectangle()).gesture(
        DragGesture(minimumDistance: 0)
          .updating($dragging) { value, dragging, _ in dragging = abs(value.translation.width) >= 5 }
          .updating($draggedLoop) { value, range, _ in
            if enabled, abs(value.translation.width) >= 5 {
              range = resizedLoop(from: value, width: geo.size.width)
            }
          }
          .onChanged { value in
          guard enabled, let firstBarPreview,
            abs(value.translation.width) >= 5 || calibrationStart != nil else { return }
          let origin = calibrationStart ?? firstBarPreview
          calibrationStart = origin
          onDragFirstBar(origin - value.translation.width / max(1, geo.size.width) * (end - start))
        }.onEnded { value in
          defer { calibrationStart = nil }
          guard enabled, calibrationStart == nil else { return }
          let x = max(0, min(geo.size.width, value.startLocation.x))
          let y = max(0, min(geo.size.width, value.location.x))
          let span = end - start
          if abs(value.translation.width) >= 5, let range = resizedLoop(from: value, width: geo.size.width) {
            if range != loop {
              onSelect(range.start, range.end)
            }
          } else if abs(x - y) < 5 {
            onSeek(start + y / max(1, geo.size.width) * span)
          } else if firstBarPreview == nil {
            onSelect(
              start + min(x, y) / geo.size.width * span, start + max(x, y) / geo.size.width * span)
          }
        }).onContinuousHover { phase in
          if enabled, case .active(let point) = phase {
            hoveringHandle = loopEndpoint(at: point, width: geo.size.width) != nil
          } else {
            hoveringHandle = false
          }
        }
    }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 9))
      .modifier(DesktopPointer(pointer: firstBarPreview != nil || hoveringHandle || draggedLoop != nil
        ? (dragging ? .grabbing : .grab) : .range))
      .help(firstBarPreview == nil ? "點擊定位，拖曳選取 A–B" : "點擊定位，左右拖曳微調起點草稿")
  }
  private func handleCenter(_ x: CGFloat, width: CGFloat) -> CGFloat {
    min(width - 9, max(9, x))
  }
  private func resizedLoop(from value: DragGesture.Value, width: CGFloat) -> ViewportRange? {
    guard let loop, let movesStart = loopEndpoint(at: value.startLocation, width: width) else { return nil }
    let coordinates = TimelineCoordinates(start: start, end: end, width: width)
    let delta = value.translation.width / coordinates.plotWidth * coordinates.span
    if movesStart {
      let lower = max(0, offset, loop.end - 180)
      let upper = max(loop.start, loop.end - 0.041)
      return ViewportRange(start: max(lower, min(upper, loop.start + delta)), end: loop.end)
    }
    let upper = min(audioEnd, loop.start + 180)
    let lower = min(loop.end, loop.start + 0.041)
    return ViewportRange(start: loop.start, end: min(upper, max(lower, loop.end + delta)))
  }
  private func loopEndpoint(at point: CGPoint, width: CGFloat) -> Bool? {
    guard firstBarPreview == nil, let loop, point.y <= 20 else { return nil }
    let coordinates = TimelineCoordinates(start: start, end: end, width: width)
    func distance(to time: Double) -> CGFloat {
      guard time >= start, time <= end else { return .infinity }
      return abs(point.x - handleCenter(coordinates.x(at: time), width: width))
    }
    let aDistance = distance(to: loop.start)
    let bDistance = distance(to: loop.end)
    guard min(aDistance, bDistance) <= 11 else { return nil }
    return aDistance <= bDistance
  }
}

struct SpectrogramView: View {
  @Environment(\.isEnabled) private var enabled
  var segments: [SpectrumData]
  var loading: Bool
  var showPitchGuide: Bool
  var a: Double, b: Double
  var loop: ViewportRange?
  var start: Double, end: Double, contrast: Double
  var notes: [ScoreNote]
  var measures: [ScoreMeasure]
  var timing: TimingMap
  var minMIDI: Int, maxMIDI: Int
  var showNotes: Bool, showOnsets: Bool, showGrid: Bool
  var firstBarPreview: Double?
  @ObservedObject var transport: Transport
  var onSelect: (Double, Double) -> Void
  var onSeek: (Double) -> Void
  var onNote: (ScoreNote) -> Void
  @State private var hover: String = ""
  private let axis: Double = 44
  // CQT 每一格的中心對應固定音高。上下邊界各加半格，才能讓譜面白框與能量列對齊。
  private var binWidth: Double { 12 / Double(segments.first?.metadata.binsPerOctave ?? 12) }
  private var pitchTop: Double { Double(maxMIDI) + binWidth / 2 }
  private var pitchRange: Double { Double(maxMIDI - minMIDI) + binWidth }
  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .topLeading) {
        // 彩色背景由 SpectrumData 快取；Canvas 只負責疊上拍點、起音及原譜音符。
        if !segments.isEmpty {
          Canvas { context, size in
            let width = max(1, size.width - axis)
            let height = max(1, size.height - 22)
            let coordinates = TimelineCoordinates(start: start, end: end, width: size.width, inset: axis)
            let span = coordinates.span
            for data in segments.reversed() {
              let left = max(start, data.metadata.start)
              let right = min(end, data.metadata.end)
              guard right > left, let image = data.render(contrast: contrast) else { continue }
              let step = Double(data.metadata.hop) / data.metadata.sampleRate
              let origin = data.metadata.frameOrigin - step / 2
              var tile = context
              let clipX = coordinates.x(at: left)
              tile.clip(to: Path(CGRect(
                x: clipX, y: 0, width: coordinates.x(at: right) - clipX, height: height)))
              tile.draw(
                Image(decorative: image, scale: 1).interpolation(.none),
                in: CGRect(
                  x: coordinates.x(at: origin), y: 0,
                  width: Double(data.metadata.columns) * step / span * width, height: height))
            }
          }
        } else if !loading {
          VStack(spacing: 10) {
            Image(systemName: "waveform.path").font(.title2)
            Text(firstBarPreview == nil ? "目前範圍尚無能量資料" : "校正範圍尚無能量資料")
              .font(.caption)
          }.foregroundStyle(Palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        Canvas { context, size in
          let width = size.width - axis
          let height = size.height - 22
          let coordinates = TimelineCoordinates(start: start, end: end, width: size.width, inset: axis)
          let span = coordinates.span
          let range = pitchRange
          if let loop { drawLoopBand(loop, in: context, coordinates: coordinates, height: height) }
          for pitch in minMIDI...maxMIDI {
            let y = (pitchTop - Double(pitch)) / range * height
            if (pitch % 12 == 0 && pitch - minMIDI > 2) || pitch == 28 || pitch == minMIDI {
              context.draw(
                Text(Pitch.name(pitch)).font(.system(size: 9, design: .monospaced)).foregroundStyle(
                  Palette.muted), at: CGPoint(x: 22, y: y))
            }
          }
          if showGrid {
            let first = Int(timing.beat(at: start).rounded(.up))
            let last = Int(timing.beat(at: end).rounded(.down))
            if last >= first, last - first < 500 {
              for beat in first...last {
                let x = coordinates.x(at: timing.seconds(at: Double(beat)))
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: height))
                context.stroke(p, with: .color(.white.opacity(0.12)), lineWidth: 1)
              }
            }
          }
          if showGrid {
            for measure in measures {
              let second = timing.seconds(at: measure.beat)
              guard second >= start, second <= end else { continue }
              let x = coordinates.x(at: second)
              var line = Path()
              line.move(to: CGPoint(x: x, y: 0))
              line.addLine(to: CGPoint(x: x, y: height))
              context.stroke(line, with: .color(Palette.mint.opacity(0.75)), lineWidth: 1.2)
            }
          }
          // 起音來自偵測；拍線／小節線來自 TimingMap，兩者不是同一種證據。
          if showOnsets {
            for (index, data) in segments.enumerated() {
              for second in data.metadata.onsets where second >= start && second <= end {
                if segments.prefix(index).contains(where: {
                  $0.metadata.start <= second && second <= $0.metadata.end
                }) { continue }
                let x = coordinates.x(at: second)
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: height))
                context.stroke(
                  p, with: .color(Palette.amber.opacity(0.6)),
                  style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
              }
            }
          }
          for (second, label) in [(a, "A"), (b, "B")] where second >= start && second <= end {
            let x = coordinates.x(at: second)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: height))
            context.stroke(line, with: .color(Palette.amber), lineWidth: 1)
            context.draw(Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.amber),
                         at: CGPoint(x: min(size.width - 7, max(axis + 7, x)), y: 9))
          }
          if showPitchGuide {
            for segment in segments {
              var line = Path()
              var previous: PitchTracePoint?
              for point in segment.metadata.pitchTrace ?? [] {
                guard point.time.isFinite, point.midi.isFinite,
                  point.time >= start, point.time <= end,
                  point.midi >= Double(minMIDI), point.midi <= Double(maxMIDI)
                else { previous = nil; continue }
                let position = CGPoint(x: coordinates.x(at: point.time),
                  y: (pitchTop - point.midi) / range * height)
                if let prior = previous, point.time - prior.time <= 0.035,
                  point.time > prior.time, abs(point.midi - prior.midi) <= 1.5 {
                  line.addLine(to: position)
                } else {
                  line.move(to: position)
                }
                previous = point
              }
              context.stroke(line, with: .color(Color(red: 0.79, green: 0.63, blue: 1)), lineWidth: 1.7)
            }
          }
          if showNotes {
            for n in notes {
              guard let pitch = n.soundingPitch, pitch >= minMIDI, pitch <= maxMIDI else {
                continue
              }
              let a = timing.seconds(at: n.beat)
              let b = timing.seconds(at: n.end)
              guard b > start, a < end else { continue }
              let x = coordinates.x(at: max(start, a))
              let y = (pitchTop - Double(pitch) - 0.35) / range * height
              let w = (min(end, b) - max(start, a)) / span * width
              context.stroke(
                Path(
                  roundedRect: CGRect(
                    x: x, y: y, width: max(3, w), height: max(3, height / range * 0.7)),
                  cornerRadius: 2), with: .color(.white.opacity(0.9)), lineWidth: 1)
            }
          }
          for i in 0...4 {
            let x = axis + Double(i) / 4 * width
            let second = start + Double(i) / 4 * span
            context.draw(
              Text(String(format: "%.2fs", second)).font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Palette.muted),
              at: CGPoint(x: min(size.width - 21, max(axis + 20, x)), y: size.height - 9))
          }
        }
        Playhead(transport: transport, start: start, end: end).padding(.leading, axis).padding(
          .bottom, 22)
        FirstBarGuide(second: firstBarPreview, start: start, end: end)
          .padding(.leading, axis).padding(.bottom, 22)
        if enabled && !hover.isEmpty {
          Text(hover).font(.system(size: 10, design: .monospaced)).padding(5).background(
            Palette.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 4)
          ).padding(.leading, axis + 6).padding(.top, 5).allowsHitTesting(false)
        }
      }.contentShape(Rectangle()).onContinuousHover { phase in
        if enabled, case .active(let point) = phase {
          let pitch = pitchTop - point.y / max(1, geo.size.height - 22) * pitchRange
          let time = TimelineCoordinates(start: start, end: end, width: geo.size.width, inset: axis)
            .seconds(at: point.x)
          hover =
            "\(Pitch.name(Int(pitch.rounded()))) · \(String(format:"%.1f",440*pow(2,(pitch-69)/12))) Hz · \(String(format:"%.3f",time)) s"
        } else {
          hover = ""
        }
      }.gesture(
        DragGesture(minimumDistance: 0).onEnded { value in
          guard enabled else { return }
          let coordinates = TimelineCoordinates(start: start, end: end, width: geo.size.width, inset: axis)
          let a = coordinates.seconds(at: value.startLocation.x)
          let b = coordinates.seconds(at: value.location.x)
          if abs(value.location.x - value.startLocation.x) > 5 {
            onSelect(min(a, b), max(a, b))
          } else {
            let pointY = Double(value.location.y)
            let plotHeight = max(1.0, Double(geo.size.height) - 22.0)
            let pitchValue = pitchTop - pointY / plotHeight * pitchRange
            let pitch = Int(pitchValue.rounded())
            if showNotes, firstBarPreview == nil,
              let n = notes.first(where: {
                $0.soundingPitch == pitch && timing.seconds(at: $0.beat) <= b
                  && timing.seconds(at: $0.end) >= b
              })
            {
              onNote(n)
            } else {
              onSeek(b)
            }
          }
        })
    }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 9))
      .modifier(DesktopPointer(pointer: .range))
  }
}
