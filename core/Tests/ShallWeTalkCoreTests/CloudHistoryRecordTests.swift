import XCTest
@testable import ShallWeTalkCore

/// 历史同步云端记录的两端互解兼容性 + 合并语义 + 冲突目录布局。
/// 样例 JSON 取自 2026-07-18 本机 iCloud 容器里 iPhone 实际上传的存量文件(实录字节,
/// 非手写),保证与真实数据格式互解;日期为默认策略(timeIntervalSinceReferenceDate)。
final class CloudHistoryRecordTests: XCTestCase {

    /// iPhone 实际上传的存量文件原文(Documents/History/00331A6E-….json,2026-07-18 实录)。
    private let realIPhoneJSON = #"{"cleanText":"为什么不是这样？","id":"00331A6E-68D4-497F-9F58-5F0B3D6CA375","date":805733139.900959,"rawText":"为什么不是这样？"}"#

    func testDecodesRealIPhoneRecord() throws {
        let rec = try CloudHistoryRecord.decode(Data(realIPhoneJSON.utf8))
        XCTAssertEqual(rec.id, UUID(uuidString: "00331A6E-68D4-497F-9F58-5F0B3D6CA375"))
        XCTAssertEqual(rec.rawText, "为什么不是这样？")
        XCTAssertEqual(rec.cleanText, "为什么不是这样？")
        XCTAssertNil(rec.finalText)
        XCTAssertNil(rec.deletedAt)
        XCTAssertNil(rec.editVersion)
        XCTAssertEqual(rec.date.timeIntervalSinceReferenceDate, 805733139.900959, accuracy: 0.001)
        XCTAssertEqual(rec.fileName, "00331A6E-68D4-497F-9F58-5F0B3D6CA375.json")
    }

