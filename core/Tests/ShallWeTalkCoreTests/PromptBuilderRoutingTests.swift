import XCTest
@testable import ShallWeTalkCore

final class PromptBuilderRoutingTests: XCTestCase {
    func testShortAndLongUseTheirOwnBases() {
        let short = PromptBuilder.buildDictation(route: .homophoneOnly)
        XCTAssertEqual(short, PromptBuilder.buildSimple())
        XCTAssertTrue(short.contains(PromptBuilder.simpleBase))
        XCTAssertFalse(short.contains(PromptBuilder.mostCompleteLongBase))
        for route in [CleanupPromptRoute.full, .explicitEnumeration] {
            XCTAssertTrue(PromptBuilder.buildDictation(route: route).contains(PromptBuilder.mostCompleteLongBase))
        }
    }
}
