import Foundation

@main struct PinyinIndexedStoreSmoke {
    static func main() throws {
        let dictionary = PinyinDictionary()
        dictionary.load()
        precondition(dictionary.loadedEntryCount > 850_000, "Must load the large indexed dictionary, not silently fall back")
        precondition(dictionary.entries.isEmpty, "Must not expand built-in rows into heap objects")
        for (key, word) in [("nihao", "你好"), ("ng", "嗯"), ("dayuyanmoxing", "大语言模型"),
                            ("zhonghuarenmingongheguodifanggejirenmindaibiaodahuihedifanggejirenminzhengfuzuzhifa", "中华人民共和国地方各级人民代表大会和地方各级人民政府组织法")] {
            precondition(dictionary.exactWords(flatKey: key).contains(where: { $0.word == word }), "Missing \(word)")
        }
        let engine = PinyinEngine()
        var ready = false
        engine.loadAsync { ready = true }
        let deadline = Date().addingTimeInterval(5)
        while !ready && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        precondition(ready)
        let longKey = "zhonghuarenmingongheguodifanggejirenmindaibiaodahuihedifanggejirenminzhengfuzuzhifa"
        for mode in [PinyinInputMode.twentySixKey, .nineKey] {
            engine.setInputMode(mode);engine.clear()
            let input = mode == .nineKey ? T9KeyMap.code(for: longKey)! : longKey
            for character in input {
                if mode == .nineKey { engine.inputT9Digit(character) } else { engine.input(character) }
            }
            precondition(engine.candidates.prefix(6).contains(where: { $0.word == "中华人民共和国地方各级人民代表大会和地方各级人民政府组织法" }))
        }
        // Hotword replacement must invalidate the overlay independently of the cached built-in rows.
        _ = dictionary.exactWords(flatKey: "nihao")
        dictionary.setUserWords([(word: "倪好", syllables: ["ni", "hao"])])
        precondition(dictionary.exactWords(flatKey: "nihao").first?.word == "倪好")
        dictionary.setUserWords([])
        precondition(dictionary.exactWords(flatKey: "nihao").first?.word == "你好")
        precondition(dictionary.prefixWords(flatKey: "").isEmpty)
        precondition(dictionary.t9PrefixWords("9", excludingExact: false, limit: 24).count > 0)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        precondition(PinyinIndexedStore(url: missing) == nil)
        precondition(!FileManager.default.fileExists(atPath: missing.path), "Read-only opening must not create files")
        try Data("not a database".utf8).write(to: missing)
        defer { try? FileManager.default.removeItem(at: missing) }
        precondition(PinyinIndexedStore(url: missing) == nil)
        print("PASS: indexed dictionary size, lazy loading, long word, legacy reading, hotword overlay, missing/corrupt resource")
    }
}
