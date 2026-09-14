import Foundation

/// App Group 可用性检测 + 统一 suite 入口。
///
/// 关键:免费 Apple ID 不支持 App Groups。`UserDefaults(suiteName:)` 在无 entitlement 时
/// 仍返回一个「非 nil 但各进程独立、并不共享」的实例——会导致主 App 写、键盘读不到,
/// 且静默不报错。用 `containerURL(forSecurityApplicationGroupIdentifier:)` 判定真实可用性:
/// 有 entitlement(付费/已配)→ 返回目录;免费/未配 → nil。
///
/// 各 store 统一取 `AppGroup.suite`:
///   - 付费/已配:走真正共享的 App Group(结构化桥 + 词库同源全可用)
///   - 免费/未配:suite 为 nil → 各 store 自动降级(文字接力落剪贴板、桥/同源 no-op)
enum AppGroup {
    static let id = "group.org.example.voicepen"

    /// ★免费账号构建开关:true 时强制关闭 App Group,全程走 Darwin+剪贴板(确定性,不靠探测)。
    /// 实测 containerURL 在 Personal Team 上会误判为"可用",导致跑那条不能真正跨进程共享、
    /// 状态卡在 opening 的 App Group 老路,故免费账号必须显式关闭,不靠探测。
    /// 2026-07-10:已升级付费开发者账号并在 project.yml 启用 entitlements,改为 false,
    /// 用回 App Group 实时桥(可流式显示识别文本)。Darwin+剪贴板兜底代码保留,
    /// 日后降级回免费账号时把这里改回 true 即可。
    static let freeAccountBuild = false

    /// 该 App Group 是否真正可用。
    static var isAvailable: Bool {
        guard !freeAccountBuild else { return false }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil
    }

    /// 真正共享的 UserDefaults;不可用时返回 nil(触发各 store 的降级路径)。
    static var suite: UserDefaults? {
        isAvailable ? UserDefaults(suiteName: id) : nil
    }
}
