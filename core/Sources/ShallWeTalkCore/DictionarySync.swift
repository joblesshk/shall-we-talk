import Foundation

/// 个人词典条目的来源:手动添加 vs 自动学习(挖掘)。跨设备合并后仍保留这一分类,
/// 决定合并结果写回本地时进 `manualDictionaryWords` 还是 `autoDictionaryWords`。
public enum WordOrigin: String, Codable, Sendable {
    case manual
    case auto
}

/// 一条可跨设备同步的词典条目。`deleted` 是墓碑标记:用户删除后写入较新时间戳的墓碑,
/// 防止另一台设备尚未感知这次删除、在下一轮合并里把旧词重新并入结果("复活")。
public struct SyncedDictionaryWord: Codable, Hashable, Sendable {
    public let word: String
    public var origin: WordOrigin
    public var updatedAt: Date
    public var deleted: Bool

    public init(word: String, origin: WordOrigin, updatedAt: Date, deleted: Bool = false) {
        self.word = word
        self.origin = origin
        self.updatedAt = updatedAt
        self.deleted = deleted
    }
}

/// 一条可跨设备同步的纠错对。字段含义与 `LearnedCorrection` 一致(source=误识别片段,
/// target=纠正后写法),额外带时间戳与墓碑,供跨设备合并。
public struct SyncedCorrectionPair: Codable, Hashable, Sendable {
    public let source: String
    public var target: String
    public var updatedAt: Date
    public var deleted: Bool

    public init(source: String, target: String, updatedAt: Date, deleted: Bool = false) {
        self.source = source
        self.target = target
        self.updatedAt = updatedAt
        self.deleted = deleted
    }
}

/// 个人词典 + 纠错对同步文件的完整内容(iCloud Documents/Dictionary/dictionary-sync.json)。
public struct DictionarySyncDocument: Codable, Sendable {
    public var words: [SyncedDictionaryWord]
    public var corrections: [SyncedCorrectionPair]
    public var updatedAt: Date

    public init(words: [SyncedDictionaryWord] = [], corrections: [SyncedCorrectionPair] = [],
                updatedAt: Date = .distantPast) {
        self.words = words
        self.corrections = corrections
        self.updatedAt = updatedAt
    }

    public static let empty = DictionarySyncDocument()
}

/// 个人词典 + 纠错对跨设备合并的纯函数集合。不做任何文件 I/O——那部分留在各端的
/// iCloud 桥接代码里(与 `CloudHistorySync` 同款 `#if os(macOS)` 模式),这里只有可
/// 独立测试的合并数学:last-write-wins + 墓碑防复活 + 三方并集 + 按时间截断。
public enum DictionarySync {
    /// 将同步等待期间的本地增删叠加到远端合并结果；只覆盖本地确实变动的词。
    public static func preservingLocalChanges(in merged: DictionarySyncDocument,
        startingManual: [String], startingAuto: [String], currentManual: [String], currentAuto: [String],
        now: Date = Date()) -> DictionarySyncDocument {
        func origins(_ manual: [String], _ auto: [String]) -> [String: WordOrigin] {
            var result = Dictionary(auto.map { ($0, WordOrigin.auto) }, uniquingKeysWith: { a, _ in a })
            for word in manual { result[word] = .manual }
            return result
        }
        let start = origins(startingManual, startingAuto)
        let current = origins(currentManual, currentAuto)
        var words = Dictionary(merged.words.map { ($0.word, $0) }, uniquingKeysWith: { a, b in
            a.updatedAt >= b.updatedAt ? a : b
        })
        for word in Set(start.keys).union(current.keys) where start[word] != current[word] {
            words[word] = SyncedDictionaryWord(word: word, origin: current[word] ?? start[word] ?? .manual,
                updatedAt: now, deleted: current[word] == nil)
        }
        var result = merged
        result.words = Array(words.values)
        return result
    }

    /// 墓碑保留期:超过这个天数的已删除条目才会被彻底清理,避免同步文件无界增长。
    public static let tombstoneRetentionDays = 90

    // MARK: - 本机快照 reconcile(当前生效状态 vs 上一轮已知快照 → 带时间戳的新快照)

