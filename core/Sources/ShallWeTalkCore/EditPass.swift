import Foundation

/// 修改模式的一次 LLM 调用结果(语音二次修改-执行方略.md v2 §7)。
/// 安全边界是"可见 diff + 一键撤销",不是自动拒绝——因此没有 `.rejected` 分支,
/// `flaggedLargeChange` 仍然携带可用的新稿,只是要求调用方在 UI 上更醒目地标出来。
public enum EditOutcome: Equatable {
    /// 正常应用的修改稿。
    case applied(String)
    /// 模型判定不出要改什么(显式 `NO_EDIT`、空输出,或输出是回答式元话语开头)。
    /// 红线:这种情况下原稿一字不动,调用方不得写入历史。
    case noEdit
    /// 输出与原文逐字相同——模型"执行了"但实际没有产生任何改动,需要明确提示用户
    /// 而不是让他以为已经改过。
    case unchanged
    /// 输出确实变了,但改动幅度相对修改要求的长度显得异常大。不拒绝,但调用方应在 UI
    /// 上高亮并要求二次确认(§7.3)。
    case flaggedLargeChange(String)
}

/// 修改模式的纯函数安全网(§7)。不复用 `CleanupService.validatedOutput`——那套校验假设
/// "输出应当保真",而修改场景下"把最后一句删掉"这类合法指令必然丢数字、丢话语标记,
/// 会被 100% 误拒。这里只做三件事,且都不自动拒绝改动本身,只分类。
public enum EditGuard {
    /// 回答式开头词表,独立于 `CleanupService.protectedDiscourseMarkers`/元话语词表——
    /// 那两份是"整理稿不该引入的说明文字",这里是"修改模式特有的应答式开头",语义不同,
    /// 不共用避免互相牵连调整。
    static let metaDiscourseOpeners = [
        "好的", "好的,", "好的，", "已为您修改", "已经修改", "修改完成",
        "已将", "我已", "已把", "根据您的要求",
    ]

    /// 幅度阈值:改动字符占原文比例超过此值、且修改要求本身很短(标点/口语化，
    /// 通常不该引出大改)时标记 `flaggedLargeChange`。占位值,需按 §9 真实语料评测调优。
    static let magnitudeRatioThreshold = 0.5
    static let magnitudeShortInstructionThreshold = 15

    /// 三步判定,串联即最终结论。空输出与哨兵同等对待——保留原稿是红线,不因为
    /// 网络抖动/模型异常返回空字符串就当作"没有改动"直接放行。
    public static func evaluate(candidate: String, original: String, instruction: String) -> EditOutcome {
        let output = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, output != "NO_EDIT" else { return .noEdit }
        guard !metaDiscourseOpeners.contains(where: { output.hasPrefix($0) }) else { return .noEdit }

        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output != trimmedOriginal else { return .unchanged }

        let distance = levenshtein(Array(trimmedOriginal), Array(output))
        let ratio = trimmedOriginal.isEmpty ? 1.0 : Double(distance) / Double(trimmedOriginal.count)
        let instructionLength = instruction.trimmingCharacters(in: .whitespacesAndNewlines).count
        if ratio > magnitudeRatioThreshold && instructionLength < magnitudeShortInstructionThreshold {
            return .flaggedLargeChange(output)
        }
        return .applied(output)
    }

    static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: rhs.count)
            for (j, right) in rhs.enumerated() {
                current[j + 1] = min(current[j] + 1, previous[j + 1] + 1,
                                     previous[j] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

/// 修改模式的调用入口:组装 prompt、发起请求、把结果交给 `EditGuard` 判定。
/// prompt 组装与网络调用都在这里,`DictationController`(iOS)只负责录音/状态机与落库。
public enum EditPass {
    /// - Parameters:
    ///   - original: 修改目标的当前稿(`finalText ?? cleanText`)。
    ///   - instruction: 第二次口述的 ASR 原文——必须是原文,不能先过整理 prompt
    ///     (§4.1:整理会把描述式用字"顺"成通顺句,指令当场失真)。
    ///   - llm: 调用方按当前设置构造的 `CleanupService`。
    public static func run(original: String, instruction: String, llm: CleanupService,
                           dictionary: [String] = [],
                           onFirstToken: (@Sendable () -> Void)? = nil,
                           onUsage: (@Sendable (CleanupService.Usage) -> Void)? = nil,
                           onDelta: @escaping (String) -> Void) async throws -> EditOutcome {
        let prompt = PromptBuilder.buildEditPass(dictionary: dictionary)
        // thinking 开(2026-08-19,用户明确要求,与去掉纠错对块同时定案):真机复现里
        // 单独打开思考模式,即便 system prompt 仍带纠错对块,模型也能正确执行修改
        // (对照 buildEditPass 去掉纠错对块的注释)。两处改动一起留下,当作双重保险——
        // 万一以后又有内容注入进这份 prompt 重新触发同一种过度保守,思考模式兜底。
        // 代价是延迟(超时相应从 90s 提到 180s,见 cleanStream)与 temperature=0
        // 失效(DeepSeek 思考模式下静默忽略 temperature),换确定性执行的可靠性。
        let candidate = try await llm.cleanStream(
            raw: instruction, systemPrompt: prompt, thinking: .enabled,
            onFirstToken: onFirstToken, onUsage: onUsage, forbidsNewNumbers: false,
            validate: false,
            userContentOverride: CleanupService.editUserContent(original: original, instruction: instruction),
            onDelta: onDelta)
        return EditGuard.evaluate(candidate: candidate, original: original, instruction: instruction)
    }
}
