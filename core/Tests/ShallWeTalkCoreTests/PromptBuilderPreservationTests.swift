import XCTest
@testable import ShallWeTalkCore

/// Prompt 保真契约:合并自原 ios/tests/PromptBuilderPreservationSmoke.swift 与
/// macos/VoicePenTests/PromptBuilderPreservationSmoke.swift(两端内容已同构,
/// macOS 版额外覆盖 buildFinalPass,本文件取并集)。
final class PromptBuilderPreservationTests: XCTestCase {
    /// 重档长口述使用“最全版 Prompt”；轻档始终使用短口述 Prompt。
    func testCleanCopyContractAcrossLevels() {
        let light = PromptBuilder.build(level: .light, customInstruction: "", dictionary: [])
        XCTAssertTrue(light.hasPrefix(PromptBuilder.dictationRoleLine))
        XCTAssertTrue(light.contains(PromptBuilder.simpleBase))
        XCTAssertFalse(light.contains(PromptBuilder.mostCompleteLongBase))
        XCTAssertFalse(light.contains(PromptBuilder.mostCompleteSegmentationRules))

        let heavy = PromptBuilder.build(level: .heavy, customInstruction: "", dictionary: [])
        XCTAssertTrue(heavy.hasPrefix(PromptBuilder.dictationRoleLine))
        XCTAssertTrue(heavy.contains(PromptBuilder.mostCompleteLongBase))
        XCTAssertTrue(heavy.contains(PromptBuilder.mostCompleteSegmentationRules))
        XCTAssertTrue(heavy.contains("自然语义边界另起一段"))
        XCTAssertTrue(heavy.contains("没有信号时至少三项"))
        XCTAssertTrue(heavy.contains("共同谓语下的并列词组"))
        XCTAssertTrue(heavy.contains("均不编号"))
        XCTAssertTrue(heavy.contains("重复错位、残句和病句"))
        XCTAssertTrue(heavy.contains("不改变说话人的声音"))
    }

    func testPersonalizedCorrectionInjection() {
        let personalized = PromptBuilder.build(
            level: .heavy, customInstruction: "", dictionary: [],
            corrections: [LearnedCorrection(source: "一只做多的", target: "一直做多的")])
        XCTAssertTrue(personalized.contains("用户已确认的上下文纠错"),
                      "personalized prompt must explain scoped correction use")
        XCTAssertTrue(personalized.contains("“一只做多的” → “一直做多的”"),
                      "personalized prompt must inject the exact contextual pair")
    }

    /// 2026-08-16:短口述路由(低于「完整整理阈值」)改用 `buildSimple(includeSegmentation:
    /// false)`——旧版专用的同音纠错短句契约(`buildShortHomophone`)已删除，存档见
    /// 工程规划.md §16.4。新短路由与长路由共用同一套保真润色目标，短路由不提分段编号；
    /// 这条测试相应锁住这条边界，以及词典/纠错注入仍然生效。
    func testShortPromptOmitsSegmentationButKeepsInjection() {
        let prompt = PromptBuilder.buildSimple(
            dictionary: ["Keychain"],
            corrections: [LearnedCorrection(source: "一只觉得", target: "一直觉得")])

        XCTAssertTrue(prompt.hasPrefix(PromptBuilder.dictationRoleLine))
        XCTAssertTrue(prompt.contains("输出内容仅包括整理、修饰后的原话"))
        XCTAssertTrue(prompt.contains("不包括你对用户的自然回复"))
        XCTAssertTrue(prompt.contains(PromptBuilder.simpleBase))
        XCTAssertTrue(prompt.contains("使语句自然、完整、流畅、易读"))
        XCTAssertTrue(prompt.contains("不要只修改个别词语后留下仍不通顺的句子"))
        XCTAssertTrue(prompt.contains("本次任务不进行简繁转换"))
        XCTAssertFalse(prompt.contains("同一次输出中完成分段和编号"),
                       "short route must not ask for segmentation or numbering")
        XCTAssertTrue(prompt.contains("“一只觉得” → “一直觉得”"))
        XCTAssertTrue(prompt.contains("Keychain"))
    }

