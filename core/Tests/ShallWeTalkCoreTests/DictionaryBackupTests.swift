import XCTest
@testable import ShallWeTalkCore

final class DictionaryBackupTests: XCTestCase {
    func testCompleteRoundTripAndLegacyImport() throws {
        let original = DictionaryBackup(manual: ["张三"], auto: ["Claude"],
            corrections: [.init(source: "张山", target: "张三")], blockedWords: ["旧词"], blockedCorrections: ["旧错"])
        let restored = try DictionaryBackup.parse(JSONEncoder().encode(original), isJSON: true)
        XCTAssertEqual(restored.corrections, original.corrections)
        XCTAssertEqual(restored.blockedWords, original.blockedWords)
        XCTAssertEqual(restored.blockedCorrections, original.blockedCorrections)
        let legacy = try DictionaryBackup.parse(Data(#"{"manual":["甲"],"auto":["乙"]}"#.utf8), isJSON: true)
        XCTAssertEqual(legacy.manual + legacy.auto, ["甲", "乙"])
        XCTAssertTrue(legacy.corrections.isEmpty)
        XCTAssertEqual(try DictionaryBackup.parse(Data("甲\n乙\n".utf8), isJSON: false).manual, ["甲", "乙"])
    }
    func testMalformedJSONDoesNotBecomeWords() {
        for text in ["{broken", "{}", #"{"manual":["甲"],"auto":[],"version":99}"#, #"{"manual":["甲\n乙"],"auto":[]}"#] {
            XCTAssertThrowsError(try DictionaryBackup.parse(Data(text.utf8), isJSON: true))
        }
    }
    func testMergePreservesLocalEditsAndDeletionChoices() {
        let local = DictionaryBackup(manual: ["保留"], corrections: [.init(source: "ASR", target: "本机")],
            blockedWords: ["删掉的词"], blockedCorrections: ["旧错"])
        let backup = DictionaryBackup(manual: ["保留", "新词", "删掉的词"],
            corrections: [.init(source: "asr", target: "备份"), .init(source: "旧错", target: "不要复活")],
            blockedWords: ["保留", "另一屏蔽"])
        let result = backup.preview(mergingInto: local)
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.duplicates, 1)
        XCTAssertEqual(result.conflicts, 4)
        XCTAssertEqual(result.merged.manual, ["保留", "新词"])
        XCTAssertEqual(result.merged.corrections, local.corrections)
        XCTAssertFalse(result.merged.blockedWords.contains("保留"))
        // 确认导入前本机有新编辑：重新计算合并，仍以最新本机为准。
        let changedLocal = DictionaryBackup(manual: ["新词"], blockedWords: ["保留"])
        XCTAssertFalse(backup.preview(mergingInto: changedLocal).merged.manual.contains("保留"))
    }
    func testRetryIsBoundedAndCleanupTimeExcludesASR() {
        XCTAssertEqual((0...3).map { DictionarySyncRetry.delay(afterFailures: $0) }, [5, 15, 45, nil])
        XCTAssertNil(DictionarySyncRetry.delay(afterFailures: -1))
        XCTAssertEqual(CleanupPassMetrics(startedMillis: 800, completedMillis: 1200).elapsedMillis, 400)
        XCTAssertNil(CleanupPassMetrics(startedMillis: 1200, completedMillis: 800).elapsedMillis)
        XCTAssertNil(CleanupPassMetrics().elapsedMillis)
    }
}
