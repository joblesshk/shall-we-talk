import Foundation

/// 会议纪要里用户要的「行程」:带时间锚点的议程条目,可在 UI 里点按跳转到转写对应位置。
public struct MeetingSummaryTimelineItem: Codable, Equatable, Sendable {
    public var at: String     // "mm:ss"
    public var topic: String
    public var detail: String

    public init(at: String, topic: String, detail: String) {
        self.at = at
        self.topic = topic
        self.detail = detail
    }
}

/// 决议性纪要惯例:结论与"是否已敲定"分开标注,不把"讨论过"和"定下来了"混为一谈。
public struct MeetingSummaryDecision: Codable, Equatable, Sendable {
    public var text: String
    /// "已确认" / "待定"——由转写原文的确定性决定,不是模型自己的主观判断。
    public var status: String

    public init(text: String, status: String) {
        self.text = text
        self.status = status
    }
}

/// 专业会议纪要的待办条目惯例:owner + deadline 是独立字段,不是揉进一句话里的散文。
/// 转写里没有明确说到负责人/截止时间时字段为 nil——绝不让模型替发言人指派任务或编造日期。
public struct MeetingSummaryActionItem: Codable, Equatable, Sendable {
    public var task: String
    public var owner: String?
    public var deadline: String?

    public init(task: String, owner: String? = nil, deadline: String? = nil) {
        self.task = task
        self.owner = owner
        self.deadline = deadline
    }
}

/// 会议纪要的结构化产出。JSON 而非 Markdown——详情页需要标题/行程/要点/决议/待办作为
/// 独立可点按的 UI 元素,从 markdown 标题里抠这些字段比一次 JSONDecoder.decode 脆弱得多。
public struct MeetingSummary: Codable, Equatable, Sendable {
    public var title: String
    public var oneLine: String
    public var timeline: [MeetingSummaryTimelineItem]
    public var keyPoints: [String]
    public var decisions: [MeetingSummaryDecision]
    public var actionItems: [MeetingSummaryActionItem]
    /// 讨论了但没有定论、需要会后跟进确认的问题——决议性纪要惯例里单列,不混进要点。
    public var openQuestions: [String]

    public init(title: String, oneLine: String, timeline: [MeetingSummaryTimelineItem],
               keyPoints: [String], decisions: [MeetingSummaryDecision],
               actionItems: [MeetingSummaryActionItem], openQuestions: [String] = []) {
        self.title = title
        self.oneLine = oneLine
        self.timeline = timeline
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
    }
}

/// 会议纪要的 prompt 构建 + 输出解析。与 `PromptBuilder`(口述整理)分开一个文件:
/// 目标任务完全不同——整理是"最小必要修改",纪要是"大幅压缩重组",复用同一套
/// prompt 层级没有意义,但复用 `PromptBuilder.dictionaryBlock` 做专有名词注入。
public enum MeetingSummaryPromptBuilder {
    /// map 阶段(长会议分块摘要)的系统 prompt。只在转写超过单次调用的合理长度时使用,
    /// 见 `chunkPromptText`。
    public static func buildChunkDigest(dictionary: [String] = []) -> String {
        var parts = [chunkDigestRole]
        if let block = PromptBuilder.dictionaryBlock(dictionary) { parts.append(block) }
        return parts.joined(separator: "\n\n")
    }

    /// reduce 阶段(或转写不长时的单次调用)的系统 prompt,产出最终结构化纪要。
    public static func buildFinalSummary(dictionary: [String] = [], startedAt: Date,
                                         duration: TimeInterval, hasGaps: Bool) -> String {
        var parts = [finalSummaryRole(startedAt: startedAt, duration: duration, hasGaps: hasGaps)]
        if let block = PromptBuilder.dictionaryBlock(dictionary) { parts.append(block) }
        parts.append(outputSchemaBlock)
        return parts.joined(separator: "\n\n")
    }

    /// user message 内容:三重反引号围栏包住转写正文,与 `CleanupService.userContent` 同一约定。
    public static func userContent(transcript: String) -> String {
        "```\n\(transcript)\n```"
    }