    func testExplicitEnumerationPromptAddsNumberingOnTopOfMostCompleteBase() {
        let prompt = PromptBuilder.buildDictation(
            route: .explicitEnumeration,
            customInstruction: "保留粤语用词",
            dictionary: ["MacBook Pro"],
            corrections: [LearnedCorrection(source: "一只觉得", target: "一直觉得")])

        XCTAssertTrue(prompt.hasPrefix(PromptBuilder.dictationRoleLine))
        XCTAssertTrue(prompt.contains(PromptBuilder.mostCompleteLongBase))
        XCTAssertTrue(prompt.contains(PromptBuilder.mostCompleteSegmentationRules))
        XCTAssertTrue(prompt.contains(PromptBuilder.explicitEnumerationInstruction))
        XCTAssertTrue(prompt.contains("序号格式是硬性验收项"))
        XCTAssertTrue(prompt.contains("仍须完成全文的同音纠错、残句病句修复、基础润色和自然分段"))
        XCTAssertTrue(prompt.contains("只编号该局部，其余全文继续正常整理"))
        XCTAssertTrue(prompt.contains("每组从“1. ”开始连续编号"))
        XCTAssertTrue(prompt.contains("终稿中该组就必须同时出现独立行的“1. ”和“2. ”"))
        XCTAssertTrue(prompt.contains("有两个任务：\n1. 发邮件。\n2. 补文件。"))
        XCTAssertTrue(prompt.contains("这个判断有两点：\n1. 没说明口径。\n2. 只证明个案。"))
        XCTAssertTrue(prompt.contains("不补造项目"))
        XCTAssertTrue(prompt.contains("保留粤语用词"))
        XCTAssertTrue(prompt.contains("MacBook Pro"))
        XCTAssertTrue(prompt.contains("“一只觉得” → “一直觉得”"))

        let baseRange = prompt.range(of: PromptBuilder.mostCompleteLongBase)
        let segmentationRange = prompt.range(of: PromptBuilder.mostCompleteSegmentationRules)
        let enumerationRange = prompt.range(of: PromptBuilder.explicitEnumerationInstruction)
        XCTAssertNotNil(baseRange)
        XCTAssertNotNil(segmentationRange)
        XCTAssertNotNil(enumerationRange)
        XCTAssertLessThan(baseRange!.lowerBound, segmentationRange!.lowerBound)
        XCTAssertLessThan(segmentationRange!.lowerBound, enumerationRange!.lowerBound)

        XCTAssertFalse(PromptBuilder.buildDictation(route: .full)
            .contains(PromptBuilder.explicitEnumerationInstruction))
        XCTAssertFalse(PromptBuilder.buildDictation(route: .homophoneOnly)
            .contains(PromptBuilder.explicitEnumerationInstruction))
    }

    func testMostCompletePromptCombinesLongBaseAndSegmentationRules() {
        let prompt = PromptBuilder.buildMostComplete(
            customInstruction: "保留粤语用词",
            dictionary: ["MacBook Pro"],
            corrections: [LearnedCorrection(source: "一只觉得", target: "一直觉得")])

        XCTAssertTrue(prompt.contains(PromptBuilder.mostCompleteLongBase))
        XCTAssertTrue(prompt.contains(PromptBuilder.mostCompleteSegmentationRules))
        XCTAssertTrue(prompt.contains("三项明确任务，每次都必须逐项执行"))
        XCTAssertTrue(prompt.contains("超过20个有效字符"))
        XCTAssertTrue(prompt.contains("明确枚举必须分项"))
        XCTAssertTrue(prompt.contains("隐性并列仅在同类同层、各自独立、关系并列、数量达标四个条件同时满足时编号"))
        XCTAssertTrue(prompt.contains("保留粤语用词"))
        XCTAssertTrue(prompt.contains("MacBook Pro"))
        XCTAssertTrue(prompt.contains("“一只觉得” → “一直觉得”"))
    }

}
