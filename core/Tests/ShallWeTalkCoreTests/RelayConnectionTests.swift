import XCTest
@testable import ShallWeTalkCore

final class RelayConnectionTests: XCTestCase {
    func testTrialCredentialIsRandomAndSessionWorksWithoutOperatorGrant() async throws {
        let first = RelaySessionClient.newTrialCredential()
        XCTAssertNotEqual(first, RelaySessionClient.newTrialCredential())
        XCTAssertEqual(first.count, 70)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelaySessionMock.self]
        config.httpAdditionalHeaders = ["X-Mock-Scenario": "valid"]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for route in [RelayNetworkRoute.overseas, .domestic] {
            let value = try await RelaySessionClient.trial(credential: first, preferred: route, session: session)
            XCTAssertTrue(value.isUsable())
        }
    }
    func testSessionResponsesAcceptOnlySuccessfulUnexpiredCredentials() async throws {
        for scenario in ["valid", "unauthorized", "expired", "malformed", "empty"] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [RelaySessionMock.self]
            config.httpAdditionalHeaders = ["X-Mock-Scenario": scenario]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            do {
                let token = try await RelaySessionClient.renew(
                    credential: String(repeating: "x", count: 48), session: session)
                XCTAssertEqual(scenario, "valid")
                XCTAssertTrue(token.isUsable())
            } catch {
                XCTAssertNotEqual(scenario, "valid")
            }
        }
    }
    func testRelayRoutesUseSecureProductionPathsAndPreserveNostreamSuffix() {
        for route in [RelayNetworkRoute.overseas, .domestic] {
            XCTAssertEqual(route.baseURL?.scheme, "https")
            XCTAssertEqual(route.asrURL?.scheme, "wss")
            XCTAssertEqual(route.asrURL?.path, "/v1/asr/bigmodel_nostream")
            XCTAssertEqual(route.cleanupURL?.appendingPathComponent("chat/completions").path,
                           "/v1/cleanup/chat/completions")
            XCTAssertEqual(route.warmupURL?.path, "/warmup")
        }
        XCTAssertEqual(RelayNetworkRoute.domestic.baseURL?.host, "relay-domestic.example.invalid")
        XCTAssertNil(RelayNetworkRoute.direct.baseURL)
        XCTAssertNil(RelayNetworkRoute.direct.asrURL)
        XCTAssertEqual(RelayNetworkRoute(rawValue: "domesticWorker"), .domestic)
    }

    func testEnrollmentNeverPutsCredentialInURLOrBody() throws {
        let fake = String(repeating: "x", count: 48)
        let request = try RelaySessionClient.request(credential: fake)
        XCTAssertEqual(request.url?.absoluteString, "https://relay-overseas.example.invalid/v1/session")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + fake)
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        for bad in ["", "short", String(repeating: "x", count: 257), fake + "\n"] {
            XCTAssertThrowsError(try RelaySessionClient.request(credential: bad))
        }
    }

    func testExpiryUsesTheSameFiveMinuteRenewalMarginAsIOS() throws {
        let value = try JSONDecoder().decode(RelayAccessSession.self,
            from: Data(#"{"token":"test-only","expiresAt":1600}"#.utf8))
        XCTAssertTrue(value.isUsable(at: Date(timeIntervalSince1970: 1299)))
        XCTAssertFalse(value.isUsable(at: Date(timeIntervalSince1970: 1300)))
        XCTAssertFalse(value.isUsable(at: Date(timeIntervalSince1970: 1601), margin: 0))
    }
}

private final class RelaySessionMock: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = request.value(forHTTPHeaderField: "X-Mock-Scenario") ?? "valid"
        let status = scenario == "unauthorized" ? 401 : 200
        let token = scenario == "empty" ? "" : "test-token"
        let expiresAt = scenario == "expired" ? 1 : Date().timeIntervalSince1970 + 3600
        let data = scenario == "malformed" ? Data("not-json".utf8)
            : try! JSONSerialization.data(withJSONObject: ["token": token, "expiresAt": expiresAt])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
