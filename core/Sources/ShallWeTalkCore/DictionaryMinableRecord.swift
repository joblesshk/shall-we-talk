import Foundation

/// DictionaryMiner 挖掘所需的最小字段集合。两端各自的 `DictationRecord`(HistoryStore.swift,
/// 平台存储层,不进本包)通过 `extension DictationRecord: DictionaryMinableRecord {}` 满足此协议,
/// 使 DictionaryMiner 不必依赖 App 的存储模型。
public protocol DictionaryMinableRecord {
    var finalText: String? { get }
    var cleanText: String { get }
}
