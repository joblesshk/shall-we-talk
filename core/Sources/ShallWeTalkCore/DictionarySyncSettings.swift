import Foundation

/// `DictionarySyncCoordinator`(App 层,duplicated in ios/_sources/Shared 与
/// macos/VoicePen/Services,与 `CloudHistorySync` 同款模式)所需的最小读写字段集合。
/// 两端的 `SettingsStore`(macOS)/`MobileSettingsStore`(iOS)已经天然拥有这些同名属性,
/// 通过 `extension X: DictionarySyncSettings {}` 一行满足协议,不必改动既有存储层——
/// 与 `DictionaryMinableRecord` 对 `DictationRecord` 的处理方式一致。
public protocol DictionarySyncSettings: AnyObject {
    var manualDictionaryWords: [String] { get }
    var autoDictionaryWords: [String] { get }
    var blockedDictionaryWords: Set<String> { get }
    var userDictionaryRaw: String { get set }
    var autoDictionaryRaw: String { get set }
    var dictionaryBlocklistRaw: String { get set }
}

/// 每一轮用户操作最多安排三次重试，后台恢复不会无限请求。
public enum DictionarySyncRetry {
    public static func delay(afterFailures attempt: Int) -> TimeInterval? {
        let delays: [TimeInterval] = [5, 15, 45]
        return delays.indices.contains(attempt) ? delays[attempt] : nil
    }
}
