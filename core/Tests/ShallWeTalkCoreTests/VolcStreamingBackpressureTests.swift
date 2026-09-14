import XCTest
@testable import ShallWeTalkCore

final class VolcStreamingBackpressureTests: XCTestCase {
    private func session(limit: Int) -> VolcStreamingSession {
        VolcStreamingSession(
            wsURL: URL(string: "wss://unused.invalid/api/v3/sauc/bigmodel")!,
            appId: "test", accessToken: "test", resourceId: "test",
            maxBufferedAudioBytes: limit, onPartial: { _ in })
    }

    func testStalledUploadStopsAtByteBudgetAndFailsInsteadOfReturningPartial() async {
        // No start(): an indefinitely stalled sender, without any network I/O.
        let stream = session(limit: 8)
        stream.feed(Data(repeating: 1, count: 4))
        stream.feed(Data(repeating: 2, count: 4))
        XCTAssertEqual(stream.queuedAudioBytes, 8)
        stream.feed(Data(repeating: 3, count: 1))
        for _ in 0..<100 { stream.feed(Data(repeating: 4, count: 8)) }
        XCTAssertEqual(stream.peakQueuedAudioBytes, 8)
        XCTAssertLessThanOrEqual(stream.queuedAudioBytes, 8)
        let before = Date()
        do {
            _ = try await stream.finish()
            XCTFail("An overflowed stream must enter whole-recording fallback")
        } catch {
            XCTAssertEqual((error as NSError).domain, "VolcASR")
            XCTAssertEqual((error as NSError).code, -3)
        }
        XCTAssertLessThan(Date().timeIntervalSince(before), 1)
    }

    func testOversizedSingleChunkDoesNotEnterTheBuffer() {
        let stream = session(limit: 4)
        stream.feed(Data(repeating: 1, count: 5))
        XCTAssertEqual(stream.peakQueuedAudioBytes, 0)
        XCTAssertNotNil(stream.diagnostics.lastErrorDescription)
    }

    func testCancelledSessionRejectsLateRecorderCallbacks() {
        let stream = session(limit: 8)
        stream.cancel()
        stream.feed(Data(repeating: 1, count: 4))
        XCTAssertEqual(stream.queuedAudioBytes, 0)
    }

    func testConcurrentProducersCannotOverrunByteBudget() {
        let stream = session(limit: 64)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            stream.feed(Data(repeating: 1, count: 8))
        }
        XCTAssertLessThanOrEqual(stream.peakQueuedAudioBytes, 64)
        XCTAssertNotNil(stream.diagnostics.lastErrorDescription)
        stream.cancel()
    }
}
