import Foundation

public enum CleanupPromptRoute: Equatable, Sendable {
    /// 短口述：用精简版 prompt 改写成通顺文字，但不提分段/编号(`buildSimple()`)。
    case homophoneOnly
    /// 长口述：使用“最全版 Prompt”，合并旧长文基础与完整分段规则(`buildMostComplete()`)。
    case full
    /// ASR 原文出现成组列举提示词：不受录音时长限制，在最全版长口述
    /// prompt 上追加强化序号规则，不再用列举 prompt 替换最全版。
    case explicitEnumeration
}

/// iOS 与 macOS 共用的口述后处理产品规则。
public enum DictationPolicy {
    /// 没有成组列举信号时，达到该录音时长后 prompt 才会要求分段与编号；更短的录音
    /// 仍用同一份精简版 prompt 做改写，只是不提这项要求。
    ///
    /// 2026-08-05 由 20 秒下调为 10 秒(彼时短路由用的是另一份更保守的同音纠错专用
    /// prompt，明确禁止分段编号)。依据:1215 条历史里短(<40 字)与中(40–99 字)两桶
    /// 合计 1107 条(91% 的使用量)落在阈值以下，这批的编号数为 0，用户实际的分段编号
    /// 意愿因此几乎全部落空。下调阈值是唯一能把这批量拉进编号路由的开关。
    /// 2026-08-29 起，重档的 ASR 定稿出现成组列举信号时会跳过这项时长判断。
    /// 2026-08-30 起，轻档始终使用短口述 prompt；重档的长口述使用“最全版 Prompt”。
    public static let defaultFullCleanupThresholdSeconds: TimeInterval = 10
    public static let fullCleanupThresholdRange: ClosedRange<TimeInterval> = 1...120
    /// 非分段的首次整理最长等待时间；超时后保留完整 ASR 原文。
    public static let directCleanupTimeoutSeconds: TimeInterval = 12

    /// 空格、换行和标点不计入产品语义中的“有效字符”。
    public static func meaningfulCharacterCount(_ text: String) -> Int {
        let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return text.unicodeScalars.reduce(into: 0) { count, scalar in
            if !ignored.contains(scalar) { count += 1 }
        }
    }

    /// 与 `PromptBuilder.filledPauseRules` 的闭合词表保持一致的纯发声停顿。
    /// 只用于"整段是否只有停顿音"的判定,不做句内删除——句内删除是 LLM 的活。
    private static let filledPauseTokens = [
        "嗯", "呃", "额", "唔", "哦", "诶", "唉",
        "uhm", "hmm", "um", "uh", "er", "ah", "mm",
    ]

    /// 整段口述除了纯发声停顿和标点之外没有任何内容。
    ///
    /// 这类录音(历史里出现过多次整段只有"嗯。")按 `filledPauseRules` 会被 LLM 删空,
    /// 而空结果会被兜底逻辑回退成 ASR 原文,反而把"嗯。"插进用户正在编辑的文档。
    /// 在调用 LLM 之前判定,既避免这次插入,也省掉一次没有意义的整理请求。
    ///
    /// 判定按整段计算,不按单字:"唔知"剩下"知"、"金额"剩下"金",都不算纯停顿。
    public static func isPureFilledPause(_ text: String) -> Bool {
        var rest = text.lowercased()
        for token in filledPauseTokens {
            rest = rest.replacingOccurrences(of: token, with: "")
        }
        return meaningfulCharacterCount(rest) == 0 && meaningfulCharacterCount(text) > 0
    }

    // MARK: - 空转守门员

    /// 判为"整理必定原样返回"的字数上限。
    ///
    /// 依据 2026-08-16 iPhone 快照 394 次真实整理请求(`开发数据/真实语音评测/`):
    /// 10–20 字桶的空转率 93%、20–30 字 88%、30–40 字 52%,40 字以后掉到 42% 并继续下滑。
    /// 40 是"还能保住九成纯度"的最后一档;再放宽纯度就开始塌。
    public static let redundantCleanupCharacterLimit = 40