    /// 把"当前本机生效词表"与"上一轮已知的同步快照"对比,生成新的本机快照:
    /// - 新增的词、或来源(手动/自动)发生变化的词,打上 `now` 时间戳;
    /// - 上一轮就有且未变的词,保留原时间戳(不会因为单纯重新计算就显得"更新");
    /// - 上一轮存在、本机现在已不再拥有的词(用户删除),写入 `now` 时间戳的墓碑;
    /// - `blocked` 里出现但从未被本函数记录过的词(如启用本功能前就已存在的屏蔽名单),
    ///   同样补一条墓碑,确保这类历史屏蔽也能传播到其它设备,不必等待用户再删一次。
    public static func reconcileWords(currentActive: [String: WordOrigin],
                                       blocked: Set<String> = [],
                                       previous: [SyncedDictionaryWord],
                                       now: Date) -> [SyncedDictionaryWord] {
        var byWord = Dictionary(uniqueKeysWithValues: previous.map { ($0.word, $0) })

        for (word, origin) in currentActive {
            if let existing = byWord[word], !existing.deleted, existing.origin == origin {
                continue // 未变,保留原时间戳
            }
            byWord[word] = SyncedDictionaryWord(word: word, origin: origin, updatedAt: now, deleted: false)
        }
        for entry in previous where !entry.deleted && currentActive[entry.word] == nil {
            byWord[entry.word] = SyncedDictionaryWord(word: entry.word, origin: entry.origin, updatedAt: now, deleted: true)
        }
        for word in blocked where byWord[word] == nil {
            byWord[word] = SyncedDictionaryWord(word: word, origin: .manual, updatedAt: now, deleted: true)
        }
        return Array(byWord.values)
    }

    /// 把本机从历史记录中学习到的纠错对并入上一轮已知快照,key 为 `source`。
    ///
    /// 每台设备只拥有自己的本地历史,因而"本机本轮没有挖掘到"不能解释成删除——否则
    /// 接收设备会把其它设备同步来的词对写成墓碑。已有墓碑同样保留,避免旧历史自动
    /// 复活明确删除的词对。
    ///
    /// `blocked`(2026-08-19 新增,与 `reconcileWords` 的 `blocked` 同一模式):用户在
    /// 任一设备上删除纠错对(不分来源手动/学习/同步)时,调用方把该 source 放进这里,
    /// 这里补一条墓碑传播出去,其它设备下一轮同步就不会再把这条带回来。
    public static func reconcileCorrections(currentActive: [LearnedCorrection],
                                             blocked: Set<String> = [],
                                             previous: [SyncedCorrectionPair],
                                             now: Date) -> [SyncedCorrectionPair] {
        var byKey = Dictionary(uniqueKeysWithValues: previous.map { ($0.source, $0) })
        for pair in currentActive {
            if let existing = byKey[pair.source] {
                if existing.deleted || existing.target == pair.target {
                    continue // 尊重墓碑;未变则保留原时间戳
                }
            }
            byKey[pair.source] = SyncedCorrectionPair(source: pair.source, target: pair.target, updatedAt: now, deleted: false)
        }
        for source in blocked where byKey[source]?.deleted != true {
            byKey[source] = SyncedCorrectionPair(
                source: source, target: byKey[source]?.target ?? "", updatedAt: now, deleted: true)
        }
        return Array(byKey.values)
    }

    // MARK: - 合并(last-write-wins + 墓碑)

    /// 按 word 取最新时间戳的一条;时间戳相同时墓碑优先(保守选择,避免新增和删除
    /// 恰好同一时刻发生时出现不确定的"复活")。
    public static func mergeWords(_ groups: [[SyncedDictionaryWord]]) -> [SyncedDictionaryWord] {
        var byWord: [String: SyncedDictionaryWord] = [:]
        for group in groups {
            for entry in group {
                if let existing = byWord[entry.word] {
                    if wins(entry, over: existing) { byWord[entry.word] = entry }
                } else {
                    byWord[entry.word] = entry
                }
            }
        }
        return Array(byWord.values)
    }

    /// 纠错对版本的同一合并逻辑,key 为 `source`。
    public static func mergeCorrections(_ groups: [[SyncedCorrectionPair]]) -> [SyncedCorrectionPair] {
        var byKey: [String: SyncedCorrectionPair] = [:]
        for group in groups {
            for entry in group {
                if let existing = byKey[entry.source] {
                    if wins(entry, over: existing) { byKey[entry.source] = entry }
                } else {
                    byKey[entry.source] = entry
                }
            }
        }
        return Array(byKey.values)
    }

    private static func wins(_ a: SyncedDictionaryWord, over b: SyncedDictionaryWord) -> Bool {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.deleted && !b.deleted
    }

    private static func wins(_ a: SyncedCorrectionPair, over b: SyncedCorrectionPair) -> Bool {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.deleted && !b.deleted
    }

