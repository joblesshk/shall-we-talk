import AppKit
import ShallWeTalkCore
import SwiftUI

/// Power Mode 设置界面:为单个 App 绑定整理档位。
///
/// 添加入口刻意用「选择 App…」的系统文件选择器指向 /Applications,而不是让用户手打
/// bundle ID——bundle ID 打错不会报错,只会静默不生效,那是最难自查的一类故障。
struct AppProfileEditor: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("为特定 App 单独设定整理力度与自定义指令。未列出的 App 一律使用上面的全局设置。")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)

            ForEach(settings.appProfiles) { profile in
                AppProfileRow(
                    profile: profile,
                    onChange: { settings.upsertAppProfile($0) },
                    onRemove: { settings.removeAppProfile(bundleID: profile.bundleID) })
            }

            HStack(spacing: 8) {
                Button("选择 App…") { addProfile() }
                    .buttonStyle(.quietStroke)
                if let frontmost = FrontmostApp.current(),
                   settings.appProfile(for: frontmost.bundleID) == nil {
                    Button("添加当前前台:\(frontmost.name)") {
                        settings.upsertAppProfile(
                            AppProfile(bundleID: frontmost.bundleID, displayName: frontmost.name))
                    }
                    .buttonStyle(.link).font(.system(size: 11))
                }
            }
        }
    }

    private func addProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        settings.upsertAppProfile(AppProfile(bundleID: bundleID, displayName: name))
    }
}

private struct AppProfileRow: View {
    let profile: AppProfile
    let onChange: (AppProfile) -> Void
    let onRemove: () -> Void

    /// 力度选择器多一个「跟随全局」项:`AppProfile.cleanupLevel` 为 nil 时不覆盖全局。
    private static let inheritTag = "__inherit__"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(profile.displayName).font(.system(size: 12, weight: .medium))
                Text(profile.bundleID).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("移除", action: onRemove)
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
            }

            Toggle("不整理,直接插入识别原文", isOn: Binding(
                get: { profile.skipCleanup },
                set: { var next = profile; next.skipCleanup = $0; onChange(next) }))
            .font(.system(size: 11))

            if !profile.skipCleanup {
                Picker("整理力度", selection: Binding(
                    get: { profile.cleanupLevel?.rawValue ?? Self.inheritTag },
                    set: { raw in
                        var next = profile
                        next.cleanupLevel = raw == Self.inheritTag ? nil : CleanupLevel(rawValue: raw)
                        onChange(next)
                    })) {
                    Text("跟随全局").tag(Self.inheritTag)
                    ForEach(CleanupLevel.allCases) { level in
                        Text(level.rawValue).tag(level.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .font(.system(size: 11))

                Toggle("为这个 App 单独写自定义指令", isOn: Binding(
                    get: { profile.customPrompt != nil },
                    set: { enabled in
                        var next = profile
                        next.customPrompt = enabled ? "" : nil
                        onChange(next)
                    }))
                .font(.system(size: 11))

                if profile.customPrompt != nil {
                    TextEditor(text: Binding(
                        get: { profile.customPrompt ?? "" },
                        set: { var next = profile; next.customPrompt = $0; onChange(next) }))
                    .frame(height: 60)
                    .font(.system(size: 11))
                }
            }
        }
        .padding(8)
        .background(Theme.accent.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
