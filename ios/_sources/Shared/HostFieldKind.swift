import Foundation

/// 宿主输入框的语义类别。
///
/// iOS 键盘扩展没有读取宿主 bundle ID 的公开 API,所以 per-app 档位在 iOS 上做不了;
/// 但系统必须告诉键盘"你站在什么样的输入框里"(邮箱框要给 @ 键、数字框给数字盘、
/// 搜索框的回车键要写"搜索"),这份信息通过 `UITextInputTraits` 可读,键盘早就在用
/// `returnKeyType` 给回车键标字。这里把同一份信号接到整理路由上。
///
/// macOS 不受此限制,前台 App 的 bundle ID 直接可读,走按 App 档位的 Power Mode。
/// 也正因为这条规则只由 `UITextInputTraits` 推导,它是 iOS 独有的,不进跨端的
/// ShallWeTalkCore;放在 `_sources/Shared/` 由主 App 与键盘扩展同模块编译,
/// 两边都不需要额外的 import 或链接。
enum HostFieldKind: String, Codable, Sendable, CaseIterable {
    /// 普通文本框:维持按录音时长路由的现有行为。
    case general
    /// 搜索框(`returnKeyType == .search`)。
    case search
    /// 即时通讯发送框(`returnKeyType == .send`)。
    case messaging
    /// 邮箱、网址、数字与电话框:整理只会添乱。
    case restricted
}

/// 输入框语义对整理环节的裁决。
enum FieldCleanupPolicy: Equatable, Sendable {
    /// 不调用 LLM,直接使用 ASR 原文。
    case skipCleanup
    /// 强制走同音纠错短路由,忽略录音时长。
    case forceShort
    /// 维持现状:由 `DictationPolicy.cleanupPromptRoute` 按成组列举信号与录音时长裁决。
    case byDuration
}

extension HostFieldKind {
    /// 该输入框应当怎么整理。
    ///
    /// 搜索框强制短路由的原因:`DictationPolicy` 的时长阈值是全局的,在搜索框里说满阈值
    /// 会走完整 prompt 并按规则分段编号,而搜索框要的只是一串关键词。完整 prompt 约
    /// 5700 字符、短 prompt 约 2200,这里同时省掉一截延迟。
    ///
    /// `messaging` 按录音时长路由:即时通讯聊天框中的长口述仍在一次完整整理中执行
    /// 分段和编号,不能因为宿主把回车键标为“发送”就退化成短口述 prompt。
    ///
    /// 密码框(`isSecureTextEntry`)按 2026-08-14 的决定不做特殊处理,归入 `general`。
    var cleanupPolicy: FieldCleanupPolicy {
        switch self {
        case .restricted: return .skipCleanup
        case .search: return .forceShort
        case .messaging: return .byDuration
        case .general: return .byDuration
        }
    }

    /// 投递到宿主输入框前的确定性变换。搜索词不需要句末或分隔标点，因此由程序删除
    /// Unicode 标点并把换行/连续空白压成单个空格；不依赖整理模型是否遵守提示词。
    /// 其他输入框逐字保留整理结果。
    func textForDelivery(_ text: String) -> String {
        guard self == .search else { return text }
        let withoutPunctuation = text.unicodeScalars
            .filter { !CharacterSet.punctuationCharacters.contains($0) }
            .map(String.init)
            .joined()
        return withoutPunctuation
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

}
