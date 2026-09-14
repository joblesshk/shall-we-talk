import Foundation

/// 在展示给用户的整理稿里,标出「这里可能听错了」的区间。
///
/// 线索:**整理模型改过**——LLM 在此处改写了 ASR 原文。它多数时候是在修同音错误,
/// 但改动本身也可能是错的——无论哪种,这里都值得用户扫一眼。
///
/// 2026-08-16:原本还有"端侧与云端两个引擎不一致"这条独立线索(`engineDisagreement`),
/// 依赖停录时起的端侧整段批量转写;那条链路已下线(改用录音过程中实时的端侧转写 +
/// 云端单向流式分句定稿,不再产出一份可以拿来事后比对的完整端侧稿),这条线索随之删除。
///
/// 区间是**当场算出来的,不落库**:用户在历史页改过 finalText 之后,任何存下来的下标都会
/// 失效。记录里已经存着算它所需的全部输入(rawText / cleanText)。
public enum UncertainSpans {
    /// 单条不确定区间。`range` 的下标落在 `displayed` 的 `Character` 序列上。
    public struct Span: Equatable, Sendable {
        public let range: ClosedRange<Int>
        public let reason: Reason
    }

    public enum Reason: Equatable, Sendable {
        /// 文字整理模型改写了 ASR 原文。
        case cleanupRewrote
    }

    /// 计算展示稿中值得复核的区间。
    ///
    /// - Parameters:
    ///   - displayed: 实际展示给用户的文字(整理稿,或用户尚未编辑过的最终稿)。
    ///   - rawASR: 云端 ASR 原文。
    /// - Returns: 按出现先后排列、互不重叠的区间;没有可用线索时为空数组。
    public static func spans(displayed: String, rawASR: String) -> [Span] {
        let characters = Array(displayed)
        guard !characters.isEmpty, !rawASR.isEmpty,
              let rewritten = TranscriptDivergence.divergentSpans(left: characters, right: Array(rawASR))
        else { return [] }
        return normalize(rewritten.map { Span(range: $0, reason: .cleanupRewrote) })
    }

    /// 合并重叠或紧邻的区间,保证渲染时不会出现区间套区间。
    ///
    /// 阈值与 `TranscriptDivergence.mergeGap` 同源同理由:紧邻的两处改写之间常夹着
    /// 一两个没动过的正常字,不合并就会画成断断续续的好几小段虚线。
    private static let mergeGap = 2

    private static func normalize(_ spans: [Span]) -> [Span] {
        let sorted = spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var merged: [Span] = []
        for span in sorted {
            guard var last = merged.last,
                  span.range.lowerBound <= last.range.upperBound + mergeGap + 1 else {
                merged.append(span)
                continue
            }
            last = Span(range: last.range.lowerBound...max(last.range.upperBound, span.range.upperBound),
                        reason: .cleanupRewrote)
            merged[merged.count - 1] = last
        }
        return merged
    }
}
