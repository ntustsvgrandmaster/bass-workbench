// SwiftUI 畫面組裝與輸入綁定；可重用的專案規則放在 WorkbenchStore，不在 View 內跑 DSP。

import SwiftUI

struct WorkbenchView: View {
  @EnvironmentObject var store: WorkbenchStore
  // 原生回歸工具可檢查 error 狀態而不開啟會阻塞測試 RunLoop 的系統對話框。
  var presentsErrors = true
  @State private var notesOverlay = true
  @State private var pitchGuide = true
  @State private var onsetsOverlay = true
  @State private var gridOverlay = true
  @State private var adjustingContrast = false
  var body: some View {
    ZStack {
      VStack(spacing: 0) {
        if let kind = store.activeAnalysis, !store.showsSetupProgress {
          HStack(spacing: 12) {
            ProgressView(value: store.progress).frame(width: 120)
            Text("\(kind.rawValue)中 · 已暫停播放").font(.caption)
            Text(store.status).font(.caption2).foregroundStyle(Palette.muted).lineLimit(1)
            Spacer(minLength: 0)
            cancelAnalysis
          }.padding(12).background(Palette.panel)
        }
        workspace.disabled(store.analysisRunning || store.showsSetupProgress)
      }
      .opacity(store.showsSetupProgress ? 0 : 1)
      .accessibilityHidden(store.showsSetupProgress)
      .allowsHitTesting(!store.showsSetupProgress)
      if store.showsSetupProgress { setupProgress }
    }.background(Palette.background).foregroundStyle(.white.opacity(0.92)).tint(Palette.mint)
      .buttonStyle(HoverButton(base: DefaultButtonStyle()))
      .preferredColorScheme(.dark).frame(minWidth: 1120, minHeight: 780)
      .alert(
        "需要處理",
        isPresented: Binding(get: { presentsErrors && store.error != nil }, set: { if !$0 { store.error = nil } })
      ) {
        Button("好") { store.error = nil }
      } message: {
        Text(store.error ?? "")
      }
      .sheet(isPresented: $store.showAssetImport) { assetImport }
  }
  private var cancelAnalysis: some View {
    Button("取消分析") { store.cancel() }
      .accessibilityIdentifier("cancel-analysis")
  }
  private var setupProgress: some View {
    VStack(spacing: 16) {
      Text(store.importingFirstOriginal ? "正在匯入原曲"
        : store.activeAnalysis == .initialSong ? "正在估測速度、起點與和弦" : "正在估測 BPM 與拍點")
        .font(.title2.weight(.semibold))
        .accessibilityIdentifier("setup-progress-title")
      ProgressView(value: store.progress).frame(width: 260)
      Text(store.status).font(.callout).foregroundStyle(Palette.muted)
        .multilineTextAlignment(.center)
      if store.analysisRunning { cancelAnalysis }
    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  @ViewBuilder private var tempoGuide: some View {
    if let bpm = store.autoAppliedGridBPM {
      VStack(alignment: .leading, spacing: 8) {
        Label("已帶入 \(bpm.formatted(.number.precision(.fractionLength(0...3)))) BPM", systemImage: "checkmark.circle")
          .font(.headline).foregroundStyle(Palette.mint)
          .accessibilityIdentifier("initial-tempo-applied")
        if store.currentRegion?.evidence?.method == AnalysisMethod.btcHarmony {
          Text("起點 \(store.project.timing.seconds(at: 0), specifier: "%.3f") 秒 · 和弦已估測")
            .font(.caption).foregroundStyle(Palette.muted)
        }
        if store.currentTempoEstimate?.fit(for: bpm)?.status != "good" {
          Text("已建立初步格線。BPM 需人工確認，請到右欄核對速度、拍號與第一小節起點。")
            .font(.caption).foregroundStyle(Palette.amber)
            .accessibilityIdentifier("initial-tempo-review")
        } else if store.currentRegion?.evidence?.method != AnalysisMethod.btcHarmony {
          Text("已建立初步小節格線。你可以開始分析，或先到右欄核對拍號與第一小節起點。")
            .font(.caption).foregroundStyle(Palette.muted)
        }
        Button("查看右欄對齊設定") { store.reviewAlignment() }
          .accessibilityIdentifier("review-initial-alignment")
      }.modifier(InspectorCard(emphasized: true))
    } else if store.currentAsset != nil && store.project.requiresAlignmentConfirmation {
      VStack(alignment: .leading, spacing: 8) {
        Label("下一步：確認速度與時間對齊", systemImage: "arrow.right.circle")
          .font(.headline).foregroundStyle(Palette.mint)
        Text(store.analysisUnavailableReason ?? "").font(.caption).foregroundStyle(Palette.muted)
        Button("前往右欄對齊設定") { store.reviewAlignment() }
          .accessibilityIdentifier("review-pending-alignment")
      }.modifier(InspectorCard(emphasized: true))
    }
  }
  private var workspace: some View {
    HStack(spacing: 0) {
      sidebar.frame(width: 176)
      Divider()
      VStack(spacing: 0) {
        header
        Divider()
        if store.currentAsset != nil {
          TransportStrip(store: store, transport: store.transport)
            .padding(.horizontal, 14).padding(.vertical, 10).background(Palette.panel)
          Divider()
        }
        ScrollView {
          VStack(alignment: .leading, spacing: 11) {
            if store.project.assets.isEmpty { welcome }
            tempoGuide
            if store.showsMeasureNavigation {
              alignment
              regionStrip
            }
            if store.currentAsset != nil { plot }
            if store.currentAsset != nil || store.project.score != nil { score }
          }.padding(14)
        }.accessibilityIdentifier("workbench-content")
        HStack(spacing: 7) {
          Circle().fill(store.busy ? Palette.amber : Palette.mint).frame(width: 6, height: 6)
          Text(store.status).font(.system(size: 10)).lineLimit(1)
          Spacer()
          Text("LOCAL · v0.2").font(.system(size: 9, design: .monospaced)).foregroundStyle(
            Palette.muted)
        }.padding(.horizontal, 20).padding(.vertical, 10).background(Palette.panel)
      }.frame(minWidth: 580)
      Divider()
      if store.currentAsset != nil || store.project.score != nil {
        HarmonyInspector(store: store).frame(width: 360)
      }
    }
  }
  // 小節點色只表示人工確認／原譜是否有音符；沒有音符也可能是正確休止，不能直接判為缺漏。
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack(spacing: 8) {
        Image(systemName: "waveform.path").font(.title2).foregroundStyle(Palette.mint)
        VStack(alignment: .leading, spacing: 1) {
          Text("BASS").font(.system(size: 18, weight: .black, design: .rounded)).tracking(3)
          Text("WORKBENCH").font(.system(size: 8, weight: .medium)).tracking(2).foregroundStyle(
            Palette.muted)
        }
      }.padding(.vertical, 12)
      Group {
        Button {
          store.chooseAudio()
        } label: {
          Label("匯入原曲／Stem", systemImage: "waveform")
        }
        Button {
          store.chooseScore()
        } label: {
          Label("匯入樂譜", systemImage: "music.note.list")
        }
        Button {
          store.chooseProject()
        } label: {
          Label("開啟專案", systemImage: "folder")
        }
        Button {
          store.save()
        } label: {
          Label("儲存專案", systemImage: "square.and.arrow.down")
        }.accessibilityIdentifier("save-project")
      }.buttonStyle(SideButton()).disabled(store.busy)
      if store.showsMeasureNavigation {
        let range = store.loopMeasureRange
        Divider()
        HStack {
          Text("小節導覽").font(.caption).foregroundStyle(Palette.muted)
          MeasureNavigationLegend()
          Spacer()
          Text("\(store.project.measures.count)").font(.caption.monospacedDigit()).foregroundStyle(
            Palette.mint)
        }
        if let range {
          Text("已選 \(range.numbers)（\(range.indices.count) 小節）")
            .font(.caption2.monospacedDigit()).foregroundStyle(Palette.mint)
            .lineLimit(1).accessibilityIdentifier("measure-loop-summary")
        }
        ScrollViewReader { reader in
          ScrollView {
            LazyVGrid(
              columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
              spacing: 6
            ) {
              ForEach(store.project.measures) { measure in
                MeasureNavigationCell(store: store, measure: measure, loop: range?.indices).id(measure.index)
                  .accessibilityIdentifier("measure-\(measure.index)")
              }
            }
          }.accessibilityIdentifier("measure-navigation")
            .onChange(of: store.navigationScrollRequest) { _, request in
              if let request { reader.scrollTo(request.index, anchor: .center) }
            }
        }
      } else {
        Spacer(minLength: 0)
      }
      HStack(spacing: 6) {
        Label("本機處理", systemImage: "desktopcomputer").font(.caption).foregroundStyle(Palette.mint)
        Spacer(minLength: 0)
        InformationButton(
          title: "本機處理",
          message: "首音與 Root 分開判斷。人工標註可確認、鎖定，音源與原譜保持完整。所有分析在本機執行。")
      }.padding(11).frame(maxWidth: .infinity, alignment: .leading).background(
        .white.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
    }.padding(13).background(Palette.panel.opacity(0.65))
  }
  private var header: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        ProjectTitleEditor(store: store)
        Text(
          store.project.score.map { "\(store.project.referenceScoreName) · \($0.staves.count) 譜表" }
            ?? "同步聆聽 · 音高觀察 · 和聲判讀"
        ).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
      }
      Spacer()
      Button {
        store.undo()
      } label: {
        Image(systemName: "arrow.uturn.backward").modifier(IconButtonFace(size: 32))
      }.buttonStyle(HoverButton(base: PlainButtonStyle(), kind: .icon))
        .disabled(!store.canUndo || store.busy).accessibilityLabel("復原").help("復原 ⌘Z")
      Button {
        store.redo()
      } label: {
        Image(systemName: "arrow.uturn.forward").modifier(IconButtonFace(size: 32))
      }.buttonStyle(HoverButton(base: PlainButtonStyle(), kind: .icon))
        .disabled(!store.canRedo || store.busy).accessibilityLabel("重做").help("重做 ⇧⌘Z")
      Menu {
        Button("分析與標註 JSON") { store.exportAnalysis() }
        Button("和聲 CSV") { store.exportCSV() }
        Button("完整 MusicXML＋已確認和弦") { store.exportMusicXML() }.disabled(store.project.score == nil)
        Divider()
        Button("在 MuseScore 編輯副本") { store.editInMuseScore() }.disabled(store.project.score == nil)
        Button("連結參考譜來源…") { store.chooseScoreUpdateSource() }.disabled(store.project.score == nil)
      } label: {
        Label("匯出／MuseScore", systemImage: "square.and.arrow.up")
      }.menuStyle(.borderlessButton).fixedSize().padding(8)
        .overlay {
          RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.20))
            .allowsHitTesting(false).accessibilityHidden(true)
        }
        .tint(.white).controlFeedback().disabled(store.busy)
    }.padding(.horizontal, 20).padding(.vertical, 12)
  }
  private var welcome: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("聽見低音，讀懂行進。").font(.system(size: 23, weight: .semibold))
      HStack {
        Button("匯入原曲") { store.chooseAudio(role: "original") }.buttonStyle(ActionButtonStyle())
          .accessibilityIdentifier("import-original-welcome")
        Button("開啟專案") { store.chooseProject() }
      }
    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(
      LinearGradient(
        colors: [Palette.mint.opacity(0.1), Palette.panel], startPoint: .topLeading,
        endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 11))
  }
  // 對齊錨點與 Stem 偏移是不同層次：前者連接樂譜拍數與主秒數，後者連接各音檔與主秒數。
  private var alignment: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Button {
          store.navigate(store.project.selectedMeasure - 1)
        } label: {
          Image(systemName: "chevron.left").modifier(IconButtonFace())
        }.buttonStyle(HoverButton(base: PlainButtonStyle(), kind: .icon))
          .accessibilityLabel("前一小節").disabled(store.project.selectedMeasure == 0 || store.busy)
        Text("第 \(store.measure.number) 小節").font(.system(size: 17, weight: .semibold))
        Text("\(store.measure.numerator)/\(store.measure.denominator)").font(
          .system(.caption, design: .monospaced)
        ).foregroundStyle(Palette.muted)
        Button {
          store.navigate(store.project.selectedMeasure + 1)
        } label: {
          Image(systemName: "chevron.right").modifier(IconButtonFace())
        }.buttonStyle(HoverButton(base: PlainButtonStyle(), kind: .icon))
          .accessibilityLabel("下一小節").disabled(store.project.selectedMeasure == store.project.measures.count - 1 || store.busy)
        Spacer()
        Label(
          store.project.score == nil ? "估算小節" : store.isEstimated ? "尚未校準" : "手動對齊",
          systemImage: store.isEstimated ? "clock.badge.questionmark" : "link"
        ).font(.caption2).foregroundStyle(store.isEstimated ? Palette.amber : Palette.mint)
      }
    }.padding(12).background(Palette.panel, in: RoundedRectangle(cornerRadius: 9))
  }
  private var regionStrip: some View {
    HStack(spacing: 6) {
      Text("和聲區間").font(.caption2).foregroundStyle(Palette.muted)
      ForEach(store.regionsInMeasure) { r in
        let title = store.chordText(r).isEmpty ? "未判定" : store.chordText(r)
        Button {
          store.selectRegion(r.id)
        } label: {
          Text(
            "\(r.startBeat-store.measure.beat+1,specifier:"%.2f")–\(r.endBeat-store.measure.beat+1,specifier:"%.2f")拍  \(title)"
          ).font(.caption2).padding(.horizontal, 9).padding(.vertical, 6).foregroundStyle(
            r.id == store.currentRegion?.id ? Palette.mint : Palette.muted
          ).background(
            r.id == store.currentRegion?.id ? Palette.mint.opacity(0.12) : .white.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 5))
          .overlay {
            RoundedRectangle(cornerRadius: 5)
              .strokeBorder(r.id == store.currentRegion?.id ? Palette.mint : .white.opacity(0.16))
              .allowsHitTesting(false).accessibilityHidden(true)
          }
        }.buttonStyle(HoverButton(base: PlainButtonStyle(), kind: .navigation, selected: r.id == store.currentRegion?.id))
          .accessibilityAddTraits(r.id == store.currentRegion?.id ? .isSelected : [])
      }
      Spacer()
      Button("游標處拆分") { store.splitRegion() }.font(.caption2).disabled(
        store.busy || store.currentRegion == nil)
      if store.regionsInMeasure.count > 1 {
        Button("合併") { store.mergeRegions() }.font(.caption2).disabled(store.busy)
      }
    }
  }
  private var plot: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Label("音高能量圖", systemImage: "waveform.path").font(.caption.weight(.semibold))
        InformationButton(title: "圖表時間與對齊", message: "綠線是小節起點，細灰線是四分音符拍線；白框依專案對齊時間顯示原譜的發聲音高。能量包含泛音，例如 E1 的 E2 泛音可能更亮。低頻 CQT 的分析窗口較長，亮色邊緣會向前後擴散，不能當作精準起音。校正請搭配波形中清楚的起音與原音，並核對前、中、後段；播放裝置的實際聲音延遲仍可能影響聽到的時間。")
        Spacer()
        if store.firstBarPreview != nil {
          Button("分析校正範圍的能量") { store.analyzeCalibrationSpectrum() }
            .buttonStyle(ActionButtonStyle()).disabled(store.busy)
            .accessibilityIdentifier("analyze-calibration-spectrum")
        } else {
          Button {
            store.analyze()
          } label: {
            Label(store.analysisRangeTitle, systemImage: "waveform.badge.magnifyingglass")
          }.buttonStyle(ActionButtonStyle()).disabled(!store.canAnalyze)
            .accessibilityIdentifier("analyze-range")
        }
      }
      if let sources = store.analysisSources {
        Text("能量圖來源 · \(store.roleName(sources.chart.role)) · \(sources.chart.name)")
          .font(.caption2).foregroundStyle(Palette.muted).lineLimit(1)
          .help(sources.chart.name)
      }
      HStack {
        Text(store.viewportDescription).font(.caption2)
          .foregroundStyle(store.firstBarPreview == nil ? Palette.muted : .purple)
          .accessibilityIdentifier("viewport-mode")
        Spacer()
        if store.currentAsset?.role == "bass" {
          Toggle("基頻候選", isOn: $pitchGuide).controlFeedback()
            .help("紫線為 Bass stem 的 pYIN 基頻候選。舊快取請重新分析目前範圍。")
        }
        Toggle("原譜", isOn: $notesOverlay).controlFeedback()
        Toggle("起音", isOn: $onsetsOverlay).controlFeedback()
        Toggle("拍線／小節", isOn: $gridOverlay).controlFeedback()
      }.font(.caption2).toggleStyle(.checkbox)
      if store.firstBarPreview == nil, let reason = store.analysisUnavailableReason {
        Text(reason).font(.caption2).foregroundStyle(Palette.muted)
          .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("analysis-unavailable-reason")
      }
      SpectrogramView(
        segments: store.spectrumSegments, loading: store.spectrumLoading,
        showPitchGuide: pitchGuide && store.currentAsset?.role == "bass", a: store.project.a, b: store.project.b,
        loop: store.firstBarPreview == nil ? store.activeLoopRange : nil,
        start: store.viewportStart, end: store.viewportEnd, contrast: store.project.contrast,
        notes: store.project.score?.notes.filter { $0.staffID == store.project.selectedStaff }
          ?? [], measures: store.project.measures, timing: store.previewTiming, minMIDI: store.project.minMIDI,
        maxMIDI: store.project.maxMIDI, showNotes: notesOverlay, showOnsets: onsetsOverlay,
        showGrid: gridOverlay && store.showsMeasureNavigation, firstBarPreview: store.previewMeasureStart,
        transport: store.transport,
        onSelect: { store.setLoop(a: $0, b: $1) }, onSeek: store.seek, onNote: store.auditionNote
      ).frame(height: 185)
      HStack(spacing: 9) {
        Picker(
          "音域",
          selection: Binding(
            get: { store.project.minMIDI },
            set: { v in
              store.edit { $0.minMIDI = v }
              store.restoreSpectrum()
            })
        ) {
          Text("B0–C4").tag(23)
          Text("E1–C4").tag(28)
          Text("C2–C4").tag(36)
        }.labelsHidden().frame(width: 100).controlFeedback()
        Picker(
          "解析度",
          selection: Binding(
            get: { store.project.binsPerOctave },
            set: { v in
              store.edit { $0.binsPerOctave = v }
              store.restoreSpectrum()
            })
        ) {
          Text("12 格／八度").tag(12)
          Text("24 格／八度").tag(24)
          Text("36 格／八度").tag(36)
        }.labelsHidden().frame(width: 110).controlFeedback()
        Text("對比").font(.caption2).foregroundStyle(Palette.muted)
        Slider(
          value: Binding(get: { store.project.contrast }, set: store.setContrast),
          in: 35...95, onEditingChanged: { adjustingContrast = $0 }
        ).frame(width: 62).controlFeedback(.drag, dragging: adjustingContrast)
        Spacer()
        Button("−") { store.zoom(2) }.disabled(store.busy).accessibilityIdentifier("zoom-out")
          .help("縮小後保持時間跨度；跟隨播放時，游標離開畫面才平移")
        Button("＋") { store.zoom(0.5) }.disabled(store.busy).accessibilityIdentifier("zoom-in")
          .help("放大後保持時間跨度；跟隨播放時，游標離開畫面才平移")
        Button("本小節") { store.zoomMeasure() }.font(.caption2).disabled(store.busy)
          .fixedSize(horizontal: true, vertical: false)
          .accessibilityIdentifier("zoom-measure").help("恢復隨小節切換的自動取景")
        Button("A–B") { store.zoomLoop() }.font(.caption2).disabled(store.busy)
          .accessibilityIdentifier("zoom-loop").help("固定顯示 A–B 範圍，不啟用或改動循環")
      }.disabled(store.busy)
      if let m = store.spectrum?.metadata {
        Text(
          "\(m.method) · \(m.cacheHit ? "快取":"本次 \(String(format:"%.2f",m.elapsed))s") · 最低音窗口約 \(String(format:"%.2f",m.lowWindowSeconds))s · 固定振幅參考 · 空白時段無能量資料"
        ).font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(2)
      }
    }
  }
  private var score: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Label("樂譜預覽", systemImage: "music.note.list").font(.caption.weight(.semibold))
        Spacer()
        if let staves = store.project.score?.staves {
          Picker(
            "分析目標譜表",
            selection: Binding(
              get: { store.project.selectedStaff },
              set: { v in store.edit { $0.selectedStaff = v } })
          ) { ForEach(staves) { s in Text(s.name).tag(s.id) } }.labelsHidden().frame(maxWidth: 210).controlFeedback()
        }
      }
      ScoreView(
        document: store.project.score, folder: store.folder,
        selected: store.project.selectedMeasure, refresh: store.scoreRefresh,
        onMeasure: { store.navigate($0) }, onMeasureLoop: store.loopMeasures,
        loopMeasures: store.loopMeasureRange?.indices
      ).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 8))
      if store.project.score != nil {
        HStack(spacing: 10) {
          if !store.notes.isEmpty {
            ScrollView(.horizontal) {
              HStack(spacing: 6) {
                ForEach(store.notes) { n in
                  Button {
                    store.auditionNote(n)
                  } label: {
                    VStack(spacing: 3) {
                      Text(n.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                      Text("拍 \(n.beat-store.measure.beat+1,specifier:"%.2f")\(n.tieStop ? " 延續":"")")
                        .font(.system(size: 9)).foregroundStyle(Palette.muted)
                    }.padding(8).background(
                      n.id == store.selectedNoteID ? Palette.mint.opacity(0.17) : Palette.panel,
                      in: RoundedRectangle(cornerRadius: 6))
                      .overlay {
                        RoundedRectangle(cornerRadius: 6)
                          .strokeBorder(n.id == store.selectedNoteID ? Palette.mint : .white.opacity(0.16))
                          .allowsHitTesting(false).accessibilityHidden(true)
                      }
                  }.buttonStyle(HoverButton(base: PlainButtonStyle(), kind: .navigation, selected: n.id == store.selectedNoteID))
                    .accessibilityAddTraits(n.id == store.selectedNoteID ? .isSelected : [])
                }
              }
            }
          } else {
            Spacer(minLength: 0)
          }
          Button { store.requestScoreUpdate() } label: {
            Label(store.scoreUpdating ? "更新中…" : "更新參考譜", systemImage: "arrow.clockwise")
              .fixedSize()
          }
          .buttonStyle(ActionButtonStyle(primary: false))
          .disabled(store.busy)
          .accessibilityIdentifier("update-reference-score")
          .help("重新讀取這份參考譜的已連結來源")
          .contextMenu {
            Button("連結參考譜來源…") { store.chooseScoreUpdateSource() }
              .disabled(store.busy)
          }
        }
      }
      if case let warnings = (store.project.score?.warnings ?? []) + store.project.warnings,
        !warnings.isEmpty
      {
        DisclosureGroup("樂譜提示（\(warnings.count)）") {
          ForEach(warnings, id: \.self) {
            Text($0).font(.system(size: 10)).foregroundStyle(Palette.amber).frame(
              maxWidth: .infinity, alignment: .leading
            ).padding(.vertical, 3)
          }
        }.font(.caption2)
      }
    }
  }
  private var assetImport: some View {
    VStack(alignment: .leading, spacing: 17) {
      Text("匯入音訊來源").font(.title2.weight(.semibold))
      Text("原檔會複製到專案內。可先匯入原曲，有 stems 時再加入。").font(.callout).foregroundStyle(Palette.muted)
      Picker("來源角色", selection: $store.importRole) {
        Text("原曲").controlFeedback().tag("original")
        Text("Bass stem").controlFeedback().tag("bass")
        Text("伴奏／和聲").controlFeedback().tag("accompaniment")
        Text("其他 stem").controlFeedback().tag("other")
      }.pickerStyle(.radioGroup)
      HStack {
        Button("取消") { store.showAssetImport = false }
        Spacer()
        Button("選擇 WAV／M4A／FLAC…") { store.selectAudio() }.buttonStyle(ActionButtonStyle())
      }
    }.padding(25).frame(width: 440).preferredColorScheme(.dark)
  }
}

