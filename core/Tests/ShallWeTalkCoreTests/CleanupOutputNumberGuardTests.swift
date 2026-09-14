import XCTest
@testable import ShallWeTalkCore

/// `validatedOutput` 的反向数字守卫。
///
/// 原有校验只防「删」:原文的数字必须都还在。但幻觉「增」对金额、日期、比例和交易数据
/// 更危险——丢一个数字读起来突兀、容易被人眼抓到,凭空多一个数字却完全通顺。
/// 守卫只在短同音纠错路由启用,原因见下面两组测试。
final class CleanupOutputNumberGuardTests: XCTestCase {
    // MARK: - 短路由:必须拦住凭空多出来的数字

    func testShortRouteRejectsHallucinatedNumber() {
        let original = "我最后下单从大几千万降到 500 万"
        let hallucinated = "我最后下单从约 8000 万降到 500 万"
        XCTAssertEqual(
            CleanupService.validatedOutput(hallucinated, original: original,
                                           forbidsNewNumbers: true),
            original)
    }

    func testShortRouteRejectsFabricatedRangeEndpoint() {
        let original = "估值大概在 30 倍以上"
        let fabricated = "估值大概在 30 到 35 倍"
        XCTAssertEqual(
            CleanupService.validatedOutput(fabricated, original: original, forbidsNewNumbers: true),
            original)
    }

    func testShortRouteStillAcceptsUnitAndSeparatorEdits() {
        // 只补单位/百分号、只换分隔符:数字令牌本身没变,必须放行(与既有契约一致)。
        XCTAssertEqual(
            CleanupService.validatedOutput("降幅 11.03%", original: "降幅 11.03",
                                           forbidsNewNumbers: true),
            "降幅 11.03%")
        XCTAssertEqual(
            CleanupService.validatedOutput("7月14日到7月15日", original: "7月14~7月15日",
                                           forbidsNewNumbers: true),
            "7月14日到7月15日")
    }

    func testShortRouteKeepsPureTextRewrites() {
        XCTAssertEqual(
            CleanupService.validatedOutput("我一直觉得这个方案可行",
                                           original: "我一只觉得这个方案可行",
                                           forbidsNewNumbers: true),
            "我一直觉得这个方案可行")
    }

    // MARK: - 完整路由:守卫必须关着,否则每次成功的编号都会被误判

    func testFullRouteAllowsListNumberingItIsDesignedToProduce() {
        // 完整 prompt 明确要求把并列枚举整理成编号列表。这些序号在原文里不存在,
        // 一旦启用反向守卫就会被当成幻觉,把每一次正确的分段编号退回 ASR 原文。
        let original = "第一件事是发合同 第二件事是确认打款"
        let numbered = "1. 发合同\n2. 确认打款"
        XCTAssertEqual(
            CleanupService.validatedOutput(numbered, original: original),
            numbered)
    }

    func testFullRouteAllowsSpokenVersionNormalisation() {
        // 完整 prompt 允许把口述的版本号规范成 V5 这类写法,同样会引入新数字令牌。
        XCTAssertEqual(
            CleanupService.validatedOutput("升级到 V5", original: "升级到版本五"),
            "升级到 V5")
    }

    func testFullRouteKeepsProtectingAgainstDroppedNumbers() {
        // 防「删」这一侧与守卫无关,两条路由都必须继续生效。
        XCTAssertEqual(
            CleanupService.validatedOutput("目前31.28%", original: "目前31.283"),
            "目前31.283")
    }

    func testFullRouteRejectsChangedNumericTokenEvenWhenOriginalIsASubstring() {
        for candidate in ["金额为131.28元。", "金额为31.283元。"] {
            XCTAssertEqual(CleanupService.validatedOutput(candidate, original: "金额为31.28元。"), "金额为31.28元。")
        }
        XCTAssertEqual(CleanupService.validatedOutput("1. 金额31.28元", original: "金额31.28元"), "1. 金额31.28元")
    }

    // MARK: - 默认值

    func testGuardIsOffByDefaultSoExistingCallSitesAreUnchanged() {
        let original = "估值大概在 30 倍以上"
        let withNewNumber = "估值大概在 30 到 35 倍"
        XCTAssertEqual(
            CleanupService.validatedOutput(withNewNumber, original: original),
            withNewNumber)
    }
}
