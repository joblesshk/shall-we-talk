import XCTest
@testable import ShallWeTalkCore

/// 修改模式安全网(语音二次修改-执行方略.md v2 §7)。三条判定都不自动拒绝改动本身,
/// 只分类——这份测试锁住分类边界,不锁具体阈值(阈值标注为占位,需按 §9 评测调优)。
final class EditGuardTests: XCTestCase {
    func testAppliesNormalSmallEdit() {
        let outcome = EditGuard.evaluate(
            candidate: "我觉得一直做多的判断是对的",
            original: "我觉得一只做多的判断是对的",
            instruction: "一直做多的直,不是一只的只")
        XCTAssertEqual(outcome, .applied("我觉得一直做多的判断是对的"))
    }

    func testSentinelIsNoEdit() {
        let outcome = EditGuard.evaluate(candidate: "NO_EDIT", original: "原文不变", instruction: "听不清")
        XCTAssertEqual(outcome, .noEdit)
    }

    func testEmptyOutputIsNoEdit() {
        // 红线:网络抖动/模型异常返回空字符串,不能当作"没有改动"直接放行——必须按
        // 判定不出处理,保留原稿。
        let outcome = EditGuard.evaluate(candidate: "   ", original: "原文不变", instruction: "随便说点什么")
        XCTAssertEqual(outcome, .noEdit)
    }

    func testMetaDiscourseOpenerIsNoEdit() {
        let outcome = EditGuard.evaluate(
            candidate: "好的,已经帮您修改好了",
            original: "原文",
            instruction: "改一下")
        XCTAssertEqual(outcome, .noEdit)
    }

    func testIdenticalOutputIsUnchanged() {
        let outcome = EditGuard.evaluate(
            candidate: "这段话完全没变",
            original: "这段话完全没变",
            instruction: "把语气改软一点")
        XCTAssertEqual(outcome, .unchanged)
    }

    func testLargeChangeWithShortInstructionIsFlaggedNotRejected() {
        let outcome = EditGuard.evaluate(
            candidate: "全新的一段完全不同的内容在这里",
            original: "原本的这段话跟新内容毫无关系",
            instruction: "改一下")
        guard case .flaggedLargeChange(let text) = outcome else {
            return XCTFail("大幅改动应标记 flaggedLargeChange 而不是吞掉,实际是 \(outcome)")
        }
        XCTAssertEqual(text, "全新的一段完全不同的内容在这里")
    }

    func testLargeChangeWithLongInstructionIsApplied() {
        // 幅度检测只在"修改要求很短"时才起疑——要求本身讲清楚了大改的理由,不该被拦。
        let outcome = EditGuard.evaluate(
            candidate: "全新的一段完全不同的内容在这里",
            original: "原本的这段话跟新内容毫无关系",
            instruction: "这段话整体重写一遍,换成完全不同的表述方式和内容,原来的意思不用保留")
        XCTAssertEqual(outcome, .applied("全新的一段完全不同的内容在这里"))
    }
}
