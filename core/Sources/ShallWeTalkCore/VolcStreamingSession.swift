import Foundation

/// URLSessionWebSocketTask 的 send/receive 在部分网络状态下不会响应 Swift Task
/// cancellation。用一次性闸门让超时分支可以先返回，迟到的 I/O 完成不能二次恢复 continuation。
private final class VolcOneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// 流式输入识别会话:录音开始即建连并持续上传音频，停止后等待服务端终稿。
/// `bigmodel_nostream` 不保证录音中持续返回可展示的 partial；是否消费中途文本由调用方决定。
/// 复用 VolcEngineASR 的帧编解码;失败时调用方退回整段上传模式。
///
/// `finish()` 把发送尾包 + 等待终包设置整体上限：nostream 端点 8 秒，其它端点 3 秒；
/// 这是网络收尾预算，不是二次识别。超时主动断开，让调用方立即走整段识别回退。
///
/// `firstPartialMillis` 是兼容既有诊断结构的字段名，实际表示建连开始到首个非空文本帧；
/// 对 nostream 它不构成实时 partial 能力承诺，Mac 主链路也不据此上屏。
/// 一句定稿转写(`show_utterances` 打开后按 `definite` 字段确认)。会议录音场景下
/// `speakerID` 承载 `enable_speaker_info` 回传的说话人标签;未开启该功能或服务端
/// 未回传时为 nil,调用方应把它当作"未标注"而不是错误。
public struct VolcUtterance: Sendable, Equatable {
    public let text: String
    public let startMs: Int
    public let endMs: Int
    public let speakerID: String?
}

/// 单次流式会话的无敏感诊断快照。调用端把它与本次听写记录一起保存，用于区分
/// 建连、上行音频、服务端回包和最终包等待这四个阶段的问题；不包含 URL、账号或凭据。
/// request/connect ID 是服务端用于追查本次会话的非敏感关联标识。
public struct VolcStreamingDiagnostics: Sendable, Equatable {
    public let requestID: String
    public let connectID: String
    public let configurationSent: Bool
    public let audioBytesSent: Int
    public let audioPacketCount: Int
    public let resultFrameCount: Int
    public let receivedFinalResult: Bool
    public let firstPartialMillis: Int?
    public let lastErrorDescription: String?
    /// 以下时点均以 `start()` 开始建连为零点。它们刻画真实会话时间线，而不是
    /// 仅仅记录最终耗时：可据此分辨建连、上行、服务端首回包与终稿收尾的延迟。
    public let configurationSentMillis: Int?
    public let firstAudioSentMillis: Int?
    public let lastAudioSentMillis: Int?
    public let finishRequestedMillis: Int?
    public let endFrameSentMillis: Int?
    /// 结束帧在 SAUC 协议中的负序号。每次会话只有一帧，供按服务端日志逐条核对。
    public let endFrameSequence: Int32?
    public let firstResultFrameMillis: Int?
    public let finalResultMillis: Int?
    public let parseableResultJSONFrameCount: Int
    public let resultObjectFrameCount: Int
    public let topLevelTextPresentFrameCount: Int
    public let topLevelNonEmptyTextFrameCount: Int
    public let utterancesPresentFrameCount: Int
    /// Frames containing at least one non-empty String `utterances[].text`.
    public let utteranceTextPresentFrameCount: Int
    public let definiteUtteranceTextFrameCount: Int
    public let finalFrameCount: Int
    public let finalFrameHadNonEmptyTopLevelText: Bool?
    public let onPartialInvocationCount: Int
    public let firstParseableResultMillis: Int?
    public let firstResultObjectMillis: Int?
    public let firstTopLevelTextMillis: Int?
    public let firstTopLevelNonEmptyTextMillis: Int?
    public let firstUtterancesMillis: Int?
    public let firstUtteranceTextMillis: Int?
    public let firstDefiniteUtteranceTextMillis: Int?
    public let firstFinalFrameMillis: Int?
    public let jsonDecodeFailureCount: Int
    public let decompressionFailureCount: Int
    public let sequenceFirst: Int32?
    public let sequenceLast: Int32?
    public let sequenceMin: Int32?
    public let sequenceMax: Int32?
    public let sequenceMonotonicityBroken: Bool
    public let sequenceDuplicateCount: Int
    public let messageTypeBucketCounts: [Int]
    public let resultFlagsBucketCounts: [Int]

