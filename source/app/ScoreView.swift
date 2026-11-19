// 原生 SwiftUI 與本機 OSMD 的邊界：只把完整 XML 傳給網頁顯示，將小節點擊傳回 Swift。

import SwiftUI
import WebKit

struct ScoreView: NSViewRepresentable {
  @Environment(\.isEnabled) private var enabled
  var document: ScoreDocument?
  var folder: URL
  var selected: Int
  var refresh: UUID
  var onMeasure: (Int) -> Void
  var onMeasureLoop: (Int, Int) -> Void
  var loopMeasures: ClosedRange<Int>? = nil
  private var loopContext: String { "\(folder.path)-\(refresh)" }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.userContentController.add(context.coordinator, name: "score")
    // 樂譜視圖不保留網頁儲存，也不需要帳號、CDN 或網路字型。
    config.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .zero, configuration: config)
    web.navigationDelegate = context.coordinator
    web.setValue(false, forKey: "drawsBackground")
    if let root = Bundle.main.resourceURL?.appendingPathComponent("score-viewer") {
      web.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
    }
    context.coordinator.web = web
    return web
  }
  func updateNSView(_ web: WKWebView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.update()
  }
  static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
    web.configuration.userContentController.removeScriptMessageHandler(forName: "score")
    web.navigationDelegate = nil
    web.stopLoading()
  }
  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var parent: ScoreView
    weak var web: WKWebView?
    var ready = false, lastToken = ""
    var lastDocument = ""
    var lastEnabled: Bool?
    var lastLoopMeasures: ClosedRange<Int>?
    init(_ parent: ScoreView) { self.parent = parent }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      ready = true
      update()
    }
    // 只允許本機檔案與 about:blank，樂譜不能把此視圖導向外部網頁。
    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      decisionHandler(
        action.request.url?.isFileURL == true || action.request.url?.absoluteString == "about:blank"
          ? .allow : .cancel)
    }
    func update() {
      guard ready, let web else { return }
      if lastEnabled != parent.enabled {
        lastEnabled = parent.enabled
        web.evaluateJavaScript("setScoreInteractionEnabled(\(parent.enabled));", completionHandler: nil)
      }
      if lastLoopMeasures != parent.loopMeasures {
        lastLoopMeasures = parent.loopMeasures
        let bounds = parent.loopMeasures.map { "\($0.lowerBound),\($0.upperBound)" } ?? "null,null"
        web.evaluateJavaScript("setScoreLoopRange(\(bounds));", completionHandler: nil)
      }
      guard let doc = parent.document else {
        if lastToken != "empty" {
          lastToken = "empty"
          lastDocument = ""
          web.evaluateJavaScript("void loadScore({xml:null,revision:'',selected:0});", completionHandler: nil)
        }
        return
      }
      // 只在文件／小節／顯示 revision 改變時重送，播放游標更新不應反覆載入整份譜。
      let token = "\(doc.revision)-\(parent.selected)-\(parent.loopContext)"
      guard token != lastToken else { return }
      lastToken = token
      do {
        // 同一譜切小節只傳選取；換譜／重新整理才讀完整 XML。
        let previousDocument = lastDocument
        var payload: [String: Any] = ["revision": doc.revision, "selected": parent.selected,
          "measureCount": doc.measures.count, "loopContext": parent.loopContext]
        let documentToken = "\(doc.revision)-\(parent.loopContext)"
        if previousDocument != documentToken {
          payload["xml"] = try String(contentsOf: parent.folder.appendingPathComponent(doc.xmlPath), encoding: .utf8)
          lastDocument = documentToken
        }
        // 用 JSON 序列化傳 XML，不能把檔案文字直接插入 JavaScript 字串。
        let json = String(
          decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        web.evaluateJavaScript("void loadScore(\(json));") { [weak self] _, error in
          if error != nil { self?.lastToken = ""; self?.lastDocument = "" }
        }
      } catch { lastToken = ""; lastDocument = "" }
    }
    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard parent.enabled, let body = message.body as? [String: Any],
        let index = body["index"] as? Int, let document = parent.document,
        body["revision"] as? String == document.revision, document.measures.indices.contains(index)
      else { return }
      switch body["type"] as? String {
      case "measure":
        parent.onMeasure(index)
      case "measure-loop":
        guard body["loopContext"] as? String == parent.loopContext,
          let other = body["other"] as? Int, document.measures.indices.contains(other) else { return }
        parent.onMeasureLoop(index, other)
      default: break
      }
    }
  }
}
