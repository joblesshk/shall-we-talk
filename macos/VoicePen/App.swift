import SwiftUI
import AVFoundation
import ShallWeTalkCore

@main
struct VoicePenApp: App {
    @NSApplicationDelegateAdaptor(VoicePenAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    init() {
        // core 包的诊断日志出口:macOS 现有日志机制是 NSLog(Console.app 可查)。
        // 不安装 handler 时 CoreDiagLog 静默丢弃,词典/历史同步日志会全部丢失。
        CoreDiagLog.handler = { component, message in
            NSLog("Shall We Talk [%@] %@", component, message)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(appState)
        } label: {
            MenuBarLabelView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }

        Window("口述历史", id: "history") {
            HistoryWindowView()
                .environmentObject(appState)
        }
        .defaultSize(width: 800, height: 540)

        Window("闪念待办", id: "todos") {
            TodoWindowView()
                .environmentObject(appState)
        }
        .defaultSize(width: 380, height: 520)

        Window("生词词典", id: "dictionary") {
            DictionaryWindowView()
                .environmentObject(appState)
        }
        .defaultSize(width: 760, height: 620)

    }
}

@MainActor
final class VoicePenAppDelegate: NSObject, NSApplicationDelegate {
    static weak var appState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let warning = Self.appState?.terminationWarning else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "当前工作尚未安全完成"
        alert.informativeText = warning + "\n仍然退出可能丢失尚未保存的内容。"
        alert.addButton(withTitle: "继续使用")
        alert.addButton(withTitle: "仍然退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// 菜单栏图标直接使用应用包内的真实五段声波图标，保持与 iOS、Dock 一致。
private struct MenuBarLabelView: View {
    var body: some View {
        Image(nsImage: MenuBarIcon.image)
    }
}