    /// 句内出现即判定"整理一定会动手"的纯发声停顿。
    ///
    /// **刻意窄于 `filledPauseTokens`**:那份表服务于 `isPureFilledPause` 的整段判定,
    /// 可以安全地包含"额""唔"——整段扣掉它们还剩内容就不算纯停顿。但这里是**句内**命中,
    /// "额"会在"金额""余额""额度"上误触发,对一个大量口述投资内容的用户等于废掉覆盖率。
    /// 同理不含 "um"/"uh" 等英文形式:它们是 `hmm` 这类词的子串,句内匹配噪声太大。
    /// 误拦的代价只是照常发一次请求(即现状),所以这里宁窄勿宽的方向是**反的**——
    /// 窄表意味着更多放行,因此每一个字都必须是"出现即几乎必然被删"的。
    private static let inlineFilledPauseMarkers: Set<Character> = [
        "嗯", "呃", "唉", "诶", "哦", "噢", "啊",
    ]

    /// 文本里是否存在重复片段。
    ///
    /// 两种形态都要认:紧邻重复("测试测试"),以及被标点或空格隔开的相邻同词
    /// ("Social, social, social." → "Social.")。只认第一种时,后者是全样本里最严重的
    /// 一次漏判(相似度 0.467);补上第二种把它消掉且不损失任何覆盖率。
    static func containsRepeatedFragment(_ text: String) -> Bool {
        let chars = Array(text)
        // 紧邻重复:2–6 字的片段与其后紧接的同长片段相同。
        if chars.count >= 4 {
            for length in 2...6 where chars.count >= length * 2 {
                for start in 0...(chars.count - length * 2) where
                    Array(chars[start..<(start + length)]) == Array(chars[(start + length)..<(start + length * 2)]) {
                    return true
                }
            }
        }
        // 隔开的相邻同词:按空白与标点切分后,相邻两段相同。
        let tokens = text.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation || sentenceEnds.contains($0) })
            .filter { $0.count >= 2 }
        for index in tokens.indices.dropLast() where tokens[index] == tokens[index + 1] {
            return true
        }
        return false
    }

    /// 文本疑似把用户词典里的多词词条说岔了。
    ///
    /// 词典里"Disruptive II"这类条目,ASR 常写成"Disruptive two"。首词出现、完整词条却
    /// 没出现,就是一次几乎确定的改写。这条是**确定性**信号而不是统计特征:用户手工维护
    /// 词典就是为了让它生效,因为词典没命中而静默跳过整理,等于让词典白配。
    /// 只看多词词条——单词条目("Claude""IBKR")无法用"首词出现"这个形状判断。
    static func mentionsIncompleteDictionaryTerm(_ text: String, dictionaryWords: [String]) -> Bool {
        let haystack = text.lowercased()
        for term in dictionaryWords {
            let parts = term.split(separator: " ").filter { !$0.isEmpty }
            guard parts.count > 1 else { continue }
            let lowered = term.lowercased()
            guard let head = parts.first?.lowercased() else { continue }
            if haystack.contains(head), !haystack.contains(lowered) { return true }
        }
        return false
    }

    /// LLM 文字整理是否会原样返回——为真时可以直接采用 ASR 原文,不发这次请求。
    ///
    /// **为什么需要它**:2026-08-16 iPhone 快照里 394 次整理请求有 268 次(68%)输出与输入
    /// 逐字节相同,每次白等 0.87 秒。这不是延迟问题,是把一个九成情况下无事可做的判断
    /// 交给了链路上最慢的一环。
    ///
    /// **误判代价是不对称的,这是本判定敢于放行的全部依据**:
    /// - 放行错了(其实该整理)→ 用户看到未整理文本。而全样本里整理前后的中位字数变化是 −1 字,
    ///   126 条真实改动中 61% 的相似度 >0.95。代价是"少删了一个'嗯'"这个量级。
    /// - 拦错了(其实是空转)→ 白等 0.87 秒,也就是现状。
    /// 所以四道闸门全部只在"出现即几乎必然被改写"时才拦,宁可放行。
    ///
    /// **实测(按时间切分留出验证,训练 236 / 留出 158)**:
    /// 覆盖 52%、纯度 91%、期望省下 0.45 秒;全部 394 条里判为空转却相似度 <0.90 的只有 1 条。
    /// 留出集与训练集的覆盖/纯度差 <1pp,不是过拟合。
    ///
    /// - Parameters:
    ///   - text: ASR 终稿。必须是终稿而不是中间结果——中间稿与终稿逐字一致率只有 35.3%。
    ///   - dictionaryWords: `settings.dictionaryWords`,用于多词词条的近似命中判定。
    ///   - corrections: 有效纠错对(手工 + 学习,已按屏蔽名单过滤,即
    ///     `DictionarySyncCoordinator.effectiveCorrections` 的结果)。完整命中任意一条
    ///     的源片段时必须交给整理执行——用户已经明确确认过这条纠错,空转守门员不能
    ///     绕过它(2026-09-06 回归审查 #3)。
    ///   - customInstruction: 用户自定义整理要求(`settings.customPrompt`)。非空白时
    ///     保守地不跳过,因为本地启发式无法判断这条要求是否已经满足。
    public static func cleanupIsRedundant(
        _ text: String, dictionaryWords: [String] = [],
        corrections: [LearnedCorrection] = [], customInstruction: String? = nil
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // ⓪ 用户已确认的纠错对完整命中源片段:整理是唯一会执行这条替换的地方,
        //    跳过就等于让已配置的纠错规则永久失效。
        guard !containsActionableCorrection(trimmed, corrections: corrections) else { return false }
        // ⓪ 存在非空白自定义整理要求:本地启发式没有能力判断这条要求是否已经满足,
        //    保守地一律不跳过,交给整理执行。
        guard (customInstruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        // ① 长度。超过上限后空转率跌破一半,再放行就是在赌。
        guard trimmed.count <= redundantCleanupCharacterLimit else { return false }
        // ② 纯发声停顿。出现即必删,是整理最高频的一类动作。
        guard !trimmed.contains(where: { inlineFilledPauseMarkers.contains($0) }) else { return false }
        // ③ 重复片段。口述改口("测试测试")整理时会合并。
        guard !containsRepeatedFragment(trimmed) else { return false }
        // ④ 成组列举信号。用户明确说了"第一/第二",整理要统一编号,与长度无关。
        guard !containsExplicitEnumerationSignals(trimmed) else { return false }
        // ⑤ 词典多词词条说岔。确定性信号,见 `mentionsIncompleteDictionaryTerm`。
        guard !mentionsIncompleteDictionaryTerm(trimmed, dictionaryWords: dictionaryWords) else { return false }
        return true
    }

    /// 文本是否完整包含某条有效纠错对的源片段。匹配规则与 `ManualCorrections.apply`
    /// 的确定性替换保持一致:大小写不敏感的整段包含,不拆字、不做模糊匹配、不做
    /// 未经验证的全局替换。跳过 source 为空或 source == target 的无效项。
    static func containsActionableCorrection(_ text: String, corrections: [LearnedCorrection]) -> Bool {
        corrections.contains { pair in
            !pair.source.isEmpty && pair.source != pair.target
                && text.range(of: pair.source, options: .caseInsensitive) != nil
        }
    }

    /// 句末标点。切段、停顿提交与自动停录共用同一套判定,避免三处各写一份而漂移。
    ///
    /// 必须同时含全角与半角:ASR 开着 `enable_punc`,中文口述回来的是全角 ！？；,
    /// 只有夹带英文时才出现半角。2026-08-05 发现原集合里的全角 ！？； 在某次改动中被
    /// 替换成了半角同形字,`Set` 去重后实际只剩 `。 ! ? ;` 四个——以 ？或 ！ 结尾的句子
    /// 从来不被认作句末,`ingest()` 只能在 。 处切段。这里改用 Unicode 转义写死,
    /// 不再依赖肉眼分辨全角/半角字形。改动本集合必须同时更新 `sentenceEndsCoverBothWidths` 测试。
    public static let sentenceEnds: Set<Character> = [
        "\u{3002}", // 。表意句号
        "\u{FF01}", // ！全角感叹号
        "\u{FF1F}", // ？全角问号
        "\u{FF1B}", // ；全角分号
        "!", "?", ";",
    ]

    /// 半句话中间的停顿放宽静音预算的倍数,同时也是硬上限
    /// (ASR 迟迟不给句末标点时不至于永不结束)。
    public static let unfinishedSentenceGraceMultiplier: Double = 2.5

    /// 已说到句末标点(忽略尾部空白)。空文本按"未说完"处理。
    public static func endsAtSentenceBoundary(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return sentenceEnds.contains(last)
    }

    /// 停顿是否应当结束录音。
    ///
    /// 一句话说完之后的停顿是真的说完了;半句话中间的停顿通常是在想下半句怎么说
    /// (用户 2026-08-05 反馈:"我经常在思考一句话的下半句该怎么说时停顿相当长的时间"),
    /// 对两者用同一个阈值会把话拦腰截断。因此未说完整句时把静音预算放宽到
    /// `unfinishedSentenceGraceMultiplier` 倍;到了这个倍数仍无句末标点则照常结束,
    /// 避免 ASR 不吐标点时录音永不停止。
    public static func shouldAutoStop(silence: TimeInterval, threshold: TimeInterval,
                                      transcriptSoFar: String) -> Bool {
        guard silence >= threshold else { return false }
        if silence >= threshold * unfinishedSentenceGraceMultiplier { return true }
        return endsAtSentenceBoundary(transcriptSoFar)
    }

    public static func normalizedFullCleanupThreshold(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, fullCleanupThresholdRange.lowerBound), fullCleanupThresholdRange.upperBound)
    }

    /// 能可靠表示口述者正在列举同层事项的成组提示词。必须按顺序同时出现一组，
    /// 单独一句“首先”或“第一”不触发；具体是否属于“第一名”“第二次”等普通词义，
    /// 交给强化 prompt 在上下文中裁决，避免路由器靠脆弱的词尾黑名单猜语义。
    private static let explicitEnumerationSignalPairs: [(String, String)] = [
        ("第一", "第二"),
        ("首先", "其次"),
        ("一是", "二是"),
        ("其一", "其二"),
    ]

    /// ASR 原文是否按先后顺序包含至少一组成对的列举提示词。
    public static func containsExplicitEnumerationSignals(_ transcript: String) -> Bool {
        explicitEnumerationSignalPairs.contains { first, second in
            guard let firstRange = transcript.range(of: first) else { return false }
            return transcript.range(of: second, range: firstRange.upperBound..<transcript.endIndex) != nil
        }
    }

    /// 轻档始终返回短口述 prompt。重档先看 ASR 定稿里的成组列举信号，
    /// 再以真实录音时长路由 prompt。成组信号覆盖 10 秒阈值；没有成组信号时，
    /// 恰好达到阈值仍视为普通长口述。
    public static func cleanupPromptRoute(
        recordingDuration: TimeInterval,
        transcript: String = "",
        fullCleanupThresholdSeconds: TimeInterval = defaultFullCleanupThresholdSeconds,
        forceShortPrompt: Bool = false
    ) -> CleanupPromptRoute {
        if forceShortPrompt { return .homophoneOnly }
        if containsExplicitEnumerationSignals(transcript) { return .explicitEnumeration }
        let duration = max(0, recordingDuration)
        let threshold = normalizedFullCleanupThreshold(fullCleanupThresholdSeconds)
        return duration < threshold ? .homophoneOnly : .full
    }

    public nonisolated static func withTimeout<T: Sendable>(
        seconds: TimeInterval = directCleanupTimeoutSeconds,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let race = CleanupDeadlineRace<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)
                let work = Task {
                    guard !Task.isCancelled else { race.resolve(nil); return }
                    race.resolve(await operation())
                }
                let timer = Task {
                    do {
                        let delay = seconds.isFinite ? max(0, min(seconds, 86_400)) : 0
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        race.resolve(nil)
                    } catch { }
                }
                race.installTasks([work, timer])
            }
        } onCancel: { race.resolve(nil) }
    }
}

/// Resume once without waiting for an I/O operation that ignores cancellation.
/// Installation is race-safe even when the caller is already cancelled.
private final class CleanupDeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private var result: Value?
    private var continuation: CheckedContinuation<Value?, Never>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<Value?, Never>) {
        lock.lock()
        if resolved {
            let value = result
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func installTasks(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        let cancel = resolved
        if !cancel { self.tasks = tasks }
        lock.unlock()
        if cancel { tasks.forEach { $0.cancel() } }
    }

    func resolve(_ value: Value?) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        result = value
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(returning: value)
    }
}
