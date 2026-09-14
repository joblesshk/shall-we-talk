import Foundation
import ShallWeTalkCore

/// 个人词典 + 纠错对跨设备同步的协调器(glue)。与 `CloudHistorySync` 同款设计:
/// 合并数学全部委托给 core 包的纯函数(`DictionarySync`),这里只负责——
/// 读取本机 Settings 当前状态 → reconcile 出带时间戳的本机快照 → 与云端合并 → 写回
/// 云端文件与本机快照 → 把结果应用回 Settings。
///
/// 线程约定(与 `CloudHistorySync`/历史 0x8BADF00D 教训一致):
/// - `syncAndMerge` 只接受/返回值类型,内部会做 iCloud 文件 I/O(可能等待占位符),
///   调用方必须在非 MainActor 上下文(如 `Task.detached`)调用。
/// - `apply(_:to:)` 会写 `@AppStorage` 字段,必须在 MainActor 上调用。
/// - `effectiveCorrections` 只读本机已缓存的 UserDefaults 快照,不触碰 iCloud,可在任意
///   线程(包括 MainActor)同步调用,与既有 `DictionaryMiner.correctionPairs` 调用点等价快。
enum DictionarySyncCoordinator {
    enum SyncFailure: Error, Sendable {
        case iCloudUnavailable
        case writeFailed
        case remotePending // 云端文件下载中,本轮跳过写入,避免用不完整数据覆盖云端(见 Bridge.PullOutcome 注释)
    }
    private static let syncLock = NSLock()
    private static let localSnapshotKey = "dictionarySyncLocalSnapshotV1"
    private static let localBlockedSnapshotKey = "dictionarySyncBlockedSnapshotV1"
    private static let localCorrectionsBlockedSnapshotKey = "dictionarySyncCorrectionsBlockedSnapshotV1"

    private static func loadLocalSnapshot() -> DictionarySyncDocument {
        guard let data = UserDefaults.standard.data(forKey: localSnapshotKey),
              let doc = try? JSONDecoder().decode(DictionarySyncDocument.self, from: data) else {
            return .empty
        }
        return doc
    }

    private static func saveLocalSnapshot(_ doc: DictionarySyncDocument) {
        guard let data = try? JSONEncoder().encode(doc) else { return }
        UserDefaults.standard.set(data, forKey: localSnapshotKey)
    }