/// 移除先標記；完成時再次確認，確認後不保留該譜工作資料。
struct ReferenceScoreControls: View {
  @ObservedObject var store: WorkbenchStore
  @State private var managing = false
  @State private var importingAfterDismissal = false
  @State private var confirmingRemoval = false
  @State private var removalIDs: Set<String> = []
  @State private var requestedImport = false
  @State private var removalError: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("參考譜", selection: Binding(get: { store.project.activeContextID },
                                        set: { _ = store.selectScore(id: $0) })) {
        ForEach(store.project.scoreContexts.filter { !$0.removed }) { context in
          Text(label(context)).tag(context.id)
        }
      }.controlFeedback().accessibilityIdentifier("reference-score")
        .help(store.project.referenceScoreHelp)
      Button {
        confirmingRemoval = false
        removalError = nil
        managing = true
      } label: {
        Label("管理樂譜", systemImage: "list.bullet")
      }.accessibilityIdentifier("manage-scores")
    }.font(.caption).disabled(store.busy)
      .sheet(isPresented: $managing, onDismiss: {
        confirmingRemoval = false
        removalIDs = []
        if importingAfterDismissal {
          importingAfterDismissal = false
          store.chooseScore()
        }
      }) {
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            Text("管理樂譜").font(.title3.weight(.semibold)).foregroundStyle(Palette.mint)
            Spacer()
            Button("完成") { requestClose() }.keyboardShortcut(.defaultAction)
              .accessibilityIdentifier("close-score-manager")
          }
          .padding(10).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
          Divider()
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
              if store.project.availableScoreContexts.isEmpty {
                Text("尚未匯入樂譜，目前使用無譜格線。").foregroundStyle(Palette.muted)
              }
              ForEach(store.project.availableScoreContexts) { context in
                HStack(spacing: 10) {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(label(context)).lineLimit(2)
                    Text(context.importTimeDescription).font(.caption2).foregroundStyle(Palette.muted)
                      .accessibilityIdentifier("score-import-time-\(context.id)")
                    Text(context.id == store.project.activeContextID ? "目前參考譜" : "校準與人工標註已保留")
                      .font(.caption2).foregroundStyle(Palette.muted)
                  }
                  Spacer()
                  if context.id != store.project.activeContextID {
                    Button("選用") { store.selectScore(id: context.id) }
                      .accessibilityIdentifier("select-score-\(context.id)")
                  }
                  Button("移除", role: .destructive) { store.removeScore(id: context.id) }
                    .accessibilityIdentifier("remove-score-\(context.id)")
                }
              }
              if !store.project.removedScoreContexts.isEmpty {
                Divider()
                Text("待移除（\(store.project.removedScoreContexts.count)）").font(.caption).foregroundStyle(Palette.amber)
                ForEach(store.project.removedScoreContexts) { context in
                  HStack {
                    VStack(alignment: .leading, spacing: 4) {
                      Text(label(context)).lineLimit(2)
                      Text(context.importTimeDescription).font(.caption2).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Button("取消移除") { store.restoreScore(id: context.id) }
                      .accessibilityIdentifier("restore-score-\(context.id)")
                  }
                }
              }
            }.padding(.vertical, 4)
          }.frame(maxHeight: .infinity)
          if let removalError {
            Text(removalError).font(.caption).foregroundStyle(Palette.amber)
              .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("score-removal-error")
          }
          Text("移除後按「完成」確認；原始譜可重新匯入，舊工作資料不保留。")
            .font(.caption).foregroundStyle(Palette.muted)
          Button("匯入樂譜…") { requestClose(importing: true) }
            .accessibilityIdentifier("import-score-in-manager")
        }.padding(20).frame(width: 500, height: 380)
          .background(Palette.background).foregroundStyle(.white.opacity(0.92))
          .disabled(confirmingRemoval)
          .overlay {
            if confirmingRemoval {
              ZStack {
                Palette.background.opacity(0.95)
                removalConfirmation.padding(20)
              }
            }
          }
          .disabled(store.busy)
          .tint(Palette.mint).buttonStyle(ScoreManagementButton())
          .preferredColorScheme(.dark)
      }
  }
  private func label(_ context: ScoreContext) -> String {
    store.project.scoreDisplayName(context)
  }
  private func requestClose(importing: Bool = false) {
    removalError = nil
    removalIDs = Set(store.project.removedScoreContexts.map(\.id))
    requestedImport = importing
    if removalIDs.isEmpty {
      importingAfterDismissal = importing
      managing = false
    } else { confirmingRemoval = true }
  }
  private var removalConfirmation: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("是否確定移除？").font(.title3.weight(.semibold))
      ScrollView {
        VStack(alignment: .leading, spacing: 5) {
          ForEach(store.project.scoreContexts.filter { removalIDs.contains($0.id) }) { context in
            Text(label(context)).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }.frame(maxHeight: 80)
      Text("這些樂譜的校準、人工標註與分析結果將不保存，也無法透過「復原」恢復。原始譜檔保留，之後可重新匯入，但不會帶回舊工作資料。")
        .font(.caption).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("取消") {
          confirmingRemoval = false
          removalIDs = []
          requestedImport = false
        }.keyboardShortcut(.cancelAction).accessibilityIdentifier("cancel-score-removal")
        Button(role: .destructive) {
          if store.finalizeScoreRemovals(removalIDs) {
            confirmingRemoval = false
            importingAfterDismissal = requestedImport
            managing = false
          } else {
            removalError = store.error ?? "未能移除工作資料，請重新確認。"
            store.error = nil
            confirmingRemoval = false
            requestedImport = false
          }
        } label: { Text("確認移除") }
          .keyboardShortcut(.defaultAction).accessibilityIdentifier("confirm-score-removal")
      }
    }.padding(20).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
  }
}

