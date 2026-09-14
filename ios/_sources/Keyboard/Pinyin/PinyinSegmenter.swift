import Foundation

/// 全拼音节切分器。
/// 音节表来自打包资源 pinyin_syllables.txt(由 tools/build_pinyin_dict.py 从数据析出,
/// 与词库自洽——共 408 个普通话音节)。
///
/// 切分只用于「显示分段」与「整句/单字兜底」;候选查询主路径用去空格的 flatKey,
/// 因此 xian → 同时命中 先/现(xian) 与 西安(xi'an),无需在这里消歧。
final class PinyinSegmenter {
    private let syllables: Set<String>
    private let maxLen: Int

    init(syllables: Set<String>) {
        self.syllables = syllables
        self.maxLen = syllables.map(\.count).max() ?? 6
    }

    func isSyllable(_ s: String) -> Bool { syllables.contains(s) }

    /// 是否为某个合法音节的前缀(用户还在敲最后一个音节时为真)。
    func isSyllablePrefix(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for syl in syllables where syl.hasPrefix(s) { return true }
        return false
    }

    struct Result {
        var syllables: [String]   // 已成功切出的完整音节序列
        var consumed: Int         // 这些音节覆盖的字符数
        var remainder: String     // 尾部未成音节的残串(还在输入中)
        var fullyCovered: Bool { remainder.isEmpty }
    }

    /// 前缀最大化切分:返回能被完整音节覆盖的最长前缀,尾部残串单列。
    /// 同一覆盖长度下偏好「更少音节」(即更长音节),符合直觉(xian→[xian] 而非 [xi,an])。
    func segment(_ input: String) -> Result {
        let chars = Array(input)
        let n = chars.count
        guard n > 0 else { return Result(syllables: [], consumed: 0, remainder: "") }

        // dp[i] = input[0..<i] 能否被完整音节序列覆盖;back[i] = 到达 i 的最后一个音节长度
        var dp = [Bool](repeating: false, count: n + 1)
        var back = [Int](repeating: 0, count: n + 1)
        dp[0] = true
        for i in 1...n {
            // 偏好更长音节(更少音节)→ 音节长度从长到短试,首个命中即定
            var len = min(maxLen, i)
            while len >= 1 {
                let start = i - len
                if dp[start], syllables.contains(String(chars[start..<i])) {
                    dp[i] = true
                    back[i] = len
                    break
                }
                len -= 1
            }
        }

        var best = 0
        for i in stride(from: n, through: 0, by: -1) where dp[i] { best = i; break }

        var syl: [String] = []
        var idx = best
        while idx > 0 {
            let len = back[idx]
            syl.insert(String(chars[(idx - len)..<idx]), at: 0)
            idx -= len
        }
        let remainder = best < n ? String(chars[best..<n]) : ""
        return Result(syllables: syl, consumed: best, remainder: remainder)
    }

    /// 供显示:把缓冲串切成 "ni'hao'shi'jie" 形式(残串原样附后)。
    func display(_ input: String) -> String {
        let r = segment(input)
        var parts = r.syllables
        if !r.remainder.isEmpty { parts.append(r.remainder) }
        return parts.joined(separator: "'")
    }
}
