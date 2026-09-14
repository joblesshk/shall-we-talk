import Foundation

/// 火山引擎(豆包)大模型流式语音识别客户端(v3 协议)
/// 依据官方文档 https://www.volcengine.com/docs/6561/1354869 与官方 SDK(volcengine-audio)实现:
/// - 帧结构: [4字节头][4字节有符号序列号][4字节payload长度][payload]
/// - 头: [版本1|头长1] [消息类型<<4|标志] [序列化<<4|压缩] [保留]
/// - full client request: 类型0b0001, 标志POS_SEQUENCE(0b0001), 序列号从1开始
/// - 音频包: 类型0b0010, 非最后一包标志0b0001序列号递增;最后一包标志0b0011且序列号取负
/// - 响应: 标志&0x01=带序列号, &0x02=最后一包;payload 可能为 gzip
///
/// 整段/单向流式路径的等待预算按音频时长动态给(见 `timeoutBudget`),不再是适配短口述
/// 兜底场景的固定 12 秒——那个值会把长句识别提前打断,2026-08-16 为部署单向流式到生产环境改掉。
/// 预算耗尽时仍会主动断开 WebSocket,避免无上限等待。
public struct VolcEngineASR: TranscriptionService {
    /// Worker 使用固定的单向流式路由；直连保持按 URL 推断的既有行为。
    public enum EndpointProtocolKind: Sendable, Equatable {
        case infer
        case nostream
        case standard
    }
    public let wsURL: URL          // wss://openspeech.bytedance.com/api/v3/sauc/bigmodel
    public let appId: String       // X-Api-App-Key
    public let accessToken: String // X-Api-Access-Key
    public let resourceId: String  // 2.0: volc.seedasr.sauc.duration / 1.0: volc.bigasr.sauc.duration
    public var hotwordsContext: String? = nil // 个人词典热词(JSON 字符串)
    /// 简繁体输出(豆包 v3 接口 `output_zh_variant` 字段,2026-08-16 加入):
    /// nil/空 = 简体(默认,不发送该字段);"traditional"/"tw"/"hk" = 繁体(大陆/台湾/香港用字)。
    public var outputChineseVariant: String? = nil
    /// 仅供测试:true 时按真实语速(200ms/块)发音频,而不是一次性灌完,用来测量
    /// "边录边传、只在停止后等最后一小截"这种真实用法下,单向流式停止说话后
    /// 真正要等多久——而不是把整段录音在录完后才一次性发送的最差情况耗时。
    public var realtimePacing: Bool = false
    private let protocolKind: EndpointProtocolKind
    private let bearerToken: String?

    public init(wsURL: URL, appId: String, accessToken: String, resourceId: String,
                hotwordsContext: String? = nil, outputChineseVariant: String? = nil,
                protocolKind: EndpointProtocolKind = .infer, bearerToken: String? = nil) {
        self.wsURL = wsURL
        self.appId = appId
        self.accessToken = accessToken
        self.resourceId = resourceId
        self.hotwordsContext = hotwordsContext
        self.outputChineseVariant = outputChineseVariant
        self.protocolKind = protocolKind
        self.bearerToken = bearerToken
    }

    public func transcribe(wav: Data) async throws -> String {
        let pcm = wav.count > 44 ? wav.subdata(in: 44..<wav.count) : wav
        guard !pcm.isEmpty else { return "" }
        guard bearerToken?.isEmpty == false || (!appId.isEmpty && !accessToken.isEmpty) else {
            throw NSError(domain: "VolcASR", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "请在设置里填写豆包的 App ID 和 Access Token"])
        }

        var req = URLRequest(url: wsURL)
        req.timeoutInterval = 15
        if let bearerToken, !bearerToken.isEmpty {
            req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        } else {
            req.setValue(appId, forHTTPHeaderField: "X-Api-App-Key")
            req.setValue(accessToken, forHTTPHeaderField: "X-Api-Access-Key")
            req.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        }
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id") // v3 必填
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        req.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")