private struct ScoreManagementButton: ButtonStyle {
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    let destructive = configuration.role == .destructive
    let text = destructive ? Palette.amber : .white.opacity(0.92)
    return configuration.label.font(.caption).foregroundStyle(text.opacity(enabled ? 1 : 0.45))
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(Palette.panel.opacity(configuration.isPressed ? 0.6 : 1),
                  in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12)))
      .modifier(ButtonFeedback(border: destructive ? Palette.amber : Palette.mint))
  }
}

/// 格子自己訂閱 Store。僅在 ForEach 閉包讀 Store／傳快照，在完整 App 中仍可能停留舊狀態。
struct MeasureNavigationCell: View {
  @ObservedObject var store: WorkbenchStore
  let measure: ScoreMeasure
  let loop: ClosedRange<Int>?

  var body: some View {
    let index = measure.index
    let isSelected = store.project.selectedMeasure == index
    let inLoop = loop?.contains(index) == true
    let joinsPrevious = inLoop && index % 3 > 0 && loop?.contains(index - 1) == true
    let joinsNext = inLoop && index % 3 < 2 && loop?.contains(index + 1) == true
    let state = MeasureNavigationState(project: store.project, measureID: measure.id)
    return Button {
      store.navigate(index, scrollNavigation: false)
    } label: {
      VStack(spacing: 2) {
        Text(measure.number).font(.system(size: 11, weight: .medium, design: .monospaced))
        MeasureStatusMark(marker: state.marker)
      }.frame(maxWidth: .infinity).frame(height: 33)
        .foregroundStyle(state.confirmation == .none ? .white.opacity(0.85) : Palette.mint)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        .background {
          if inLoop {
            UnevenRoundedRectangle(topLeadingRadius: joinsPrevious ? 0 : 6,
              bottomLeadingRadius: joinsPrevious ? 0 : 6, bottomTrailingRadius: joinsNext ? 0 : 6,
              topTrailingRadius: joinsNext ? 0 : 6)
              .fill(Palette.mint.opacity(0.32))
              .padding(.leading, joinsPrevious ? -3 : 0).padding(.trailing, joinsNext ? -3 : 0)
              .allowsHitTesting(false).accessibilityHidden(true)
          }
        }
        .overlay(alignment: .leading) {
          if index == loop?.lowerBound { loopEdge.padding(.leading, 2) }
        }
        .overlay(alignment: .trailing) {
          if index == loop?.upperBound { loopEdge.padding(.trailing, 2) }
        }
        .overlay {
          if isSelected {
            RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.7), lineWidth: 1.5)
              .allowsHitTesting(false).accessibilityHidden(true)
          }
        }
        .opacity(store.busy ? 0.48 : 1)
        .contentShape(Rectangle())
    }.buttonStyle(HoverButton(base: PlainButtonStyle(), kind: .navigation, selected: isSelected))
      .highPriorityGesture(TapGesture().modifiers(.shift).onEnded {
        store.loopMeasures(store.project.selectedMeasure, index)
      })
      .disabled(store.busy)
      .help("第 \(measure.number) 小節 · \(state.description)；點擊定位並暫停播放。")
      .accessibilityLabel("第 \(measure.number) 小節")
      .accessibilityValue(inLoop ? "\(state.description)，在 A–B 範圍內" : state.description)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
  private var loopEdge: some View {
    Capsule().fill(Palette.mint).frame(width: 2, height: 20)
      .allowsHitTesting(false).accessibilityHidden(true)
  }
}

