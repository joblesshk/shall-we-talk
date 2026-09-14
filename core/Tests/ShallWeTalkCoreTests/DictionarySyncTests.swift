import XCTest
@testable import ShallWeTalkCore

final class DictionarySyncTests: XCTestCase {
    func testLocalChangesDuringSyncSurviveWithoutDiscardingRemoteWords() {
        let now = Date()
        let remote = DictionarySyncDocument(words: ["A", "remote"].map {
            SyncedDictionaryWord(word: $0, origin: .manual, updatedAt: now)
        })
        let result = DictionarySync.preservingLocalChanges(in: remote,
            startingManual: ["A"], startingAuto: [], currentManual: ["B"], currentAuto: [])
        let active = Set(result.words.filter { !$0.deleted }.map(\.word))
        XCTAssertEqual(active, ["B", "remote"])
        XCTAssertTrue(result.words.contains { $0.word == "A" && $0.deleted })
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func d(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    // MARK: - reconcileWords

    func testReconcileWordsKeepsOriginalTimestampWhenUnchanged() {
        let previous = [SyncedDictionaryWord(word: "谷歌", origin: .manual, updatedAt: d(0))]
        let reconciled = DictionarySync.reconcileWords(
            currentActive: ["谷歌": .manual], previous: previous, now: d(100))
        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled[0].updatedAt, d(0), "未变的词不应该被虚增新近度")
    }

    func testReconcileWordsStampsNewWordWithNow() {
        let reconciled = DictionarySync.reconcileWords(
            currentActive: ["深度求索": .manual], previous: [], now: d(50))
        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled[0].updatedAt, d(50))
        XCTAssertFalse(reconciled[0].deleted)
    }

    func testReconcileWordsTombstonesRemovedWord() {
        let previous = [SyncedDictionaryWord(word: "旧词", origin: .manual, updatedAt: d(0))]
        let reconciled = DictionarySync.reconcileWords(
            currentActive: [:], previous: previous, now: d(10))
        XCTAssertEqual(reconciled.count, 1)
        XCTAssertTrue(reconciled[0].deleted)
        XCTAssertEqual(reconciled[0].updatedAt, d(10))
    }

