import SwiftUI

/// BPM 輸入與候選只改共用草稿；由外層一次套用整區。
struct TempoControls: View {
  @ObservedObject var store: WorkbenchStore
  @Binding var input: String
  var anchorsLocked: Bool
  var submit: () -> Void
  @State private var inspected: Double?
  @State private var showingDetails = false
  @State private var showingModels = false
  @FocusState private var editing: Bool
  private var estimate: TempoEstimate? { store.currentTempoEstimate }
  private var estimating: Bool { store.activeAnalysis == .tempo }
  private var estimateTitle: String {
    if estimating { return "估測中…" }
    return estimate == nil ? "估測 BPM" : "重新估測"
  }
  private var candidate: TempoCandidate? {
    guard let estimate, let bpm = inspected ?? estimate.preferredBPM else { return nil }
    return estimate.candidates?.first { $0.bpm == bpm }
  }
  private var needsReview: Bool {
    guard let estimate else { return false }
    return estimate.preferredBPM == nil || candidate.map { $0.fit.status != "good" } == true
  }
  private func number(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...6)).grouping(.never))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 7) {
        Text("1. BPM").fontWeight(.medium)
        TextField("100", text: $input).frame(width: 92).focused($editing).controlFeedback(.field)
          .accessibilityIdentifier("alignment-bpm").onSubmit(submit)
          .help("輸入 20–400 BPM，按 Enter 確認整區設定")
          .disabled(anchorsLocked)
        Spacer(minLength: 0)
        estimateControl
        Button { showingDetails.toggle() } label: { Image(systemName: "info.circle").modifier(IconButtonFace()) }
          .buttonStyle(HoverButton(base: PlainButtonStyle(), kind: .icon)).accessibilityLabel("BPM 估測詳情")
          .accessibilityIdentifier("tempo-details").help("顯示 BPM 估測詳情")
          .popover(isPresented: $showingDetails) { details }
      }
      Text("估測模型 · \(store.tempoEstimator.title)")
        .foregroundStyle(Palette.muted).accessibilityIdentifier("tempo-model-label")
      if let notice = store.tempoModelNotice { Text(notice).foregroundStyle(Palette.amber) }
      if let estimate {
        if estimate.buttonBPMS.isEmpty {
          Text("未找到可用的 BPM 候選").foregroundStyle(Palette.amber)
            .accessibilityIdentifier("tempo-no-candidates")
        } else {
          options(estimate)
          if needsReview {
            Text("需人工確認").foregroundStyle(Palette.amber)
              .accessibilityIdentifier("tempo-review")
          }
        }
      }
    }.font(.caption2).disabled(store.busy)
      .onChange(of: store.project.id) { inspected = nil; showingDetails = false; showingModels = false }
      .onChange(of: store.busy) { if store.busy { showingModels = false; showingDetails = false } }
      .onChange(of: estimate) { inspected = nil }
      .onChange(of: editing) { _, value in store.setEditing("tempo", active: value) }
      .onDisappear { store.setEditing("tempo", active: false) }
  }
  private var estimateControl: some View {
    ControlGroup {
      Button(estimateTitle) { store.estimateTempo() }
        .accessibilityIdentifier("estimate-tempo")
      Button { showingModels.toggle() } label: {
        Image(systemName: "chevron.down")
      }
      .accessibilityLabel("使用其他模型重新估測")
      .accessibilityIdentifier("tempo-model")
      .help("使用其他模型重新估測")
    }
    .popover(isPresented: $showingModels, arrowEdge: .bottom) { modelChoices }
    .disabled(store.project.masterAsset == nil)
  }
  private var modelChoices: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("使用其他模型重新估測").fontWeight(.medium)
      Label("\(store.tempoEstimator.title)（目前）", systemImage: "checkmark")
        .foregroundStyle(Palette.muted).accessibilityIdentifier("tempo-current-model")
      Divider()
      ForEach(TempoEstimator.allCases.filter { $0 != store.tempoEstimator }) { model in
        let available = model != .small0 || store.small0Available
        Button(available ? model.title : "\(model.title)（未安裝）") {
          showingModels = false
          store.estimateTempo(using: model)
        }
        .disabled(!available || store.busy)
        .accessibilityIdentifier("tempo-model-\(model.rawValue)")
      }
    }.lineLimit(1).fixedSize(horizontal: true, vertical: false).padding(12)
  }
  private func options(_ estimate: TempoEstimate) -> some View {
    HStack(alignment: .top, spacing: 7) {
      Text("填入 BPM 草稿").foregroundStyle(Palette.muted).frame(width: 86, alignment: .leading)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), alignment: .leading)], alignment: .leading) {
        ForEach(Array(estimate.buttonBPMS.enumerated()), id: \.offset) { index, bpm in
          option(bpm, index: index, recommended: estimate.recommendedBPM == bpm)
        }
      }
    }
  }
  private func option(_ bpm: Double, index: Int, recommended: Bool) -> some View {
    let active = Double(input) == bpm
    return Button {
      inspected = bpm
      input = String(bpm); editing = false
    } label: {
      Text(number(bpm) + (recommended ? " · 建議" : ""))
        .foregroundStyle(active ? Palette.mint : Color.primary)
    }.accessibilityIdentifier("tempo-option-\(index)")
      .accessibilityValue(active ? (store.project.timing.bpm == bpm ? "目前速度" : "待確認") : "未選用")
      .disabled(anchorsLocked)
  }
  private var details: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 9) {
        Text("BPM 估測詳情").font(.headline)
        if let estimate {
          Text("• 估測方法：\(estimate.estimator == "small0" ? "Beat This! small0（CPU）" : "librosa")")
          if let c = candidate {
            Text("• 檢視候選：\(number(c.bpm)) BPM")
            Text("• \(c.usedFloat ? "量化未通過，保留浮點速度" : "使用量化速度")；量化前 \(number(c.originalBPM)) BPM")
            Text("• P95：\(c.fit.p95Ms, specifier: "%.1f") ms（95% 配對起音的誤差不超過此值）")
            Text("• 誤差中位數：\(c.fit.medianMs, specifier: "%.1f") ms；最大值：\(c.fit.maxMs, specifier: "%.1f") ms")
            Text("• 前後漂移：\(c.fit.driftMs, specifier: "%+.1f") ms（後段與前段誤差之差）")
            Text("• 觀測：\(c.fit.count) 個起音；配對 \(Int(c.fit.coverage * 100))%")
            Text("• 評估：\(estimate.start, specifier: "%.1f")–\(estimate.end, specifier: "%.1f") 秒")
            Text("• 截距：\(c.fit.intercept, specifier: "%.4f") 秒；不代表第一小節起點")
          }
          ForEach(Array(estimate.warnings.enumerated()), id: \.offset) { _, warning in Text("• \(warning)") }
          if !estimate.beats.isEmpty {
            HStack(alignment: .top, spacing: 7) {
              Text("拍點試聽定位").foregroundStyle(Palette.muted).frame(width: 86, alignment: .leading)
              LazyVGrid(columns: [GridItem(.adaptive(minimum: 62))], alignment: .leading) {
                ForEach(Array(estimate.beats.prefix(8).enumerated()), id: \.offset) { _, second in
                  Button(String(format: "%.2fs", second)) { store.seek(second) }
                }
              }
            }
          }
        } else { Text("• 先估測 BPM，或直接輸入速度。") }
        Text("• 候選順序不是正確機率；半／倍速、拍號與小節起點仍需聆聽確認。")
      }.font(.caption).fixedSize(horizontal: false, vertical: true).padding(14)
    }.frame(width: 350, height: 370).accessibilityIdentifier("tempo-details-content")
  }
}