    public init(requestID: String, connectID: String,
                configurationSent: Bool, audioBytesSent: Int, audioPacketCount: Int,
                resultFrameCount: Int, receivedFinalResult: Bool,
                firstPartialMillis: Int?, lastErrorDescription: String?,
                configurationSentMillis: Int?, firstAudioSentMillis: Int?,
                lastAudioSentMillis: Int?, finishRequestedMillis: Int?,
                endFrameSentMillis: Int?, endFrameSequence: Int32?, firstResultFrameMillis: Int?,
                finalResultMillis: Int?, parseableResultJSONFrameCount: Int = 0,
                resultObjectFrameCount: Int = 0, topLevelTextPresentFrameCount: Int = 0,
                topLevelNonEmptyTextFrameCount: Int = 0, utterancesPresentFrameCount: Int = 0,
                utteranceTextPresentFrameCount: Int = 0, definiteUtteranceTextFrameCount: Int = 0,
                finalFrameCount: Int = 0, finalFrameHadNonEmptyTopLevelText: Bool? = nil,
                onPartialInvocationCount: Int = 0, firstParseableResultMillis: Int? = nil,
                firstResultObjectMillis: Int? = nil, firstTopLevelTextMillis: Int? = nil,
                firstTopLevelNonEmptyTextMillis: Int? = nil, firstUtterancesMillis: Int? = nil,
                firstUtteranceTextMillis: Int? = nil, firstDefiniteUtteranceTextMillis: Int? = nil,
                firstFinalFrameMillis: Int? = nil, jsonDecodeFailureCount: Int = 0,
                decompressionFailureCount: Int = 0, sequenceFirst: Int32? = nil,
                sequenceLast: Int32? = nil, sequenceMin: Int32? = nil, sequenceMax: Int32? = nil,
                sequenceMonotonicityBroken: Bool = false, sequenceDuplicateCount: Int = 0,
                messageTypeBucketCounts: [Int] = Array(repeating: 0, count: 16),
                resultFlagsBucketCounts: [Int] = Array(repeating: 0, count: 16)) {
        self.requestID = requestID
        self.connectID = connectID
        self.configurationSent = configurationSent
        self.audioBytesSent = audioBytesSent
        self.audioPacketCount = audioPacketCount
        self.resultFrameCount = resultFrameCount
        self.receivedFinalResult = receivedFinalResult
        self.firstPartialMillis = firstPartialMillis
        self.lastErrorDescription = lastErrorDescription
        self.configurationSentMillis = configurationSentMillis
        self.firstAudioSentMillis = firstAudioSentMillis
        self.lastAudioSentMillis = lastAudioSentMillis
        self.finishRequestedMillis = finishRequestedMillis
        self.endFrameSentMillis = endFrameSentMillis
        self.endFrameSequence = endFrameSequence
        self.firstResultFrameMillis = firstResultFrameMillis
        self.finalResultMillis = finalResultMillis
        self.parseableResultJSONFrameCount = parseableResultJSONFrameCount
        self.resultObjectFrameCount = resultObjectFrameCount
        self.topLevelTextPresentFrameCount = topLevelTextPresentFrameCount
        self.topLevelNonEmptyTextFrameCount = topLevelNonEmptyTextFrameCount
        self.utterancesPresentFrameCount = utterancesPresentFrameCount
        self.utteranceTextPresentFrameCount = utteranceTextPresentFrameCount
        self.definiteUtteranceTextFrameCount = definiteUtteranceTextFrameCount
        self.finalFrameCount = finalFrameCount
        self.finalFrameHadNonEmptyTopLevelText = finalFrameHadNonEmptyTopLevelText
        self.onPartialInvocationCount = onPartialInvocationCount
        self.firstParseableResultMillis = firstParseableResultMillis
        self.firstResultObjectMillis = firstResultObjectMillis
        self.firstTopLevelTextMillis = firstTopLevelTextMillis
        self.firstTopLevelNonEmptyTextMillis = firstTopLevelNonEmptyTextMillis
        self.firstUtterancesMillis = firstUtterancesMillis
        self.firstUtteranceTextMillis = firstUtteranceTextMillis
        self.firstDefiniteUtteranceTextMillis = firstDefiniteUtteranceTextMillis
        self.firstFinalFrameMillis = firstFinalFrameMillis
        self.jsonDecodeFailureCount = jsonDecodeFailureCount
        self.decompressionFailureCount = decompressionFailureCount
        self.sequenceFirst = sequenceFirst; self.sequenceLast = sequenceLast
        self.sequenceMin = sequenceMin; self.sequenceMax = sequenceMax
        self.sequenceMonotonicityBroken = sequenceMonotonicityBroken
        self.sequenceDuplicateCount = sequenceDuplicateCount
        self.messageTypeBucketCounts = messageTypeBucketCounts
        self.resultFlagsBucketCounts = resultFlagsBucketCounts
    }
}

enum VolcResultFrameParse {
    case shortOrInvalid
    case otherMessageType
    case result(sequence: Int32?, flags: UInt8, body: Data, compressed: Bool)
    case resultDecompressionFailed(sequence: Int32?, flags: UInt8)
    case resultJSONFailed(sequence: Int32?, flags: UInt8)

    static func parse(_ data: Data) -> VolcResultFrameParse {
        let b = [UInt8](data)
        guard b.count >= 4 else { return .shortOrInvalid }
        let headerSize = Int(b[0] & 0x0F) * 4
        guard headerSize >= 4, b.count >= headerSize else { return .shortOrInvalid }
        let type = (b[1] >> 4) & 0x0F
        let flags = b[1] & 0x0F
        guard type == 0b1001 else { return .otherMessageType }
        var p = headerSize
        var sequence: Int32?
        if flags & 0x01 != 0 {
            guard b.count >= p + 4 else { return .shortOrInvalid }
            sequence = Int32(bitPattern: VolcEngineASR.readU32(b, at: p)); p += 4
        }
        guard b.count >= p + 4 else { return .shortOrInvalid }
        p += 4 // payload size; retain existing behavior of consuming the remainder
        guard b.count >= p else { return .shortOrInvalid }
        let compressed = (b[2] & 0x0F) == 0b0001
        var body = Data(b[p...])
        if compressed {
            guard let uncompressed = VolcEngineASR.gunzip(body) else {
                return .resultDecompressionFailed(sequence: sequence, flags: flags)
            }
            body = uncompressed
        }
        guard (try? JSONSerialization.jsonObject(with: body)) != nil else {
            return .resultJSONFailed(sequence: sequence, flags: flags)
        }
        return .result(sequence: sequence, flags: flags, body: body, compressed: compressed)
    }
}