    func testReconcileWordsSyncsLegacyBlocklistNeverSeenBefore() {
        // 启用本功能前就已存在的屏蔽词,从未出现在 previous 快照里,也应该补一条墓碑。
        let reconciled = DictionarySync.reconcileWords(
            currentActive: [:], blocked: ["旧屏蔽词"], previous: [], now: d(5))
        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled[0].word, "旧屏蔽词")
        XCTAssertTrue(reconciled[0].deleted)
    }

    func testReconcileCorrectionsStampsChangedTargetWithNow() {
        let previous = [SyncedCorrectionPair(source: "一只做多", target: "一直做多", updatedAt: d(0))]
        let reconciled = DictionarySync.reconcileCorrections(
            currentActive: [LearnedCorrection(source: "一只做多", target: "一直做多的呀")],
            previous: previous, now: d(20))
        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled[0].target, "一直做多的呀")
        XCTAssertEqual(reconciled[0].updatedAt, d(20), "target 变化必须刷新时间戳")
    }

    func testReconcileCorrectionsPreservesRemoteOnlyPairOnReceivingDevice() throws {
        let remoteOnly = SyncedCorrectionPair(
            source: "一只做多", target: "一直做多", updatedAt: d(0))

        let reconciled = DictionarySync.reconcileCorrections(
            currentActive: [], previous: [remoteOnly], now: d(20))

        let pair = try XCTUnwrap(reconciled.first)
        XCTAssertFalse(pair.deleted, "接收设备没有对应本地历史时,不能把远端词对解释成删除")
        XCTAssertEqual(pair.updatedAt, d(0), "纯接收不应虚增更新时间")
    }

    func testRemoteOnlyCorrectionSurvivesTwoDeviceTwoRoundSync() throws {
        let learnedOnA = DictionarySync.reconcileCorrections(
            currentActive: [LearnedCorrection(source: "一只做多", target: "一直做多")],
            previous: [], now: d(10))
        let cloudAfterA = DictionarySyncDocument(
            words: [], corrections: learnedOnA, updatedAt: d(10))

        let receivedOnB = DictionarySync.merge(
            local: .empty, remote: cloudAfterA, now: d(20))
        let secondRoundOnB = DictionarySync.reconcileCorrections(
            currentActive: [], previous: receivedOnB.corrections, now: d(30))
        let cloudAfterB = DictionarySync.merge(
            local: DictionarySyncDocument(
                words: [], corrections: secondRoundOnB, updatedAt: d(30)),
            remote: cloudAfterA,
            now: d(30))

        let pair = try XCTUnwrap(cloudAfterB.corrections.first)
        XCTAssertFalse(pair.deleted)
        XCTAssertEqual(pair.source, "一只做多")
        XCTAssertEqual(pair.target, "一直做多")
    }

    func testReconcileCorrectionsDoesNotReviveExistingTombstoneFromOldHistory() throws {
        let deleted = SyncedCorrectionPair(
            source: "一只做多", target: "一直做多", updatedAt: d(20), deleted: true)

        let reconciled = DictionarySync.reconcileCorrections(
            currentActive: [LearnedCorrection(source: "一只做多", target: "一直做多")],
            previous: [deleted], now: d(30))

        XCTAssertTrue(try XCTUnwrap(reconciled.first).deleted)
    }

    // MARK: - mergeWords: last-write-wins

    func testMergeWordsPicksNewerTimestamp() {
        let a = SyncedDictionaryWord(word: "W", origin: .manual, updatedAt: d(0))
        let b = SyncedDictionaryWord(word: "W", origin: .auto, updatedAt: d(10))
        let merged = DictionarySync.mergeWords([[a], [b]])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].origin, .auto, "更新的写入应该胜出(LWW)")
        XCTAssertEqual(merged[0].updatedAt, d(10))
    }

    func testMergeWordsUnionsDistinctKeys() {
        let a = SyncedDictionaryWord(word: "苹果", origin: .manual, updatedAt: d(0))
        let b = SyncedDictionaryWord(word: "香蕉", origin: .manual, updatedAt: d(0))
        let merged = DictionarySync.mergeWords([[a], [b]])
        XCTAssertEqual(Set(merged.map(\.word)), ["苹果", "香蕉"])
    }

    // MARK: - tombstone 防复活(核心场景:macOS 拿到 iOS 更新的删除,不应把旧词复活)

    func testTombstoneWithNewerTimestampBeatsStaleLiveEntry() {
        // 设备 A(iOS)较早添加了词 W;设备 B(macOS)本地仍带着这个较早的活词条(从未删除过)。
        let staleLiveFromB = SyncedDictionaryWord(word: "W", origin: .manual, updatedAt: d(0))
        // 用户随后在设备 A 上删除了 W,产生一条更新的墓碑。
        let newerTombstoneFromA = SyncedDictionaryWord(word: "W", origin: .manual, updatedAt: d(100), deleted: true)
        let merged = DictionarySync.mergeWords([[staleLiveFromB], [newerTombstoneFromA]])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].deleted, "更新的墓碑必须战胜过期的活词条,不能被复活")
    }

    func testEndToEndDeleteOnOneDeviceDoesNotRevivedOnAnother() {
        // 完整场景:B 设备(macOS)从未删除过 W,本机 currentActive 仍包含 W;
        // 但云端已经是 A 设备(iOS)较新时间产生的墓碑。合并后 W 必须从 B 的存活列表消失。
        let bPrevious = [SyncedDictionaryWord(word: "W", origin: .manual, updatedAt: d(0))]
        let bReconciled = DictionarySync.reconcileWords(
            currentActive: ["W": .manual], previous: bPrevious, now: d(50))
        let cloudDoc = DictionarySyncDocument(
            words: [SyncedDictionaryWord(word: "W", origin: .manual, updatedAt: d(100), deleted: true)],
            corrections: [], updatedAt: d(100))
        let localDoc = DictionarySyncDocument(words: bReconciled, corrections: [], updatedAt: d(50))
        let merged = DictionarySync.merge(local: localDoc, remote: cloudDoc, now: d(100))
        XCTAssertTrue(DictionarySync.activeWords(merged.words).isEmpty,
                       "iOS 删除词后,macOS 合并结果里该词不应复活")
    }

    // MARK: - activeCorrections: 截断到 maxCorrectionPairs 语义

    func testActiveCorrectionsTruncatesToLimitByRecency() {
        let pairs = (0..<5).map { i in
            SyncedCorrectionPair(source: "s\(i)", target: "t\(i)", updatedAt: d(Double(i)))
        }
        let result = DictionarySync.activeCorrections(pairs, limit: 3)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.source), ["s4", "s3", "s2"], "应保留最新的 N 条")
    }

    func testActiveCorrectionsExcludesTombstones() {
        let pairs = [
            SyncedCorrectionPair(source: "a", target: "A", updatedAt: d(0)),
            SyncedCorrectionPair(source: "b", target: "B", updatedAt: d(1), deleted: true),
        ]
        let result = DictionarySync.activeCorrections(pairs, limit: 10)
        XCTAssertEqual(result.map(\.source), ["a"])
    }

    // MARK: - pruneTombstones

    func testPruneTombstonesRemovesOldDeletedEntries() {
        let now = Date()
        let oldTombstone = SyncedDictionaryWord(
            word: "old", origin: .manual,
            updatedAt: Calendar(identifier: .gregorian).date(byAdding: .day, value: -91, to: now)!,
            deleted: true)
        let recentTombstone = SyncedDictionaryWord(
            word: "recent", origin: .manual,
            updatedAt: Calendar(identifier: .gregorian).date(byAdding: .day, value: -10, to: now)!,
            deleted: true)
        let alive = SyncedDictionaryWord(
            word: "alive", origin: .manual,
            updatedAt: Calendar(identifier: .gregorian).date(byAdding: .day, value: -500, to: now)!)

        let pruned = DictionarySync.pruneTombstones(words: [oldTombstone, recentTombstone, alive],
                                                      corrections: [], now: now)
        let words = Set(pruned.words.map(\.word))
        XCTAssertFalse(words.contains("old"), "超过保留期的墓碑应被清理")
        XCTAssertTrue(words.contains("recent"), "未超过保留期的墓碑应保留")
        XCTAssertTrue(words.contains("alive"), "存活条目无论多旧都不应被墓碑清理逻辑误删")
    }

    // MARK: - partitionLocalWords

    func testPartitionLocalWordsSplitsBySourceAndTombstone() {
        let merged = [
            SyncedDictionaryWord(word: "手动词", origin: .manual, updatedAt: d(2)),
            SyncedDictionaryWord(word: "自动词", origin: .auto, updatedAt: d(1)),
            SyncedDictionaryWord(word: "已删词", origin: .manual, updatedAt: d(3), deleted: true),
        ]
        let partitioned = DictionarySync.partitionLocalWords(merged)
        XCTAssertEqual(partitioned.manual, ["手动词"])
        XCTAssertEqual(partitioned.auto, ["自动词"])
        XCTAssertEqual(partitioned.blocked, ["已删词"])
    }

    // MARK: - merge() 整体入口:三方并集 + 截断

    func testMergeProducesUnionAcrossLocalAndRemote() {
        let local = DictionarySyncDocument(
            words: [SyncedDictionaryWord(word: "本机词", origin: .manual, updatedAt: d(0))],
            corrections: [SyncedCorrectionPair(source: "本机纠错", target: "X", updatedAt: d(0))])
        let remote = DictionarySyncDocument(
            words: [SyncedDictionaryWord(word: "云端词", origin: .auto, updatedAt: d(0))],
            corrections: [SyncedCorrectionPair(source: "云端纠错", target: "Y", updatedAt: d(0))])
        let merged = DictionarySync.merge(local: local, remote: remote, now: d(1))
        XCTAssertEqual(Set(merged.words.map(\.word)), ["本机词", "云端词"])
        XCTAssertEqual(Set(merged.corrections.map(\.source)), ["本机纠错", "云端纠错"])
    }

    // MARK: - mergeAll: 多个冲突变体目录各自的 dictionary-sync.json 合并成一份

    func testMergeAllUnionsWordsAcrossVariantDocuments() throws {
        let canonical = DictionarySyncDocument(
            words: [SyncedDictionaryWord(word: "规范目录词", origin: .manual, updatedAt: d(0))],
            corrections: [])
        let variant = DictionarySyncDocument(
            words: [SyncedDictionaryWord(word: "变体目录词", origin: .auto, updatedAt: d(0))],
            corrections: [])
        let merged = try XCTUnwrap(DictionarySync.mergeAll([canonical, variant], now: d(1)))
        XCTAssertEqual(Set(merged.words.map(\.word)), ["规范目录词", "变体目录词"])
    }

    func testMergeAllPicksNewerAcrossVariantDocumentsOnConflict() throws {
        // 同一个词在规范目录与冲突变体目录里都有(各自设备都写过),取时间戳更新的一份。
        let canonical = DictionarySyncDocument(
            words: [SyncedDictionaryWord(word: "W", origin: .manual, updatedAt: d(0))], corrections: [])
        let variant = DictionarySyncDocument(
            words: [SyncedDictionaryWord(word: "W", origin: .auto, updatedAt: d(50))], corrections: [])
        let merged = try XCTUnwrap(DictionarySync.mergeAll([canonical, variant], now: d(100)))
        XCTAssertEqual(merged.words.count, 1)
        XCTAssertEqual(merged.words[0].origin, .auto)
        XCTAssertEqual(merged.words[0].updatedAt, d(50))
    }

    func testMergeAllReturnsNilForEmptyList() {
        XCTAssertNil(DictionarySync.mergeAll([]))
    }

    // MARK: - CloudDictionaryLayout: "Dictionary 2" 冲突变体目录扫描

    func testDictionaryFoldersFindsCanonicalAndConflictVariants() throws {
        let fm = FileManager.default
        let documents = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: documents) }
        for dir in ["Dictionary", "Dictionary 2", "Dictionary 3", "History"] {
            try fm.createDirectory(at: documents.appendingPathComponent(dir),
                                   withIntermediateDirectories: true)
        }
        // 干扰项:同前缀的普通文件不应入选
        fm.createFile(atPath: documents.appendingPathComponent("Dictionary 4").path, contents: Data())

        let folders = CloudDictionaryLayout.dictionaryFolders(inDocuments: documents)
        XCTAssertEqual(folders.map(\.lastPathComponent), ["Dictionary", "Dictionary 2", "Dictionary 3"])
    }

    func testDictionaryFoldersEmptyWhenDocumentsMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
        XCTAssertEqual(CloudDictionaryLayout.dictionaryFolders(inDocuments: missing), [])
    }
}