/// 格子與圖例使用相同符號；顏色之外仍有空心／半圓／實心之別。
struct MeasureStatusMark: View {
  let marker: MeasureNavigationState.Marker
  var body: some View {
    Group {
      switch marker {
      case .partial:
        Image(systemName: "circle.lefthalf.filled").foregroundStyle(Palette.mint)
      case .complete:
        Image(systemName: "circle.fill").foregroundStyle(Palette.mint)
      case .notes:
        Image(systemName: "circle.fill").foregroundStyle(Palette.muted)
      case .empty:
        Image(systemName: "circle.fill").foregroundStyle(Palette.amber)
      case .unavailable:
        Image(systemName: "circle").foregroundStyle(Palette.muted)
      }
    }.font(.system(size: 6)).frame(width: 8, height: 8).accessibilityHidden(true)
  }
}

struct MeasureNavigationLegend: View {
  @State private var showing = false
  var body: some View {
    Button { showing.toggle() } label: {
      Image(systemName: "info.circle").font(.system(size: 13))
        .modifier(IconButtonFace())
    }.buttonStyle(HoverButton(base: PlainButtonStyle(), kind: .icon)).foregroundStyle(Palette.muted)
      .help("查看小節導覽圖例").accessibilityLabel("小節導覽圖例")
      .accessibilityIdentifier("measure-legend")
      .popover(isPresented: $showing) {
        VStack(alignment: .leading, spacing: 11) {
          Text("小節導覽圖例").font(.headline)
          HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).stroke(Palette.mint, lineWidth: 1)
              .frame(width: 12, height: 12)
            Text("綠框：目前選取的小節")
          }
          row(.notes, "灰點：未確認，目前譜表有音符")
          row(.empty, "橘點：未確認，此譜表無一般音符")
          row(.unavailable, "空心灰圈：尚無樂譜或有效譜表")
          row(.partial, "半圓綠點：部分區間已人工確認")
          row(.complete, "實心綠點：全部區間已人工確認")
          Divider()
          Text("灰底只表示未選取，仍可點擊。沒有一般音符可能是休止，不代表漏譜。確認後仍可從小節提示查看譜面資訊。")
            .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }.font(.caption).padding(14).frame(width: 290, alignment: .leading)
          .accessibilityIdentifier("measure-legend-content")
      }
  }
  private func row(_ marker: MeasureNavigationState.Marker, _ text: String) -> some View {
    HStack(spacing: 8) { MeasureStatusMark(marker: marker).frame(width: 12); Text(text) }
  }
}

struct SideButton: ButtonStyle {
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 11, weight: .medium)).frame(
      maxWidth: .infinity, alignment: .leading
    ).padding(.vertical, 6).foregroundStyle(
      configuration.isPressed ? Palette.mint : .white.opacity(enabled ? 0.85 : 0.42))
      .padding(.horizontal, 6)
      .background(.white.opacity(enabled ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 6))
      .contentShape(Rectangle())
      .modifier(ButtonFeedback(kind: .navigation))
  }
}