/// Session-local sequence evidence. The set is bounded by the number of received
/// sequence-bearing frames and is never persisted; only aggregate results escape.
struct VolcSequenceObservation {
    private(set) var seen = Set<Int32>()
    private(set) var first: Int32?
    private(set) var last: Int32?
    private(set) var minimum: Int32?
    private(set) var maximum: Int32?
    private(set) var monotonicityBroken = false
    private(set) var duplicateCount = 0

    mutating func observe(_ sequence: Int32) {
        if first == nil { first = sequence; minimum = sequence; maximum = sequence }
        if let last, sequence < last { monotonicityBroken = true }
        if !seen.insert(sequence).inserted { duplicateCount += 1 }
        self.last = sequence
        minimum = Swift.min(minimum ?? sequence, sequence)
        maximum = Swift.max(maximum ?? sequence, sequence)
    }
}

/// Structural utterance signals only; no text is returned or retained.
struct VolcUtteranceSignals {
    let present: Bool
    let hasNonEmptyText: Bool
    let hasDefiniteNonEmptyText: Bool

    static func from(_ utterances: [[String: Any]]?) -> VolcUtteranceSignals {
        guard let utterances else { return VolcUtteranceSignals(present: false, hasNonEmptyText: false, hasDefiniteNonEmptyText: false) }
        let hasNonEmpty = utterances.contains { ($0["text"] as? String)?.isEmpty == false }
        let hasDefinite = utterances.contains {
            ($0["definite"] as? Bool) == true && (($0["text"] as? String)?.isEmpty == false)
        }
        return VolcUtteranceSignals(present: true, hasNonEmptyText: hasNonEmpty, hasDefiniteNonEmptyText: hasDefinite)
    }
}

public final class VolcStreamingSession: @unchecked Sendable {
    /// 端点类型不能只靠 URL 最后一段推断：Worker 路由使用自有域名。
    public enum EndpointProtocolKind: Sendable, Equatable {
        case infer
        case nostream
        case standard
    }
    /// 两端统一复用系统共享会话。Mac 专用无状态会话经实测不能稳定改善终稿缺失，已撤回。
    private let requestID: String
    private let connectID: String
    private let task: URLSessionWebSocketTask
    private let onPartial: (String) -> Void
    private let onUtterance: ((VolcUtterance) -> Void)?
    private let enableSpeakerInfo: Bool
    /// 说话人分离开着,但已经收到过若干句定稿转写却始终没有 speakerID 时,提醒一次
    /// (账号/资源 ID 很可能没有真正开通该能力),不逐句刷屏。
    private var loggedMissingSpeakerInfo = false
    private var definiteUtteranceCountSinceStart = 0

    private let audioIn: AsyncStream<Data>
    private let audioCont: AsyncStream<Data>.Continuation
    private let maxBufferedAudioBytes: Int
    private var bufferedAudioBytes = 0
    private var peakBufferedAudioBytes = 0
    private var acceptsAudio = true
    private var sendTask: Task<Void, Error>?
    private var recvTask: Task<Void, Never>?

    // receiveLoop 写、finish 读,锁保护
    private let lock = NSLock()
    private var _latest = ""
    private var _done = false
    private var _error: Error?
    private var _startedAt: Date?
    private var _firstPartialMillis: Int?
    private var _configurationSent = false
    private var _audioBytesSent = 0
    private var _audioPacketCount = 0
    private var _resultFrameCount = 0
    private var _receivedFinalResult = false
    private var _configurationSentMillis: Int?
    private var _firstAudioSentMillis: Int?
    private var _lastAudioSentMillis: Int?
    private var _finishRequestedMillis: Int?
    private var _endFrameSentMillis: Int?
    private var _endFrameSequence: Int32?
    private var _firstResultFrameMillis: Int?
    private var _finalResultMillis: Int?
    private var _parseableResultJSONFrameCount = 0
    private var _resultObjectFrameCount = 0
    private var _topLevelTextPresentFrameCount = 0
    private var _topLevelNonEmptyTextFrameCount = 0
    private var _utterancesPresentFrameCount = 0
    // Despite the legacy field name, this counts non-empty String utterance text only.
    private var _utteranceTextPresentFrameCount = 0
    private var _definiteUtteranceTextFrameCount = 0
    private var _finalFrameCount = 0
    private var _finalFrameHadNonEmptyTopLevelText: Bool?
    private var _onPartialInvocationCount = 0
    private var _firstParseableResultMillis: Int?
    private var _firstResultObjectMillis: Int?
    private var _firstTopLevelTextMillis: Int?
    private var _firstTopLevelNonEmptyTextMillis: Int?
    private var _firstUtterancesMillis: Int?
    private var _firstUtteranceTextMillis: Int?
    private var _firstDefiniteUtteranceTextMillis: Int?
    private var _firstFinalFrameMillis: Int?
    private var _jsonDecodeFailureCount = 0
    private var _decompressionFailureCount = 0
    private var _sequenceObservation = VolcSequenceObservation()
    private var _messageTypeBucketCounts = Array(repeating: 0, count: 16)
    private var _resultFlagsBucketCounts = Array(repeating: 0, count: 16)
    /// 已经回调过 onUtteranceDefinite 的分句,进度到哪个 end_time(毫秒)。分句按时间
    /// 顺序单调递增,服务端会在后续帧里重复下发已经 definite 过的分句,用这个游标去重,
    /// 不比对内容(内容一旦 definite 就不会再变,2026-08-16 对 80s 真实语音验证过)。
    private var _reportedUtteranceEndMs = -1

