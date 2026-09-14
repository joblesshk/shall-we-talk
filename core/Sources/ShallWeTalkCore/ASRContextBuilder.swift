import Foundation

/// ASRContextBuilder 所需的最小字段集合。两端各自的 `DictationRecord`(HistoryStore.swift,
/// 平台存储层,不进本包)通过 `extension DictationRecord: RecentTextRecord {}` 满足此协议,
/// 与 DictionaryMinableRecord 同样的设计,使本包不必依赖 App 的存储模型。
public protocol RecentTextRecord: DictionaryMinableRecord {
    var date: Date { get }
}

/// 把最近一段时间内已产出的口述文字打包成火山 ASR 的 `context_data`(对话历史),
/// 随 `corpus.context` 一起传给识别请求,辅助后续识别——同一时间窗内反复出现的
/// 人名、术语、话题,让模型带着"最近说过什么"的线索去判断同音字。
///
/// 容量对齐火山文档(2026-08-16 核对 docs.volcengine.com/docs/6561/2604976「热词与上下文」):
/// 800 tokens、20 轮(含)以内,超出时服务端也会按新→旧截断,但客户端先截一次可以省首包体积、
/// 避免文档提到的"传满 20 轮会影响性能"。
public enum ASRContextBuilder {
    public static let lookbackSeconds: TimeInterval = 20 * 60
    public static let maxTurns = 20
    /// 中文场景下 1 字约占 1~2 token,按上限 2 保守估算,给 800 token 预算留余量。
    public static let tokenBudgetChars = 400

    /// `records` 不要求预先排序:内部按时间从新到旧重排,以匹配文档要求的
    /// `context_data` 排列顺序,并保证预算耗尽时先舍弃的是最旧的文字。
    public static func contextData<R: RecentTextRecord>(records: [R], now: Date = Date()) -> [[String: String]] {
        let cutoff = now.addingTimeInterval(-lookbackSeconds)
        let recent = records.filter { $0.date >= cutoff }.sorted { $0.date > $1.date }
        var result: [[String: String]] = []
        var usedChars = 0
        for r in recent {
            let text = (r.finalText ?? r.cleanText).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard result.count < maxTurns, usedChars + text.count <= tokenBudgetChars else { break }
            result.append(["text": text])
            usedChars += text.count
        }
        return result
    }
}
