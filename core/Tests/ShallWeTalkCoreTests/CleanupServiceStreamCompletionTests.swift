import XCTest
@testable import ShallWeTalkCore

final class CleanupServiceStreamCompletionTests: XCTestCase {
    private final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var body = ""
        nonisolated(unsafe) static var holdsConnectionOpen = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
            if !Self.holdsConnectionOpen { client?.urlProtocolDidFinishLoading(self) }
        }

        override func stopLoading() {}
    }

    private func service(body: String, holdsConnectionOpen: Bool = false) -> CleanupService {
        StubProtocol.body = body
        StubProtocol.holdsConnectionOpen = holdsConnectionOpen
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        return CleanupService(baseURL: URL(string: "https://stream.invalid/v1")!, apiKey: "dummy",
                              model: "dummy", session: session)
    }

    private func assertFailure(_ expected: CleanupService.StreamError, body: String,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await service(body: body).clean(raw: "原文", systemPrompt: "整理",
                                                    validate: false)
            XCTFail("expected stream failure", file: file, line: line)
        } catch let error as CleanupService.StreamError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    func testDoneMarkerDeliversCompleteText() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"完整正文\"}}]}\n\n"
            + "data: [DONE]\n\n"
        let result = try await service(body: body).clean(raw: "原文", systemPrompt: "整理",
                                                           validate: false)
        XCTAssertEqual(result, "完整正文")
    }

    func testStopFinishReasonIsValidWithoutDoneForCompatibleProviders() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"完整正文\"}}]}\n\n"
            + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        let result = try await service(body: body).clean(raw: "原文", systemPrompt: "整理",
                                                           validate: false)
        XCTAssertEqual(result, "完整正文")
    }

    func testEOFWithoutCompletionMarkerRejectsPartialText() async {
        await assertFailure(.incomplete,
                            body: "data: {\"choices\":[{\"delta\":{\"content\":\"半截\"}}]}\n\n")
    }

    func testLengthFinishRejectsPartialTextEvenWhenDoneFollows() async {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"半截\"}}]}\n\n"
            + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n"
            + "data: [DONE]\n\n"
        await assertFailure(.outputTruncated, body: body)
    }

    func testServerErrorEventRejectsStream() async {
        await assertFailure(.server("配额不足"),
                            body: "data: {\"error\":{\"message\":\"配额不足\"}}\n\n")
    }

    func testMalformedJSONRejectsStreamInsteadOfSkippingDamage() async {
        await assertFailure(.malformedEvent, body: "data: {not-json}\n\ndata: [DONE]\n\n")
    }

    func testCompletedStreamWithNoBodyIsRejected() async {
        await assertFailure(.emptyOutput, body: "data: [DONE]\n\n")
    }

    func testCancellationCannotReturnAccumulatedPartialText() async {
        let service = service(
            body: "data: {\"choices\":[{\"delta\":{\"content\":\"半截\"}}]}\n\n",
            holdsConnectionOpen: true)
        let task = Task {
            try await service.clean(raw: "原文", systemPrompt: "整理", validate: false)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled request must not deliver partial text")
        } catch is CancellationError {
            // Expected: cancellation is distinct from a completed model response.
        } catch let error as URLError where error.code == .cancelled {
            // Foundation may surface the transport cancellation directly.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
    }
}
