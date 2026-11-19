import Foundation

@MainActor protocol DraftEditing: AnyObject {
  var project: Project { get }
  func loopValidation(a: Double, b: Double) -> String?
  func setLoop(a: Double?, b: Double?, enable: Bool?) -> Bool
  func renameProject(_ title: String) -> Bool
  func setEditing(_ scope: String, active: Bool)
}

enum LoopRange {
  static func validation(a: Double, b: Double, asset: MediaAsset?) -> String? {
    guard a.isFinite, b.isFinite, a >= 0, b > a + 0.04 else {
      return "B 必須大於 A，且區段需超過 0.04 秒。"
    }
    guard b - a <= 180 else { return "A–B 循環上限為 180 秒。" }
    if let asset, a < max(0, asset.offset) || b > asset.duration + asset.offset {
      return "必須在目前音源涵蓋的時間內。"
    }
    return nil
  }
}

/// 畫面輸入的草稿；只有明確提交才更新專案，便於獨立驗證中途輸入與取消。
struct LoopDraft {
  var a = ""
  var b = ""
  var validation: String?

  mutating func reset(a: Double, b: Double) {
    self.a = String(format: "%.3f", a)
    self.b = String(format: "%.3f", b)
    validation = nil
  }

  @MainActor @discardableResult mutating func apply(to store: DraftEditing) -> Bool {
    guard let start = Double(a.trimmingCharacters(in: .whitespacesAndNewlines)),
      let end = Double(b.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      validation = "請輸入有效秒數。"
      return false
    }
    if let message = store.loopValidation(a: start, b: end) {
      validation = message
      return false
    }
    guard store.setLoop(a: start, b: end, enable: nil) else { return false }
    reset(a: store.project.a, b: store.project.b)
    return true
  }
}

struct ProjectTitleDraft {
  var editing = false
  var text = ""
  var invalid = false

  @MainActor mutating func begin(in store: DraftEditing) {
    text = store.project.title
    invalid = false
    editing = true
    store.setEditing("title", active: true)
  }
  @MainActor @discardableResult mutating func save(to store: DraftEditing) -> Bool {
    guard store.renameProject(text) else {
      invalid = true
      return false
    }
    cancel(in: store)
    return true
  }
  @MainActor mutating func cancel(in store: DraftEditing) {
    editing = false
    invalid = false
    store.setEditing("title", active: false)
  }
}
