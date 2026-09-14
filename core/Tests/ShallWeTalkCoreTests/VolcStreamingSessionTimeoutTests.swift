import XCTest
@testable import ShallWeTalkCore

/// 覆盖普通端点 finish() 的 3 秒整体硬超时，以及 nostream 终稿收尾的扩展预算。
///
/// 不调用 start():底层 WebSocket 从未建连、receiveLoop/sendTask 都未启动,finish() 内部的
/// snapshot() 会永远停在"未完成、无错误",天然模拟"卡住不返回终包"的场景——不需要任何真实或
/// 模拟网络 I/O,同时仍然验证的是真实的 3 秒挂钟耗时(源码里的超时时长未做可注入化)。
final class VolcStreamingSessionTimeoutTests: XCTestCase {
    func testDiagnosticsExposeStableNonSecretServerCorrelationIDs() {
        let session = VolcStreamingSession(
            wsURL: URL(string: "wss://hang.invalid/api/v3/sauc/bigmodel")!,
            appId: "id", accessToken: "token", resourceId: "volc.seedasr.sauc.duration"
        ) { _ in }

        let diagnostics = session.diagnostics
        XCTAssertFalse(diagnostics.requestID.isEmpty)
        XCTAssertFalse(diagnostics.connectID.isEmpty)
        XCTAssertNotEqual(diagnostics.requestID, diagnostics.connectID)
        XCTAssertNil(diagnostics.endFrameSequence)
    }

    func testFinishWithoutStartTimesOutAtThreeSecondsInsteadOfHangingIndefinitely() async {
        let session = VolcStreamingSession(
            wsURL: URL(string: "wss://hang.invalid/api/v3/sauc/bigmodel")!,
            appId: "id", accessToken: "token", resourceId: "volc.seedasr.sauc.duration"
        ) { _ in }

        let start = Date()
        do {
            _ = try await session.finish()
            XCTFail("finish() must throw when no final packet ever arrives")
        } catch {
            // 期望即可,不强求具体错误文案(finishCore 的 3s 内层超时与外层 3s 硬超时是一场竞速,
            // 谁先到都合法,详见 VolcStreamingSession.finish 实现注释)。
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(elapsed, 2.9, "must not fail before the 3s cap has actually elapsed")
        XCTAssertLessThan(elapsed, 5, "the overall finish() must not exceed the 3s cap by a wide margin")
    }


    func testNostreamEndpointUsesLongerFinishBudget() {
        XCTAssertEqual(VolcStreamingSession.finishTimeoutSeconds(forNostreamEndpoint: false), 3)
        XCTAssertEqual(VolcStreamingSession.finishTimeoutSeconds(forNostreamEndpoint: true), 8)
    }

}