/// 此子畫面直接觀察 Transport，避免每 35 ms 的游標更新讓整個工作台重新組裝。
struct TransportStrip: View {
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var transport: Transport
  @State private var showingVolume = false
  @State private var scrubbingPlayback = false
  @State private var adjustingVolume: String?
  var body: some View {
    VStack(spacing: 9) {
      HStack(spacing: 9) {
        Button {
          store.playPause()
        } label: {
          Image(systemName: transport.playing ? "pause.fill" : "play.fill").frame(
            width: 20, height: 18)
        }.buttonStyle(ActionButtonStyle(primary: false)).disabled(store.currentAsset == nil)
          .accessibilityIdentifier("play-pause")
        Button { store.setMetronome(!store.project.practice.metronome) } label: {
          Image(systemName: "metronome").font(.system(size: 17))
            .foregroundStyle(store.project.practice.metronome ? Palette.mint : Palette.muted)
            .frame(width: 24, height: 20)
            .overlay(alignment: .bottomTrailing) {
              if store.project.practice.metronome {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 8))
                  .foregroundStyle(Palette.mint).background(Palette.panel, in: Circle())
                  .offset(x: 2, y: 1).accessibilityHidden(true)
              }
            }
        }.accessibilityLabel("節拍器")
          .accessibilityValue(store.project.practice.metronome ? "開啟" : "關閉")
          .accessibilityIdentifier("metronome-toggle")
          .help(store.project.practice.metronome ? "關閉節拍器" : "開啟節拍器")
          .disabled(store.busy)
        Picker(
          "播放來源", selection: Binding(get: { store.project.selectedAsset }, set: store.loadAsset)
        ) {
          if store.project.assets.isEmpty { Text("尚未匯入音源").tag("") }
          ForEach(store.project.assets) { a in
            Text("\(store.roleName(a.role)) · \(a.name)").tag(a.id)
          }
        }.labelsHidden().frame(maxWidth: 240).controlFeedback().disabled(store.busy)
        Spacer()
        TextField(
          "秒", value: Binding(get: { transport.position }, set: store.seek),
          format: .number.precision(.fractionLength(3))
        ).textFieldStyle(.roundedBorder).frame(width: 70)
          .font(.system(.caption, design: .monospaced)).controlFeedback(.field)
        Text("秒").font(.caption2).foregroundStyle(Palette.muted)
        PlaybackSpeedControl(store: store).padding(.leading, 5)
      }
      HStack {
        if transport.countingIn {
          Text("預備中")
            .font(.caption.monospacedDigit()).foregroundStyle(Palette.amber)
            .accessibilityIdentifier("count-in-status")
        } else {
          Text("播放：第 \(store.playbackMeasureNumber) 小節")
            .font(.caption.monospacedDigit()).foregroundStyle(Palette.mint)
            .accessibilityIdentifier("playback-measure")
        }
        if store.isEstimated { Text("尚未校準").font(.caption2).foregroundStyle(Palette.amber) }
        Spacer()
        if store.editingPlaybackSelection {
          Text("編輯中，暫緩跟隨").font(.caption2).foregroundStyle(Palette.muted)
        }
        Toggle("跟隨播放", isOn: Binding(get: { store.followPlayback }, set: store.setFollowPlayback))
          .toggleStyle(.checkbox).font(.caption2).controlFeedback()
      }
      HStack(spacing: 8) {
        Button { showingVolume.toggle() } label: { Label("音量", systemImage: "speaker.wave.2") }
          .accessibilityIdentifier("playback-volume")
          .popover(isPresented: $showingVolume) {
            VStack(alignment: .leading, spacing: 14) {
              Text("音量").font(.headline)
              volumeControl("音源", value: store.project.practice.musicVolume, limit: 1,
                id: "music-volume", set: { store.setMusicVolume($0, persist: false) })
              volumeControl("節拍器", value: store.project.practice.volume,
                limit: PracticeSettings.maximumClickVolume, id: "metronome-volume",
                set: { store.setMetronomeVolume($0, persist: false) })
            }.padding(16).frame(width: 270)
              .accessibilityElement(children: .contain).accessibilityIdentifier("playback-volume-panel")
          }
        Spacer(minLength: 0)
        Picker("預備", selection: Binding(get: { store.project.practice.countInBars }, set: store.setCountInBars)) {
          Text("無預備").tag(0)
          ForEach(1...3, id: \.self) { n in Text("\(n) 小節").tag(n) }
        }.frame(width: 140).controlFeedback().accessibilityIdentifier("count-in-bars")
        InformationButton(title: "節拍器與預備拍", message: "依目前 BPM、拍號與校準點拍，小節首拍加重；6/8 會敲六個八分音符。預備只在按播放時出現，即使節拍器關閉仍會打預備拍，之後從原位置播放；小節中途起播會銜接該位置的拍相位。暫停、定位或分析可取消預備；A–B 回跳不重做。")
      }.font(.caption2).disabled(store.busy)
      WaveformView(
        waveform: store.waveform, start: store.viewportStart, end: store.viewportEnd,
        offset: store.currentAsset?.offset ?? 0, a: store.project.a, b: store.project.b,
        loop: store.activeLoopRange, audioEnd: (store.currentAsset?.duration ?? 0) + (store.currentAsset?.offset ?? 0),
        transport: transport, onSelect: { store.setLoop(a: $0, b: $1) }, onSeek: store.seek,
        firstBarPreview: store.firstBarPreview, previewMeasureStart: store.previewMeasureStart,
        onDragFirstBar: store.dragFirstBarPreview
      ).frame(height: 46)
      LoopControls(store: store, transport: transport)
      if let a = store.currentAsset {
        Slider(
          value: Binding(get: { transport.position }, set: store.seek),
          in: 0...max(0.1, a.duration + a.offset),
          onEditingChanged: { scrubbingPlayback = $0 }
        ).controlSize(.small).controlFeedback(.drag, dragging: scrubbingPlayback)
      }
    }
  }
  private func volumeControl(_ title: String, value: Float, limit: Float, id: String,
    set: @escaping (Float) -> Void) -> some View {
    VStack(spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text("\(Int((value * 100).rounded()))%").monospacedDigit()
      }.font(.caption)
      Slider(value: Binding(get: {
        id == "music-volume" ? store.project.practice.musicVolume : store.project.practice.volume
      }, set: set), in: 0...limit, onEditingChanged: { editing in
        adjustingVolume = editing ? id : nil
        if !editing { store.persist() }
      })
        .controlFeedback(.drag, dragging: adjustingVolume == id)
        .accessibilityLabel("\(title)音量").accessibilityIdentifier(id)
    }
  }
}

private struct PlaybackSpeedControl: View {
  private enum Field { case rate, bpm }
  private static let presets: [Float] = [1, 0.75, 0.5]
  private static let limits = 0.25...2.0

  @ObservedObject var store: WorkbenchStore
  @Environment(\.locale) private var locale
  @State private var showingEditor = false
  @State private var rateText = ""
  @State private var bpmText = ""
  @State private var editedField: Field = .rate
  @State private var adjustedBoundary: Double?
  @State private var fieldVersion = 0
  @FocusState private var focus: Field?

  private var baseBPM: Double? {
    let bpm = store.project.timing.bpm
    guard !store.project.requiresAlignmentConfirmation, store.autoAppliedGridBPM == nil,
      bpm.isFinite, bpm > 0 else { return nil }
    return bpm
  }

  private var preset: Float? {
    Self.presets.first { $0 == store.project.rate }
  }

  private var rateLabel: String {
    let rounded = format(Double(store.project.rate), digits: 2)
    if preset == nil, Self.presets.contains(where: { format(Double($0), digits: 2) == rounded }) {
      let separator = locale.decimalSeparator ?? "."
      return String(store.project.rate).replacingOccurrences(of: ".", with: separator) + "×"
    }
    return rounded + "×"
  }