    /// 对方端将来多写的键(metrics、recognitionSource 等)必须被忽略而不是解码失败。
    func testDecodeIgnoresUnknownFutureFields() throws {
        let futureJSON = #"""
        {"id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","date":806000000.5,
         "rawText":"原文","cleanText":"整理稿","finalText":"最终稿",
         "metrics":{"asrFinalMillis":812,"totalMillis":2044},
         "recognitionSource":"volc-streaming","audioFileName":"x.wav"}
        """#
        let rec = try CloudHistoryRecord.decode(Data(futureJSON.utf8))
        XCTAssertEqual(rec.finalText, "最终稿")
        XCTAssertEqual(rec.cleanText, "整理稿")
    }

    /// macOS 编码 → iOS 侧同一格式可解;且只写协定的 5 个键,本机字段绝不泄漏上云。
    func testEncodedRecordRoundTripsAndContainsOnlyContractKeys() throws {
        let rec = CloudHistoryRecord(id: UUID(), date: Date(),
                                     rawText: "raw", cleanText: "clean", finalText: "final")
        let data = try rec.encoded()
        let decoded = try CloudHistoryRecord.decode(data)
        XCTAssertEqual(decoded, rec)

        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["id", "date", "rawText", "cleanText", "finalText"])
    }

    func testEncodedOmitsNilFinalText() throws {
        let rec = CloudHistoryRecord(id: UUID(), date: Date(), rawText: "r", cleanText: "c")
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: rec.encoded()) as? [String: Any]).keys
        XCTAssertFalse(keys.contains("finalText"))
        XCTAssertFalse(keys.contains("deletedAt"))
    }

    func testTombstoneRoundTripsWithoutDeletedText() throws {
        let id = UUID()
        let originalDate = Date(timeIntervalSinceReferenceDate: 100)
        let deletedAt = Date(timeIntervalSinceReferenceDate: 200)
        let tombstone = CloudHistoryRecord.tombstone(
            id: id, originalDate: originalDate, deletedAt: deletedAt)

        let decoded = try CloudHistoryRecord.decode(tombstone.encoded())
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.date, originalDate)
        XCTAssertEqual(decoded.deletedAt, deletedAt)
        XCTAssertEqual(decoded.rawText, "")
        XCTAssertEqual(decoded.cleanText, "")
        XCTAssertNil(decoded.finalText)
    }

    // MARK: - 合并语义(与 iOS CloudHistorySync.pull 既有行为一致)

    private struct LocalRecord: CloudMergeableHistoryRecord, Equatable {
        let id: UUID
        let date: Date
        var rawText: String = ""
        var cleanText: String = ""
        var finalText: String?
        var revisions: [EditRevision]?
        var editVersion: HistoryEditVersion?
        var recognitionVersion: HistoryEditVersion?
        var audioFileName: String? // 本机独有字段:合并过程中必须原样保留
    }

    private func make(_ cloud: CloudHistoryRecord) -> LocalRecord {
        LocalRecord(id: cloud.id, date: cloud.date, rawText: cloud.rawText,
                    cleanText: cloud.cleanText, finalText: cloud.finalText,
                    revisions: cloud.revisions, editVersion: cloud.editVersion,
                    recognitionVersion: cloud.recognitionVersion, audioFileName: nil)
    }

    func testMergeInsertsCloudOnlyRecordsSortedByDateDescending() {
        let old = CloudHistoryRecord(id: UUID(), date: Date(timeIntervalSinceReferenceDate: 100),
                                     rawText: "r", cleanText: "c")
        let new = CloudHistoryRecord(id: UUID(), date: Date(timeIntervalSinceReferenceDate: 200),
                                     rawText: "r", cleanText: "c")
        let outcome = CloudHistoryMerge.merge(local: [LocalRecord](), cloud: [old, new], makeRecord: make)
        XCTAssertEqual(outcome.inserted, 2)
        XCTAssertEqual(outcome.records?.map(\.id), [new.id, old.id])
    }

    func testMergeAdoptsCloudFinalTextOnlyWhenLocalUnedited() {
        let id1 = UUID(), id2 = UUID()
        let local = [
            LocalRecord(id: id1, date: Date(), finalText: nil, audioFileName: "a.wav"),
            LocalRecord(id: id2, date: Date(), finalText: "本地已编辑", audioFileName: nil),
        ]
        let cloud = [
            CloudHistoryRecord(id: id1, date: Date(), rawText: "r", cleanText: "c", finalText: "云端编辑"),
            CloudHistoryRecord(id: id2, date: Date(), rawText: "r", cleanText: "c", finalText: "云端另一版"),
        ]
        let outcome = CloudHistoryMerge.merge(local: local, cloud: cloud, makeRecord: make)
        XCTAssertEqual(outcome.adoptedFinal, 1)
        XCTAssertEqual(outcome.inserted, 0)
        let byID = Dictionary(uniqueKeysWithValues: outcome.records!.map { ($0.id, $0) })
        XCTAssertEqual(byID[id1]?.finalText, "云端编辑")
        XCTAssertEqual(byID[id1]?.audioFileName, "a.wav") // 本机字段保留
        XCTAssertEqual(byID[id2]?.finalText, "本地已编辑") // 本地编辑优先
    }

    func testMergeReturnsNilRecordsWhenNothingChanged() {
        let id = UUID()
        let local = [LocalRecord(id: id, date: Date(), finalText: nil, audioFileName: nil)]
        let cloud = [CloudHistoryRecord(id: id, date: Date(), rawText: "r", cleanText: "c")]
        let outcome = CloudHistoryMerge.merge(local: local, cloud: cloud, makeRecord: make)
        XCTAssertNil(outcome.records)
        XCTAssertEqual(outcome.inserted, 0)
        XCTAssertEqual(outcome.adoptedFinal, 0)
    }

    func testLaterCloudEditReplacesPreviouslySyncedEditAndRevisionStackAtomically() throws {
        let id = UUID()
        let firstRevision = EditRevision(instructionRaw: "第一次", before: "整理稿", after: "第一稿")
        let secondRevision = EditRevision(instructionRaw: "第二次", before: "第一稿", after: "第二稿")
        let v1 = HistoryEditVersion(counter: 1, updatedAt: Date(timeIntervalSinceReferenceDate: 10),
                                    originID: "device-a")
        let v2 = HistoryEditVersion(counter: 2, updatedAt: Date(timeIntervalSinceReferenceDate: 20),
                                    originID: "device-a")
        let local = LocalRecord(id: id, date: Date(), finalText: "第一稿",
                                revisions: [firstRevision], editVersion: v1,
                                audioFileName: "local.wav")
        let cloud = CloudHistoryRecord(id: id, date: local.date, rawText: "原文",
                                       cleanText: "整理稿", finalText: "第二稿",
                                       revisions: [firstRevision, secondRevision], editVersion: v2)

        let outcome = CloudHistoryMerge.merge(local: [local], cloud: [cloud], makeRecord: make)
        let merged = try XCTUnwrap(outcome.records?.first)
        XCTAssertEqual(merged.finalText, "第二稿")
        XCTAssertEqual(merged.revisions, [firstRevision, secondRevision])
        XCTAssertEqual(merged.editVersion, v2)
        XCTAssertEqual(merged.audioFileName, "local.wav")
    }

    func testVersionedUndoToCleanTextReplacesOlderNonEmptyFinalText() throws {
        let id = UUID()
        let local = LocalRecord(
            id: id, date: Date(), finalText: "旧最终稿", revisions: [],
            editVersion: HistoryEditVersion(counter: 2, updatedAt: .distantPast, originID: "a"),
            audioFileName: nil)
        let cloud = CloudHistoryRecord(
            id: id, date: local.date, rawText: "原文", cleanText: "整理稿",
            finalText: nil, revisions: nil,
            editVersion: HistoryEditVersion(counter: 3, updatedAt: Date(), originID: "b"))

        let merged = try XCTUnwrap(
            CloudHistoryMerge.merge(local: [local], cloud: [cloud], makeRecord: make).records?.first)
        XCTAssertNil(merged.finalText)
        XCTAssertNil(merged.revisions)
        XCTAssertEqual(merged.editVersion?.counter, 3)
    }

    func testConcurrentSameCounterUsesTimestampThenOriginIDDeterministically() throws {
        let id = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let earlier = HistoryEditVersion(counter: 4, updatedAt: date, originID: "z-device")
        let later = HistoryEditVersion(counter: 4, updatedAt: date.addingTimeInterval(1),
                                       originID: "a-device")
        let local = LocalRecord(id: id, date: date, finalText: "本地并发稿", revisions: nil,
                                editVersion: earlier, audioFileName: nil)
        let remote = CloudHistoryRecord(id: id, date: date, rawText: "原", cleanText: "整",
                                        finalText: "云端并发稿", editVersion: later)
        let merged = try XCTUnwrap(
            CloudHistoryMerge.merge(local: [local], cloud: [remote], makeRecord: make).records?.first)
        XCTAssertEqual(merged.finalText, "云端并发稿")

        let tieA = HistoryEditVersion(counter: 5, updatedAt: date, originID: "a-device")
        let tieZ = HistoryEditVersion(counter: 5, updatedAt: date, originID: "z-device")
        XCTAssertTrue(tieZ > tieA)
    }

    func testLatestLocalStateRebasePreservesRecordAddedAfterPullSnapshot() throws {
        let a = LocalRecord(id: UUID(), date: Date(timeIntervalSinceReferenceDate: 1),
                            finalText: nil, revisions: nil, editVersion: nil,
                            audioFileName: nil)
        let b = LocalRecord(id: UUID(), date: Date(timeIntervalSinceReferenceDate: 3),
                            finalText: "同步等待期间新增", revisions: nil, editVersion: nil,
                            audioFileName: "b.wav")
        let c = CloudHistoryRecord(id: UUID(), date: Date(timeIntervalSinceReferenceDate: 2),
                                   rawText: "c", cleanText: "c")

        _ = CloudHistoryMerge.merge(local: [a], cloud: [c], makeRecord: make)
        let rebased = try XCTUnwrap(
            CloudHistoryMerge.merge(local: [b, a], cloud: [c], makeRecord: make).records)
        XCTAssertEqual(Set(rebased.map(\.id)), Set([a.id, b.id, c.id]))
        XCTAssertEqual(rebased.first(where: { $0.id == b.id })?.audioFileName, "b.wav")
    }

    func testOlderAsyncPushCannotReplaceNewerCloudEdit() {
        let id = UUID()
        let old = CloudHistoryRecord(
            id: id, date: Date(), rawText: "r", cleanText: "c", finalText: "旧稿",
            editVersion: HistoryEditVersion(counter: 1, updatedAt: .distantPast, originID: "a"))
        let new = CloudHistoryRecord(
            id: id, date: old.date, rawText: "r", cleanText: "c", finalText: "新稿",
            editVersion: HistoryEditVersion(counter: 2, updatedAt: Date(), originID: "a"))
        XCTAssertFalse(CloudHistoryMerge.shouldReplaceCloudFile(existing: new, with: old))
        XCTAssertTrue(CloudHistoryMerge.shouldReplaceCloudFile(existing: old, with: new))
    }

    func testNextEditVersionSaturatesUntrustedMaxCounterWithoutOverflowing() {
        let poisoned = HistoryEditVersion(counter: .max, updatedAt: .distantPast,
                                           originID: "remote")
        let next = HistoryEditVersion.next(after: poisoned, originID: "local", at: Date())
        XCTAssertEqual(next.counter, .max)
        XCTAssertTrue(next > poisoned)
    }

    func testRemoteTombstoneRemovesExistingLocalRecord() {
        let id = UUID()
        let local = [LocalRecord(id: id, date: Date(), finalText: nil, audioFileName: "a.wav")]
        let deletedAt = Date(timeIntervalSinceReferenceDate: 500)
        let cloud = [CloudHistoryRecord.tombstone(
            id: id, originalDate: local[0].date, deletedAt: deletedAt)]

        let outcome = CloudHistoryMerge.merge(local: local, cloud: cloud, makeRecord: make)

        XCTAssertEqual(outcome.records, [])
        XCTAssertEqual(outcome.removed, 1)
        XCTAssertEqual(outcome.deletions[id], deletedAt)
        XCTAssertTrue(outcome.deletionsChanged)
    }

    func testLocalTombstoneBlocksStaleCloudRecordFromReviving() {
        let id = UUID()
        let deletedAt = Date(timeIntervalSinceReferenceDate: 500)
        let cloud = [CloudHistoryRecord(
            id: id, date: Date(timeIntervalSinceReferenceDate: 100), rawText: "r", cleanText: "c")]

        let outcome = CloudHistoryMerge.merge(
            local: [LocalRecord](), localDeletions: [id: deletedAt],
            cloud: cloud, makeRecord: make)

        XCTAssertNil(outcome.records)
        XCTAssertEqual(outcome.inserted, 0)
        XCTAssertEqual(outcome.deletions[id], deletedAt)
    }

    func testTombstoneWinsWhenConflictDirectoryAlsoContainsLiveRecord() {
        let id = UUID()
        let live = CloudHistoryRecord(
            id: id, date: Date(timeIntervalSinceReferenceDate: 100), rawText: "r", cleanText: "c")
        let tombstone = CloudHistoryRecord.tombstone(
            id: id, originalDate: live.date,
            deletedAt: Date(timeIntervalSinceReferenceDate: 500))

        let outcome = CloudHistoryMerge.merge(
            local: [LocalRecord](), cloud: [live, tombstone], makeRecord: make)

        XCTAssertNil(outcome.records)
        XCTAssertEqual(outcome.inserted, 0)
        XCTAssertNotNil(outcome.deletions[id])
    }

    // MARK: - 冲突目录布局("History 2" 变体扫描)

    func testHistoryFoldersFindsCanonicalAndConflictVariants() throws {
        let fm = FileManager.default
        let documents = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: documents) }
        for dir in ["History", "History 2", "History 3", "Dictionary"] {
            try fm.createDirectory(at: documents.appendingPathComponent(dir),
                                   withIntermediateDirectories: true)
        }
        // 干扰项:同前缀的普通文件不应入选
        fm.createFile(atPath: documents.appendingPathComponent("History 4").path, contents: Data())

        let folders = CloudHistoryLayout.historyFolders(inDocuments: documents)
        XCTAssertEqual(folders.map(\.lastPathComponent), ["History", "History 2", "History 3"])
    }

    // MARK: - 推送前字段级合并(2026-09-06 回归审查 #2)
    //
    // 复现:replaceRecognition 更新 rawText/cleanText 但不推进 editVersion;
    // 旧的 shouldReplaceCloudFile 只比较编辑维度,版本相等时拒绝正文更新,push 仍报告
    // 成功。mergeForPush 把正文(rawText/cleanText/recognitionVersion)与编辑
    // (finalText/revisions/editVersion)拆成两个独立版本分别判断、分别采用。

    func testMergeForPushAdoptsRecognitionOnlyWhenOnlyRecognitionVersionIsNewer() {
        let id = UUID()
        let v1 = HistoryEditVersion(counter: 1, updatedAt: Date(timeIntervalSinceReferenceDate: 1), originID: "a")
        let existing = CloudHistoryRecord(id: id, date: Date(), rawText: "wrong ASR", cleanText: "wrong ASR",
                                          finalText: "用户编辑", editVersion: v1, recognitionVersion: v1)
        let incoming = CloudHistoryRecord(id: id, date: existing.date, rawText: "correct ASR", cleanText: "correct ASR",
                                          finalText: "用户编辑", editVersion: v1,
                                          recognitionVersion: .next(after: v1, originID: "a"))
        let merged = try? XCTUnwrap(CloudHistoryMerge.mergeForPush(existing: existing, incoming: incoming))
        XCTAssertEqual(merged?.rawText, "correct ASR")
        XCTAssertEqual(merged?.cleanText, "correct ASR")
        XCTAssertEqual(merged?.finalText, "用户编辑", "重识别不应触碰用户已编辑的最终稿")
        XCTAssertEqual(merged?.editVersion, v1, "只有正文版本推进,编辑版本不应该被改动")
    }

    func testMergeForPushAdoptsEditOnlyWhenOnlyEditVersionIsNewer() {
        let id = UUID()
        let recognitionVersion = HistoryEditVersion(counter: 1, updatedAt: Date(), originID: "a")
        let existing = CloudHistoryRecord(id: id, date: Date(), rawText: "raw", cleanText: "clean",
                                          finalText: nil, editVersion: nil,
                                          recognitionVersion: recognitionVersion)
        let incoming = CloudHistoryRecord(id: id, date: existing.date, rawText: "raw", cleanText: "clean",
                                          finalText: "新编辑",
                                          editVersion: .next(after: nil, originID: "a"),
                                          recognitionVersion: recognitionVersion)
        let merged = try? XCTUnwrap(CloudHistoryMerge.mergeForPush(existing: existing, incoming: incoming))
        XCTAssertEqual(merged?.finalText, "新编辑")
        XCTAssertEqual(merged?.rawText, "raw", "只有编辑版本推进,正文不应该被改动")
        XCTAssertEqual(merged?.recognitionVersion, recognitionVersion)
    }

    func testMergeForPushAdoptsBothDimensionsWhenBothAreNewerInterleaved() {
        let id = UUID()
        let existing = CloudHistoryRecord(id: id, date: Date(), rawText: "旧原文", cleanText: "旧整理",
                                          finalText: "旧编辑",
                                          editVersion: HistoryEditVersion(counter: 1, updatedAt: .distantPast, originID: "a"),
                                          recognitionVersion: HistoryEditVersion(counter: 1, updatedAt: .distantPast, originID: "a"))
        let incoming = CloudHistoryRecord(id: id, date: existing.date, rawText: "新原文", cleanText: "新整理",
                                          finalText: "新编辑",
                                          editVersion: HistoryEditVersion(counter: 2, updatedAt: Date(), originID: "a"),
                                          recognitionVersion: HistoryEditVersion(counter: 2, updatedAt: Date(), originID: "a"))
        let merged = try? XCTUnwrap(CloudHistoryMerge.mergeForPush(existing: existing, incoming: incoming))
        XCTAssertEqual(merged?.rawText, "新原文")
        XCTAssertEqual(merged?.finalText, "新编辑")
    }

    func testMergeForPushRejectsStaleAsyncTaskOnBothDimensions() {
        // 旧任务晚完成:incoming 在两个维度都比云端已有内容旧,不能覆盖任何一个维度。
        let id = UUID()
        let existing = CloudHistoryRecord(id: id, date: Date(), rawText: "新原文", cleanText: "新整理",
                                          finalText: "新编辑",
                                          editVersion: HistoryEditVersion(counter: 2, updatedAt: Date(), originID: "b"),
                                          recognitionVersion: HistoryEditVersion(counter: 2, updatedAt: Date(), originID: "b"))
        let staleIncoming = CloudHistoryRecord(id: id, date: existing.date, rawText: "旧原文", cleanText: "旧整理",
                                               finalText: "旧编辑",
                                               editVersion: HistoryEditVersion(counter: 1, updatedAt: .distantPast, originID: "a"),
                                               recognitionVersion: HistoryEditVersion(counter: 1, updatedAt: .distantPast, originID: "a"))
        XCTAssertNil(CloudHistoryMerge.mergeForPush(existing: existing, incoming: staleIncoming))
        XCTAssertFalse(CloudHistoryMerge.shouldReplaceCloudFile(existing: existing, with: staleIncoming))
    }

    func testMergeForPushIsIdempotentWhenNothingChanged() {
        let id = UUID()
        let version = HistoryEditVersion(counter: 1, updatedAt: Date(), originID: "a")
        let record = CloudHistoryRecord(id: id, date: Date(), rawText: "raw", cleanText: "clean",
                                        finalText: "final", editVersion: version, recognitionVersion: version)
        XCTAssertNil(CloudHistoryMerge.mergeForPush(existing: record, incoming: record))
    }

    func testMergeForPushConvergesRegardlessOfArrivalOrder() {
        // 正文更新(B)与编辑更新(C)是两条独立异步任务,不管谁先落盘,最终状态必须一致。
        let id = UUID()
        let base = CloudHistoryRecord(id: id, date: Date(), rawText: "原文", cleanText: "原文",
                                      finalText: nil, editVersion: nil, recognitionVersion: nil)
        let recognitionUpdate = CloudHistoryRecord(id: id, date: base.date, rawText: "修正原文", cleanText: "修正原文",
                                                   finalText: nil, editVersion: nil,
                                                   recognitionVersion: .next(after: nil, originID: "a"))
        let editUpdate = CloudHistoryRecord(id: id, date: base.date, rawText: "原文", cleanText: "原文",
                                            finalText: "用户编辑", editVersion: .next(after: nil, originID: "b"),
                                            recognitionVersion: nil)

        let orderOne = CloudHistoryMerge.mergeForPush(
            existing: CloudHistoryMerge.mergeForPush(existing: base, incoming: recognitionUpdate) ?? base,
            incoming: editUpdate)
        let orderTwo = CloudHistoryMerge.mergeForPush(
            existing: CloudHistoryMerge.mergeForPush(existing: base, incoming: editUpdate) ?? base,
            incoming: recognitionUpdate)

        XCTAssertEqual(orderOne?.rawText, "修正原文")
        XCTAssertEqual(orderOne?.finalText, "用户编辑")
        XCTAssertEqual(orderOne?.rawText, orderTwo?.rawText)
        XCTAssertEqual(orderOne?.finalText, orderTwo?.finalText)
        XCTAssertEqual(orderOne?.editVersion, orderTwo?.editVersion)
        XCTAssertEqual(orderOne?.recognitionVersion, orderTwo?.recognitionVersion)
    }

    func testMergeForPushNeverRevivesDeletedCloudRecord() {
        let id = UUID()
        let tombstone = CloudHistoryRecord.tombstone(id: id, originalDate: Date(), deletedAt: Date())
        let incoming = CloudHistoryRecord(id: id, date: tombstone.date, rawText: "重新识别的正文",
                                          cleanText: "重新识别的正文",
                                          recognitionVersion: .next(after: nil, originID: "a"))
        XCTAssertNil(CloudHistoryMerge.mergeForPush(existing: tombstone, incoming: incoming))
        XCTAssertFalse(CloudHistoryMerge.shouldReplaceCloudFile(existing: tombstone, with: incoming))
    }

    func testMergeForPushAdoptsRecognitionWhenExistingPredatesRecognitionVersioning() {
        // 旧格式云文件没有 recognitionVersion 键,解码为 nil;不代表它已经是最新版本，
        // 有 recognitionVersion 的一侧应该被采用(与 editVersion 的 nil/some 规则一致)。
        let id = UUID()
        let legacyJSON = #"{"id":"\#(id.uuidString)","date":100,"rawText":"旧正文","cleanText":"旧正文"}"#
        let existing = try! CloudHistoryRecord.decode(Data(legacyJSON.utf8))
        XCTAssertNil(existing.recognitionVersion, "旧格式必须解码为 nil,不能凭空升级版本")
        let incoming = CloudHistoryRecord(id: id, date: existing.date, rawText: "新正文", cleanText: "新正文",
                                          recognitionVersion: .next(after: nil, originID: "a"))
        let merged = try? XCTUnwrap(CloudHistoryMerge.mergeForPush(existing: existing, incoming: incoming))
        XCTAssertEqual(merged?.rawText, "新正文")
    }

    // MARK: - 拉取合并同样独立处理正文与编辑维度

    func testPullMergeAdoptsRecognitionIndependentlyFromEditDimension() {
        // 本地已经手改过最终稿(编辑版本更新),但识别正文还是旧的;云端在另一台设备上
        // 重新识别过(正文版本更新),编辑维度却落后。两个维度必须分别采纳:
        // 最终稿保留本地编辑,正文接受云端的重识别结果。
        let id = UUID()
        let local = LocalRecord(
            id: id, date: Date(), rawText: "本地旧原文", cleanText: "本地旧原文",
            finalText: "本地用户编辑",
            editVersion: HistoryEditVersion(counter: 2, updatedAt: Date(), originID: "local"),
            recognitionVersion: HistoryEditVersion(counter: 1, updatedAt: .distantPast, originID: "local"),
            audioFileName: "local.wav")
        let cloud = CloudHistoryRecord(
            id: id, date: local.date, rawText: "云端重识别正文", cleanText: "云端重识别正文",
            finalText: "云端旧编辑",
            editVersion: HistoryEditVersion(counter: 1, updatedAt: .distantPast, originID: "remote"),
            recognitionVersion: HistoryEditVersion(counter: 2, updatedAt: Date(), originID: "remote"))

        let outcome = CloudHistoryMerge.merge(local: [local], cloud: [cloud], makeRecord: make)
        let merged = try? XCTUnwrap(outcome.records?.first)
        XCTAssertEqual(merged?.finalText, "本地用户编辑", "编辑版本更新的一方应该保留最终稿")
        XCTAssertEqual(merged?.rawText, "云端重识别正文", "正文版本更新的一方应该被独立采纳")
        XCTAssertEqual(merged?.audioFileName, "local.wav", "本机字段不受正文/编辑合并影响")
        XCTAssertEqual(outcome.adoptedRecognition, 1)
        XCTAssertEqual(outcome.adoptedFinal, 0)
    }

    func testPullMergeRepeatedApplicationIsIdempotent() {
        let id = UUID()
        let cloud = CloudHistoryRecord(id: id, date: Date(), rawText: "raw", cleanText: "clean",
                                       recognitionVersion: .next(after: nil, originID: "a"))
        let local = [make(cloud)]
        let outcome = CloudHistoryMerge.merge(local: local, cloud: [cloud], makeRecord: make)
        XCTAssertNil(outcome.records, "已经采用过的云端内容重复合并不应再报告变化")
        XCTAssertEqual(outcome.adoptedRecognition, 0)
    }

    func testHistoryFoldersEmptyWhenDocumentsMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
        XCTAssertEqual(CloudHistoryLayout.historyFolders(inDocuments: missing), [])
    }
}
