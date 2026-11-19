import SwiftUI

/// 拍號只修改外層共用草稿；起點由 AlignmentControls 的唯一欄位設定。
struct EstimatedGridControls: View {
  @Binding var numerator: Int
  @Binding var denominator: Int
  var body: some View {
    HStack(spacing: 7) {
      Text("2. 拍號").fontWeight(.medium)
      Picker("每小節拍數", selection: $numerator) {
        ForEach(1...12, id: \.self) { Text("\($0)").tag($0) }
      }.labelsHidden().frame(width: 58).controlFeedback().accessibilityIdentifier("grid-numerator")
      Text("／")
      Picker("拍號分母", selection: $denominator) {
        ForEach([2, 4, 8, 16], id: \.self) { Text("\($0)").tag($0) }
      }.labelsHidden().frame(width: 58).controlFeedback().accessibilityIdentifier("grid-denominator")
      Spacer(minLength: 0)
      InformationButton(title: "無譜小節格線", message: "依曲長與拍號建立小節。變更拍號會重建格線，舊標註保留於歷史。")
    }
  }
}