  @FocusState private var focusedPreset: Float?
  private let warningColor = Color(red: 0.87, green: 0.53, blue: 0.53)

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Self.presets, id: \.self) { rate in
        segment(format(Double(rate), digits: 2) + "×", selected: preset == rate) {
          store.setPlaybackRate(rate)
        }
        .focused($focusedPreset, equals: rate)
        .onMoveCommand { direction in
          guard let index = Self.presets.firstIndex(of: rate) else { return }
          switch direction {
          case .left where index > 0: selectPreset(at: index - 1)
          case .right where index + 1 < Self.presets.count: selectPreset(at: index + 1)
          default: break
          }
        }
        .accessibilityIdentifier("playback-rate-\(rate)")
      }
      segment(preset == nil ? rateLabel : "自訂…", selected: preset == nil, chevron: preset == nil) {
        resetDraft()
        showingEditor = true
      }
      .accessibilityLabel("自訂播放速度")
      .accessibilityValue(preset == nil ? rateLabel : "")
      .accessibilityIdentifier("playback-rate-custom")
      .popover(isPresented: $showingEditor, arrowEdge: .top) { editor }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("播放速度")
    .font(.caption)
    .padding(2)
    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    .disabled(store.busy || store.currentAsset == nil)
    .onChange(of: store.project.id) { showingEditor = false }
    .onChange(of: store.project.activeContextID) { showingEditor = false }
    .onChange(of: store.busy) { if store.busy { showingEditor = false } }
    .onChange(of: baseBPM) {
      if showingEditor { resetDraft() }
    }
  }

  private func segment(_ title: String, selected: Bool, chevron: Bool = false,
                       action: @escaping () -> Void) -> some View {
    Button(action: action) {
      segmentLabel(title, chevron: chevron)
        .padding(.horizontal, 5)
        .frame(width: 61, height: 24)
    }
    .buttonStyle(PlaybackSpeedButtonStyle(selected: selected))
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func segmentLabel(_ title: String, chevron: Bool) -> some View {
    HStack(spacing: 3) {
      Text(title).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
      if chevron { Image(systemName: "chevron.down").font(.system(size: 8)) }
    }
  }

  private func selectPreset(at index: Int) {
    let rate = Self.presets[index]
    focusedPreset = rate
    store.setPlaybackRate(rate)
  }

  private var draftRate: Double? {
    if let adjustedBoundary { return adjustedBoundary }
    switch editedField {
    case .rate: return parse(rateText)
    case .bpm: return baseBPM.flatMap { bpm in parse(bpmText).map { $0 / bpm } }
    }
  }

  private var outsideRange: Bool {
    draftRate.map { !Self.limits.contains($0) } ?? false
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let baseBPM {
        Text("基準曲速：\(format(baseBPM, digits: 2)) BPM").foregroundStyle(Palette.muted)
      }
      input("倍率", field: .rate, unit: "×")
      input("練習 BPM", field: .bpm, unit: "BPM").disabled(baseBPM == nil)
      if baseBPM == nil {
        Text("請先確認曲速").foregroundStyle(Palette.muted)
      }
      if outsideRange || adjustedBoundary != nil {
        Text(adjustedBoundary == nil ? "倍率範圍為 0.25×～2×。" : "已調至最近的邊界，再按一次確認即可套用。")
          .foregroundStyle(warningColor)
          .accessibilityIdentifier("playback-rate-limit")
      }
      HStack {
        Button("重設為 1×") { apply(1) }
          .buttonStyle(PlaybackSpeedButtonStyle(panelAction: true))
          .accessibilityIdentifier("playback-rate-reset")
        Spacer()
        Button("確認", action: submit)
          .buttonStyle(PlaybackSpeedButtonStyle(panelAction: true))
          .disabled(draftRate == nil)
          .accessibilityIdentifier("playback-rate-confirm")
      }
    }
    .frame(width: 265)
    .padding(14)
    .background(Palette.panel.ignoresSafeArea())
    .presentationBackground(Palette.panel)
    .background(PlaybackSpeedFieldAppearance())
    .onAppear { focus = .rate }
    .onExitCommand { showingEditor = false }
  }

  private func input(_ title: String, field: Field, unit: String) -> some View {
    HStack {
      Text(title).frame(width: 60, alignment: .leading)
      HStack(spacing: 6) {
        TextField(title, text: Binding(
          get: { field == .rate ? rateText : bpmText },
          set: { value in
            guard value != (field == .rate ? rateText : bpmText) else { return }
            editedField = field
            adjustedBoundary = nil
            if field == .rate {
              rateText = value
              bpmText = bpmDisplay(for: parse(value))
            } else {
              bpmText = value
              rateText = draftRate.map { format($0, digits: 10) } ?? ""
            }
          }))
          .textFieldStyle(.plain)
          .monospacedDigit()
          .modifier(DesktopPointer(pointer: .text))
          .focused($focus, equals: field)
          .accessibilityIdentifier(field == .rate ? "playback-rate-input" : "playback-bpm-input")
          .onSubmit(submit)
          .id(fieldVersion)
          .onAppear {
            if adjustedBoundary != nil && editedField == field { focus = field }
          }
        Text(unit).foregroundStyle(Palette.muted).frame(width: 28, alignment: .trailing)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 8).frame(height: 28)
      .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
      .overlay {
        let invalid = editedField == field && (outsideRange || adjustedBoundary != nil)
        RoundedRectangle(cornerRadius: 5)
          .strokeBorder(invalid ? warningColor : focus == field ? Palette.mint : .white.opacity(0.17))
          .allowsHitTesting(false).accessibilityHidden(true)
      }
    }
  }

  private func parse(_ text: String) -> Double? {
    let separator = locale.decimalSeparator ?? "."
    let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: separator, with: "."))
    return value.flatMap { $0.isFinite ? $0 : nil }
  }

  private func format(_ value: Double, digits: Int, minimum: Int = 0) -> String {
    value.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(minimum...digits)))
  }

  private func bpmDisplay(for rate: Double?) -> String {
    guard let baseBPM, let rate, (baseBPM * rate).isFinite else { return "" }
    return format(baseBPM * rate, digits: 1, minimum: 1)
  }

  private func resetDraft() {
    editedField = .rate
    adjustedBoundary = nil
    let rate = store.project.rate
    let separator = locale.decimalSeparator ?? "."
    rateText = String(rate).replacingOccurrences(of: ".", with: separator)
    bpmText = bpmDisplay(for: Double(rate))
  }

  private func submit() {
    guard let rate = draftRate else { return }
    if !Self.limits.contains(rate) {
      let boundary = min(Self.limits.upperBound, max(Self.limits.lowerBound, rate))
      focus = nil
      // Let AppKit finish committing the active field editor before replacing its text.
      Task { @MainActor in
        guard showingEditor else { return }
        adjustedBoundary = boundary
        rateText = format(boundary, digits: 2)
        bpmText = bpmDisplay(for: boundary)
        fieldVersion += 1
      }
      return
    }
    apply(Float(rate))
  }

  private func apply(_ rate: Float) {
    store.setPlaybackRate(rate)
    showingEditor = false
  }
}

private struct PlaybackSpeedButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  @Environment(\.isFocused) private var focused
  @State private var hover = false
  var selected = false
  var panelAction = false

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: 5)
    configuration.label
      .padding(.horizontal, panelAction ? 9 : 0)
      .padding(.vertical, panelAction ? 5 : 0)
      .foregroundStyle(selected ? Palette.mint : Color.primary.opacity(enabled ? 1 : 0.45))
      .background(selected ? Palette.mint.opacity(0.17) : .white.opacity(panelAction ? 0.07 : 0), in: shape)
      .overlay {
        shape.fill(.white.opacity(enabled && (hover || configuration.isPressed) ? 0.08 : 0))
          .allowsHitTesting(false).accessibilityHidden(true)
      }
      .overlay {
        shape.strokeBorder(focused ? Palette.mint : .clear)
          .allowsHitTesting(false).accessibilityHidden(true)
      }
      .contentShape(Rectangle())
      .onHover { inside in
        hover = inside
        if inside { (enabled ? NSCursor.pointingHand : .operationNotAllowed).set() }
        else { NSCursor.arrow.set() }
      }
      .onChange(of: enabled) {
        if hover { (enabled ? NSCursor.pointingHand : .operationNotAllowed).set() }
      }
  }
}

/// The popover shares an AppKit field editor across its inputs.
private struct PlaybackSpeedFieldAppearance: NSViewRepresentable {
  func makeNSView(context: Context) -> Observer { Observer() }
  func updateNSView(_ view: Observer, context: Context) {}

  final class Observer: NSView {
    private weak var editor: NSTextView?
    private var originalSelection: [NSAttributedString.Key: Any]?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      NotificationCenter.default.removeObserver(self)
      restoreSelection()
      guard window != nil else { return }
      NotificationCenter.default.addObserver(self, selector: #selector(beginEditing(_:)),
        name: NSControl.textDidBeginEditingNotification, object: nil)
      NotificationCenter.default.addObserver(self, selector: #selector(endEditing(_:)),
        name: NSControl.textDidEndEditingNotification, object: nil)
    }

    @objc private func beginEditing(_ notification: Notification) {
      guard let field = notification.object as? NSTextField, field.window === window,
        let text = field.currentEditor() as? NSTextView else { return }
      field.focusRingType = .none
      restoreSelection()
      editor = text
      originalSelection = text.selectedTextAttributes
      var selection = text.selectedTextAttributes
      selection[.backgroundColor] = NSColor(Palette.mint)
      selection[.foregroundColor] = NSColor(Palette.background)
      text.selectedTextAttributes = selection
    }

    @objc private func endEditing(_ notification: Notification) {
      if let field = notification.object as? NSTextField, field.window === window { restoreSelection() }
    }

    private func restoreSelection() {
      if let originalSelection { editor?.selectedTextAttributes = originalSelection }
      originalSelection = nil
      editor = nil
    }
  }
}

