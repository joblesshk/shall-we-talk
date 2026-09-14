import Foundation

/// 一趟文字整理请求（首轮整理或结构化通读）的本机诊断时间线。
/// 所有相对时间以“本次录音停止”为零点；长口述分段整理可能在停止前已开始，因此
/// `startedMillis` 允许为负数。字段不参与 iCloud 历史格式，只供两端开发诊断作同口径比较。
public struct CleanupPassMetrics: Codable, Sendable, Equatable {
    /// 此趟的第一个请求开始发送的时点；分段首轮为最早分段请求的时点。
    public var startedMillis: Int?
    /// 收到第一个非空正文 token 的时点；未拿到正文或无需请求时为 nil。
    public var firstTokenMillis: Int?
    /// 此趟所有请求（含必要重试）结束、结果已选定的时点。
    public var completedMillis: Int?
    /// 本趟实际发出的 LLM 请求数；分段首轮和重试可能大于 1。
    public var requestCount: Int?
    /// 供应商返回的 prompt token 总数；任一请求未返回该字段时为 nil，避免伪造总数。
    public var promptTokens: Int?
    /// 其中命中前缀缓存的 token 总数；未知时保持 nil，不能解释为零命中。
    public var cachedPromptTokens: Int?

    public init(startedMillis: Int? = nil, firstTokenMillis: Int? = nil,
                completedMillis: Int? = nil, requestCount: Int? = nil,
                promptTokens: Int? = nil, cachedPromptTokens: Int? = nil) {
        self.startedMillis = startedMillis
        self.firstTokenMillis = firstTokenMillis
        self.completedMillis = completedMillis
        self.requestCount = requestCount
        self.promptTokens = promptTokens
        self.cachedPromptTokens = cachedPromptTokens
    }

    /// 缓存字段缺失时必须保持未知，不能把缺失误报成 0%。
    public var promptCacheHitRate: Double? {
        guard let promptTokens, promptTokens > 0, let cachedPromptTokens else { return nil }
        return Double(cachedPromptTokens) / Double(promptTokens)
    }
}

/// 端到端延迟打点(毫秒):覆盖"松开录音键→文字上屏"链路的关键分段。
/// 字段全部 optional,兼容任一段缺失(离线、流式失败退整段、短口述不整理、旧记录解码)。
///
/// 锚点约定(除一项例外均以"录音停止"为锚点——这是用户体感的等待起点):
/// - `asrFinalMillis` / `llmFirstTokenMillis` / `cleanupCompleteMillis` / `totalMillis`:
///   录音停止 → 该阶段完成的耗时。
/// - `asrFirstPartialMillis` 例外:以"流式会话建连开始"(约等于录音开始)为锚点,而非录音停止。
///   流式识别的首个中间结果几乎总在用户仍在说话、尚未停止录音时到达;若以"停止"为锚点会得到
///   无意义的负数。这里保留 `VolcStreamingSession.firstPartialMillis` 原有语义(首字延迟/TTFT,
///   原只在 macOS 千问 A/B 面板使用),本次只是让它跨平台可用,不重新定义口径。
public struct LatencyMetrics: Codable, Sendable, Equatable {
    /// 流式会话建连开始 → ASR 首个中间结果(TTFT);整段回退路径无中间结果,恒为 nil
    public var asrFirstPartialMillis: Int?
    /// 录音停止 → ASR 终稿就绪(含流式收尾等待或整段回退的完整时长)
    public var asrFinalMillis: Int?
    /// 录音停止 → 本次整理管线中,停止后发起的首个 LLM 请求收到第一个非空 token
    /// (多段并行整理时,若尾段已在停止前提交完毕、停止后无需再发新请求,则为 nil)
    public var llmFirstTokenMillis: Int?
    /// 录音停止 → 整理完成(含多段整理的最终通读/重排步骤);未触发整理时为 nil
    public var cleanupCompleteMillis: Int?
    /// 录音停止 → 端到端总耗时(文字定稿、可上屏/入库的时刻)
    public var totalMillis: Int?
    /// 本次整理请求的 system+user prompt token 数(供应商返回才有)。
    public var promptTokens: Int?
    /// 其中命中服务端前缀缓存的 token 数。
    ///
    /// 存这两个字段是为了让“把易变段落垫到 prompt 末尾”这类改动可被复盘:命中率直接
    /// 决定首字延迟,而首字延迟是短口述等待时间的大头。旧记录没有这两个键,解码为 nil。
    public var cachedPromptTokens: Int?
    /// 首轮整理的独立时间线及缓存账单。旧记录/跳过整理路径为 nil。
    public var firstCleanupPass: CleanupPassMetrics?
    /// 结构化通读的独立时间线及缓存账单。短口述、跳过整理等未运行该趟时为 nil。
    public var structurePass: CleanupPassMetrics?

