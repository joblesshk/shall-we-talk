import Foundation

/// 对 `PromptBuilder.build(...)` 渲染出的最终文本做"消融手术"——删掉某个功能模块对应的
/// 规则文字(含它在开头任务总纲句、判断标准、共享示例池里的所有印迹),其余原样不动。
///
/// 只操作渲染后的字符串,不改 `PromptBuilder.swift` 本身:那些规则常量(`l1Base`、
/// `filledPauseRules` 等)都是 internal/private,这个实验工具是独立 target,本来就看不到,
/// 只能拿 `PromptBuilder.build(...)` 返回的最终字符串做手术——这也符合这一轮"不碰生产
/// prompt 逻辑,只在工程工具里做对比"的范围。
///
/// 每处删除都先断言目标文本存在且唯一,找不到就直接抛错——防止 `PromptBuilder` 的措辞
/// 改了之后,消融逻辑悄悄切错地方却不报错,参照文件里已有的 `legacyFullPrompt` 同一手法。
///
/// 只覆盖长文路由(`PromptBuilder.build`,即 `l1Base` + `structureRules`)——这是生产流量
/// 最大、规则最密的路由,短路由(`buildShortHomophone`)这一轮不在范围内。
///
/// 不消融的底盘:规则 3(保真边界)、规则 4(专名保护)——这两条是安全护栏,关掉没有
/// "测效果"的意义。
enum CleanupModule: String, CaseIterable {
    case homophoneCorrection
    case filledPauseRemoval
    case repetitionAndSelfCorrection
    case wordOrderRepair
    case misusedWordCorrection
    case structuring

    var displayName: String {
        switch self {
        case .homophoneCorrection: return "同音/近音纠错(规则1)"
        case .filledPauseRemoval: return "停顿音删除(规则2)"
        case .repetitionAndSelfCorrection: return "自我修正/重复删除(规则6+7)"
        case .wordOrderRepair: return "异常语序修复(规则8)"
        case .misusedWordCorrection: return "用词纠正(规则9)"
        case .structuring: return "分段编号(structureRules)"
        }
    }
}

struct PromptAblationError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum PromptAblation {
    static func ablate(_ prompt: String, removing module: CleanupModule) throws -> String {
        switch module {
        case .homophoneCorrection: return try ablateHomophone(prompt)
        case .filledPauseRemoval: return try ablateFilledPause(prompt)
        case .repetitionAndSelfCorrection: return try ablateRepetition(prompt)
        case .wordOrderRepair: return try ablateWordOrder(prompt)
        case .misusedWordCorrection: return try ablateMisusedWord(prompt)
        case .structuring: return try ablateStructuring(prompt)
        }
    }

    // MARK: - 通用手术工具

    private static func removeOnce(_ text: String, exact target: String, replacement: String = "") throws -> String {
        let occurrences = text.components(separatedBy: target).count - 1
        guard occurrences == 1 else {
            throw PromptAblationError(message:
                "消融标记出现 \(occurrences) 次(应为 1):\(target.prefix(50))…")
        }
        guard let range = text.range(of: target) else {
            throw PromptAblationError(message: "消融标记未找到:\(target.prefix(50))…")
        }
        var result = text
        result.replaceSubrange(range, with: replacement)
        return result
    }

