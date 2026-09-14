import XCTest
@testable import ShallWeTalkCore

/// 修改模式 prompt 契约(语音二次修改-执行方略.md v2 §3.2)。仿
/// `PromptBuilderPreservationTests` 的写法:锁住四段草稿里"改动本段 prompt 时请连同理由
/// 一并改"标注的关键约束,不锁整段措辞——措辞本身还要用真实语料调优。
final class EditPassPromptTests: XCTestCase {
    func testCarriesRoleLineVerbatim() {
        let prompt = PromptBuilder.buildEditPass()
        XCTAssertTrue(prompt.contains(PromptBuilder.roleLine),
                      "修改模式必须复用现有 roleLine,一字不改")
    }

    func testDescribesDescriptiveCorrectionForm() {
        let prompt = PromptBuilder.buildEditPass()
        XCTAssertTrue(prompt.contains("一直做多的直，不是一只的只"),
                      "必须用描述式用字的例句说明第二次口述的真实形态,否则模型会把整句话当成待插入正文")
    }

    func testRequiresVerbatimCopyOutsideEditedSpan() {
        let prompt = PromptBuilder.buildEditPass()
        XCTAssertTrue(prompt.contains("逐字照抄"),
                      "保真边界:未被修改要求指向的部分必须逐字照抄,不润色不重新分段")
        XCTAssertTrue(prompt.contains("只改一处"),
                      "目标词在原文多处出现时只改一处,防止批量误伤")
    }

    func testHasNoEditSentinel() {
        let prompt = PromptBuilder.buildEditPass()
        XCTAssertTrue(prompt.contains("NO_EDIT"),
                      "必须给模型一条明确的认输通道")
    }

    func testInjectsDictionary() {
        let prompt = PromptBuilder.buildEditPass(dictionary: ["Keychain"])
        XCTAssertTrue(prompt.contains("Keychain"))
    }

    func testOmitsDictionaryBlockWhenEmpty() {
        let prompt = PromptBuilder.buildEditPass()
        XCTAssertFalse(prompt.contains("个人词典"))
    }

    /// 2026-08-19 真机复现锁死:纠错对块一旦出现在修改模式 prompt 里,会让模型把
    /// "只替换完整命中的已知错误片段"泛化到当次修改指令本身,导致该指令没在纠错对
    /// 列表里时模型过度保守、原文照抄输出。`buildEditPass` 不再接受纠错对参数,
    /// 这条测试锁住"纠错对块的措辞不会出现在修改模式 prompt 里"这件事,防止有人
    /// 图省事把 `corrections` 参数加回来。
    func testNeverInjectsCorrectionsBlock() {
        let prompt = PromptBuilder.buildEditPass(dictionary: ["Keychain"])
        XCTAssertFalse(prompt.contains("用户已确认的上下文纠错"))
    }
}
