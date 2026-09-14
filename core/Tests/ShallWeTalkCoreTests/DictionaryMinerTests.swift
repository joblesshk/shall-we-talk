import XCTest
@testable import ShallWeTalkCore

/// 迁移自 ios/tests/DictionaryMinerSmoke.swift。测试桩不复用 App 的 DictationRecord
/// (存储层,不进本包),而是定义一个满足 DictionaryMinableRecord 的最小类型,
/// 与两端 App 的做法(HistoryStore.DictationRecord 加协议 extension)对称。
final class DictionaryMinerTests: XCTestCase {
    private struct StubRecord: DictionaryMinableRecord {
        var finalText: String?
        var cleanText: String
    }

    func testEqualFrequencyWordsHaveStableOrder() {
        let first = StubRecord(finalText: nil, cleanText: "ZebraTool AlphaTool BetaTool")
        let reversed = StubRecord(finalText: nil, cleanText: "BetaTool AlphaTool ZebraTool")
        let expected = ["AlphaTool", "BetaTool", "ZebraTool"]
        XCTAssertEqual(DictionaryMiner.mine(records: Array(repeating: first, count: 3),
                                            manual: [], blocked: []), expected)
        XCTAssertEqual(DictionaryMiner.mine(records: Array(repeating: reversed, count: 3),
                                            manual: [], blocked: []), expected)
    }

    func testExplicitEditLearnsExactContextualCorrection() {
        let corrected = StubRecord(
            finalText: "谷歌，我是一直做多的呀。",
            cleanText: "谷歌，我是一只做多的呀。")
        let pairs = DictionaryMiner.correctionPairs(records: [corrected])
        XCTAssertEqual(pairs, [LearnedCorrection(source: "一只做多的", target: "一直做多的")],
                       "one explicit edit must learn an exact contextual correction")
    }

    func testSingleCharacterFragmentsDoNotPolluteDictionary() {
        let corrected = StubRecord(
            finalText: "谷歌，我是一直做多的呀。",
            cleanText: "谷歌，我是一只做多的呀。")
        let autoWords = DictionaryMiner.mine(records: [corrected, corrected], manual: [], blocked: [])
        XCTAssertFalse(autoWords.contains("直"),
                       "single-character correction fragments must not pollute the global dictionary")
    }

    func testUneditedValidClassifierPhraseCreatesNoCorrection() {
        let untouched = StubRecord(finalText: nil, cleanText: "这是一只做多的基金。")
        XCTAssertTrue(DictionaryMiner.correctionPairs(records: [untouched]).isEmpty,
                     "unedited valid classifier phrases must not create corrections")
    }
}