    private let hotwordsContext: String?
    /// 简繁体输出,语义同 `VolcEngineASR.outputChineseVariant`。
    private let outputChineseVariant: String?
    /// 只有显式传入时才将音频合并为固定大小。nil 保持 iOS 的变长回调封包行为。
    private let audioPacketBytesOverride: Int?
    private let paceAudioPackets: Bool
    /// Mac 服务端兼容路径：让最后一个真实 PCM 包携带负序号结束标志，避免只发空
    /// 结束包后服务端遗漏终稿。默认 false，iOS 保持原协议不变。
    private let finalFrameCarriesAudio: Bool
    /// 有些端点会遗漏最终帧标志。旧行为可在超时时采用最后一条文本；但若调用方
    /// 需要“绝不缺尾”的主听写结果，应关闭此项并走整段回退，而不是把中间稿伪装成定稿。
    private let acceptLatestTextOnTimeout: Bool
    /// bigmodel_nostream 端点的结果帧可能在录音期间只有空的顶层 text；不能假设
    /// utterances/definite 会持续提供可见文字，因此收尾使用扩展预算。
    private let isNostreamEndpoint: Bool

    public init(wsURL: URL, appId: String, accessToken: String, resourceId: String,
                hotwordsContext: String? = nil,
                outputChineseVariant: String? = nil,
                audioPacketBytesOverride: Int? = nil,
                paceAudioPackets: Bool = false,
                finalFrameCarriesAudio: Bool = false,
                acceptLatestTextOnTimeout: Bool = true,
                enableSpeakerInfo: Bool = false,
                maxBufferedAudioBytes: Int = 4 * 1024 * 1024,
                protocolKind: EndpointProtocolKind = .infer,
                bearerToken: String? = nil,
                onPartial: @escaping (String) -> Void,
                onUtterance: ((VolcUtterance) -> Void)? = nil) {
        self.onPartial = onPartial
        self.onUtterance = onUtterance
        self.enableSpeakerInfo = enableSpeakerInfo
        self.maxBufferedAudioBytes = max(1, maxBufferedAudioBytes)
        self.requestID = UUID().uuidString
        self.connectID = UUID().uuidString
        self.hotwordsContext = hotwordsContext
        self.outputChineseVariant = outputChineseVariant
        self.audioPacketBytesOverride = audioPacketBytesOverride
        self.paceAudioPackets = paceAudioPackets
        self.finalFrameCarriesAudio = finalFrameCarriesAudio
        self.acceptLatestTextOnTimeout = acceptLatestTextOnTimeout
        switch protocolKind {
        case .infer: self.isNostreamEndpoint = wsURL.lastPathComponent == "bigmodel_nostream"
        case .nostream: self.isNostreamEndpoint = true
        case .standard: self.isNostreamEndpoint = false
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
        req.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
        req.setValue(connectID, forHTTPHeaderField: "X-Api-Connect-Id")
        req.setValue("-1", forHTTPHeaderField: "X-Api-Sequence") // 与整段路径保持一致,避免网关差异化拒绝
        task = URLSession.shared.webSocketTask(with: req)
        (audioIn, audioCont) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
    }

    /// 建连 + 发配置。抛错说明流式不可用,调用方退回整段模式
    public func start() async throws {
        withLockedState {
            _startedAt = Date()
            _firstPartialMillis = nil
        }
        task.resume()
        let config = Self.requestConfig(
            enableSpeakerInfo: enableSpeakerInfo,
            hotwordsContext: hotwordsContext,
            outputChineseVariant: outputChineseVariant)
        let data = try JSONSerialization.data(withJSONObject: config)
        let configFrame = VolcEngineASR.frame(type: 0b0001, flags: 0b0001, seq: 1, payload: data)
        let gate = VolcOneShotGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task { [task] in
                do {
                    try await task.send(.data(configFrame))
                    if gate.claim() { continuation.resume() }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            Task { [task] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard gate.claim() else { return }
                task.cancel(with: .goingAway, reason: nil)
                continuation.resume(throwing: NSError(
                    domain: "VolcASR", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "流式识别连接配置超过 8 秒"]))
            }
        }
        withLockedState {
            _configurationSent = true
            _configurationSentMillis = elapsedMillisLocked()
        }

        recvTask = Task { await self.receiveLoop() }
        sendTask = Task { try await self.sendLoop() }
    }

    /// 建连首帧的 `request` 配置。抽成静态纯函数供单测:断言 `enable_speaker_info`
    /// 只在会议模式显式传入时才出现,且默认(听写路径)配置与改动前字节级一致——
    /// 这是"会议功能不能拖累既有听写"的回归保护线。不发送 `enable_channel_split`:
    /// 本 App 只采集单声道麦克风,声道分离对这里的音频形态不适用。
    static func requestConfig(enableSpeakerInfo: Bool,
                              hotwordsContext: String?,
                              outputChineseVariant: String?) -> [String: Any] {
        var request: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            "enable_ddc": true,
            "show_utterances": true,
            "result_type": "full",
        ]
        if enableSpeakerInfo { request["enable_speaker_info"] = true }
        if let ctx = hotwordsContext {
            request["corpus"] = ["context": ctx] // 个人词典热词
        }
        if let variant = outputChineseVariant, !variant.isEmpty {
            request["output_zh_variant"] = variant // 简→繁,默认不发送(简体)
        }
        return [
            "user": ["uid": "voicepen"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": request,
        ]
    }

    /// 录音线程直接调用:有序入队、非阻塞
    public func feed(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        let overflow = withLockedState { () -> Bool in
            guard acceptsAudio, _error == nil, !_done else { return false }
            // Reserve bytes before enqueueing, including the chunk currently being
            // sent. Dropping individual packets would silently corrupt recognition.
            guard pcm.count <= maxBufferedAudioBytes - bufferedAudioBytes else {
                acceptsAudio = false
                _error = NSError(domain: "VolcASR", code: -3, userInfo: [
                    NSLocalizedDescriptionKey: "语音上传积压超过限额，改用完整录音识别"
                ])
                return true
            }
            bufferedAudioBytes += pcm.count
            peakBufferedAudioBytes = max(peakBufferedAudioBytes, bufferedAudioBytes)
            audioCont.yield(pcm)
            return false
        }
        if overflow { cancel() }
    }

    /// Pending PCM, including the chunk currently in the send loop. The default
    /// 4 MiB budget permits about 131 seconds of 16 kHz mono Int16 upload backlog.
    public var queuedAudioBytes: Int { withLockedState { bufferedAudioBytes } }
    public var peakQueuedAudioBytes: Int { withLockedState { peakBufferedAudioBytes } }

    /// 结束：冲刷缓冲、发结束帧、等待最终包。为容纳服务端和网络的偶发尾延迟，
    /// native nostream 给 8 秒硬预算，其它端点给 3 秒。
    ///
    /// 这里不能用两个同为 8 秒的 task-group 子任务竞速：旧实现中，正常收尾分支到点
    /// 会返回已经收到的最新文本，超时分支却在同一时刻抛错，导致几十上百个结果帧
    /// 已到达仍被误判为失败；底层 WebSocket send/receive 不响应 Task.cancel 时，结构化
    /// 任务组还会等待子任务退出，使所谓“硬超时”反而无限挂住。
    public func finish() async throws -> String {
        withLockedState {
            acceptsAudio = false
            if _finishRequestedMillis == nil { _finishRequestedMillis = elapsedMillisLocked() }
        }
        audioCont.finish()
        let timeoutSeconds = Self.finishTimeoutSeconds(forNostreamEndpoint: isNostreamEndpoint)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let (done, err, text) = snapshot()
            if let err { throw err }
            if done {
                task.cancel(with: .normalClosure, reason: nil)
                return text
            }
            // 20ms 轮询粒度将调度超出 8s 硬窗口的误差压到人体无感范围。
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let (_, err, text) = snapshot()
        cancel()
        if let err { throw err }
        // `bigmodel_nostream` 可能漏发协议终稿标志，但此前的 full result 帧已经携带
        // 完整累积文本。超过硬预算后采用最新文本，不能把可用结果丢掉再整段上传一次。
        if acceptLatestTextOnTimeout,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            CoreDiagLog.handler?("asr", "终稿标志未在 \(Int(timeoutSeconds)) 秒内到达，采用最新完整结果")
            return text
        }
        throw NSError(domain: "VolcASR", code: -2,
                      userInfo: [NSLocalizedDescriptionKey: "流式识别收尾超过 \(Int(timeoutSeconds)) 秒且没有可用结果"])
    }

