import Foundation

/// 语音词典 ⇄ 拼音键盘的「同源」桥。
///
/// 现有 MobileSettingsStore 用 UserDefaults.standard 存词典,键盘扩展读不到;
/// 这里把「生效词表」镜像进 App Group суite,键盘扩展据此注入拼音用户词。
/// 主 App 在词典变更时 publish;键盘在出现/轮询时按 version 变化增量重载。
enum SharedDictionaryStore {
    static let appGroupID = AppGroup.id
    // 免费账号 App Group 不可用时为 nil → words() 返回空,键盘只用内置词库(拼音不受影响)
    private static var suite: UserDefaults? { AppGroup.suite }
    private static let wordsKey = "sharedDictionaryWords"
    private static let versionKey = "sharedDictionaryVersion"
    private static let learnedWordsKey = "sharedDictionaryLearnedWordsV1"
    private static let maxLearnedWords = 120

    private struct LearnedWord: Codable {
        let word: String
        var count: Int
        var lastUsed: TimeInterval
    }

    /// 主 App 调用:把生效词表写入 App Group,并 bump 版本号。
    static func publish(_ words: [String]) {
        guard let suite else { return }
        let cleaned = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        suite.set(cleaned.joined(separator: "\n"), forKey: wordsKey)
        suite.set(Date().timeIntervalSince1970, forKey: versionKey)
    }

    /// 键盘调用:读取当前词表。
    static func words() -> [String] {
        guard let suite else { return [] }
        let published = (suite.string(forKey: wordsKey) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        var seen = Set(published)
        return published + learnedWords().filter { seen.insert($0).inserted }
    }

    /// 记录键盘候选词的实际选择。仅多字中文词会进入学习表;上限防止 App Group 无界增长。
    static func recordSelection(_ word: String) {
        guard let suite else { return }
        let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 2, cleaned.count <= 8,
              cleaned.unicodeScalars.allSatisfy({ (0x3400...0x9FFF).contains($0.value) }) else { return }

        var records = learnedRecords()
        let now = Date().timeIntervalSince1970
        if let index = records.firstIndex(where: { $0.word == cleaned }) {
            records[index].count += 1
            records[index].lastUsed = now
        } else {
            records.append(LearnedWord(word: cleaned, count: 1, lastUsed: now))
        }
        records.sort {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.lastUsed > $1.lastUsed
        }
        if records.count > maxLearnedWords { records.removeLast(records.count - maxLearnedWords) }
        if let data = try? JSONEncoder().encode(records) {
            suite.set(data, forKey: learnedWordsKey)
            suite.set(now, forKey: versionKey)
        }
    }

    /// 至少被选两次才给语音识别，避免一次误触污染约 100 字符的宝贵热词空间。
    static func learnedWords(minimumCount: Int = 1, limit: Int = maxLearnedWords) -> [String] {
        Array(learnedRecords().filter { $0.count >= minimumCount }.prefix(limit).map(\.word))
    }

    private static func learnedRecords() -> [LearnedWord] {
        guard let data = suite?.data(forKey: learnedWordsKey),
              let records = try? JSONDecoder().decode([LearnedWord].self, from: data) else { return [] }
        return records
    }

    /// 版本号(时间戳),供键盘检测变更、避免重复注入。
    static func version() -> TimeInterval {
        suite?.double(forKey: versionKey) ?? 0
    }
}
