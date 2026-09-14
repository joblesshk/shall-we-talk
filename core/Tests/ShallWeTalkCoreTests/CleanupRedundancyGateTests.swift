import XCTest
@testable import ShallWeTalkCore

/// 空转守门员(`DictationPolicy.cleanupIsRedundant`)。
///
/// 用例分两类:形状用例(每道闸门单独成立),以及从 2026-08-16 iPhone 快照真实样本
/// 固化下来的回归用例。后者是这套阈值当初被选中的依据,改动闸门必须先看它们还过不过。
final class CleanupRedundancyGateTests: XCTestCase {

    // MARK: 放行(判定为空转)

    func testShortCleanChineseIsRedundant() {
        // 10–20 字桶实测空转率 93%,是覆盖率的主要来源。
        XCTAssertTrue(DictationPolicy.cleanupIsRedundant("明天下午三点开会，地点在会议室。"))
    }

    func testMixedScriptStaysRedundantWhenNothingElseTriggers() {
        // 中英混排本身不拦:样本里含拉丁字母的空转率仍有 54%,
        // 真正该拦的是词典说岔(见下面的 Disruptive 用例),而不是"有英文"这个形状。
        XCTAssertTrue(DictationPolicy.cleanupIsRedundant("这不是 ETF 没有损耗。"))
    }

    func testDictionaryTermSpelledCorrectlyStaysRedundant() {
        // 完整词条已经出现,没有可改的,照常放行。
        XCTAssertTrue(DictationPolicy.cleanupIsRedundant(
            "Disruptive II 的账户。", dictionaryWords: ["Disruptive II"]))
    }

    // MARK: 拦截(必须发 LLM 请求)

    func testInlineFilledPauseBlocks() {
        XCTAssertFalse(DictationPolicy.cleanupIsRedundant("嗯，我觉得这个方案可以做。"))
        XCTAssertFalse(DictationPolicy.cleanupIsRedundant("这个呃有点问题。"))
    }

    func testFinancialVocabularyIsNotMistakenForFilledPause() {
        // "额"刻意不在句内停顿表里:金额/余额/额度会误触发,而这位用户大量口述投资内容。
        // 这条用例锁住那个取舍,防止有人"顺手"把 filledPauseTokens 整份搬过来。
        XCTAssertTrue(DictationPolicy.cleanupIsRedundant("这笔金额和余额对不上。"))
    }

    func testAdjacentRepeatBlocks() {
        XCTAssertFalse(DictationPolicy.cleanupIsRedundant("测试测试测试。"))
    }

    func testRepeatSeparatedByPunctuationBlocks() {
        // 真实样本:"Social, social, social." → "Social."(相似度 0.467),
        // 是全样本里最严重的一次漏判。只认紧邻重复时它会被放行。
        XCTAssertFalse(DictationPolicy.cleanupIsRedundant("Social, social, social."))
    }

    func testIncompleteDictionaryTermBlocks() {
        // 真实样本:"Disruptive two 的账户。" → "Disruptive II 的账户。"
        XCTAssertFalse(DictationPolicy.cleanupIsRedundant(
            "Disruptive two 的账户。", dictionaryWords: ["Disruptive II"]))
    }

    func testSingleWordDictionaryEntryDoesNotBlock() {
        // 单词条目没有"首词出现但整条没出现"这个形状,不能拿来拦截,
        // 否则词典里每多一个词就少一批放行。
        XCTAssertTrue(DictationPolicy.cleanupIsRedundant(
            "帮我把 Claude 打开。", dictionaryWords: ["Claude", "IBKR"]))
    }

    func testEnumerationSignalsBlockRegardlessOfLength() {
        // 成组列举要统一编号,与字数无关——这条比长度闸门更靠后但独立成立。
        let text = "第一是预算，第二是工期。"
        XCTAssertLessThanOrEqual(text.count, DictationPolicy.redundantCleanupCharacterLimit)
        XCTAssertFalse(DictationPolicy.cleanupIsRedundant(text))
    }

    func testAtLengthLimitStillRedundant() {
        // 上限本身算放行(<=),避免阈值语义在调参时漂移。
        // 不能用 String(repeating:) 造这个串——重复字符会先撞上重复片段闸门,
        // 测到的就不是长度边界了。这里用一句正好 40 字、无重复片段的真实中文。
        let text = "今天下午和团队讨论了新版本的排期安排，大家一致同意先把核心链路做完，其余往后放。"
        XCTAssertEqual(text.count, DictationPolicy.redundantCleanupCharacterLimit)
        XCTAssertTrue(DictationPolicy.cleanupIsRedundant(text))
    }

    func testOverLengthBlocks() {
        // 在上面那句正好卡上限的文本后面多加一个字,只跨过长度闸门,不引入其它信号。
        let text = "今天下午和团队讨论了新版本的排期安排，大家一致同意先把核心链路做完，其余往后放好。"
        XCTAssertEqual(text.count, DictationPolicy.redundantCleanupCharacterLimit + 1)
        XCTAssertFalse(DictationPolicy.cleanupIsRedundant(text))
    }

