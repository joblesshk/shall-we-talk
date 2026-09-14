import XCTest
@testable import ShallWeTalkCore

/// 覆盖 §端到端延迟打点(工程规划 2026-07-17):
/// - LatencyMetrics 的解码兼容性(旧记录缺字段必须正常解码,不能抛错)
/// - compactSummary 的分段耗时文案口径
/// `structurePass` 继续解码旧历史记录，但 native nostream 生产链路不再写入新值。
final class LatencyMetricsTests: XCTestCase {

    // MARK: - 解码兼容性

    func testDecodeEmptyObjectLeavesAllFieldsNil() throws {
        let data = Data("{}".utf8)
        let metrics = try JSONDecoder().decode(LatencyMetrics.self, from: data)
        XCTAssertNil(metrics.asrFirstPartialMillis)
        XCTAssertNil(metrics.asrFinalMillis)
        XCTAssertNil(metrics.llmFirstTokenMillis)
        XCTAssertNil(metrics.cleanupCompleteMillis)
        XCTAssertNil(metrics.totalMillis)
    }

    func testDecodePartialFieldsOnlySetsPresentKeys() throws {
        let data = Data(#"{"asrFinalMillis": 800, "totalMillis": 2100}"#.utf8)
        let metrics = try JSONDecoder().decode(LatencyMetrics.self, from: data)
        XCTAssertEqual(metrics.asrFinalMillis, 800)
        XCTAssertEqual(metrics.totalMillis, 2100)
        XCTAssertNil(metrics.asrFirstPartialMillis)
        XCTAssertNil(metrics.llmFirstTokenMillis)
        XCTAssertNil(metrics.cleanupCompleteMillis)
    }

    func testEncodeDecodeRoundTripPreservesValues() throws {
        let metrics = LatencyMetrics(asrFirstPartialMillis: 300, asrFinalMillis: 900,
                                     llmFirstTokenMillis: 1100, cleanupCompleteMillis: 1900,
                                     totalMillis: 2000)
        let data = try JSONEncoder().encode(metrics)
        let decoded = try JSONDecoder().decode(LatencyMetrics.self, from: data)
        XCTAssertEqual(decoded, metrics)
    }

    func testCleanupPassTimelinesRoundTripIndependently() throws {
        let first = CleanupPassMetrics(startedMillis: 920, firstTokenMillis: 1310,
                                       completedMillis: 1680, requestCount: 1,
                                       promptTokens: 720, cachedPromptTokens: 640)
        let structure = CleanupPassMetrics(startedMillis: 1690, firstTokenMillis: 1950,
                                           completedMillis: 2420, requestCount: 2,
                                           promptTokens: 1460, cachedPromptTokens: 1280)
        let original = LatencyMetrics(asrFinalMillis: 860, cleanupCompleteMillis: 2420,
                                      firstCleanupPass: first, structurePass: structure)
        let decoded = try JSONDecoder().decode(LatencyMetrics.self,
                                                from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.firstCleanupPass, first)
        XCTAssertEqual(decoded.structurePass, structure)
        XCTAssertEqual(decoded.firstCleanupPass?.promptCacheHitRate ?? 0, 640.0 / 720.0,
                       accuracy: 0.0001)
        XCTAssertEqual(decoded.structurePass?.requestCount, 2)
    }

    /// 模拟旧版 DictationRecord JSON(整条记录里根本没有 "metrics" 键,不是 metrics 内部字段缺失):
    /// 两端 HistoryStore 的 DictationRecord 都是 `var metrics: LatencyMetrics? = nil` 这种可选带默认值
    /// 字段,走的是与本测试同样的 Codable 机制——旧记录必须正常解码,不能抛错、不能崩溃。
    func testOuterRecordWithoutMetricsKeyDecodesToNilMetrics() throws {
        struct FixtureRecord: Codable, Equatable {
            let id: UUID
            var rawText: String
            var cleanText: String
            var metrics: LatencyMetrics? = nil
        }
        let id = UUID()
        let legacyJSON = """
        {"id":"\(id.uuidString)","rawText":"你好","cleanText":"你好。"}
        """
        let data = Data(legacyJSON.utf8)
        let record = try JSONDecoder().decode(FixtureRecord.self, from: data)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.rawText, "你好")
        XCTAssertNil(record.metrics, "legacy records with no metrics key must decode with metrics == nil, not throw")
    }

    // MARK: - compactSummary 文案口径

    func testCompactSummaryFormatsAllThreeSegments() {
        // 识别 1.2s(asrFinalMillis=1200);整理增量 0.8s(cleanupCompleteMillis-asrFinalMillis=2000-1200);共 2.1s(totalMillis)
        let metrics = LatencyMetrics(asrFinalMillis: 1200, cleanupCompleteMillis: 2000, totalMillis: 2100)
        XCTAssertEqual(metrics.compactSummary, "识别 1.2s · 整理 0.8s · 共 2.1s")
    }

    func testCompactSummaryNilWhenEverythingMissing() {
        XCTAssertNil(LatencyMetrics().compactSummary)
    }

    func testCompactSummaryOmitsCleanupWhenNoCleanupHappened() {
        // 旧记录/容错场景可能没有整理耗时，摘要应只显示识别与总耗时。
        let metrics = LatencyMetrics(asrFinalMillis: 400, totalMillis: 420)
        XCTAssertEqual(metrics.compactSummary, "识别 0.4s · 共 0.4s")
    }

    func testCompactSummaryFallsBackToCleanupCompleteWhenTotalMissing() {
        let metrics = LatencyMetrics(asrFinalMillis: 500, cleanupCompleteMillis: 1500)
        XCTAssertEqual(metrics.compactSummary, "识别 0.5s · 整理 1.0s · 共 1.5s")
    }

    func testCompactSummaryClampsNegativeCleanupDeltaToZero() {
        // 防御性:理论上 cleanupCompleteMillis 不应早于 asrFinalMillis,但打点若有微小抖动
        // 也不该展示负数耗时给用户。
        let metrics = LatencyMetrics(asrFinalMillis: 1000, cleanupCompleteMillis: 950, totalMillis: 1000)
        XCTAssertEqual(metrics.compactSummary, "识别 1.0s · 整理 0.0s · 共 1.0s")
    }

}