        let task = URLSession.shared.webSocketTask(with: req)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        do {
            // 总预算按音频时长动态给,不再是不管音频长短统一 12 秒的固定值。
            // 超时分支先主动断开 WebSocket，确保正在等待的 send/receive 真正退出，
            // 不留下结构化并发悬挂。
            let budget = Self.timeoutBudget(forPcmBytes: pcm.count)
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await run(task: task, pcm: pcm) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                    task.cancel(with: .goingAway, reason: nil)
                    throw NSError(domain: "VolcASR", code: -2, userInfo: [NSLocalizedDescriptionKey:
                        "识别超过 \(Int(budget)) 秒(音频约 \(Int(Double(pcm.count) / 32_000))s)"])
                }
                do {
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        } catch {
            throw Self.enrich(error, task: task, resourceId: resourceId)
        }
    }

    private func run(task: URLSessionWebSocketTask, pcm: Data) async throws -> String {
        // 1. Full Client Request,序列号 1
        var request: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            "enable_ddc": true,
            "show_utterances": true,
            "result_type": "full",
        ]
        if let ctx = hotwordsContext {
            request["corpus"] = ["context": ctx] // 个人词典热词
        }
        if let variant = outputChineseVariant, !variant.isEmpty {
            request["output_zh_variant"] = variant // 简→繁,默认不发送(简体)
        }
        let config: [String: Any] = [
            "user": ["uid": "voicepen"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": request,
        ]
        let configData = try JSONSerialization.data(withJSONObject: config)
        var seq: Int32 = 1
        try await task.send(.data(Self.frame(type: 0b0001, flags: 0b0001, seq: seq, payload: configData)))

        // 2. 音频分块(200ms/块),序列号递增;最后一块序列号取负,标志 0b0011。
        // realtimePacing 打开时按真实语速逐块发送并睡够 200ms,模拟"边录边传"；
        // 关闭时(生产默认)一次性灌完,连接本身在录音开始就建好、chunk 随录随发,
        // 这里的关闭态只是测试重放historical WAV 时的简化,不代表生产行为。
        let chunkSize = 6400
        var offset = 0
        var lastChunkSentAt: Date?
        while offset < pcm.count {
            let end = min(offset + chunkSize, pcm.count)
            let part = pcm.subdata(in: offset..<end)
            let isLast = end >= pcm.count
            seq += 1
            let sendSeq = isLast ? -seq : seq
            let flags: UInt8 = isLast ? 0b0011 : 0b0001
            try await task.send(.data(Self.frame(type: 0b0010, flags: flags, seq: sendSeq, payload: part)))
            offset = end
            if realtimePacing {
                lastChunkSentAt = Date()
                if !isLast { try await Task.sleep(nanoseconds: 200_000_000) }
            }
        }
        if realtimePacing {
            FileHandle.standardError.write(Data(
                "  [realtime-pace] 最后一块音频已发出,开始计时尾部等待…\n".utf8))
        }

        // 3. 接收结果,直到最后一包(标志 & 0x02)。总时长上限由调用方(transcribe)的
        // 动态预算把关;这里的超时只防单帧静默(服务端完全不回包),不对总识别时长封顶,
        // 单向流式的长音频需要多次收包、每次都在预算内属正常。
        var latest = ""
        let frameStallTimeout: TimeInterval = 30
        while true {
            let msg = try await Self.receive(task, timeout: frameStallTimeout)
            guard case .data(let d) = msg else { continue }
            let bytes = [UInt8](d)
            guard bytes.count >= 8 else { continue }

            let headerSize = Int(bytes[0] & 0x0F) * 4
            let msgType = (bytes[1] >> 4) & 0x0F
            let flags = bytes[1] & 0x0F
            let compressed = (bytes[2] & 0x0F) == 0b0001
            var p = headerSize
            if flags & 0x01 != 0 { p += 4 } // 跳过序列号
            let isLast = (flags & 0x02) != 0

            if msgType == 0b1111 { // 错误帧: [错误码4B][长度4B][消息]
                guard bytes.count >= p + 8 else { throw Self.err("服务端返回格式异常的错误帧") }
                let code = Self.readU32(bytes, at: p)
                var body = Data(bytes[(p + 8)...])
                if compressed, let un = Self.gunzip(body) { body = un }
                let text = String(data: body, encoding: .utf8) ?? ""
                throw Self.err("豆包识别服务报错(\(code) \(Self.codeHint(code))): \(text.prefix(200))")
            }
            if msgType == 0b1001 { // 结果帧: [长度4B][JSON]
                guard bytes.count >= p + 4 else { continue }
                var body = Data(bytes[(p + 4)...])
                if compressed, let un = Self.gunzip(body) { body = un }
                if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                   let result = obj["result"] as? [String: Any],
                   let t = result["text"] as? String, !t.isEmpty {
                    latest = t
                    // show_utterances 打开后的效果肉眼不可见(协议只返回 text 给调用方),
                    // 这里打到 stderr 便于 CLI 测试时观察分句/说话人是否真的回传了。
                    if let utterances = result["utterances"] as? [[String: Any]], !utterances.isEmpty {
                        let speakers = Set(utterances.compactMap { $0["speaker_id"] as? String })
                        FileHandle.standardError.write(Data(
                            "  [show_utterances] \(utterances.count) 句,speaker_id=\(speakers.sorted())\n".utf8))
                    }
                }
                if isLast {
                    if realtimePacing, let lastChunkSentAt {
                        let tailMs = Int(Date().timeIntervalSince(lastChunkSentAt) * 1000)
                        FileHandle.standardError.write(Data(
                            "  [realtime-pace] 尾部等待(最后一块发出→收到终稿) = \(tailMs)ms\n".utf8))
                    }
                    break
                }
            }
        }
        return latest
    }


    /// 连接诊断:用 0.5 秒静音音频依次测试各「端点 × Resource ID」组合,返回逐项结果
    public static func diagnose(appId: String, accessToken: String) async -> String {
        guard !appId.isEmpty, !accessToken.isEmpty else {
            return "请先填写 App ID 和 Access Token"
        }
        let combos: [(String, String)] = [
            ("bigmodel_nostream", "volc.seedasr.sauc.duration"),
            ("bigmodel_async", "volc.seedasr.sauc.duration"),
            ("bigmodel", "volc.bigasr.sauc.duration"),
            ("bigmodel", "volc.seedasr.sauc.duration"),
            ("bigmodel", "volc.seedasr.sauc.concurrent"),
        ]
        let silence = WavEncoder.wav(pcm: Data(count: 16000), sampleRate: 16000, channels: 1)
        var lines: [String] = []
        for (path, res) in combos {
            let url = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/\(path)")!
            let svc = VolcEngineASR(wsURL: url, appId: appId, accessToken: accessToken, resourceId: res)
            do {
                _ = try await svc.transcribe(wav: silence)
                lines.append("✅ /\(path) + \(res):连接成功")
            } catch {
                lines.append("❌ /\(path) + \(res):\(error.localizedDescription)")
            }
        }
        return lines.joined(separator: "\n\n")
    }

    /// 整段/单向流式的总等待预算:按音频时长(16kHz/16bit/单声道 PCM,故字节数/32_000=秒数)
    /// 动态给,不再用只适配短口述兜底场景的固定值——单向流式必须等服务端处理完整句才有
    /// 结果,没有中间可用的 partial,长音频天然需要更长等待。下限 20 秒兜网络抖动;
    /// 系数按实测数据(30~80 秒音频普遍 4~15 秒返回)留出安全余量。
    static func timeoutBudget(forPcmBytes bytes: Int) -> TimeInterval {
        let audioSeconds = Double(bytes) / 32_000
        return max(20, audioSeconds * 1.5 + 15)
    }

    // MARK: - 帧编码

    static func frame(type: UInt8, flags: UInt8, seq: Int32, payload: Data) -> Data {
        var d = Data(capacity: 12 + payload.count)
        d.append(0x11)                 // 版本1 | 头长1(4字节)
        d.append((type << 4) | flags)  // 消息类型 | 标志
        d.append(0x10)                 // 序列化 JSON | 无压缩
        d.append(0x00)                 // 保留
        var s = seq.bigEndian
        withUnsafeBytes(of: &s) { d.append(contentsOf: $0) }
        var size = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &size) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }

    static func readU32(_ bytes: [UInt8], at i: Int) -> UInt32 {
        (UInt32(bytes[i]) << 24) | (UInt32(bytes[i + 1]) << 16) | (UInt32(bytes[i + 2]) << 8) | UInt32(bytes[i + 3])
    }

    /// gzip 解压:剥掉 gzip 头/尾后用 zlib raw deflate 解
    static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b else { return nil }
        var i = 10
        let flg = b[3]
        if flg & 0x04 != 0, i + 2 <= b.count { // FEXTRA
            let xlen = Int(b[i]) | (Int(b[i + 1]) << 8)
            i += 2 + xlen
        }
        if flg & 0x08 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 } // FNAME
        if flg & 0x10 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 } // FCOMMENT
        if flg & 0x02 != 0 { i += 2 } // FHCRC
        guard i < b.count - 8 else { return nil }
        let deflated = Data(b[i..<(b.count - 8)])
        return try? (deflated as NSData).decompressed(using: .zlib) as Data
    }

    static func codeHint(_ code: UInt32) -> String {
        switch code {
        case 45000001: return "请求参数无效"
        case 45000002: return "空音频"
        case 45000030: return "资源未开通或无权限,请核对 Resource ID 与控制台开通情况"
        case 45000081: return "等待下一包超时"
        case 55000031: return "服务器繁忙"
        default: return ""
        }
    }

    static func err(_ msg: String) -> NSError {
        NSError(domain: "VolcASR", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    /// 握手被拒时,火山把原因放在 HTTP 响应头里,补充进错误信息
    private static func enrich(_ error: Error, task: URLSessionWebSocketTask, resourceId: String) -> Error {
        if (error as NSError).domain == "VolcASR" { return error }
        var detail = error.localizedDescription
        if let http = task.response as? HTTPURLResponse {
            // 把火山返回的相关响应头全部带出来,便于定位
            let interesting = http.allHeaderFields.compactMap { k, v -> String? in
                let key = String(describing: k)
                return key.lowercased().hasPrefix("x-api") || key.lowercased().hasPrefix("x-tt")
                    ? "\(key)=\(v)" : nil
            }.sorted().joined(separator: " ")
            detail = "HTTP \(http.statusCode) \(interesting.isEmpty ? "(无诊断头)" : interesting)"
        }
        return NSError(domain: "VolcASR", code: -3, userInfo: [NSLocalizedDescriptionKey:
            "豆包连接失败 [\(resourceId)]:\(detail)"])
    }

    /// receive 加超时,避免服务端不回包时永久挂起
    private static func receive(_ task: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NSError(domain: "VolcASR", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "等待识别结果超时"])
            }
            let r = try await group.next()!
            group.cancelAll()
            return r
        }
    }
}
