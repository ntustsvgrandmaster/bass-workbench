// 應用程式入口：建立唯一工作視窗，接收專案檔開啟要求，並在結束前保存。

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  static var store: WorkbenchStore?
  // 從 Finder 冷啟動時，視窗的 Store 可能尚未建立；暫存檔案路徑等 onAppear 接手。
  static var pendingFile: String?
  static var initialized = false
  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    Task { @MainActor in
      if let path = filenames.first {
        if let store = Self.store {
          store.openProject(URL(fileURLWithPath: path))
        } else {
          Self.pendingFile = path
        }
      }
      sender.reply(toOpenOrPrint: .success)
    }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if Self.store?.analysisRunning == true { Self.store?.cancel() }
    Self.store?.persist()
    return .terminateNow
  }
}
@main struct BassHarmonyApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var store = WorkbenchStore()
  var body: some Scene {
    Window("Bass Workbench · Harmony", id: "workbench") {
      WorkbenchView().environmentObject(store).onAppear {
        AppDelegate.store = store
        // 只在首次出現時恢復上次專案，避免視窗更新時反覆載入、洗掉目前編輯。
        if !AppDelegate.initialized {
          AppDelegate.initialized = true
          if let path = AppDelegate.pendingFile ?? ProcessInfo.processInfo.environment[
            "BASS_OPEN_PROJECT"] ?? UserDefaults.standard.string(forKey: "lastProject")
          {
            store.openProject(URL(fileURLWithPath: path))
            AppDelegate.pendingFile = nil
          }
        }
      }.onOpenURL { url in store.openProject(url) }
    }.defaultSize(width: 1280, height: 920).commands {
      CommandGroup(replacing: .newItem) {
        Button("新增採譜專案") { store.newProject() }.keyboardShortcut("n").disabled(store.busy)
        Button("開啟專案…") { store.chooseProject() }.keyboardShortcut("o").disabled(store.busy)
        Button("顯示目前自動儲存位置") { store.revealAutosave() }.disabled(store.busy)
        Button("儲存專案…") { store.save() }.keyboardShortcut("s").disabled(store.busy)
        Button("另存完整專案…") { store.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
          .disabled(store.busy)
      }
      CommandGroup(replacing: .undoRedo) {
        Button("復原") { store.undo() }.keyboardShortcut("z").disabled(!store.canUndo || store.busy)
        Button("重做") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(
          !store.canRedo || store.busy)
      }
      CommandMenu("採譜") {
        Button("匯入原曲／Stem…") { store.chooseAudio() }.disabled(store.busy)
        Button("匯入完整樂譜…") { store.chooseScore() }.disabled(store.busy)
        Divider()
        Button("分析目前範圍") { store.analyze() }.keyboardShortcut("r").disabled(
          !store.canAnalyze)
        Button("播放／暫停") { store.playPause() }.keyboardShortcut(.space, modifiers: [.command])
          .disabled(store.busy || store.currentAsset == nil)
        Button("在 MuseScore 編輯副本") { store.editInMuseScore() }.disabled(
          store.project.score == nil || store.busy)
      }
    }
  }
}