    func testEmptyTextIsNotRedundant() {
        // 空文本走不到整理,更不该被这里判成"空转已处理"。
        XCTAssertFalse(DictationPolicy.cleanupIsRedundant("   \n "))
    }

    // MARK: - 有效纠错对与自定义要求必须覆盖空转守门员(2026-09-06 回归审查 #3)
    //
    // 复现:用户配置"张山 → 张三",ASR 仍输出"请联系张山。"——旧实现只看文本与词典,
    // 完整命中纠错源片段也会被短文本启发式直接放行,PromptBuilder 的纠错块因此永远
    // 没有机会执行。这里同时覆盖手工纠错、学习纠错、屏蔽纠错(不应传入)、自定义要求、
    // 空白要求,以及它们与既有短句启发式共存时的优先级。

    func testManualCorrectionHitForcesCleanupEvenWhenTextWouldOtherwiseBeRedundant() {
        let text = "请联系张山。"
        XCTAssertTrue(DictationPolicy.cleanupIsRedundant(text), "预置:不带纠错对时这句话本应被判定为空转")
        XCTAssertFalse(DictationPolicy.cleanupIsRedundant(
            text, corrections: [LearnedCorrection(source: "张山", target: "张三")]))
    }

    func testLearnedCorrectionHitForcesCleanupSameAsManualCorrection() {
        // 学习纠错与手工纠错在 effectiveCorrections 里已经合并成同一个数组,
        // cleanupIsRedundant 不需要也不应该区分来源。
        let text = "请联系张山。"
        XCTAssertFalse(DictationPolicy.cleanupIsRedundant(
            text, corrections: [LearnedCorrection(source: "张山", target: "张三")]))
    }

    func testBlockedCorrectionMustBeExcludedUpstreamAndDoesNotForceCleanup() {
        // 屏蔽名单在 DictionarySyncCoordinator.effectiveCorrections 里过滤,不在
        // cleanupIsRedundant 内部重新判断屏蔽状态——这里验证的是:一条"已被屏蔽"因而
        // 没有出现在传入数组里的纠错对,不会意外继续拦下本该放行的空转判定。
        let text = "请联系张山。"
        XCTAssertTrue(DictationPolicy.cleanupIsRedundant(text, corrections: []))
    }

    func testCorrectionPairWithEqualSourceAndTargetDoesNotForceCleanup() {
        // source == target 是无效纠错对(替换没有意义),与 ManualCorrections.apply
        // 的过滤条件保持一致,不应该单独触发"必须整理"。
        let text = "请联系张山。"
        XCTAssertTrue(DictationPolicy.cleanupIsRedundant(
            text, corrections: [LearnedCorrection(source: "张山", target: "张山")]))
    }

    func testCorrectionPairWithEmptySourceDoesNotForceCleanup() {
        let text = "请联系张山。"
        XCTAssertTrue(DictationPolicy.cleanupIsRedundant(
            text, corrections: [LearnedCorrection(source: "", target: "张三")]))
    }

    func testCorrectionNotPresentInTextDoesNotForceCleanup() {
        // 纠错对存在,但这句话根本没说到"张山"——不应该被无关纠错对拖累。
        XCTAssertTrue(DictationPolicy.cleanupIsRedundant(
            "明天下午三点开会，地点在会议室。",
            corrections: [LearnedCorrection(source: "张山", target: "张三")]))
    }

    func testCorrectionMatchIsCaseInsensitiveConsistentWithManualCorrectionsApply() {
        // 与 ManualCorrections.apply 用同一套大小写不敏感匹配,行为不能各说各话。
        XCTAssertFalse(DictationPolicy.cleanupIsRedundant(
            "用 claude 打开。", corrections: [LearnedCorrection(source: "Claude", target: "Claude AI")]))
    }

    func testNonBlankCustomInstructionForcesCleanupEvenForShortText() {
        let text = "明天下午三点开会，地点在会议室。"
        XCTAssertTrue(DictationPolicy.cleanupIsRedundant(text), "预置:不带自定义要求时应判定为空转")
        XCTAssertFalse(DictationPolicy.cleanupIsRedundant(text, customInstruction: "所有数字改用阿拉伯数字"))
    }

    func testBlankCustomInstructionDoesNotForceCleanup() {
        // 空字符串与纯空白都算"未配置",不能让默认值意外触发保守路径。
        let text = "明天下午三点开会，地点在会议室。"
        XCTAssertTrue(DictationPolicy.cleanupIsRedundant(text, customInstruction: ""))
        XCTAssertTrue(DictationPolicy.cleanupIsRedundant(text, customInstruction: "   \n"))
        XCTAssertTrue(DictationPolicy.cleanupIsRedundant(text, customInstruction: nil))
    }

    func testActionableCorrectionOverridesInlineFilledPauseBlockToo() {
        // 纠错对检查在最前面,即使文本本身已经因为别的信号该被拦截,
        // 命中纠错对时依然要放行整理(两者都指向"必须整理",结果一致但路径要对)。
        XCTAssertFalse(DictationPolicy.cleanupIsRedundant(
            "嗯，请联系张山。", corrections: [LearnedCorrection(source: "张山", target: "张三")]))
    }
}