struct ProjectTitleEditor: View {
  @ObservedObject var store: WorkbenchStore
  @State private var draft = ProjectTitleDraft()
  @FocusState private var focused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 7) {
        if draft.editing {
          TextField("專案名稱", text: $draft.text).textFieldStyle(.roundedBorder).controlFeedback(.field)
            .accessibilityIdentifier("title-input")
            .focused($focused).onSubmit(save).onExitCommand(perform: cancel)
          Button("儲存", action: save).accessibilityLabel("儲存名稱").disabled(store.busy)
            .accessibilityIdentifier("save-title")
          Button("取消", action: cancel).accessibilityLabel("取消名稱編輯")
            .accessibilityIdentifier("cancel-title")
        } else {
          Text(store.project.title).lineLimit(1).font(.system(size: 19, weight: .semibold))
            .accessibilityIdentifier("project-title")
          Button {
            draft.begin(in: store)
            focused = true
          } label: {
            Image(systemName: "pencil").modifier(IconButtonFace())
          }.buttonStyle(HoverButton(base: PlainButtonStyle(), kind: .icon)).accessibilityLabel("編輯專案名稱").help("編輯專案名稱").disabled(store.busy)
            .accessibilityIdentifier("edit-title")
        }
      }
      if draft.invalid { Text("請輸入專案名稱").font(.caption2).foregroundStyle(Palette.amber) }
    }.onChange(of: store.project.id) { cancel() }
      .onDisappear { store.setEditing("title", active: false) }
  }
  private func save() {
    if draft.save(to: store) { focused = false }
  }
  private func cancel() {
    focused = false
    draft.cancel(in: store)
  }
}

struct LoopControls: View {
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var transport: Transport
  @State private var draft = LoopDraft()
  @State private var highlightBounds = false
  @FocusState private var field: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Toggle("A–B 循環", isOn: Binding(get: { store.project.loop }, set: { enabled in
          field = nil
          store.setLoopEnabled(enabled)
        }))
          .toggleStyle(.checkbox).controlFeedback()
        Button("本小節循環") { if store.loopCurrentMeasure() { reset() } }
        if let range = store.loopMeasureRange {
          Text("第 \(range.numbers) 小節 · \(store.project.a, specifier: "%.3f")–\(store.project.b, specifier: "%.3f") s")
            .font(.caption2.monospacedDigit()).foregroundStyle(Palette.mint)
            .lineLimit(1).accessibilityIdentifier("loop-measure-summary")
        }
        Spacer()
        InformationButton(
          title: "A–B 循環", message: "可跨多個小節，最長 180 秒。拖曳波形或能量圖可設定範圍；手動輸入 A、B 後按「套用」，切換小節不會改寫範圍。")
      }
      HStack(spacing: 6) {
        Text("A").foregroundStyle(Palette.amber)
        TextField("起點秒數", text: $draft.a).frame(width: 66).focused($field, equals: "a").controlFeedback(.field)
          .accessibilityLabel("A 起點秒數").accessibilityIdentifier("loop-a").onSubmit(apply)
          .overlay { boundsHighlight }
        Button("A＝游標") {
          draft.a = String(format: "%.3f", transport.position)
          draft.validation = nil
        }
        Text("B").foregroundStyle(Palette.amber)
        TextField("終點秒數", text: $draft.b).frame(width: 66).focused($field, equals: "b").controlFeedback(.field)
          .accessibilityLabel("B 終點秒數").accessibilityIdentifier("loop-b").onSubmit(apply)
          .overlay { boundsHighlight }
        Button("B＝游標") {
          draft.b = String(format: "%.3f", transport.position)
          draft.validation = nil
        }
        Button("套用", action: apply).accessibilityLabel("套用 A–B")
          .accessibilityIdentifier("apply-loop")
        Button("取消", action: reset).accessibilityLabel("取消 A–B 編輯")
          .accessibilityIdentifier("cancel-loop")
        Spacer(minLength: 0)
      }.textFieldStyle(.roundedBorder).tint(.gray)
      if let validation = draft.validation {
        Text(validation).foregroundStyle(Palette.amber).accessibilityIdentifier("loop-error")
      }
    }.font(.caption2).disabled(store.busy || store.currentAsset == nil)
      .task(id: store.activeLoopRange) {
        highlightBounds = store.activeLoopRange != nil
        if highlightBounds {
          try? await Task.sleep(for: .milliseconds(650))
          if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { highlightBounds = false } }
        }
      }
      .onAppear(perform: reset)
      .onChange(of: store.project.id) { reset() }
      .onChange(of: store.project.a) { reset() }
      .onChange(of: store.project.b) { reset() }
      .onChange(of: draft.a) { draft.validation = nil }
      .onChange(of: draft.b) { draft.validation = nil }
      .onChange(of: field) { _, value in store.setEditing("loop", active: value != nil) }
      .onDisappear { store.setEditing("loop", active: false) }
  }
  private var boundsHighlight: some View {
    RoundedRectangle(cornerRadius: 5)
      .strokeBorder(Palette.mint.opacity(highlightBounds ? 0.9 : 0), lineWidth: 1.5)
      .allowsHitTesting(false).accessibilityHidden(true)
  }
  private func reset() {
    draft.reset(a: store.project.a, b: store.project.b)
    field = nil
  }
  private func apply() {
    if draft.apply(to: store) { field = nil }
  }
}

struct InformationButton: View {
  var title: String
  var message: String
  @State private var showing = false
  var body: some View {
    Button {
      showing.toggle()
    } label: {
      Image(systemName: "info.circle").font(.system(size: 13))
        .modifier(IconButtonFace())
    }.buttonStyle(HoverButton(base: PlainButtonStyle(), kind: .icon)).foregroundStyle(Palette.muted)
      .accessibilityLabel("\(title)說明").help("顯示\(title)說明")
      .accessibilityIdentifier("info-\(title)")
      .popover(isPresented: $showing) {
        VStack(alignment: .leading, spacing: 8) {
          Text(title).font(.headline)
          Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
        }.padding(14).frame(width: 260, alignment: .leading)
      }
  }
}

private struct InspectorCard: ViewModifier {
  var emphasized = false
  func body(content: Content) -> some View {
    content.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(emphasized ? Palette.mint.opacity(0.08) : Color.white.opacity(0.035),
                  in: RoundedRectangle(cornerRadius: 9))
      .overlay {
        RoundedRectangle(cornerRadius: 9)
          .strokeBorder(emphasized ? Palette.mint.opacity(0.48) : .white.opacity(0.10))
          .allowsHitTesting(false)
      }
  }
}

