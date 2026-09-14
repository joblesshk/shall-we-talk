import AppKit
import ShallWeTalkCore

/// 按前台 App 绑定的整理档位(Power Mode)。
///
/// iOS 键盘扩展拿不到宿主 bundle ID,只能按输入框类型路由(见 `HostFieldKind`);
/// macOS 没有这个限制——VoicePen 是 `LSUIElement` 菜单栏 App,永远不会成为前台,
/// 所以起录瞬间 `NSWorkspace.frontmostApplication` 就是用户真正在写字的那个 App。
///
/// 设计上刻意只覆盖三件事:整理力度、自定义指令、是否整理。再多的按 App 配置
/// (词典、供应商、快捷键)都还没有被真实需求验证,不预留。
struct AppProfile: Codable, Identifiable, Equatable {
    /// 前台 App 的 bundle ID,同时用作主键。
    var bundleID: String
    /// 展示名。只用于设置页,匹配一律按 bundleID。
    var displayName: String
    /// 该 App 下不做 LLM 整理,直接插入 ASR 原文。命中时另外两项被忽略。
    var skipCleanup: Bool = false
    /// 覆盖全局整理力度;nil = 沿用全局设置。
    var cleanupLevelRaw: String?
    /// 覆盖全局自定义指令;nil = 沿用全局设置。空字符串是有效值,表示"这个 App 下不要自定义指令"。
    var customPrompt: String?

    var id: String { bundleID }

    var cleanupLevel: CleanupLevel? {
        get { cleanupLevelRaw.flatMap(CleanupLevel.init(rawValue:)) }
        set { cleanupLevelRaw = newValue?.rawValue }
    }
}

/// 一次口述实际生效的整理参数:全局设置叠加当前 App 的覆盖项。
struct ResolvedCleanupSettings {
    var level: CleanupLevel
    var customInstruction: String
    var skipCleanup: Bool

    /// `profile` 为 nil(没有为该 App 配过档位,或读不到前台 App)时逐字等于全局设置,
    /// 即 Power Mode 引入前的行为。
    ///
    /// 轻档仍调用整理模型，只是固定使用短口述 prompt。只有 App Profile
    /// 明确开启 `skipCleanup` 时才直接插入 ASR 原文。
    static func resolve(global level: CleanupLevel,
                        customInstruction: String,
                        profile: AppProfile?) -> ResolvedCleanupSettings {
        guard let profile else {
            return ResolvedCleanupSettings(level: level, customInstruction: customInstruction,
                                           skipCleanup: false)
        }
        let effectiveLevel = profile.cleanupLevel ?? level
        return ResolvedCleanupSettings(
            level: effectiveLevel,
            customInstruction: profile.customPrompt ?? customInstruction,
            skipCleanup: profile.skipCleanup)
    }
}

enum FrontmostApp {
    /// 起录瞬间的前台 App。VoicePen 自身是 `LSUIElement`,不会出现在这里;
    /// 万一出现(例如设置窗口被激活),返回 nil 让调用方回落全局设置。
    static func current() -> (bundleID: String, name: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return nil }
        return (bundleID, app.localizedName ?? bundleID)
    }
}