    static func finishTimeoutSeconds(forNostreamEndpoint enabled: Bool) -> TimeInterval {
        enabled ? 8 : 3
    }

    public func cancel() {
        withLockedState { acceptsAudio = false }
        audioCont.finish()
        sendTask?.cancel()
        recvTask?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }

    public var firstPartialMillis: Int? {
        withLockedState { _firstPartialMillis }
    }

    /// 返回当前快照，即使 `finish()` 已抛错也可读取。错误文本仅用于本机工作记录，
    /// 上层不应将它同步到云端或展示凭据相关上下文。
    public var diagnostics: VolcStreamingDiagnostics {
        withLockedState {
            VolcStreamingDiagnostics(
                requestID: requestID,
                connectID: connectID,
                configurationSent: _configurationSent,
                audioBytesSent: _audioBytesSent,
                audioPacketCount: _audioPacketCount,
                resultFrameCount: _resultFrameCount,
                receivedFinalResult: _receivedFinalResult,
                firstPartialMillis: _firstPartialMillis,
                lastErrorDescription: _error?.localizedDescription,
                configurationSentMillis: _configurationSentMillis,
                firstAudioSentMillis: _firstAudioSentMillis,
                lastAudioSentMillis: _lastAudioSentMillis,
                finishRequestedMillis: _finishRequestedMillis,
                endFrameSentMillis: _endFrameSentMillis,
                endFrameSequence: _endFrameSequence,
                firstResultFrameMillis: _firstResultFrameMillis,
                finalResultMillis: _finalResultMillis,
                parseableResultJSONFrameCount: _parseableResultJSONFrameCount,
                resultObjectFrameCount: _resultObjectFrameCount,
                topLevelTextPresentFrameCount: _topLevelTextPresentFrameCount,
                topLevelNonEmptyTextFrameCount: _topLevelNonEmptyTextFrameCount,
                utterancesPresentFrameCount: _utterancesPresentFrameCount,
                utteranceTextPresentFrameCount: _utteranceTextPresentFrameCount,
                definiteUtteranceTextFrameCount: _definiteUtteranceTextFrameCount,
                finalFrameCount: _finalFrameCount,
                finalFrameHadNonEmptyTopLevelText: _finalFrameHadNonEmptyTopLevelText,
                onPartialInvocationCount: _onPartialInvocationCount,
                firstParseableResultMillis: _firstParseableResultMillis,
                firstResultObjectMillis: _firstResultObjectMillis,
                firstTopLevelTextMillis: _firstTopLevelTextMillis,
                firstTopLevelNonEmptyTextMillis: _firstTopLevelNonEmptyTextMillis,
                firstUtterancesMillis: _firstUtterancesMillis,
                firstUtteranceTextMillis: _firstUtteranceTextMillis,
                firstDefiniteUtteranceTextMillis: _firstDefiniteUtteranceTextMillis,
                firstFinalFrameMillis: _firstFinalFrameMillis,
                jsonDecodeFailureCount: _jsonDecodeFailureCount,
                decompressionFailureCount: _decompressionFailureCount,
                sequenceFirst: _sequenceObservation.first, sequenceLast: _sequenceObservation.last,
                sequenceMin: _sequenceObservation.minimum, sequenceMax: _sequenceObservation.maximum,
                sequenceMonotonicityBroken: _sequenceObservation.monotonicityBroken,
                sequenceDuplicateCount: _sequenceObservation.duplicateCount,
                messageTypeBucketCounts: _messageTypeBucketCounts,
                resultFlagsBucketCounts: _resultFlagsBucketCounts)
        }
    }

