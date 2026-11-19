import SwiftUI

struct AlignmentControls: View {
  @ObservedObject var store: WorkbenchStore
  @State private var draft = AlignmentEditorDraft()
  @State private var expanded = false
  @State private var openedForInitialEstimate = false
  @State private var twoPointsExpanded = false
  @State private var anchorsExpanded = false
  @FocusState private var field: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Button {
        openedForInitialEstimate = false
        expanded.toggle()
      } label: {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 7) {
            Image(systemName: "slider.horizontal.3").foregroundStyle(Palette.mint)
            Text("速度與時間對齊").font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            Label(expanded ? "收合" : "展開",
                  systemImage: expanded ? "chevron.up" : "chevron.down")
              .font(.caption.weight(.semibold)).foregroundStyle(Palette.mint)
              .padding(.horizontal, 8).padding(.vertical, 5)
              .background(Palette.mint.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
          }
          HStack(spacing: 8) {
            Text(store.project.timing.alignmentSummary).foregroundStyle(Palette.muted)
              .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("alignment-summary")
            if expanded && draft.isModified {
              Text("待確認").foregroundStyle(Palette.amber).accessibilityIdentifier("alignment-dirty")
            }
          }
        }.contentShape(Rectangle())
      }.buttonStyle(HoverButton(base: PlainButtonStyle())).accessibilityIdentifier("toggle-time-alignment")
        .accessibilityLabel(expanded ? "收合時間對齊" : "展開時間對齊")
        .accessibilityValue("\(expanded ? "已展開" : "已收合")；\(store.project.timing.alignmentSummary)")
      if expanded {
        editor
          .onChange(of: draft.useTwoPoints) { _, enabled in
            if enabled { store.endFirstBarPreview() }
          }
          .onChange(of: store.firstBarPreview) { _, second in syncPreview(second) }
      }
    }.font(.caption2).textFieldStyle(.roundedBorder)
      .disabled(store.busy || store.currentAsset == nil)
      .onAppear(perform: reset)
      .onChange(of: store.alignmentRevealRequest) { _, request in
        if !expanded {
          openedForInitialEstimate = request.initialEstimate
          expanded = true
        }
      }
      .onChange(of: store.project.id) { close() }
      .onChange(of: store.project.activeContextID) { close() }
      .onChange(of: store.currentAsset?.id) { reset() }
      .onChange(of: store.currentAsset?.offset) { if !draft.isModified { reset() } }
      .onChange(of: store.project.timing) { if !draft.isModified { reset() } }
      .onChange(of: store.project.score?.revision) { close() }
      .onChange(of: expanded) { _, value in if value { reset() } else { discard() } }
      .onChange(of: field) { updateEditing() }
      .onChange(of: draft.isModified) { updateEditing() }
      .onDisappear(perform: releaseEditing)
  }
  private var editor: some View {
    VStack(alignment: .leading, spacing: 9) {
      TempoControls(store: store, input: displayedBPM,
        anchorsLocked: draft.useTwoPoints || draft.anchorTiming.anchors.count >= 2, submit: apply)
      if store.project.score == nil {
        Divider()
        EstimatedGridControls(numerator: $draft.numerator, denominator: $draft.denominator)
      }
      Divider()
      Text(store.project.score == nil ? "3. 第一小節起點（秒）" : "2. 第一小節起點（秒）")
        .fontWeight(.medium)
      HStack(spacing: 6) {
        TextField("小節起點", text: displayedStart).frame(width: 84).focused($field, equals: "start").controlFeedback(.field)
          .help("輸入秒數或用格線微調，波形與能量圖會跟著移動。按確認後儲存格線。")
          .accessibilityIdentifier("alignment-start").onSubmit(apply).disabled(draft.useTwoPoints)
        Button("起點＝游標") { displayedStart.wrappedValue = String(store.transport.position) }.disabled(draft.useTwoPoints)
        Spacer(minLength: 0)
        InformationButton(title: "第一小節起點", message: "這是第一小節在原音時間軸上的秒數。修改時會一起平移格線與錨點。若設為 −0.1 秒，格線的第一拍在音檔開始前 0.1 秒，畫面會留白。播放從音檔 0.000 秒開始，會直接進入第一拍已過 0.1 秒的位置。速度誤差請用 BPM 或兩點校正；音源偏移另用來對齊不同音檔。")
      }
      if store.project.score != nil,
        let grid = store.project.scoreContexts.first(where: { $0.score == nil }),
        grid.timing.calibrated,
        abs(grid.timing.seconds(at: 0) - store.project.timing.seconds(at: 0)) > 0.0001 {
        Button("帶入無譜起點") { displayedStart.wrappedValue = String(grid.timing.seconds(at: 0)) }
          .disabled(draft.useTwoPoints)
          .help("將無譜格線的第一小節秒數填入草稿，按確認後更新目前樂譜的起點。")
      }
      HStack {
        Text("格線微調").foregroundStyle(Palette.muted)
        Spacer()
        Button("圖上校正") { previewFirstBar() }.disabled(draft.useTwoPoints)
          .accessibilityIdentifier("preview-first-bar")
          .help("將波形和能量圖移到起點草稿。左右拖曳波形可微調起點。")
      }
      HStack(spacing: 5) {
        Button("−0.10 s") { nudge(-0.1) }.help("往前 0.1 秒")
        Button("−0.01 s") { nudge(-0.01) }.help("往前 0.01 秒")
          .accessibilityIdentifier("first-bar-earlier-fine")
        Button("+0.01 s") { nudge(0.01) }.help("往後 0.01 秒")
        Button("+0.10 s") { nudge(0.1) }.help("往後 0.1 秒")
          .accessibilityIdentifier("first-bar-later-tenth")
        Spacer(minLength: 0)
      }.disabled(draft.useTwoPoints)
      if draft.anchorTiming.anchors.count >= 2 && !draft.useTwoPoints {
        Text("區段速度由錨點決定；請用兩點校正，或清除錨點後修改 BPM。")
          .foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
      }
      AlignmentSection(draft.useTwoPoints ? "兩點校正速度與起點（使用中）" : "兩點校正速度與起點",
        isExpanded: $twoPointsExpanded, identifier: "two-point-alignment") {
        VStack(alignment: .leading, spacing: 8) {
          Toggle("使用兩點校正", isOn: $draft.useTwoPoints).toggleStyle(.checkbox).controlFeedback()
            .accessibilityIdentifier("use-two-point-alignment")
          pointRow("A", index: $draft.points.firstIndex, time: $draft.points.firstSeconds, focus: "point-a")
          pointRow("B", index: $draft.points.lastIndex, time: $draft.points.lastSeconds, focus: "point-b")
          HStack {
            if draft.useTwoPoints, let timing = try? draft.timing(project: store.project) {
              Text("換算 \(timing.bpm, specifier: "%.4f") BPM · 起點 \(timing.seconds(at: 0), specifier: "%.3f") s")
                .foregroundStyle(Palette.mint).accessibilityIdentifier("two-point-preview")
            }
            Spacer(minLength: 0)
            Button("重設校正點") { draft.points.reset(from: store.project); draft.useTwoPoints = false }
            InformationButton(title: "兩點校正", message: "填入兩個已知小節起點的實際秒數，可預覽換算結果。按確認後更新速度與錨點。取消勾選可回到 BPM 與起點。A、B 與循環端點無關。")
          }
        }.padding(.top, 6)
      }
      manualAnchors
      HStack {
        Text("錨點 \(draft.anchorTiming.anchors.count) 個").foregroundStyle(Palette.muted)
        if !draft.anchorTiming.anchors.isEmpty {
          Button("清除錨點") { perform { try draft.clearAnchors(project: store.project) } }
            .accessibilityIdentifier("clear-draft-anchors").disabled(draft.useTwoPoints)
        }
        Spacer(minLength: 0)
        Button("取消", action: reset).accessibilityIdentifier("cancel-alignment")
          .buttonStyle(ActionButtonStyle(primary: false))
        Button("確認", action: apply).accessibilityIdentifier("apply-alignment")
          .buttonStyle(ActionButtonStyle())
          .disabled(!draft.isModified && !store.project.requiresAlignmentConfirmation
            && store.autoAppliedGridBPM == nil && !openedForInitialEstimate)
      }
      if let message = draft.validation {
        Text(message).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("alignment-validation")
      }
    }
    .onChange(of: draft.points.firstSeconds) { if !draft.points.firstSeconds.isEmpty { draft.useTwoPoints = true } }
    .onChange(of: draft.points.lastSeconds) { if !draft.points.lastSeconds.isEmpty { draft.useTwoPoints = true } }
  }
  private var displayedBPM: Binding<String> {
    Binding(get: {
      if draft.useTwoPoints, let timing = try? draft.timing(project: store.project) { return String(timing.bpm) }
      return draft.bpm
    }, set: { draft.bpm = $0 })
  }
  private var displayedStart: Binding<String> {
    Binding(get: {
      if draft.useTwoPoints, let timing = try? draft.timing(project: store.project) { return String(timing.seconds(at: 0)) }
      return draft.firstBar
    }, set: {
      draft.firstBar = $0
      previewFirstBar()
    })
  }
  private var manualAnchors: some View {
    AlignmentSection("手動錨點與音源偏移", isExpanded: $anchorsExpanded, identifier: "manual-alignment") {
      VStack(alignment: .leading, spacing: 9) {
        HStack {
          Button("此刻＝小節起點") { addAnchor(end: false) }.accessibilityIdentifier("draft-anchor-start")
          Button("此刻＝小節結尾") { addAnchor(end: true) }.accessibilityIdentifier("draft-anchor-end")
          Spacer(minLength: 0)
        }.disabled(draft.useTwoPoints)
        HStack(spacing: 6) {
          Text("音源偏移（秒）")
          TextField("音源偏移", text: $draft.sourceOffset).frame(width: 82).controlFeedback(.field)
            .focused($field, equals: "source-offset").accessibilityIdentifier("source-offset-draft").onSubmit(apply)
          Spacer(minLength: 0)
          InformationButton(title: "音源偏移", message: "調整目前聆聽音檔相對於原曲的時間。正值表示此音檔較晚開始。按確認後一併儲存錨點與音源偏移。")
        }
        ForEach(draft.anchorTiming.anchors.sorted { $0.beat < $1.beat }) { anchor in
          HStack(spacing: 7) {
            let timing = (try? draft.timing(project: store.project)) ?? draft.anchorTiming
            Text("拍 \(anchor.beat + 1, specifier: "%.2f") → \(timing.seconds(of: anchor), specifier: "%.3f") s").monospacedDigit()
            Button { perform { try draft.removeAnchor(anchor.id, project: store.project) } } label: { Image(systemName: "xmark").modifier(IconButtonFace()) }
              .buttonStyle(HoverButton(base: PlainButtonStyle(), border: Palette.amber, kind: .icon))
              .help("移除此草稿錨點").disabled(draft.useTwoPoints)
            Spacer(minLength: 0)
          }
        }
      }.padding(.top, 7)
    }
  }
  private func pointRow(_ label: String, index: Binding<Int>, time: Binding<String>, focus: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Text(label).foregroundStyle(Palette.amber)
        Picker("\(label) 小節起點", selection: index) {
          ForEach(draft.proposedMeasures(project: store.project)) { measure in
            Text("第 \(measure.number) 小節起點").tag(measure.index)
          }
        }.labelsHidden().frame(width: 142).controlFeedback()
        Button("用目前小節") { index.wrappedValue = store.project.selectedMeasure }
      }
      HStack(spacing: 6) {
        TextField("實際秒數", text: time).frame(width: 90).focused($field, equals: focus).controlFeedback(.field)
          .accessibilityIdentifier("\(focus)-seconds")
        Text("s").foregroundStyle(Palette.muted)
        Button("取游標") { time.wrappedValue = store.transport.position.description }
      }.padding(.leading, 14)
    }
  }
  private func perform(_ operation: () throws -> Void) {
    do { try operation(); draft.validation = nil } catch { draft.validation = error.localizedDescription }
  }
  private func addAnchor(end: Bool) {
    let measures = draft.proposedMeasures(project: store.project)
    guard measures.indices.contains(store.project.selectedMeasure) else { return }
    let measure = measures[store.project.selectedMeasure]
    perform { try draft.addAnchor(beat: end ? measure.end : measure.beat,
      seconds: store.transport.position, project: store.project) }
  }
  private func nudge(_ seconds: Double) {
    perform {
      try draft.nudge(seconds)
      previewFirstBar()
    }
  }
  private func previewFirstBar() {
    guard let second = Double(draft.firstBar.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
    updateEditing()
    store.previewFirstBar(second)
  }
  private func syncPreview(_ second: Double?) {
    guard expanded, !draft.useTwoPoints, let second,
      Double(draft.firstBar.trimmingCharacters(in: .whitespacesAndNewlines)) != second else { return }
    field = nil
    draft.firstBar = String(second)
  }
  private func apply() {
    field = nil
    do {
      _ = try draft.applying(to: store.project, asset: store.currentAsset)
      if store.applyAlignmentEditor(draft) {
        if openedForInitialEstimate { close() } else { reset() }
      } else {
        draft.validation = store.error
      }
    } catch { draft.validation = error.localizedDescription }
  }
  private func reset() {
    store.endFirstBarPreview()
    field = nil
    draft.reset(project: store.project, asset: store.currentAsset)
    updateEditing()
  }
  private func updateEditing() {
    store.hasPendingAlignmentDraft = expanded && draft.isModified
    store.setAlignmentEditing(active: expanded && (field != nil || draft.isModified))
  }
  private func releaseEditing() {
    store.endFirstBarPreview()
    store.hasPendingAlignmentDraft = false
    store.setAlignmentEditing(active: false)
  }
  private func discard() { field = nil; twoPointsExpanded = false; anchorsExpanded = false; reset(); releaseEditing() }
  private func close() { openedForInitialEstimate = false; expanded = false; discard() }
}

/// 子面板與外層採相同的整列開關，保留鍵盤／輔助使用的標準按鈕動作。
private struct AlignmentSection<Content: View>: View {
  let title: String
  @Binding var isExpanded: Bool
  let identifier: String
  let content: Content
  init(_ title: String, isExpanded: Binding<Bool>, identifier: String,
       @ViewBuilder content: () -> Content) {
    self.title = title
    self._isExpanded = isExpanded
    self.identifier = identifier
    self.content = content()
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button { isExpanded.toggle() } label: {
        HStack(spacing: 6) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right").accessibilityHidden(true)
          Text(title)
          Spacer(minLength: 0)
        }.contentShape(Rectangle()).padding(.vertical, 4)
      }.buttonStyle(HoverButton(base: PlainButtonStyle())).accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "已展開" : "已收合")
      if isExpanded { content }
    }
  }
}