    /// 清理超过保留期的墓碑,避免同步文件无界增长。存活条目不受影响,不满保留期的
    /// 墓碑也保留(防止过早清理导致旧设备把词重新带回来)。
    public static func pruneTombstones(words: [SyncedDictionaryWord], corrections: [SyncedCorrectionPair],
                                        now: Date, retentionDays: Int = tombstoneRetentionDays)
        -> (words: [SyncedDictionaryWord], corrections: [SyncedCorrectionPair]) {
        guard let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -retentionDays, to: now) else {
            return (words, corrections)
        }
        return (
            words.filter { !($0.deleted && $0.updatedAt < cutoff) },
            corrections.filter { !($0.deleted && $0.updatedAt < cutoff) }
        )
    }

    /// 三方合并入口:本机快照(已含本轮 reconcile 结果)∪ 云端文档,并清理过期墓碑。
    /// 调用方负责把结果写回云端文件与本机快照,以及应用回本地设置。
    public static func merge(local: DictionarySyncDocument, remote: DictionarySyncDocument,
                              now: Date = Date()) -> DictionarySyncDocument {
        let words = mergeWords([local.words, remote.words])
        let corrections = mergeCorrections([local.corrections, remote.corrections])
        let pruned = pruneTombstones(words: words, corrections: corrections, now: now)
        return DictionarySyncDocument(words: pruned.words, corrections: pruned.corrections, updatedAt: now)
    }

    /// 多份云端文档的并集合并(与 `CloudDictionaryLayout` 的冲突变体目录扫描配套):
    /// `Dictionary`、`Dictionary 2` 等每个变体目录各自的 `dictionary-sync.json` 读出后,
    /// 用同一套 LWW + 墓碑语义两两合并成一份。列表为空返回 nil。
    public static func mergeAll(_ docs: [DictionarySyncDocument], now: Date = Date()) -> DictionarySyncDocument? {
        guard !docs.isEmpty else { return nil }
        let words = mergeWords(docs.map(\.words))
        let corrections = mergeCorrections(docs.map(\.corrections))
        let pruned = pruneTombstones(words: words, corrections: corrections, now: now)
        return DictionarySyncDocument(words: pruned.words, corrections: pruned.corrections, updatedAt: now)
    }

    // MARK: - 消费:合并结果 → 各端可直接使用的形态

    /// 合并结果中仍存活(非墓碑)的条目。
    public static func activeWords(_ merged: [SyncedDictionaryWord]) -> [SyncedDictionaryWord] {
        merged.filter { !$0.deleted }
    }

    /// 合并后的纠错对,按更新时间取最新 N 条(与 `DictionaryMiner.maxCorrectionPairs` 同一截断语义)。
    public static func activeCorrections(_ merged: [SyncedCorrectionPair], limit: Int) -> [LearnedCorrection] {
        merged.filter { !$0.deleted }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { LearnedCorrection(source: $0.source, target: $0.target) }
    }

    /// 把合并结果(须包含墓碑,即整份 `merged.words`,不是 `activeWords` 过滤后的子集)按
    /// 来源拆回三个本地存量数组(手动 / 自动 / 屏蔽名单),按更新时间从新到旧排列,供各端
    /// 写回 `userDictionaryRaw` / `autoDictionaryRaw` / `dictionaryBlocklistRaw`。
    public static func partitionLocalWords(_ merged: [SyncedDictionaryWord]) -> (manual: [String], auto: [String], blocked: [String]) {
        var manual: [String] = []
        var auto: [String] = []
        var blocked: [String] = []
        for entry in merged.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if entry.deleted {
                blocked.append(entry.word)
            } else if entry.origin == .manual {
                manual.append(entry.word)
            } else {
                auto.append(entry.word)
            }
        }
        return (manual, auto, blocked)
    }
}

/// 云容器内词典目录的布局工具,与 `CloudHistoryLayout` 同一根因修复(2026-07-18 实测):
/// 容器重建窗口内 App 抢建目录,会把云端目录以冲突变体名(如 "Dictionary 2")落地。
/// 拉取时必须把这些变体一并扫进来;写入始终写规范目录 `Dictionary`。
public enum CloudDictionaryLayout {
    public static let folderName = "Dictionary"

    /// `Documents/` 下参与拉取的全部词典目录:规范目录(存在则排最前)+ `Dictionary 2`
    /// 等 iCloud 冲突改名变体。只认目录;不存在时返回空数组。
    public static func dictionaryFolders(inDocuments documents: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: documents,
                                                        includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        var canonical: [URL] = []
        var variants: [URL] = []
        for url in entries {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let name = url.lastPathComponent
            if name == folderName {
                canonical.append(url)
            } else if name.hasPrefix(folderName + " ") {
                variants.append(url)
            }
        }
        return canonical + variants.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