    private func snapshot() -> (Bool, Error?, String) {
        withLockedState { (_done, _error, _latest) }
    }

    /// NSLock 的获取与释放必须留在同步函数边界内；Swift 6 禁止在 async 函数体中
    /// 直接调用 lock/unlock，因为锁可能跨 suspension point 被错误持有。
    private func withLockedState<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// 仅在 `withLockedState` 闭包中调用，避免读 `_startedAt` 时引入第二次加锁。
    private func elapsedMillisLocked(now: Date = Date()) -> Int? {
        guard let startedAt = _startedAt else { return nil }
        return max(0, Int(now.timeIntervalSince(startedAt) * 1000))
    }

    // MARK: - 发送:攒够 100ms 就发一包

    private func sendLoop() async throws {
        var seq: Int32 = 1
        var buffer = Data()
        var lastPacketSentAt: Date?
        // `finalFrameCarriesAudio` 时保留最新完整包到 finish：下一个包到达才发送前一个，
        // 结束时把这个真实 PCM 包连同负序号一次发出。额外延迟最多一包(约 100ms)。
        var pendingFinalPacket: Data?

        func waitForPacing(packetBytes: Int) async throws {
            guard paceAudioPackets, let lastPacketSentAt else { return }
            let audioSeconds = Double(packetBytes) / 32_000.0
            let remaining = audioSeconds - Date().timeIntervalSince(lastPacketSentAt)
            if remaining > 0 {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000.0))
            }
        }

        for await chunk in audioIn {
            defer { withLockedState { bufferedAudioBytes -= chunk.count } }
            try Task.checkCancellation()
            buffer.append(chunk)
            if let packetBytes = audioPacketBytesOverride {
                // 保留最后一包到 finish，让它自身携带负序号和结束标志。
                // 单独空结束包在 Mac + nostream 上会偶发不得到最终响应。
                while buffer.count > packetBytes {
                    seq += 1
                    let packet = Data(buffer.prefix(packetBytes))
                    try await waitForPacing(packetBytes: packet.count)
                    try await task.send(.data(VolcEngineASR.frame(
                        type: 0b0010, flags: 0b0001, seq: seq, payload: packet)))
                    lastPacketSentAt = Date()
                    withLockedState {
                        _audioBytesSent += packet.count
                        _audioPacketCount += 1
                        if _firstAudioSentMillis == nil { _firstAudioSentMillis = elapsedMillisLocked() }
                        _lastAudioSentMillis = elapsedMillisLocked()
                    }
                    buffer.removeFirst(packetBytes)
                }
            } else if buffer.count >= 3200 {
                // 保留原有 iOS 行为：转码器每次回调可能略大于 100ms，
                // 达到门槛就整块发送，不在共享核心中悄悄改变 iOS 封包节奏。
                let packet = buffer
                buffer.removeAll(keepingCapacity: true)
                if finalFrameCarriesAudio {
                    if let prior = pendingFinalPacket {
                        seq += 1
                        try await task.send(.data(VolcEngineASR.frame(
                            type: 0b0010, flags: 0b0001, seq: seq, payload: prior)))
                        withLockedState {
                            _audioBytesSent += prior.count
                            _audioPacketCount += 1
                            if _firstAudioSentMillis == nil { _firstAudioSentMillis = elapsedMillisLocked() }
                            _lastAudioSentMillis = elapsedMillisLocked()
                        }
                    }
                    pendingFinalPacket = packet
                } else {
                    seq += 1
                    try await task.send(.data(VolcEngineASR.frame(
                        type: 0b0010, flags: 0b0001, seq: seq, payload: packet)))
                    withLockedState {
                        _audioBytesSent += packet.count
                        _audioPacketCount += 1
                        if _firstAudioSentMillis == nil { _firstAudioSentMillis = elapsedMillisLocked() }
                        _lastAudioSentMillis = elapsedMillisLocked()
                    }
                }
            }
        }
        if audioPacketBytesOverride != nil {
            seq += 1
            try await waitForPacing(packetBytes: buffer.count)
            try await task.send(.data(VolcEngineASR.frame(
                type: 0b0010, flags: 0b0011, seq: -seq, payload: buffer)))
            lastPacketSentAt = Date()
            withLockedState {
                _audioBytesSent += buffer.count
                _audioPacketCount += 1
                if _firstAudioSentMillis == nil { _firstAudioSentMillis = elapsedMillisLocked() }
                _lastAudioSentMillis = elapsedMillisLocked()
                _endFrameSentMillis = elapsedMillisLocked()
                _endFrameSequence = -seq
            }
            return
        }
        if finalFrameCarriesAudio {
            if !buffer.isEmpty {
                if let prior = pendingFinalPacket {
                    seq += 1
                    try await task.send(.data(VolcEngineASR.frame(
                        type: 0b0010, flags: 0b0001, seq: seq, payload: prior)))
                    withLockedState {
                        _audioBytesSent += prior.count
                        _audioPacketCount += 1
                        if _firstAudioSentMillis == nil { _firstAudioSentMillis = elapsedMillisLocked() }
                        _lastAudioSentMillis = elapsedMillisLocked()
                    }
                }
                pendingFinalPacket = buffer
            }
            seq += 1
            let finalPayload = pendingFinalPacket ?? Data()
            try await task.send(.data(VolcEngineASR.frame(
                type: 0b0010, flags: 0b0011, seq: -seq, payload: finalPayload)))
            withLockedState {
                _audioBytesSent += finalPayload.count
                _audioPacketCount += 1
                if _firstAudioSentMillis == nil { _firstAudioSentMillis = elapsedMillisLocked() }
                _lastAudioSentMillis = elapsedMillisLocked()
                _endFrameSentMillis = elapsedMillisLocked()
                _endFrameSequence = -seq
            }
            return
        }
        if !buffer.isEmpty {
            seq += 1
            try await task.send(.data(VolcEngineASR.frame(
                type: 0b0010, flags: 0b0001, seq: seq, payload: buffer)))
            let bytesSent = buffer.count
            withLockedState {
                _audioBytesSent += bytesSent
                _audioPacketCount += 1
                if _firstAudioSentMillis == nil { _firstAudioSentMillis = elapsedMillisLocked() }
                _lastAudioSentMillis = elapsedMillisLocked()
            }
        }
        seq += 1
        try await task.send(.data(VolcEngineASR.frame(
            type: 0b0010, flags: 0b0011, seq: -seq, payload: Data())))
        withLockedState {
            _endFrameSentMillis = elapsedMillisLocked()
            _endFrameSequence = -seq
        }
    }

    // MARK: - 接收:持续更新中间结果,遇最终包结束

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                guard case .data(let d) = msg else { continue }
                let bytes = [UInt8](d)
                guard bytes.count >= 8 else { continue }

                let headerSize = Int(bytes[0] & 0x0F) * 4
                let msgType = (bytes[1] >> 4) & 0x0F
                let flags = bytes[1] & 0x0F
                let compressed = (bytes[2] & 0x0F) == 0b0001
                withLockedState {
                    _messageTypeBucketCounts[Int(msgType)] += 1
                    if msgType == 0b1001 { _resultFlagsBucketCounts[Int(flags)] += 1 }
                }
                var p = headerSize
                if flags & 0x01 != 0 { p += 4 }

                if msgType == 0b1111 {
                    guard bytes.count >= p + 8 else { continue }
                    let code = VolcEngineASR.readU32(bytes, at: p)
                    var body = Data(bytes[(p + 8)...])
                    if compressed, let un = VolcEngineASR.gunzip(body) { body = un }
                    let text = String(data: body, encoding: .utf8) ?? ""
                    withLockedState {
                        _error = VolcEngineASR.err("豆包识别服务报错(\(code) \(VolcEngineASR.codeHint(code))): \(text.prefix(200))")
                    }
                    return
                }
                if msgType == 0b1001 {
                    guard bytes.count >= p + 4 else { continue }
                    withLockedState {
                        _resultFrameCount += 1
                        if _firstResultFrameMillis == nil { _firstResultFrameMillis = elapsedMillisLocked() }
                        if flags & 0x02 != 0 {
                            _finalFrameCount += 1
                            if _firstFinalFrameMillis == nil { _firstFinalFrameMillis = elapsedMillisLocked() }
                        }
                    }
                    let parsed = VolcResultFrameParse.parse(d)
                    if case .result(let sequence, let resultFlags, let body, _) = parsed {
                        withLockedState {
                            if let sequence { _sequenceObservation.observe(sequence) }
                        }
                        withLockedState {
                            _parseableResultJSONFrameCount += 1
                            if _firstParseableResultMillis == nil { _firstParseableResultMillis = elapsedMillisLocked() }
                        }
                        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                            withLockedState { _jsonDecodeFailureCount += 1 }
                            continue
                        }
                        if let result = obj["result"] as? [String: Any] {
                            let textValue = result["text"] as? String
                            let textPresent = result["text"] != nil
                            let nonEmpty = !(textValue ?? "").isEmpty
                            let utterances = result["utterances"] as? [[String: Any]]
                            let utteranceSignals = VolcUtteranceSignals.from(utterances)
                            withLockedState {
                                _resultObjectFrameCount += 1
                                if _firstResultObjectMillis == nil { _firstResultObjectMillis = elapsedMillisLocked() }
                                if textPresent { _topLevelTextPresentFrameCount += 1; if _firstTopLevelTextMillis == nil { _firstTopLevelTextMillis = elapsedMillisLocked() } }
                                if nonEmpty { _topLevelNonEmptyTextFrameCount += 1; if _firstTopLevelNonEmptyTextMillis == nil { _firstTopLevelNonEmptyTextMillis = elapsedMillisLocked() } }
                                if utteranceSignals.present { _utterancesPresentFrameCount += 1; if _firstUtterancesMillis == nil { _firstUtterancesMillis = elapsedMillisLocked() } }
                                if utteranceSignals.hasNonEmptyText { _utteranceTextPresentFrameCount += 1; if _firstUtteranceTextMillis == nil { _firstUtteranceTextMillis = elapsedMillisLocked() } }
                                if utteranceSignals.hasDefiniteNonEmptyText { _definiteUtteranceTextFrameCount += 1; if _firstDefiniteUtteranceTextMillis == nil { _firstDefiniteUtteranceTextMillis = elapsedMillisLocked() } }
                                if resultFlags & 0x02 != 0 { _finalFrameHadNonEmptyTopLevelText = nonEmpty }
                            }
                            if let t = textValue, !t.isEmpty {
                        let partialHandler = withLockedState { () -> (String) -> Void in
                            if _firstPartialMillis == nil, let startedAt = _startedAt {
                                _firstPartialMillis = Int(Date().timeIntervalSince(startedAt) * 1000)
                            }
                            _latest = t
                            _onPartialInvocationCount += 1
                            return onPartial
                        }
                        partialHandler(t)
                        // show_utterances 打开后,分句会在 definite 变 true 时逐句确认(2026-08-16
                        // 对 80s 真实语音验证:一旦 definite,内容后续不再变)。按 end_time 单调游标
                        // 去重后逐句回调,给调用方一个"提前定稿、不会反悔"的分句流,不必等 finish()。
                            }
                        if let onUtterance, let utterances {
                            for u in utterances {
                                guard (u["definite"] as? Bool) == true,
                                      let text = u["text"] as? String, !text.isEmpty,
                                      let startMs = u["start_time"] as? Int,
                                      let endMs = u["end_time"] as? Int else { continue }
                                let alreadyReported = withLockedState { () -> Bool in
                                    guard endMs > _reportedUtteranceEndMs else { return true }
                                    _reportedUtteranceEndMs = endMs
                                    return false
                                }
                                guard !alreadyReported else { continue }
                                // 字段命名未经该账号真机确认;三种形态都试,取不到就当未标注,
                                // 不因此丢弃这条分句(见 enableSpeakerInfo 的诊断日志)。
                                let speaker = (u["speaker_id"] as? String)
                                    ?? (u["speaker_id"] as? Int).map(String.init)
                                    ?? ((u["additions"] as? [String: Any])?["speaker"] as? String)
                                definiteUtteranceCountSinceStart += 1
                                if enableSpeakerInfo, speaker == nil, !loggedMissingSpeakerInfo,
                                   definiteUtteranceCountSinceStart >= 3 {
                                    loggedMissingSpeakerInfo = true
                                    CoreDiagLog.handler?("asr", "enable_speaker_info 已开启但分句未回传说话人标签,请核实账号/资源 ID 是否已开通说话人分离")
                                }
                                onUtterance(VolcUtterance(text: text, startMs: startMs, endMs: endMs, speakerID: speaker))
                            }
                        }
                        }
                    } else if case .resultDecompressionFailed = parsed {
                        withLockedState { _decompressionFailureCount += 1 }
                    } else if case .resultJSONFailed = parsed {
                        withLockedState { _jsonDecodeFailureCount += 1 }
                    }
                    if flags & 0x02 != 0 {
                        withLockedState {
                            _receivedFinalResult = true
                            _finalResultMillis = elapsedMillisLocked()
                            _done = true
                        }
                        return
                    }
                }
            } catch {
                withLockedState {
                    if !_done && _error == nil { _error = error }
                }
                return
            }
        }
    }
}