    private static func loadBlockedSnapshot() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: localBlockedSnapshotKey) ?? [])
    }

    private static func saveBlockedSnapshot(_ blocked: Set<String>) {
        UserDefaults.standard.set(blocked.sorted(), forKey: localBlockedSnapshotKey)
    }

    private static func loadBlockedCorrectionsSnapshot() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: localCorrectionsBlockedSnapshotKey) ?? [])
    }

    private static func saveBlockedCorrectionsSnapshot(_ blocked: Set<String>) {
        UserDefaults.standard.set(blocked.sorted(), forKey: localCorrectionsBlockedSnapshotKey)
    }

    /// 一轮完整同步:本机当前状态 reconcile → 拉取云端 → 合并(LWW + 墓碑 + 清理过期墓碑)
    /// → 写回云端文件 + 本机快照。只有云端写入成功后才推进本机快照。
    ///
    /// 入参全部是值类型快照(调用方在 MainActor 上取好),内部不持有任何 Settings/History
    /// 引用,可安全整体丢进 `Task.detached`。
    static func syncAndMerge(currentManual: [String], currentAuto: [String], currentBlocked: Set<String>,
                              corrections: [LearnedCorrection], currentBlockedCorrections: Set<String> = [])
        -> Result<DictionarySyncDocument, SyncFailure> {
        syncLock.lock()
        defer { syncLock.unlock() }
        let now = Date()

        var currentWords: [String: WordOrigin] = [:]
        for w in currentManual { currentWords[w] = .manual }
        for w in currentAuto where currentWords[w] == nil { currentWords[w] = .auto }

        let previous = loadLocalSnapshot()
        // 只同步本轮新进入屏蔽名单的词/纠错对，避免已过 90 天并被清理的墓碑不断重生。
        let newlyBlocked = currentBlocked.subtracting(loadBlockedSnapshot())
        let newlyBlockedCorrections = currentBlockedCorrections.subtracting(loadBlockedCorrectionsSnapshot())
        let reconciledWords = DictionarySync.reconcileWords(
            currentActive: currentWords, blocked: newlyBlocked, previous: previous.words, now: now)
        let reconciledCorrections = DictionarySync.reconcileCorrections(
            currentActive: corrections, blocked: newlyBlockedCorrections, previous: previous.corrections, now: now)
        let reconciledLocal = DictionarySyncDocument(words: reconciledWords, corrections: reconciledCorrections, updatedAt: now)

        guard DictionarySyncBridge.isAvailable else {
            CoreDiagLog.log("dictSync", "iCloud 不可用,未推进同步快照(词典=\(currentWords.count))")
            return .failure(.iCloudUnavailable)
        }

        let remote: DictionarySyncDocument
        switch DictionarySyncBridge.pull() {
        case .data(let doc):
            remote = doc
        case .empty:
            remote = .empty
        case .pending:
            CoreDiagLog.log("dictSync", "云端词典文件下载中,本轮跳过写入(本机=\(currentWords.count),避免覆盖云端未拉全的数据)")
            return .failure(.remotePending)
        }
        let merged = DictionarySync.merge(local: reconciledLocal, remote: remote, now: now)
        guard DictionarySyncBridge.write(merged) else {
            return .failure(.writeFailed)
        }
        saveLocalSnapshot(merged)
        saveBlockedSnapshot(currentBlocked)
        saveBlockedCorrectionsSnapshot(currentBlockedCorrections)

        let wordCount = DictionarySync.activeWords(merged.words).count
        let correctionCount = DictionarySync.activeCorrections(merged.corrections, limit: DictionaryMiner.maxCorrectionPairs).count
        CoreDiagLog.log("dictSync", "同步完成 词典=\(wordCount) 纠错=\(correctionCount)")
        return .success(merged)
    }

    /// 把合并结果拆回本地三个字段(手动 / 自动 / 屏蔽名单)。必须在 MainActor 上调用。
    @MainActor
    static func apply(_ merged: DictionarySyncDocument, to settings: DictionarySyncSettings,
                      startingManual: [String], startingAuto: [String]) {
        let current = DictionarySync.preservingLocalChanges(in: merged,
            startingManual: startingManual, startingAuto: startingAuto,
            currentManual: settings.manualDictionaryWords, currentAuto: settings.autoDictionaryWords)
        let partitioned = DictionarySync.partitionLocalWords(current.words)
        settings.userDictionaryRaw = partitioned.manual.joined(separator: "\n")
        settings.autoDictionaryRaw = partitioned.auto.joined(separator: "\n")
        // 屏蔽名单取并集:云端墓碑 ∪ 本机已有屏蔽项,防止本机独有的历史屏蔽记录被覆盖丢失。
        var blocked = settings.blockedDictionaryWords
        partitioned.blocked.forEach { blocked.insert($0) }
        settings.dictionaryBlocklistRaw = blocked.sorted().joined(separator: "\n")
    }

    /// 供 ASR 热词 context 与整理 prompt 消费:手动添加 ∪ 本机实时挖掘 ∪ 云端已合并的纠错对,
    /// 按 source 去重(手动优先于实时挖掘,反映用户明确意图;实时挖掘优先于云端旧快照,
    /// 因为它反映最新的本地历史),截断到 limit。只读本机 UserDefaults 缓存,不触碰 iCloud,
    /// 可在 MainActor 上同步调用。
    static func effectiveCorrections<R: DictionaryMinableRecord>(
        records: [R], manual: [LearnedCorrection] = [], blocked: Set<String> = [],
        limit: Int = DictionaryMiner.maxCorrectionPairs)
        -> [LearnedCorrection] {
        let blockedLower = Set(blocked.map { $0.lowercased() })
        let live = DictionaryMiner.correctionPairs(records: records, blocked: blocked, limit: limit)
        let synced = DictionarySync.activeCorrections(loadLocalSnapshot().corrections, limit: limit)
        var seen = Set<String>()
        var merged: [LearnedCorrection] = []
        for pair in manual + live + synced
            where !blockedLower.contains(pair.source.lowercased()) && seen.insert(pair.source.lowercased()).inserted {
            merged.append(pair)
        }
        return Array(merged.prefix(limit))
    }
}
