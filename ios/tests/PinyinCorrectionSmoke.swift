import Foundation

/// 拼音错点纠正 + "候选栏永不为空"的冒烟测试。
///
/// 这几条不是风格约束,是用户 2026-08-04 定的硬规则和两个**已经踩过的坑**,
/// 用 grep 守卫锁不住(都是运行时行为),所以真跑一遍引擎。
@main
struct PinyinCorrectionSmoke {
    static func main() {
        let engine = PinyinEngine()
        let semaphore = DispatchSemaphore(value: 0)
        engine.loadAsync { semaphore.signal() }
        // CLI 里 main queue 不会自己跑,loadAsync 的回调挂在上面,必须边等边泵 RunLoop。
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }

        guard engine.dictionary.loadedEntryCount > 0 else {
            fail("词库没加载起来(冒烟测试需要 PinyinData/*.txt 与可执行文件同目录)")
        }

        func type(_ text: String) -> PinyinEngine {
            engine.clear()
            for character in text { _ = engine.input(character) }
            return engine
        }

        // ① 硬规则:候选栏永远不能空。挑几类最容易打空的输入。
        for text in ["i", "u", "v", "qwrt", "zzz", "bbbb", "aeiou", "xyzq", "vvvv", "iiii"] {
            if type(text).candidates.isEmpty {
                fail("输入「\(text)」时候选栏为空——这条硬规则不允许有例外")
            }
        }

        // ② 错点纠正确实在工作(读不出来的输入要能纠回真词)。
        for (typo, expected) in [("nihqo", "你好"), ("shjjie", "世界"), ("tjankong", "天空")] {
            let words = type(typo).candidates.prefix(6).map(\.word)
            if !words.contains(expected) {
                fail("「\(typo)」应纠正出「\(expected)」,实得 \(words)")
            }
        }

        // ③ 回归:纠错**不得改写用户敲下的字母**。
        // 曾经把纠错结果写回 buffer,导致半截输入被纠歪后,后面敲的字母长在错词根上,
        // 整串跑偏(zhokgguo → 做哦贵哦)。
        let engineAfterTyping = type("zhokgguo")
        if engineAfterTyping.buffer != "zhokgguo" {
            fail("纠错改写了原始输入:buffer=\(engineAfterTyping.buffer),应为 zhokgguo")
        }
        if !engineAfterTyping.candidates.prefix(6).map(\.word).contains("中国") {
            fail("「zhokgguo」应纠正出「中国」,实得 \(engineAfterTyping.candidates.prefix(6).map(\.word))")
        }

        // ④ 回归:命中层级必须排在词频前面。
        // 单字词频(「我」)比词的词频高几个数量级,只比频次会把 qoanyue 纠成「我按月」。
        let qianyue = type("qoanyue").candidates.prefix(6).map(\.word)
        if !qianyue.contains("签约") {
            fail("「qoanyue」应纠正出「签约」而不是被高频单字带偏,实得 \(qianyue)")
        }

        // ⑤ 克制:读得通的输入不许被纠。「nih」是「ni」+ 合法声母「h」,用户还在打。
        let stillTyping = type("nih")
        if stillTyping.correctionApplied {
            fail("「nih」是正常的半截输入,不该触发纠错(纠成了 \(stillTyping.effectiveKey))")
        }

        // ⑥ 两到六个声母触发简拼，且发生在 QWERTY 纠错之前。
        for (initials, expected) in [
            ("xx", "谢谢"), ("nh", "你好"), ("zg", "中国"),
            ("wm", "我们"), ("sj", "升级"), ("ah", "安徽")
        ] {
            let abbreviated = type(initials)
            let words = abbreviated.candidates.prefix(6).map(\.word)
            if !words.contains(expected) {
                fail("简拼「\(initials)」前六应包含「\(expected)」,实得 \(words)")
            }
            if abbreviated.correctionApplied {
                fail("简拼「\(initials)」不应触发 QWERTY 纠错")
            }
        }
        if let thanks = type("xx").candidates.first(where: { $0.word == "谢谢" }) {
            let selection = engine.select(thanks)
            if selection.hasRemainder || engine.isComposing {
                fail("简拼候选选中后必须消耗整段声母输入")
            }
        } else {
            fail("简拼 xx 缺少谢谢")
        }
        engine.setHotwords(["谢谢"])
        if type("xx").candidates.first?.word != "谢谢" {
            fail("学习词即时重注入后，谢谢必须升为 xx 的首选")
        }
        let ng = type("ng").candidates.prefix(6).map(\.word)
        if !ng.contains("嗯") {
            fail("ng 同时是完整拼音和简拼时必须保留完整拼音精确候选,实得 \(ng)")
        }

        // ⑦ 九宫格完整数字码与退格/分词闭环。
        engine.setInputMode(.nineKey)
        func typeT9(_ digits: String) -> PinyinEngine {
            engine.clear()
            for digit in digits {
                if digit == "'" { _ = engine.inputSeparator() }
                else { _ = engine.inputT9Digit(digit) }
            }
            return engine
        }
        for (digits, expected) in [("943943", "谢谢"), ("64426", "你好"), ("94664486", "中国")] {
            let words = typeT9(digits).candidates.prefix(12).map(\.word)
            if !words.contains(expected) {
                fail("九宫格「\(digits)」应包含「\(expected)」,实得 \(words)")
            }
        }
        let separated = typeT9("943'943")
        if separated.displayComposition != "943'943" {
            fail("九宫格显式分词边界丢失: \(separated.displayComposition)")
        }
        if !separated.backspace() || separated.buffer != "943'94" {
            fail("九宫格退格必须删除一个真实输入字符")
        }
        let ambiguous = Set(typeT9("7426").candidates.map(\.word))
        let boundaryFiltered = Set(typeT9("74'26").candidates.map(\.word))
        if !ambiguous.contains("山") || boundaryFiltered.contains("山")
            || !boundaryFiltered.contains("前") {
            fail("九宫格分词边界应保留 qi+an 的『前』并过滤不可在 2 位处分开的 shan『山』")
        }
        for digits in ["2", "99", "222222", "999999"] {
            if typeT9(digits).candidates.isEmpty {
                fail("九宫格输入「\(digits)」时候选栏为空")
            }
        }

        print("PASS: pinyin correction, initials and T9 smoke tests")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}