    private static func removeBetween(_ text: String, start: String, end: String) throws -> String {
        guard let startRange = text.range(of: start) else {
            throw PromptAblationError(message: "消融起始标记未找到:\(start.prefix(50))…")
        }
        guard let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
            throw PromptAblationError(message: "消融结束标记未找到(在起始标记之后):\(end.prefix(50))…")
        }
        var result = text
        result.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        return collapseBlankLines(result)
    }

    /// 删完一段之后常会留下三个以上连续换行(段落间空行 + 被删段落本来的空行叠加),
    /// 统一收成两个换行(一个空行的段落间隔),避免 prompt 里出现异常大段空白。
    private static func collapseBlankLines(_ text: String) -> String {
        var result = text
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result
    }

    // MARK: - 开头任务总纲句:四个"headline 模块"(同音纠错②停顿删除③分段④用词纠正)
    // 各自的改写版本。规则 6/7/8(自我修正/重复、句内同位替换、异常语序)不在总纲句里
    // 被点名,消融它们不需要动这句。

    private static let originalSummary = """
    本轮的处理方针是“ASR 音近纠错优先”。你有四项明确任务，每次都必须逐项执行:①根据发音、句法与上下文，纠正同音字、近音字、词边界错分以及中英文近音误识别(首要任务)；②删除纯发声停顿(必做，不是可选的润色)；③按不同意思分段，并把枚举内容整理为编号列表——既包括作者已明确口述序号的，也包括命中分段规则必编位的隐性并列枚举；④改正明显用错的词。四项任务都不等于激进改写：所有修改都必须通过保真边界，只做准确、通顺、易读所必需的最小修改，只输出整理后的正文。
    """

    private static func replaceSummary(_ text: String, with newSummary: String) throws -> String {
        try removeOnce(text, exact: originalSummary, replacement: newSummary)
    }

    // MARK: - homophoneCorrection(规则 1)

    private static func ablateHomophone(_ prompt: String) throws -> String {
        let text = try replaceSummary(prompt, with: """
        本轮的处理方针是“最小必要修改”。你有三项明确任务，每次都必须逐项执行:①删除纯发声停顿(必做，不是可选的润色)；②按不同意思分段，并把枚举内容整理为编号列表——既包括作者已明确口述序号的，也包括命中分段规则必编位的隐性并列枚举；③改正明显用错的词。三项任务都不等于激进改写：所有修改都必须通过保真边界，只做准确、通顺、易读所必需的最小修改，只输出整理后的正文。
        """)
        return try removeHomophoneBody(text)
    }

    /// 只删规则 1 正文 + 它的专属示例,不动总纲句——单独消融时总纲句由调用方各自的
    /// 版本处理;这里拆出来是为了给"同时消融 homophoneCorrection + misusedWordCorrection"
    /// 这种组合消融复用,组合场景的总纲句要一次性改完,不能先套用单模块的版本再改一遍
    /// (单模块版本已经把总纲句里对方那一项写回去了,再删一次会找不到标记)。
    private static func removeHomophoneBody(_ prompt: String) throws -> String {
        var text = prompt
        text = try removeBetween(text,
            start: "1. ASR 同音近音纠错(首要任务):",
            end: "若两种理解都合理、仅凭常识猜测、或修改会改变事实与立场，必须保留原文。")
        text = try removeBetween(text,
            start: "“谷歌，我是一只做多的呀” → “谷歌，我是一直做多的呀”",
            end: "“他去彪马的脱口秀” → 没有其他证据时，不得因品牌 PUMA 知名而改成 PUMA")
        return text
    }

    // MARK: - filledPauseRemoval(规则 2)

    private static func ablateFilledPause(_ prompt: String) throws -> String {
        var text = try replaceSummary(prompt, with: """
        本轮的处理方针是“ASR 音近纠错优先”。你有三项明确任务，每次都必须逐项执行:①根据发音、句法与上下文，纠正同音字、近音字、词边界错分以及中英文近音误识别(首要任务)；②按不同意思分段，并把枚举内容整理为编号列表——既包括作者已明确口述序号的，也包括命中分段规则必编位的隐性并列枚举；③改正明显用错的词。三项任务都不等于激进改写：所有修改都必须通过保真边界，只做准确、通顺、易读所必需的最小修改，只输出整理后的正文。
        """)
        text = try removeBetween(text,
            start: "2. 删除纯发声停顿(必做):",
            end: "“我都唔知佢点样分” → 粤语否定词,原样保留")
        text = try removeBetween(text,
            start: "与规则 2 的边界:",
            end: "判不准时看删除后是否改变了转折、立场或语气:改变则保留，只是少了一个发声则删除。")
        text = try removeOnce(text,
            exact: "- 命中规则 2 的必删位置:删除，不再要求额外证据。\n",
            replacement: "")
        text = try removeBetween(text,
            start: "“时间有点紧啊” → 原样保留，句末语气词",
            end: "“时间啊有点紧” → “时间有点紧”(“啊”占据停顿位)")
        return text
    }

    // MARK: - repetitionAndSelfCorrection(规则 6+7)
    //
    // 判断标准里第 2、3 条("删除后只消除口吃或被替代版本…" / "同一位置只能容纳一个答案…")
    // 没有点名具体规则号,写得足够通用,规则 2(停顿)、6、7 都会用到——不专属这个模块,
    // 消融时保留不动,避免误伤其他还在生效的规则。

    private static func ablateRepetition(_ prompt: String) throws -> String {
        var text = prompt
        text = try removeBetween(text,
            start: "6. 处理自我修正与重复:",
            end: "只有明确要双语并列时才同时保留。")
        text = try removeBetween(text,
            start: "“这个、这个方案我们下周再谈” → “这个方案我们下周再谈”",
            end: "“这个方案我们下周再谈” → 原样保留，“这个”有所指")
        text = try removeBetween(text,
            start: "“我想问能不能用个人名义打款，我想问能不能用 BVI 公司名义打款” → “我想问能不能用 BVI 公司名义打款”",
            end: "“基金这个月的 Monthly Statement 月结报告发了吗” → “基金这个月的月结报告发了吗”")
        return text
    }

    // MARK: - wordOrderRepair(规则 8)

    private static func ablateWordOrder(_ prompt: String) throws -> String {
        var text = prompt
        text = try removeBetween(text,
            start: "8. 修复异常语序与最小校对:",
            end: "不得合成原文不存在的第三种意思。")
        text = try removeOnce(text,
            exact: "“我明天去应该公司处理” → “我明天应该去公司处理”\n",
            replacement: "")
        return text
    }

    // MARK: - misusedWordCorrection(规则 9,无外部引用,最干净)

    private static func ablateMisusedWord(_ prompt: String) throws -> String {
        let text = try replaceSummary(prompt, with: """
        本轮的处理方针是“ASR 音近纠错优先”。你有三项明确任务，每次都必须逐项执行:①根据发音、句法与上下文，纠正同音字、近音字、词边界错分以及中英文近音误识别(首要任务)；②删除纯发声停顿(必做，不是可选的润色)；③按不同意思分段，并把枚举内容整理为编号列表——既包括作者已明确口述序号的，也包括命中分段规则必编位的隐性并列枚举。三项任务都不等于激进改写：所有修改都必须通过保真边界，只做准确、通顺、易读所必需的最小修改，只输出整理后的正文。
        """)
        return try removeMisusedWordBody(text)
    }

    /// 只删规则 9 正文 + 它的专属示例,不动总纲句——理由同 `removeHomophoneBody`。
    private static func removeMisusedWordBody(_ prompt: String) throws -> String {
        try removeBetween(prompt,
            start: "9. 改正明显用错的词:",
            end: "“他做菜惨不忍睹” → 原样保留")
    }

    // MARK: - 组合消融:homophoneCorrection + misusedWordCorrection 一起关掉
    //
    // 用户明确要求的组合:同音/近音纠错 + 用词纠正一起关掉,和原版 prompt 对比。
    // 总纲句只能改一次(改成只剩②停顿删除③分段编号两项),不能先套单模块版本再叠加,
    // 否则第二次 removeOnce 会因为总纲句已经不是 originalSummary 而找不到标记。
    static func ablateHomophoneAndMisusedWord(_ prompt: String) throws -> String {
        var text = try replaceSummary(prompt, with: """
        本轮的处理方针是“最小必要修改”。你有两项明确任务，每次都必须逐项执行:①删除纯发声停顿(必做，不是可选的润色)；②按不同意思分段，并把枚举内容整理为编号列表——既包括作者已明确口述序号的，也包括命中分段规则必编位的隐性并列枚举。两项任务都不等于激进改写：所有修改都必须通过保真边界，只做准确、通顺、易读所必需的最小修改，只输出整理后的正文。
        """)
        text = try removeHomophoneBody(text)
        text = try removeMisusedWordBody(text)
        return text
    }

    // MARK: - 组合消融(加强版):在上面的基础上,把规则 1、规则 9 里"证据不足/理解
    // 不确定就保留原文"这条边界语言并入规则 3,防止总纲句任务数变少之后模型在模糊
    // 输入上过度删改。
    //
    // 起因(2026-08-16 用户实测发现):普通组合消融跑真实语料时,有一条录音后半句是
    // "你帮我改成原本那句话改一下,保持原本的文言风格和用词不变"——这种像是对着模型
    // 下指令的内容,baseline 正确地当正文保留,组合消融却把它整句删掉了。规则 3 自己
    // 虽然也有保真边界,但没有显式写"证据不足/两种理解都合理时必须保留"这条决策
    // 原则——这条原则原本分别写在规则 1("若两种理解都合理...必须保留原文")和规则 9
    // ("证据不足时一律保留原词")里,被这两条规则一起带走了。这里把这条原则、以及规则 9
    // 里"不做文明用语替换"那条边界,一并搬进规则 3,同时去掉规则 3 里"唯一例外是规则 9"
    // 这个悬空引用(规则 9 已经不存在,那个例外也不该再提)。
    static func ablateHomophoneAndMisusedWordReinforced(_ prompt: String) throws -> String {
        var text = try replaceSummary(prompt, with: """
        本轮的处理方针是“最小必要修改”。你有两项明确任务，每次都必须逐项执行:①删除纯发声停顿(必做，不是可选的润色)；②按不同意思分段，并把枚举内容整理为编号列表——既包括作者已明确口述序号的，也包括命中分段规则必编位的隐性并列枚举。两项任务都不等于激进改写：所有修改都必须通过保真边界，只做准确、通顺、易读所必需的最小修改，只输出整理后的正文。
        """)
        text = try removeHomophoneBody(text)
        text = try removeMisusedWordBody(text)
        text = try removeOnce(text,
            exact: "3. 保留内容与作者声音:不得改变事实、观点、态度、情绪、强调、否定、条件、例外、数字、日期、金额、公式、人名和中英混说；保留原有用词、正式程度与表达习惯，不润色、不总结、不压缩、不擅自补充(唯一例外是规则 9 的明显用错的词)。阿拉伯数字必须逐个原样复制，不得舍入、计算、更换小数位或把它改成你认为更正确的数字。可删除数字内明显的误触空格，可在不改动数字本身时补足上下文已明确的单位或百分号；中文口述的版本号可规范为 V5 等常用写法。代号和公式只能根据原文内部的明确重说或强上下文修复，不得凭知识补齐。",
            replacement: "3. 保留内容与作者声音:不得改变事实、观点、态度、情绪、强调、否定、条件、例外、数字、日期、金额、公式、人名和中英混说；保留原有用词、正式程度与表达习惯，不润色、不总结、不压缩、不擅自补充。任何修改都必须有充分证据支持:两种理解都合理、仅凭常识或猜测、或证据不足时，一律保留原文，不得改动。不做文明用语替换:粗话、脏话、口头禅、贬义词都是作者的表达方式，不是错误，一律原样保留，绝不替换、绝不删除、绝不弱化。阿拉伯数字必须逐个原样复制，不得舍入、计算、更换小数位或把它改成你认为更正确的数字。可删除数字内明显的误触空格，可在不改动数字本身时补足上下文已明确的单位或百分号；中文口述的版本号可规范为 V5 等常用写法。代号和公式只能根据原文内部的明确重说或强上下文修复，不得凭知识补齐。")
        return text
    }

    // MARK: - structuring(structureRules,由 l2() 拼接在 l1Base 之后,不属于 l1Base
    // 自己的 9 条编号规则)

    private static func ablateStructuring(_ prompt: String) throws -> String {
        var text = try replaceSummary(prompt, with: """
        本轮的处理方针是“ASR 音近纠错优先”。你有三项明确任务，每次都必须逐项执行:①根据发音、句法与上下文，纠正同音字、近音字、词边界错分以及中英文近音误识别(首要任务)；②删除纯发声停顿(必做，不是可选的润色)；③改正明显用错的词。三项任务都不等于激进改写：所有修改都必须通过保真边界，只做准确、通顺、易读所必需的最小修改，只输出整理后的正文。
        """)
        text = try removeBetween(text,
            start: "分段规则:",
            end: "“我今天去了公司，处理完合同又跑了一趟银行。” → 例外位 (d)，同一主语的连续动作，叙事推进，不编号")
        return text
    }
}
