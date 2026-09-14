import Foundation

/// 两段文字的分歧区间提取——原本用于云端与端侧两份转写稿比对,现在只被
/// `UncertainSpans`(整理稿 vs ASR 原文)使用;2026-08-16 端侧整段批量转写下线后,
/// 面向"云端 vs 端侧"的 `fragments(cloud:onDevice:)` 一并删除,只留通用的区间提取。
public enum TranscriptDivergence {
    /// 超过这个长度就不做对齐。编辑距离是 O(n×m),而口述稿 p90 只有 83 字,
    /// 这个上限只用于挡住异常长输入,正常使用碰不到。
    private static let maxAlignLength = 2_000

    /// 分歧字符占左侧文本的比例超过此值时,说明两段文本整体上就没谈拢,
    /// 逐处标注没有意义,直接放弃这次信号。
    private static let maxUsefulRatio = 0.5

    /// 两段文字的分歧区间,下标落在 `left` 的字符数组上。整段谈不拢或完全一致时返回 nil。
    static func divergentSpans(left: [Character], right: [Character]) -> [ClosedRange<Int>]? {
        let (leftNorm, leftIndexMap) = normalize(left)
        let (rightNorm, _) = normalize(right)
        guard !leftNorm.isEmpty, !rightNorm.isEmpty else { return nil }
        guard leftNorm.count <= maxAlignLength, rightNorm.count <= maxAlignLength else { return nil }

        let matched = matchedCloudPositions(leftNorm, rightNorm)
        let divergentCount = leftNorm.count - matched.filter { $0 }.count
        guard divergentCount > 0 else { return nil }
        guard Double(divergentCount) / Double(leftNorm.count) <= maxUsefulRatio else { return nil }

        // 归一化下标上的连续不匹配段 → 回映射到原文下标区间(保留其中的标点)。
        var runs: [(start: Int, end: Int)] = []
        var current: Int? = nil
        for i in 0..<leftNorm.count {
            if matched[i] {
                if let s = current { runs.append((s, i - 1)); current = nil }
            } else if current == nil {
                current = i
            }
        }
        if let s = current { runs.append((s, leftNorm.count - 1)) }
        return merge(runs).map { leftIndexMap[$0.start]...leftIndexMap[$0.end] }
    }

    /// 合并只隔了一两个字的相邻分歧段。
    ///
    /// 中文同音误识里,错字之间常常夹着一个偶然对上的字——「灵动岛」听成「联动导」,
    /// 中间的「动」在 LCS 里是匹配的,不合并就会切成「灵」「岛」两个单字碎片,
    /// 丢掉了「灵动岛」这个让人(和 LLM)一眼看懂的词形。
    private static let mergeGap = 2

    private static func merge(_ runs: [(start: Int, end: Int)]) -> [(start: Int, end: Int)] {
        guard var pending = runs.first else { return [] }
        var merged: [(start: Int, end: Int)] = []
        for run in runs.dropFirst() {
            if run.start - pending.end - 1 <= mergeGap {
                pending.end = run.end
            } else {
                merged.append(pending)
                pending = run
            }
        }
        merged.append(pending)
        return merged
    }

    /// 去掉空白与标点,统一小写。只保留参与比对的字符,并记录每个字符在原文中的下标。
    private static func normalize(_ characters: [Character]) -> ([Character], [Int]) {
        var normalized: [Character] = []
        var indexMap: [Int] = []
        for (index, character) in characters.enumerated() where character.isLetter || character.isNumber {
            normalized.append(Character(character.lowercased()))
            indexMap.append(index)
        }
        return (normalized, indexMap)
    }

    /// 标记云端每个字符是否在最长公共子序列里。在 LCS 中 = 两个引擎一致 = 可信。
    ///
    /// 用 LCS 而不是编辑距离回溯:这里只关心「哪些位置对上了」,不关心替换/增删的具体归类,
    /// LCS 的语义正好是「双方都认同的部分」。
    private static func matchedCloudPositions(_ cloud: [Character], _ device: [Character]) -> [Bool] {
        let n = cloud.count, m = device.count
        // 滚动数组只够算长度,回溯需要完整表。n、m 都受 maxAlignLength 约束。
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                table[i][j] = cloud[i - 1] == device[j - 1]
                    ? table[i - 1][j - 1] + 1
                    : max(table[i - 1][j], table[i][j - 1])
            }
        }
        var matched = [Bool](repeating: false, count: n)
        var i = n, j = m
        while i > 0, j > 0 {
            if cloud[i - 1] == device[j - 1] {
                matched[i - 1] = true
                i -= 1; j -= 1
            } else if table[i - 1][j] >= table[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return matched
    }
}
