import Foundation

/// Public routing metadata only. Device credentials and access tokens never belong here.
public enum RelayNetworkRoute: String, CaseIterable, Identifiable, Sendable {
    case overseas = "overseasWorker"
    case domestic = "domesticWorker"
    case direct = "apiDirect"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .overseas: return "海外连接"
        case .domestic: return "国内连接"
        case .direct: return "API直连"
        }
    }
    public var usesWorker: Bool { self != .direct }
    public var baseURL: URL? {
        switch self {
        case .overseas: return URL(string: "https://relay-overseas.example.invalid")!
        case .domestic: return URL(string: "https://relay-domestic.example.invalid")!
        case .direct: return nil
        }
    }
    public var asrURL: URL? {
        guard let baseURL else { return nil }
        var url = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        url.scheme = "wss"
        return url.url!.appendingPathComponent("v1/asr/bigmodel_nostream")
    }
    public var cleanupURL: URL? { baseURL?.appendingPathComponent("v1/cleanup") }
    public var warmupURL: URL? { baseURL?.appendingPathComponent("warmup") }
}

public struct RelayAccessSession: Decodable, Sendable {
    public let token: String
    public let expiresAt: Double
    public func isUsable(at now: Date = Date(), margin: TimeInterval = 300) -> Bool {
        !token.isEmpty && expiresAt.isFinite && expiresAt > now.timeIntervalSince1970 + margin
    }
}

/// Matches the enrolled iOS device protocol. The authorization control plane remains
/// Cloudflare even when voice and cleanup payloads use the domestic relay.
public enum RelaySessionClient {
    public static func newTrialCredential() -> String {
        "trial_" + (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    /// Both entrances independently sign compatible sessions without usage quotas.
    /// Preserve the installation identity; fail over only for transport/server errors.
    public static func trial(credential: String, preferred: RelayNetworkRoute,
                             session: URLSession = .shared) async throws -> RelayAccessSession {
        guard credential.range(of: "^trial_[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw NSError(domain: "Relay", code: 401, userInfo: [NSLocalizedDescriptionKey: "无法读取本机试用授权。"])
        }
        let first: RelayNetworkRoute = preferred == .domestic ? .domestic : .overseas
        let routes: [RelayNetworkRoute] = [first, first == .domestic ? .overseas : .domestic]
        var lastError: Error = URLError(.cannotConnectToHost)
        for route in routes {
            var request = URLRequest(url: route.baseURL!.appendingPathComponent("v1/trial/session"))
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 429 || status == 401 || status == 403 {
                    throw NSError(domain: "TrialDenied", code: status,
                        userInfo: [NSLocalizedDescriptionKey: "暂时无法完成连接授权，请稍后重试。"])
                }
                guard status == 200,
                      let value = try? JSONDecoder().decode(RelayAccessSession.self, from: data),
                      value.isUsable(margin: 60) else { throw URLError(.badServerResponse) }
                return value
            } catch {
                if (error as NSError).domain == "TrialDenied" || Task.isCancelled { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    public static func request(credential: String) throws -> URLRequest {
        guard (32...256).contains(credential.count),
              !credential.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw NSError(domain: "Relay", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "此设备尚未完成连接授权，请联系服务提供方。"])
        }
        var request = URLRequest(url: RelayNetworkRoute.overseas.baseURL!.appendingPathComponent("v1/session"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        return request
    }
    public static func renew(credential: String, session: URLSession = .shared) async throws -> RelayAccessSession {
        let (data, response) = try await session.data(for: request(credential: credential))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let grant = try? JSONDecoder().decode(RelayAccessSession.self, from: data),
              grant.isUsable(margin: 60) else {
            throw NSError(domain: "Relay", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "连接授权未通过或已过期，请重新激活此设备。"])
        }
        return grant
    }
}