    /// 长会议 map-reduce 切分:按 `MeetingTranscript.promptText` 的行结构(一行一句)切,
    /// 绝不在一句话中间断开。`maxChars` 默认 6000——中文会议转写下单次调用仍在合理
    /// 注意力预算内;短会议(整段 <= 6000 字)调用方应直接跳过分块,一次性摘要。
    public static func chunkPromptText(_ text: String, maxChars: Int = 6000) -> [String] {
        guard text.count > maxChars else { return text.isEmpty ? [] : [text] }
        var chunks: [String] = []
        var current: [Substring] = []
        var currentLength = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineLength = line.count + 1
            if currentLength + lineLength > maxChars, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current = []
                currentLength = 0
            }
            current.append(line)
            currentLength += lineLength
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }

    // MARK: - Prompt 正文
    //
    // 设计参考(不照搬任何一家模板,综合后按本 App 场景重写):专业会议纪要惯例把
    // "决议"与"讨论过但未定"分开、待办条目要求 owner+deadline 独立字段而非散文一句话、
    // 严禁在时间/负责人/结论上做无依据的补全——宁可标"未在转写中明确提及",不得编造。

    private static let chunkDigestRole = """
    你是会议纪要助手,正在处理一场长会议转写的其中一段(转写按 [mm:ss] 说话人：内容 逐行给出,\
    可能包含"— 通话打断 —"这类边界提示)。请把这一段压缩成带时间锚点的要点摘要,供后续与其它\
    分段的摘要合并成完整纪要。只输出摘要正文(纯文本,分行列点,每条前保留该点在原文中最早出现的\
    [mm:ss] 时间戳),不输出标题、前后缀或任何解释。遇到边界提示时如实标注"此处有中断",不要把\
    打断前后的内容强行连成因果关系。凡是提到具体人名、金额、日期、承诺事项的地方,原样保留,\
    不要因为压缩摘要而丢失这些细节——它们是后续生成决议/待办条目的原始依据。
    """

    private static func finalSummaryRole(startedAt: Date, duration: TimeInterval, hasGaps: Bool) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日 HH:mm"
        let durationText = Self.durationText(duration)
        let gapNote = hasGaps
            ? "这场会议的转写中存在因中断产生的时间缺口(已用「— 通话打断 —」等标记标出);遇到这类标记时,只说明此处有中断,不要臆测缺失内容,不要把打断前后的话强行编成连续因果。"
            : "这场会议的转写是连续的,没有中断缺口。"
        return """
        你是专业会议纪要撰写助手,服务对象是需要快速回顾长会议、准备下一步行动的投资人/高管,\
        场景可能是投资人电话、董事会、尽调访谈等对准确性要求很高的场合。输入是一份带时间戳、\
        按说话人分行的会议转写。会议开始于 \(df.string(from: startedAt)),时长约 \(durationText)。\(gapNote)

        请通读全文,产出一份忠实、精炼、可直接用于工作汇报或存档的结构化纪要,遵循以下惯例:

        1. 标题概括这场会议的核心主题(如"XX项目Q3投后管理电话会"),不用"会议纪要"这类空泛说法。
        2. 「行程」按时间顺序列出会议实际讨论过的议题节点(不是提前设定的议程),每条带最贴近的\
        [mm:ss] 时间戳、议题名和一两句要点。
        3. 「决议」只收录转写中明确达成一致或明确表态的结论,并标注 status:讨论中已有明确共识/\
        表态记为"已确认";只是提出、尚未有人明确拍板的记为"待定"。不得把"讨论过某个方向"\
        升级成"决议"。
        4. 「待办事项」每条尽量拆出负责人(owner)和截止时间(deadline)两个独立字段——但只有\
        转写里**明确点名**某人负责、或**明确说出**具体时间时才填,没提到就填 null,绝不替发言人\
        指派任务、绝不编造日期。任务本身(task)要具体到可执行的动作,不要"跟进一下"这类空话\
        ——如果转写里确实只说了这么模糊,就照实转述,不要替它加细节。
        5. 「未决问题」收录讨论中提出但没有结论、需要会后确认或跟进的问题,与"决议"分开,\
        不要混在一起。
        6. 「关键要点」是除行程/决议/待办/未决问题之外仍值得记录的信息(数据、立场、风险提示等)。
        7. 说话人标签(如"说话人 1")若转写中出现,可在要点/决议/待办里保留以标明发言归属,\
        但不要杜撰姓名、职务或身份。
        8. 忠实于原文语气与立场,不要替发言人下结论或添加你自己的评价;这份纪要是给人工复核后\
        才对外使用的草稿,不确定的地方标"未在转写中明确提及"比编造更有价值。
        """
    }

    private static let outputSchemaBlock = """
    只输出一个 JSON 对象,不要代码块围栏,不要任何解释或前后缀。JSON 结构:
    {"title": "string", "oneLine": "string(一句话概括,不超过 60 字)",
     "timeline": [{"at": "mm:ss", "topic": "string", "detail": "string"}],
     "keyPoints": ["string"],
     "decisions": [{"text": "string", "status": "已确认" 或 "待定"}],
     "actionItems": [{"task": "string", "owner": "string 或 null", "deadline": "string 或 null"}],
     "openQuestions": ["string"]}
    没有内容的数组给空数组 [],不要省略字段;owner/deadline 没有依据时必须是 null,不是空字符串。
    """

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "\(h) 小时 \(m) 分钟" : "\(m) 分钟"
    }
}

/// 纪要 JSON 输出的解析与兜底校验。不复用 `CleanupService.validatedOutput`——那套"数字/话语
/// 标记不得消失"的保真校验假设与摘要任务(本就要求压缩重组)天然冲突,见调用方注释。
public enum MeetingSummaryParser {
    /// 解析失败(JSON 非法、缺少必要字段)返回 nil,调用方应回退展示 `summaryRaw` 原文,
    /// 而不是空白页。
    public static func parse(_ raw: String) -> MeetingSummary? {
        guard let jsonString = extractJSONObject(from: raw),
              let data = jsonString.data(using: .utf8),
              var summary = try? JSONDecoder().decode(MeetingSummary.self, from: data) else { return nil }

        let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        summary.title = String(title.prefix(40))
        summary.timeline = summary.timeline.filter { isValidTimestamp($0.at) }
        summary.decisions = summary.decisions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        summary.actionItems = summary.actionItems.filter { !$0.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return summary
    }

    /// 剥离 ```json ... ``` / ``` ... ``` 围栏与围栏外的说明性前后文,取第一个 `{` 到
    /// 最后一个匹配的 `}` 之间的内容——模型偶尔会在 JSON 前后加一两句解释。
    private static func extractJSONObject(from raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fenceRange = text.range(of: "```", options: .backwards) {
                text = String(text[..<fenceRange.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else {
            return nil
        }
        return String(text[start...end])
    }

    /// 对应 prompt 里要求的 "mm:ss" 格式(`^\d{1,2}:\d{2}$`)。不引入 NSRegularExpression
    /// 依赖,手写校验足够;格式不对的行程条目直接丢弃,不让整个解析失败。
    private static func isValidTimestamp(_ s: String) -> Bool {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let (minutes, seconds) = (parts[0], parts[1])
        guard (1...2).contains(minutes.count), minutes.allSatisfy(\.isNumber) else { return false }
        guard seconds.count == 2, seconds.allSatisfy(\.isNumber) else { return false }
        return true
    }
}