    public init(asrFirstPartialMillis: Int? = nil,
                asrFinalMillis: Int? = nil,
                llmFirstTokenMillis: Int? = nil,
                cleanupCompleteMillis: Int? = nil,
                totalMillis: Int? = nil,
                promptTokens: Int? = nil,
                cachedPromptTokens: Int? = nil,
                firstCleanupPass: CleanupPassMetrics? = nil,
                structurePass: CleanupPassMetrics? = nil) {
        self.asrFirstPartialMillis = asrFirstPartialMillis
        self.asrFinalMillis = asrFinalMillis
        self.llmFirstTokenMillis = llmFirstTokenMillis
        self.cleanupCompleteMillis = cleanupCompleteMillis
        self.totalMillis = totalMillis
        self.promptTokens = promptTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.firstCleanupPass = firstCleanupPass
        self.structurePass = structurePass
    }

    /// 前缀缓存命中率(0...1);供应商未返回账单时为 nil。
    public var promptCacheHitRate: Double? {
        guard let promptTokens, promptTokens > 0, let cachedPromptTokens else { return nil }
        return Double(cachedPromptTokens) / Double(promptTokens)
    }

    /// 记下一次整理请求的账单。传 nil(供应商没返回)时不覆盖已有值。
    public mutating func apply(_ usage: CleanupService.Usage?) {
        guard let usage else { return }
        promptTokens = usage.promptTokens
        cachedPromptTokens = usage.cachedPromptTokens
    }
}

public extension LatencyMetrics {
    /// 紧凑单行摘要,如"识别 1.2s · 整理 0.8s · 共 2.1s";所有分段均缺失时返回 nil。
    /// 口径:识别=asrFinalMillis(录音停止→识别终稿);整理=在识别终稿基础上的增量耗时
    /// (cleanupCompleteMillis-asrFinalMillis,避免与识别时长重复计入);共=totalMillis,
    /// 缺失时退化为已知的最终阶段耗时(cleanupCompleteMillis 或 asrFinalMillis)。
    var compactSummary: String? {
        var parts: [String] = []
        if let asr = asrFinalMillis {
            parts.append("识别 \(Self.formatSeconds(asr))")
        }
        if let cleanup = cleanupCompleteMillis {
            let delta = asrFinalMillis.map { max(cleanup - $0, 0) } ?? cleanup
            parts.append("整理 \(Self.formatSeconds(delta))")
        }
        if let total = totalMillis ?? cleanupCompleteMillis ?? asrFinalMillis {
            parts.append("共 \(Self.formatSeconds(total))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func formatSeconds(_ millis: Int) -> String {
        String(format: "%.1fs", Double(millis) / 1000)
    }
}

/// 独立于识别状态；旧历史缺失此项表示未知，不能由正文相同推断失败。
public enum CleanupStatus: String, Codable, Sendable {
    case succeeded, skipped, failed
}

extension CleanupPassMetrics {
    public var elapsedMillis: Int? {
        guard let start = startedMillis, let end = completedMillis, end >= start else { return nil }
        return end - start
    }
}