struct HarmonyInspector: View {
  @ObservedObject var store: WorkbenchStore
  @FocusState private var annotationFocus: String?
  var body: some View {
    ScrollViewReader { reader in
      ScrollView { inspectorContent }
        .onChange(of: store.alignmentRevealRequest) {
          reader.scrollTo("alignment-card", anchor: .top)
        }
    }.background(Palette.panel.opacity(0.6))
      .onChange(of: annotationFocus) { _, value in
        store.setEditing("annotation", active: value != nil)
      }
      .onChange(of: store.project.id) {
        annotationFocus = nil
        store.setEditing("annotation", active: false)
      }
      .onChange(of: store.project.activeContextID) {
        annotationFocus = nil
        store.setEditing("annotation", active: false)
      }
      .onDisappear { store.setEditing("annotation", active: false) }
  }
  private var inspectorContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      if store.currentAsset != nil {
        AlignmentControls(store: store)
          .modifier(InspectorCard(emphasized: store.project.requiresAlignmentConfirmation || store.autoAppliedGridBPM != nil))
          .id("alignment-card")
      }
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("和聲").font(.headline)
          Spacer()
          if store.currentRegion?.annotation.confirmed == true {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.mint)
          }
        }
        analysisControls
        Divider()
        if let r = store.currentRegion {
          summary(r)
          annotations(r)
          if let e = r.evidence {
            candidates(r, e)
            evidence(r, e)
          }
          context
        } else {
          Text("匯入音源後，即可依小節保存 Root 與和弦標註。").font(.caption).foregroundStyle(Palette.muted)
        }
      }.modifier(InspectorCard())
      DisclosureGroup("分析來源與專案") {
        VStack(alignment: .leading, spacing: 10) {
          Picker(
            "和聲來源",
            selection: Binding(
              get: { store.project.harmonyAsset },
              set: { v in
                store.edit {
                  $0.harmonyAsset = v
                  $0.timing.revision += 1
                }
              })
          ) {
            ForEach(store.project.assets) { a in
              Text(store.roleName(a.role) + " · " + a.name).tag(a.id)
            }
          }.controlFeedback()
          Picker(
            "Bass 來源",
            selection: Binding(
              get: { store.project.bassAsset },
              set: { v in
                store.edit {
                  $0.bassAsset = v
                  $0.timing.revision += 1
                }
              })
          ) {
            Text("自動選擇").tag("")
            ForEach(store.project.assets) { a in
              Text(store.roleName(a.role) + " · " + a.name).tag(a.id)
            }
          }.controlFeedback()
          if let region = store.currentRegion, store.freshEvidence(region)?.method == AnalysisMethod.btcHarmony,
            let original = store.project.masterAsset {
            Text("目前和弦結果來自 \(original.name)")
          }
          ReferenceScoreControls(store: store)
          Button("重新連結音源") { store.relinkAsset() }
          Button("清除分析快取") { store.clearCache() }
        }.font(.caption2).padding(.top, 9)
      }.font(.caption).disabled(store.busy).modifier(InspectorCard())
      DisclosureGroup("處理紀錄") {
        ForEach(Array(store.log.enumerated()), id: \.offset) { _, text in
          Text(text).font(.system(size: 10)).foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }.font(.caption).modifier(InspectorCard())
    }.padding(12)
  }
  private var analysisControls: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Button("分析全曲") { store.analyze(fullSong: true) }
          .accessibilityIdentifier("analyze-song")
          .disabled(!store.canAnalyze)
        Spacer(minLength: 0)
        InformationButton(title: "全曲分析", message: "依目前格線更新整首的和弦候選。格線調整後可再次分析。人工標註與鎖定會保留。")
      }.font(.caption)
      if !store.analysisSummary.isEmpty {
        Text(store.analysisSummary).font(.caption2).foregroundStyle(Palette.muted)
      }
      if !store.analysisExclusions.isEmpty {
        DisclosureGroup("未分析區間（\(store.analysisExclusions.count)）") {
          ForEach(Array(store.analysisExclusions.enumerated()), id: \.offset) { _, message in
            Text(message).font(.caption2).foregroundStyle(Palette.amber)
          }
        }.font(.caption2)
      }
    }
  }
  // 顯示優先序：已鎖定人工值（可為空）→ 未鎖定人工值 → 未過期的自動候選。
  private func summary(_ r: HarmonyRegion) -> some View {
    let a = r.annotation
    let e = store.freshEvidence(r)
    let root = a.rootLocked ? a.root : !a.root.isEmpty ? a.root : e?.root.map(Pitch.pc) ?? ""
    let chord = a.chordLocked ? a.chord : !a.chord.isEmpty ? a.chord : e?.chord ?? ""
    let hasValues = !root.isEmpty || !chord.isEmpty || a.rootLocked || a.chordLocked
    return VStack(alignment: .leading, spacing: 8) {
      if hasValues {
        HStack {
          valueRow("推定 Root", root, a.rootLocked)
          Spacer()
          valueRow("和弦大方向", chord, a.chordLocked)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("analysis-result-values")
      } else if e != nil || r.evidence == nil {
        Text(e == nil ? "尚未分析 · 可先手動標註" : "分析完成 · 暫無可用候選")
          .font(.caption2).foregroundStyle(Palette.muted)
          .accessibilityIdentifier("analysis-result-empty")
      }
      if let note = store.firstScoreNote {
        Text(
          "原譜：\(note.name)\(note.tieStop ? "（延續）":"") · 拍 \(note.beat-store.measure.beat+1,specifier:"%.2f")"
        ).font(.caption2).foregroundStyle(Palette.muted)
      }
      if let previous = r.evidence, previous.timingRevision != store.project.timing.revision {
        Label("來源／對齊已變更，候選待更新", systemImage: "clock.arrow.circlepath").font(.caption2)
          .foregroundStyle(Palette.amber)
      }
    }
  }
  private func valueRow(_ title: String, _ value: String, _ locked: Bool) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 5) {
        Text(title).font(.system(size: 10)).foregroundStyle(Palette.muted)
        if locked {
          Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(Palette.mint)
        }
      }
      if value.isEmpty {
        Text(locked ? "已鎖定空白" : "—").font(.caption).foregroundStyle(Palette.muted)
      } else {
        Text(value).font(.system(size: 27, weight: .medium, design: .monospaced))
          .foregroundStyle(Palette.mint)
      }
    }
  }
  // 「確認」是人工決策；自動候選與每個欄位的獨立 lock 不共用同一個狀態。
  private func annotations(_ r: HarmonyRegion) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      annotationField(
        "Root", value: r.annotation.root, locked: r.annotation.rootLocked,
        set: { v in store.annotate(regionID: r.id) { if !$0.rootLocked { $0.root = v } } },
        lock: { v in store.annotate(regionID: r.id) { $0.rootLocked = v } })
      annotationField(
        "和弦", value: r.annotation.chord, locked: r.annotation.chordLocked,
        set: { v in store.annotate(regionID: r.id) { if !$0.chordLocked { $0.chord = v } } },
        lock: { v in store.annotate(regionID: r.id) { $0.chordLocked = v } })
      Button(r.annotation.confirmed ? "解除本區間確認" : "確認並鎖定本區間") {
        store.annotate(regionID: r.id) { a in
          if a.confirmed {
            a.confirmed = false
            a.rootLocked = false
            a.chordLocked = false
          } else {
            if !a.rootLocked && a.root.isEmpty {
              a.root = store.freshEvidence(r)?.root.map(Pitch.pc) ?? ""
            }
            if !a.chordLocked && a.chord.isEmpty { a.chord = store.freshEvidence(r)?.chord ?? "" }
            a.confirmed = true
            a.rootLocked = true
            a.chordLocked = true
          }
        }
      }.font(.caption).frame(maxWidth: .infinity)
      Text("鎖定空白代表暫無法判定。重新分析會保留人工標註。").font(.system(size: 9)).foregroundStyle(
        Palette.muted
      ).fixedSize(horizontal: false, vertical: true)
      if r.annotation.firstLocked || !r.annotation.firstNote.isEmpty {
        DisclosureGroup("既有首音標註") {
          annotationField(
            "首音", value: r.annotation.firstNote, locked: r.annotation.firstLocked,
            set: { v in store.annotate(regionID: r.id) { if !$0.firstLocked { $0.firstNote = v } } },
            lock: { v in store.annotate(regionID: r.id) { $0.firstLocked = v } })
        }.font(.caption2)
      }
    }
  }
  private func annotationField(
    _ label: String, value: String, locked: Bool, set: @escaping (String) -> Void,
    lock: @escaping (Bool) -> Void
  ) -> some View {
    HStack {
      Text(label).font(.caption).frame(width: 30, alignment: .leading)
      TextField("手動標註", text: Binding(get: { value }, set: set)).textFieldStyle(.roundedBorder)
        .controlFeedback(.field).accessibilityIdentifier("annotation-\(label)")
        .focused($annotationFocus, equals: label)
        .disabled(locked)
      Toggle(isOn: Binding(get: { locked }, set: lock)) {
        Image(systemName: locked ? "lock.fill" : "lock.open")
      }.toggleStyle(.checkbox).labelsHidden().controlFeedback().help(locked ? "解除鎖定" : "鎖定此欄")
    }
  }
  @ViewBuilder private func candidates(_ r: HarmonyRegion, _ e: HarmonyEvidence) -> some View {
    let visible = e.candidates.prefix(3).filter { !r.annotation.rejected.contains($0.symbol) }
    if !visible.isEmpty || !r.annotation.rejected.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Divider()
        Text("和弦候選").font(.caption.weight(.semibold))
        ForEach(visible) { c in
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              HStack {
                Text(c.symbol).font(.system(size: 15, weight: .medium, design: .monospaced))
                Text(String(format: "%.2f", c.score)).font(.system(size: 9, design: .monospaced))
                  .foregroundStyle(Palette.muted)
              }
              if e.method != AnalysisMethod.btcHarmony && !c.support.isEmpty {
                Text(c.support.joined(separator: " · ")).font(.system(size: 9)).foregroundStyle(Palette.muted)
              }
            }
            Spacer()
            Button("採用") { store.accept(c, regionID: r.id) }.font(.caption2)
              .accessibilityIdentifier("adopt-chord-\(c.symbol)").disabled(
                (r.annotation.rootLocked && r.annotation.chordLocked) || store.freshEvidence(r) == nil)
            Button {
              store.reject(c, regionID: r.id)
            } label: {
              Image(systemName: "xmark").font(.system(size: 9)).modifier(IconButtonFace())
            }.buttonStyle(HoverButton(base: PlainButtonStyle(), border: Palette.amber, kind: .icon)).help("忽略此候選")
          }
        }
        if !r.annotation.rejected.isEmpty {
          Button("恢復已忽略候選（\(r.annotation.rejected.count)）") {
            store.annotate(regionID: r.id) { $0.rejected = [] }
          }
          .font(.caption2)
        }
      }
    }
  }
  private func evidence(_ r: HarmonyRegion, _ e: HarmonyEvidence) -> some View {
    DisclosureGroup("判斷依據與來源") {
      VStack(alignment: .leading, spacing: 8) {
        Text(
          "低音重心：\(e.bassCenter.map(Pitch.name) ?? "—")\nRoot 候選差距：\(String(format:"%.3f",e.rootMargin))\n方法：\(e.method)"
        ).font(.system(size: 10)).foregroundStyle(Palette.muted).textSelection(.enabled)
        if e.method == AnalysisMethod.tunedHarmony, let cents = e.tuningCents {
          Text("全曲調音 \(cents, specifier: "%+.0f") cents").font(.caption2).foregroundStyle(Palette.muted)
        }
        ForEach(e.warnings, id: \.self) {
          Text($0).font(.system(size: 10)).foregroundStyle(Palette.amber).fixedSize(
            horizontal: false, vertical: true)
        }
      }.padding(.top, 7)
    }.font(.caption)
  }
  private var context: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("前後行進").font(.caption).foregroundStyle(Palette.muted)
      HStack {
        ForEach(
          store.project.regions.filter {
            abs($0.startBeat - store.measure.beat) < store.measure.length * 2
          }.sorted { $0.startBeat < $1.startBeat }.prefix(5)
        ) { r in
          Text(store.chordText(r).isEmpty ? "—" : store.chordText(r)).font(
            .system(size: 12, design: .monospaced)
          ).foregroundStyle(r.measureID == store.measure.id ? Palette.mint : Palette.muted)
          if r.id != store.project.regions.last?.id {
            Text("→").font(.caption2).foregroundStyle(Palette.muted.opacity(0.5))
          }
        }
      }
    }
  }
}
