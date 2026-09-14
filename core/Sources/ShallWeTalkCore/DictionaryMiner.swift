import Foundation

/// 词典自动学习:从历史口述中挖掘常用/典型词汇,自动入典,无需手动添加
/// 两路信号:
///   ① 英文/混写专有词(Shall We Talk、Seed-ASR 这类 ASR 高危词)出现于 ≥3 条记录
///   ② 用户对整理稿的同一处针对性修正出现 ≥2 次(信号最强,修正后的写法入典)
/// 每次口述完成后全量重算(确定性,几百条记录毫秒级);用户移除过的词进屏蔽名单,不再自动加回
public enum DictionaryMiner {
    public static let englishThreshold = 3
    public static let correctionThreshold = 2
    public static let maxAutoWords = 30
    public static let maxCorrectionPairs = 20

    private static let stopwords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "you", "not", "but", "are", "was",
        "have", "has", "had", "can", "will", "just", "from", "they", "what", "when",
        "how", "why", "who", "all", "one", "two", "app", "api", "ios", "mac", "ok", "okay",
        "a", "an", "i", "is", "it", "in", "on", "of", "to", "so", "we", "me", "my",
        "no", "yes", "do", "if", "or", "at", "be", "as", "by", "up", "out", "get", "go",
    ]

    public static func mine<R: DictionaryMinableRecord>(records: [R], manual: Set<String>, blocked: Set<String>) -> [String] {
        var englishCount: [String: Int] = [:]
        var correctionCount: [String: Int] = [:]

        for r in records.prefix(300) {
            let text = r.finalText ?? r.cleanText
            // ① 英文/混写词:每条记录同词只计一次(避免单条长文刷频次)
            var seen = Set<String>()
            for token in tokens(in: text) where seen.insert(token).inserted {
                englishCount[token, default: 0] += 1
            }
            // ② 用户修正:整理稿 → 最终稿的聚焦替换
            if let final = r.finalText, final != r.cleanText,
               let replacement = focusedReplacement(old: r.cleanText, new: final) {
                correctionCount[replacement, default: 0] += 1
            }
        }

        var candidates: [String] = []
        for (w, c) in correctionCount.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value })
            where c >= correctionThreshold { candidates.append(w) }
        for (w, c) in englishCount.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value })
            where c >= englishThreshold { candidates.append(w) }

        var out: [String] = []
        for w in candidates {
            let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !manual.contains(t), !blocked.contains(t), !out.contains(t) else { continue }
            out.append(t)
            if out.count >= maxAutoWords { break }
        }
        return out
    }

    /// 明确的用户编辑一次即生效，因为学到的是带上下文的精确片段，
    /// 而不是会污染其他句子的单个常用字。历史记录按新到旧，新修正优先。
    /// `blocked`(2026-08-19 新增,source 大小写不敏感):用户删除过的纠错对不再重新挖出——
    /// 产生这条纠错对的编辑历史本身还在,不排除的话每次都会被重新挖回来,删了等于没删。
    public static func correctionPairs<R: DictionaryMinableRecord>(
        records: [R], blocked: Set<String> = [], limit: Int = maxCorrectionPairs) -> [LearnedCorrection] {
        let blockedLower = Set(blocked.map { $0.lowercased() })
        var result: [LearnedCorrection] = []
        var seenSources = Set<String>()
        for record in records.prefix(300) {
            guard let final = record.finalText, final != record.cleanText,
                  let pair = contextualCorrection(old: record.cleanText, new: final),
                  !blockedLower.contains(pair.source.lowercased()),
                  seenSources.insert(pair.source).inserted else { continue }
            result.append(pair)
            if result.count >= limit { break }
        }
        return result
    }

    /// 提取含英文字母的词(纯英文或字母数字混合,如 Shall We Talk、iPhone15、Seed-ASR)
    private static func tokens(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9\\-\\.]{1,24}") else { return [] }
        let ns = text as NSString
        var result: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var t = ns.substring(with: m.range)
            while t.hasSuffix(".") || t.hasSuffix("-") { t = String(t.dropLast()) }
            guard t.count >= 2, !stopwords.contains(t.lowercased()) else { continue }
            result.append(t)
        }
        return result
    }

    /// 聚焦替换检测:去掉公共前后缀后,中间差异段足够短(≤8 字)即视为一次针对性修正
    /// 大段改写(意图变化)不产生候选
    private static func focusedReplacement(old: String, new: String) -> String? {
        let o = Array(old), n = Array(new)
        var p = 0
        while p < o.count, p < n.count, o[p] == n[p] { p += 1 }
        var s = 0
        while s < o.count - p, s < n.count - p, o[o.count - 1 - s] == n[n.count - 1 - s] { s += 1 }
        let oldMid = String(o[p..<(o.count - s)])
        let newMid = String(n[p..<(n.count - s)]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard newMid.count >= 2, newMid.count <= 8, oldMid.count <= 8, newMid != oldMid else { return nil }
        // 纯标点/空白的修正不算词
        let meaningful = newMid.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0) || $0.properties.isIdeographic
        }
        return meaningful ? newMid : nil
    }

    private static func contextualCorrection(old: String, new: String) -> LearnedCorrection? {
        let o = Array(old), n = Array(new)
        var prefix = 0
        while prefix < o.count, prefix < n.count, o[prefix] == n[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < o.count - prefix, suffix < n.count - prefix,
              o[o.count - 1 - suffix] == n[n.count - 1 - suffix] { suffix += 1 }

        let oldDiffEnd = o.count - suffix
        let newDiffEnd = n.count - suffix
        guard prefix < oldDiffEnd || prefix < newDiffEnd else { return nil }
        let oldMidCount = oldDiffEnd - prefix
        let newMidCount = newDiffEnd - prefix
        guard oldMidCount <= 8, newMidCount <= 8 else { return nil }

        // 左侧 1 字 + 右侧 3 字通常足以形成不会误伤普通句子的短语：
        // 例如“我是一只做多的”修正后学到“一只做多 → 一直做多”。
        let left = min(1, prefix)
        let right = min(3, suffix)
        let source = String(o[(prefix - left)..<(oldDiffEnd + right)])
        let target = String(n[(prefix - left)..<(newDiffEnd + right)])
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, !trimmedTarget.isEmpty,
              trimmedSource != trimmedTarget,
              trimmedSource.count <= 16, trimmedTarget.count <= 16 else { return nil }
        return LearnedCorrection(source: trimmedSource, target: trimmedTarget)
    }
}
