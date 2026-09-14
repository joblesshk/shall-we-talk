import Foundation

/// 火山引擎(豆包)"录音文件识别大模型 · 极速版"REST API(单次同步调用,`/recognize/flash`)。
///
/// 会议记录功能的**权威转写来源**:会议实时进行时只用端侧模型出一份粗糙草稿(见
/// `OnDeviceLiveCaptioner`),让用户知道"正在录、正在转",不追求准确;会议结束后
/// 整段音频改用这支 API 重新识别一遍,拿到的高精度、带说话人分离的结果**替换**掉
/// 草稿,草稿本身随即丢弃(不与最终稿并存)。
///
/// 选型说明(2026-08-20 与用户确认):官方"标准版"异步 submit+query 接口
/// (`/auc/bigmodel/submit` + `/query`)的公开文档只列出 `audio.url` 一种音频输入方式,
/// 要求先有一个公网可访问的音频地址——本 App 没有服务器,拿不出这个 URL。极速版
/// `/recognize/flash` 端点官方文档明确支持内联 `audio.data`(base64)二选一 `audio.url`,
/// 字段与标准版基本一致(少几个仅用于排队/回调的字段),这里选它作为唯一可行路径。
/// 请求字段按极速接口可支持的最高保真档位配置。录音是 16 kHz/16-bit/单声道 WAV,
/// 因而明确带上对应 `audio` 元数据；会议默认为普通话(`zh-CN`)，以保证说话人分离生效。
/// `enable_itn` 和 `enable_punc` 打开以保留可读的数字、金额、日期与断句；
/// `enable_ddc` 必须关闭——它会删改停顿词和重复词，属于后续整理而非忠实转写。
/// `show_utterances` 与 `enable_speaker_info` 一起打开。极速接口公开说明仅列出
/// `ssd_version: "200"`；不能把异步文件识别 2.0 面向多人会议的 `300` 参数直接移植到
/// 这个端点。个人词典/热词仍通过
/// `request.corpus.context` 注入（与 `VolcStreamingSession` 的 `corpus.context` 同一约定）。
///
/// 本客户端仍使用支持内联 `audio.data` 的极速端点。文档中的录音文件识别 2.0 异步
/// submit/query 端点要求 `audio.url`，因此在具备私有、限时签名的音频 URL 前，不能把本地
/// 会议录音伪装成该接口的输入或直接替换端点。
///
/// ⚠️ 唯一未经真实账号验证的点:说话人标签字段路径。官方文档本身的示例响应没有开
/// `enable_speaker_info`,该开关打开后的字段名(`result.utterances[].additions.speaker`)
/// 来自第三方工程实践文章交叉印证,不是官方示例直接给出的。解析时按此路径为先,
/// 同时保留其它可能形态作为兜底,取不到就按未标注处理,不因此丢弃整句转写文字。
/// 上线前应跑一次 `VolcFileTranscriptionLiveRegressionTests`(真实凭据,环境变量门控)核实。
public enum VolcFileTranscription {
    public struct TranscriptUtterance: Sendable, Equatable {
        public let text: String
        public let startMs: Int
        public let endMs: Int
        public let speakerID: String?

        public init(text: String, startMs: Int, endMs: Int, speakerID: String?) {
            self.text = text
            self.startMs = startMs
            self.endMs = endMs
            self.speakerID = speakerID
        }
    }

    public struct TranscriptResult: Sendable, Equatable {
        public let text: String
        public let utterances: [TranscriptUtterance]

        public init(text: String, utterances: [TranscriptUtterance]) {
            self.text = text
            self.utterances = utterances
        }
    }

    private static let flashURL = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash")!

    /// 这里单独保留为可测试的纯配置构造，避免会后权威转写的参数随着实时识别配置漂移。
    static func makeRequestPayload(wav: Data, enableSpeakerInfo: Bool,
                                   hotwordsContext: String?, outputChineseVariant: String?) -> [String: Any] {
        var request: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            // 原始会议纪要需要可追溯；去口语化交给后续摘要而非 ASR。
            "enable_ddc": false,
            "show_utterances": true,
            // 录音文件均为单声道，不能借由声道冒充说话人。
            "enable_channel_split": false,
        ]
        if enableSpeakerInfo {
            request["enable_speaker_info"] = true
            request["ssd_version"] = "200"
        }
        if let variant = outputChineseVariant, !variant.isEmpty { request["output_zh_variant"] = variant }
        if let ctx = hotwordsContext, !ctx.isEmpty { request["corpus"] = ["context": ctx] }

