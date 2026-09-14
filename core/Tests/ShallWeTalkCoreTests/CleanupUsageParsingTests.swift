import XCTest
@testable import ShallWeTalkCore

/// 流末 token 账单的解析。字段形状来自各家文档而非实跑响应,所以两种命名都要覆盖:
/// DeepSeek 用 `prompt_cache_hit_tokens`,OpenAI 系用 `prompt_tokens_details.cached_tokens`。
final class CleanupUsageParsingTests: XCTestCase {
    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    func testParsesDeepSeekCacheFields() {
        let usage = CleanupService.Usage.parse(object("""
        {"choices":[],"usage":{"prompt_tokens":4096,"completion_tokens":120,
         "prompt_cache_hit_tokens":3840,"prompt_cache_miss_tokens":256}}
        """))
        XCTAssertEqual(usage?.promptTokens, 4096)
        XCTAssertEqual(usage?.cachedPromptTokens, 3840)
        XCTAssertEqual(usage?.completionTokens, 120)
        XCTAssertEqual(usage?.cacheHitRate ?? 0, 0.9375, accuracy: 0.0001)
    }

    func testParsesOpenAIStyleCachedTokens() {
        let usage = CleanupService.Usage.parse(object("""
        {"choices":[],"usage":{"prompt_tokens":2048,"completion_tokens":64,
         "prompt_tokens_details":{"cached_tokens":1024}}}
        """))
        XCTAssertEqual(usage?.promptTokens, 2048)
        XCTAssertEqual(usage?.cachedPromptTokens, 1024)
        XCTAssertEqual(usage?.cacheHitRate ?? 0, 0.5, accuracy: 0.0001)
    }

    func testContentChunksCarryNoUsage() {
        XCTAssertNil(CleanupService.Usage.parse(object("""
        {"choices":[{"delta":{"content":"你好"}}]}
        """)))
        // 供应商常在普通 chunk 里显式写 usage: null,不能当成账单。
        XCTAssertNil(CleanupService.Usage.parse(object("""
        {"choices":[{"delta":{"content":"你好"}}],"usage":null}
        """)))
    }

    func testMissingCacheFieldsLeaveRateUnknownRatherThanZero() {
        let usage = CleanupService.Usage.parse(object("""
        {"choices":[],"usage":{"prompt_tokens":512,"completion_tokens":32}}
        """))
        XCTAssertEqual(usage?.promptTokens, 512)
        XCTAssertNil(usage?.cachedPromptTokens)
        XCTAssertNil(usage?.cacheHitRate, "拿不到缓存字段时必须是未知,不能报告成 0% 命中")
    }

    func testMetricsApplyIgnoresNilUsage() {
        var metrics = LatencyMetrics(promptTokens: 100, cachedPromptTokens: 80)
        metrics.apply(nil)
        XCTAssertEqual(metrics.promptTokens, 100)
        XCTAssertEqual(metrics.cachedPromptTokens, 80)
    }

    /// 旧记录没有这两个键,必须仍能解码(历史 JSON 直接落盘,不能因为加字段而读不回来)。
    func testLegacyMetricsWithoutTokenFieldsStillDecode() throws {
        let legacy = Data(#"{"asrFinalMillis":550,"totalMillis":1200}"#.utf8)
        let decoded = try JSONDecoder().decode(LatencyMetrics.self, from: legacy)
        XCTAssertEqual(decoded.asrFinalMillis, 550)
        XCTAssertNil(decoded.promptTokens)
        XCTAssertNil(decoded.promptCacheHitRate)
    }
}
