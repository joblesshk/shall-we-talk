import XCTest
@testable import ShallWeTalkCore

final class ManualCorrectionsTests: XCTestCase {
    func testCaseInsensitiveReplaceRegardlessOfSourceCasing() {
        let pairs = [LearnedCorrection(source: "Meta Alpha", target: "Metalpha")]
        XCTAssertEqual(ManualCorrections.apply(to: "我们投了 meta alpha 这个项目", pairs: pairs),
                       "我们投了 Metalpha 这个项目")
        XCTAssertEqual(ManualCorrections.apply(to: "META ALPHA 的估值", pairs: pairs), "Metalpha 的估值")
        XCTAssertEqual(ManualCorrections.apply(to: "MeTa AlPhA", pairs: pairs), "Metalpha")
    }

    func testReplacesAllOccurrences() {
        let pairs = [LearnedCorrection(source: "meta alpha", target: "Metalpha")]
        XCTAssertEqual(ManualCorrections.apply(to: "Meta Alpha 和 META ALPHA", pairs: pairs),
                       "Metalpha 和 Metalpha")
    }

    func testNoPairsOrEmptyTextIsNoOp() {
        XCTAssertEqual(ManualCorrections.apply(to: "hello", pairs: []), "hello")
        XCTAssertEqual(ManualCorrections.apply(to: "", pairs: [LearnedCorrection(source: "a", target: "b")]), "")
    }

    func testSkipsPairWhereSourceEqualsTarget() {
        let pairs = [LearnedCorrection(source: "Metalpha", target: "Metalpha")]
        XCTAssertEqual(ManualCorrections.apply(to: "Metalpha", pairs: pairs), "Metalpha")
    }
}
