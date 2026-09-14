import Foundation

/// 从用户观察到的丢尾问题出发，验证真实词库下的选择与后续输入。
@main
struct PinyinSelectionSmoke {
    static func main() {
        let engine = PinyinEngine()
        var ready = false
        engine.loadAsync { ready = true }
        let deadline = Date().addingTimeInterval(10)
        while !ready && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        guard ready, engine.dictionaryReady else { fatalError("Dictionary failed to load") }
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        func type(_ text: String, mode: PinyinInputMode = .twentySixKey) {
            engine.setInputMode(mode)
            engine.clear()
            for character in text {
                if mode == .twentySixKey { engine.input(character) }
                else if character == "'" { engine.inputSeparator() }
                else { engine.inputT9Digit(character) }
            }
        }
        func select(_ word: String, remainder: String) {
            guard let candidate = engine.candidates.first(where: { $0.word == word }) else {
                failures.append("Missing \(word) for \(engine.buffer)")
                return
            }
            check(engine.candidates.prefix(6).contains(where: { $0.word == word }),
                  "\(word) is outside the six visible candidates for \(engine.buffer)")
            let selection = engine.select(candidate)
            check(selection.text == word, "Wrong selection for \(word)")
            check(engine.buffer == remainder,
                  "Selecting \(word): expected remainder \(remainder), got \(engine.buffer)")
            check(selection.hasRemainder == !remainder.isEmpty, "Wrong remainder flag for \(word)")
        }

        type("nihaom")
        select("你好", remainder: "m")
        for c in "ingtian" { engine.input(c) }
        select("明天", remainder: "")

        type("nihaoshijie")
        select("你", remainder: "haoshijie")
        select("好", remainder: "shijie")
        select("世界", remainder: "")

        // 西安与先共享flatKey，不能从另一种音节切分推算消费长度。
        type("xian")
        select("西安", remainder: "")
        type("nh")
        select("你好", remainder: "")
        // 补全候选只消耗已敲的输入；不会要求用户再输入未敲的音节。
        type("shuruf")
        select("输入法", remainder: "")
        type("nihqo")
        select("你好", remainder: "")

        let digits = T9KeyMap.code(for: "womingtianqushanghai")!
        type(digits, mode: .nineKey)
        select("我", remainder: T9KeyMap.code(for: "mingtianqushanghai")!)
        select("明天", remainder: T9KeyMap.code(for: "qushanghai")!)
        select("去", remainder: T9KeyMap.code(for: "shanghai")!)
        select("上海", remainder: "")

        type("96'6464'8426", mode: .nineKey)
        select("我", remainder: "6464'8426")
        select("明天", remainder: "")

        type("64'426'6", mode: .nineKey)
        select("你好", remainder: "6")
        type("943'943'", mode: .nineKey)
        select("谢谢", remainder: "")
        type("74'26", mode: .nineKey)
        check(!engine.candidates.contains(where: { $0.word == "山" }), "T9 ignored explicit boundary")
        select("前", remainder: "")

        // 不可解码的兜底只消费第一个数字，不得吞掉后续数字。
        type("999999", mode: .nineKey)
        if let first = engine.candidates.first {
            let result = engine.select(first)
            check(result.hasRemainder && !engine.buffer.isEmpty, "T9 fallback cleared the entire input")
        } else { failures.append("T9 fallback is empty") }

        // 旧候选不能在输入变化后提交到新的组合串。
        type("nihao")
        let old = engine.candidates.first!
        engine.input("m")
        let rejected = engine.select(old)
        check(rejected.text.isEmpty && engine.buffer == "nihaom", "Stale candidate modified current input")

        if !failures.isEmpty {
            for failure in failures { print("FAIL: \(failure)") }
            exit(1)
        }
        print("PASS: pinyin selection preserves partial input, T9 remainders, and candidate identity")
    }
}
