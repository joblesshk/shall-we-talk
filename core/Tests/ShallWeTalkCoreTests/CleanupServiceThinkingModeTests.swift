import XCTest
@testable import ShallWeTalkCore

/// 覆盖本次改动(2026-07-18):CleanupService.ThinkingMode / Ark 检测 / 90s-180s 分级超时
/// 从 iOS 专属搬为两端共享。用 URLProtocol 拦截请求而不是真连网:零网络、零等待、确定性,
/// 直接断言发出的 URLRequest(payload 字段 + timeoutInterval),不依赖任何真实模型端点。
final class CleanupServiceThinkingModeTests: XCTestCase {
    /// 拦截 URLSession.shared 的请求并立即返回一段最小 SSE 响应,不发生真实网络 I/O。
    private final class CapturingURLProtocol: URLProtocol {
        // 测试串行执行(XCTest 默认单线程跑同一 test case),用类变量在 startLoading 里记录即可。
        nonisolated(unsafe) static var lastRequest: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://mock.invalid")!,
                statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"])!
            let body = "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(CapturingURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(CapturingURLProtocol.self)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        CapturingURLProtocol.lastRequest = nil
    }

    /// URLProtocol 拦截到的 request 里,httpBody 常被 Foundation 转成 httpBodyStream 传递
    /// (尤其是走 `bytes(for:)` 这类流式 API 时),两处都要兜底读取。
    private func payload(of request: URLRequest) throws -> [String: Any] {
        let body: Data
        if let direct = request.httpBody {
            body = direct
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            body = data
        } else {
            body = Data()
        }
        XCTAssertFalse(body.isEmpty, "captured request must carry a JSON body")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return obj
    }

    // MARK: - Ark(火山方舟)检测:本次新增的 macOS 侧覆盖点

    func testArkRequestSendsNativeThinkingTypeDisabledByDefault() async throws {
        let svc = CleanupService(baseURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3")!,
                                 apiKey: "k", model: "doubao-seed-1.6-flash")
        _ = try await svc.cleanStream(raw: "raw", systemPrompt: "sys") { _ in }
        let req = try XCTUnwrap(CapturingURLProtocol.lastRequest)
        let body = try payload(of: req)
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual(req.timeoutInterval, 90)
    }

    func testArkRequestSendsNativeThinkingTypeEnabledWhenRequested() async throws {
        let svc = CleanupService(baseURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3")!,
                                 apiKey: "k", model: "doubao-seed-1.6-flash")
        _ = try await svc.cleanStream(raw: "raw", systemPrompt: "sys", thinking: .enabled) { _ in }
        let req = try XCTUnwrap(CapturingURLProtocol.lastRequest)
        let body = try payload(of: req)
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "enabled")
        XCTAssertEqual(req.timeoutInterval, 180)
    }

    /// Ark 检测也认模型名(即使 baseURL 是自定义端点)
    func testArkDetectionByModelNameAlone() async throws {
        let svc = CleanupService(baseURL: URL(string: "https://custom.example.com/v1")!,
                                 apiKey: "k", model: "doubao-pro-4k")
        _ = try await svc.cleanStream(raw: "raw", systemPrompt: "sys") { _ in }
        let req = try XCTUnwrap(CapturingURLProtocol.lastRequest)
        let body = try payload(of: req)
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
    }

    // MARK: - DeepSeek:两端此前都已支持,确认统一后未退化

    func testDeepSeekRequestSendsNativeThinkingType() async throws {
        let svc = CleanupService(baseURL: URL(string: "https://api.deepseek.com/v1")!,
                                 apiKey: "k", model: "deepseek-flash")
        _ = try await svc.cleanStream(raw: "raw", systemPrompt: "sys") { _ in }
        let req = try XCTUnwrap(CapturingURLProtocol.lastRequest)
        let body = try payload(of: req)
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
    }

    // MARK: - Qwen:此前是 macOS 专属分支,现在两端共享且随 thinking 参数变化(此前固定 false)

    func testQwenRequestSendsEnableThinkingFalseByDefault() async throws {
        let svc = CleanupService(baseURL: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!,
                                 apiKey: "k", model: "qwen3.6-flash")
        _ = try await svc.cleanStream(raw: "raw", systemPrompt: "sys") { _ in }
        let req = try XCTUnwrap(CapturingURLProtocol.lastRequest)
        let body = try payload(of: req)
        XCTAssertEqual(body["enable_thinking"] as? Bool, false)
        // Qwen 不是 DeepSeek/Ark,不应该同时带上 thinking.type 字段
        XCTAssertNil(body["thinking"])
    }

    func testQwenRequestSendsEnableThinkingTrueWhenRequested() async throws {
        let svc = CleanupService(baseURL: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!,
                                 apiKey: "k", model: "qwen3.6-flash")
        _ = try await svc.cleanStream(raw: "raw", systemPrompt: "sys", thinking: .enabled) { _ in }
        let req = try XCTUnwrap(CapturingURLProtocol.lastRequest)
        let body = try payload(of: req)
        XCTAssertEqual(body["enable_thinking"] as? Bool, true)
    }

    // MARK: - OpenAI 推理模型:reasoning_effort 随 thinking 分级(此前固定 minimal)

    func testOpenAIReasoningModelUsesMinimalEffortByDefault() async throws {
        let svc = CleanupService(baseURL: URL(string: "https://api.openai.com/v1")!,
                                 apiKey: "k", model: "gpt-5-nano")
        _ = try await svc.cleanStream(raw: "raw", systemPrompt: "sys") { _ in }
        let req = try XCTUnwrap(CapturingURLProtocol.lastRequest)
        let body = try payload(of: req)
        XCTAssertEqual(body["reasoning_effort"] as? String, "minimal")
        XCTAssertNil(body["temperature"])
    }

    func testOpenAIReasoningModelUsesHighEffortWhenThinkingEnabled() async throws {
        let svc = CleanupService(baseURL: URL(string: "https://api.openai.com/v1")!,
                                 apiKey: "k", model: "gpt-5-nano")
        _ = try await svc.cleanStream(raw: "raw", systemPrompt: "sys", thinking: .enabled) { _ in }
        let req = try XCTUnwrap(CapturingURLProtocol.lastRequest)
        let body = try payload(of: req)
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
    }

    // MARK: - 普通端点(自定义/非推理模型):不受 ThinkingMode 影响,行为不变

    func testPlainCustomEndpointHasNoThinkingFieldsAndFixedTimeout() async throws {
        let svc = CleanupService(baseURL: URL(string: "https://api.siliconflow.cn/v1")!,
                                 apiKey: "k", model: "some-model")
        _ = try await svc.cleanStream(raw: "raw", systemPrompt: "sys", thinking: .enabled) { _ in }
        let req = try XCTUnwrap(CapturingURLProtocol.lastRequest)
        let body = try payload(of: req)
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["enable_thinking"])
        // 2026-08-03:校对是确定性任务,温度从 0.2 降到 0 换取规则执行的可复现性。
        XCTAssertEqual(body["temperature"] as? Double, 0)
        // 非 DeepSeek/Ark/Qwen 端点的超时仍按 thinking 分级(90/180),这是纯超时机制,不依赖供应商检测
        XCTAssertEqual(req.timeoutInterval, 180)
    }
}