        return [
            "user": ["uid": "voicepen"],
            // 会议录音器固定输出这一格式；显式传入而不是依赖接口默认值。
            "audio": [
                "format": "wav",
                "data": wav.base64EncodedString(),
                "rate": 16_000,
                "bits": 16,
                "channel": 1,
            ],
            // 当前会议主要为普通话。若未来提供会议语种设置，可将这个固定值升级为用户选择。
            "language": "zh-CN",
            "request": request,
        ]
    }

    /// 整段音频(WAV,含 44 字节头)识别。建议按 `MeetingSegment` 逐段调用而不是整场会议
    /// 拼一个大文件——极速版官方文档上限 100MB/约 2 小时,逐段调用天然避开这个上限,
    /// 也让"某一段识别失败"不连累其它段已经拿到的高质量结果。
    public static func transcribe(wav: Data, appId: String, accessToken: String, resourceId: String,
                                  enableSpeakerInfo: Bool, hotwordsContext: String? = nil,
                                  outputChineseVariant: String? = nil,
                                  endpoint: URL? = nil, bearerToken: String? = nil) async throws -> TranscriptResult {
        guard bearerToken?.isEmpty == false || (!appId.isEmpty && !accessToken.isEmpty) else {
            throw VolcEngineASR.err("请在设置里填写豆包的 App ID 和 Access Token")
        }
        guard wav.count > 44 else { throw VolcEngineASR.err("录音文件为空,无法识别") }

        let payload = makeRequestPayload(wav: wav, enableSpeakerInfo: enableSpeakerInfo,
                                         hotwordsContext: hotwordsContext,
                                         outputChineseVariant: outputChineseVariant)
        var req = URLRequest(url: endpoint ?? flashURL)
        req.httpMethod = "POST"
        if let bearerToken, !bearerToken.isEmpty {
            req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        } else {
            req.setValue(appId, forHTTPHeaderField: "X-Api-App-Key")
            req.setValue(accessToken, forHTTPHeaderField: "X-Api-Access-Key")
            req.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        }
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        req.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        // 极速版仍是"整段音频先传完再识别",一段 20 分钟轮转的会议录音上传+识别预留
        // 充裕时间;会议场景不追求低延迟,宁可等,不设一个容易被打断长会议的短超时。
        req.timeoutInterval = 180

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw VolcEngineASR.err("录音文件识别无响应")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw VolcEngineASR.err("录音文件识别失败 HTTP \(http.statusCode): \(body)")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw VolcEngineASR.err("录音文件识别返回非 JSON")
        }
        if let code = obj["code"] as? Int, code != 0, code != 20000000 {
            let message = (obj["message"] as? String) ?? "未知错误码 \(code)"
            throw VolcEngineASR.err("\(message)（\(VolcEngineASR.codeHint(UInt32(bitPattern: Int32(code))))）")
        }
        guard let result = obj["result"] as? [String: Any] else {
            throw VolcEngineASR.err("录音文件识别完成但缺少 result 字段")
        }
        let text = (result["text"] as? String) ?? ""
        let utterances = ((result["utterances"] as? [[String: Any]]) ?? []).compactMap { u -> TranscriptUtterance? in
            guard let t = u["text"] as? String, !t.isEmpty else { return nil }
            let startMs = (u["start_time"] as? Int) ?? 0
            let endMs = (u["end_time"] as? Int) ?? 0
            let additions = u["additions"] as? [String: Any]
            let speaker = (additions?["speaker"] as? String)
                ?? (u["speaker_id"] as? String)
                ?? (u["speaker_id"] as? Int).map(String.init)
            return TranscriptUtterance(text: t, startMs: startMs, endMs: endMs, speakerID: speaker)
        }
        return TranscriptResult(text: text, utterances: utterances)
    }
}
