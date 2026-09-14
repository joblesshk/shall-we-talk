import Foundation

/// 词库项。freq 越大越靠前;isUser 标记来自语音热词/用户词(同源注入),排序时加权。
struct PinyinEntry {
    let word: String
    let syllableCount: Int
    var freq: Int
    var isUser: Bool = false
}

/// 全拼词库：雾凇只读索引 + 运行时用户词；文本核心集用于资源异常时降级。
///
/// 索引以「去空格 flatKey」为主键:xian 同时命中单音节字与 xi'an=西安,天然跨切分歧义。
/// 雾凇索引在构建时生成；下列 Swift 数组/二分索引只用于文本降级路径。
final class PinyinDictionary {
    private(set) var entries: [PinyinEntry] = []
    private var indexedStore: PinyinIndexedStore?
    private var byKey: [String: [Int]] = [:]          // flatKey -> entries 下标
    private var sortedKeys: [String] = []             // 唯一 flatKey,字典序,供前缀二分
    private var initialPostings: [InitialPosting] = [] // 按编码排序的连续简拼 posting
    /// `sortedKeys` 下标按其 T9 数字码排序的排列；复用现有 byKey posting，不复制词条索引。
    private var t9Order: [Int32] = []
    private var charPinyin: [Character: String] = [:] // 单字 -> 音节,供热词转拼音
    private(set) var syllableSet: Set<String> = []
    private(set) var isReady = false
    /// 文本应急词库的限载上限；雾凇索引不在启动时展开词条。
    /// 调大更全但更吃内存,过大有被系统 jetsam 杀扩展的风险。
    var maxEntries = 50_000
    var loadedEntryCount: Int { indexedStore?.entryCount ?? entries.count }

    // 用户词单独存,便于随热词变更整体替换而不动内置词
    private var userEntries: [PinyinEntry] = []
    private var userFlatKeys: [String] = []
    private var userByKey: [String: [Int]] = [:]
    private var userByInitials: [String: [Int]] = [:]
    private var userByT9Key: [String: [Int]] = [:]

    /// 从 keyboard 扩展 bundle 加载资源(同步,建议放后台队列调用)。
    func load(bundle: Bundle = .main) {
        loadSyllables(bundle: bundle)
        loadCharPinyin(bundle: bundle)
        if let url = bundle.url(forResource: "pinyin_ice", withExtension: "sqlite") {
            indexedStore = PinyinIndexedStore(url: url)
        }
        if indexedStore == nil { loadDict(bundle: bundle) }
        isReady = true
    }

    private func loadSyllables(bundle: Bundle) {
        guard let url = bundle.url(forResource: "pinyin_ice_syllables", withExtension: "txt")
                ?? bundle.url(forResource: "pinyin_syllables", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        syllableSet = Set(text.split(whereSeparator: \.isNewline).map(String.init))
    }

    private func loadCharPinyin(bundle: Bundle) {
        guard let url = bundle.url(forResource: "char_pinyin", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: "\t")
            guard cols.count == 2, let ch = cols[0].first else { continue }
            charPinyin[ch] = String(cols[1])
        }
    }

    private func loadDict(bundle: Bundle) {
        guard let url = bundle.url(forResource: "pinyin_dict", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var keySet = Set<String>()
        entries.reserveCapacity(min(maxEntries, 110_000))
        initialPostings.reserveCapacity(min(maxEntries, 50_000))
        // 文件前部是生成器预选的移动核心集;达上限即停(降低键盘扩展内存峰值)。
        text.enumerateLines { line, shouldStop in
            let cols = line.split(separator: "\t")
            guard cols.count == 3 else { return }
            let word = String(cols[0])
            let sylls = cols[1].split(separator: " ").map(String.init)
            let freq = Int(cols[2]) ?? 1
            let key = sylls.joined()
            let idx = self.entries.count
            self.entries.append(PinyinEntry(word: word, syllableCount: sylls.count, freq: freq))
            self.byKey[key, default: []].append(idx)
            keySet.insert(key)
            if sylls.count >= 2, sylls.count <= 6 {
                let initials = String(sylls.compactMap(\.first))
                if let code = CompactPinyinIndex.initialsCode(initials) {
                    self.initialPostings.append(InitialPosting(code: code, entryIndex: Int32(idx)))
                }
            }
            if self.entries.count >= self.maxEntries { shouldStop = true }
        }
        sortedKeys = keySet.sorted()
        initialPostings.sort {
            $0.code == $1.code ? $0.entryIndex < $1.entryIndex : $0.code < $1.code
        }
        // 排序期间预算完整数字码；排序完成后只保留 4-byte 下标排列。
        let preparedT9 = sortedKeys.enumerated().compactMap { index, key -> (Int32, String)? in
            guard let code = T9KeyMap.code(for: key) else { return nil }
            return (Int32(index), code)
        }
        t9Order = preparedT9.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return sortedKeys[Int($0.0)] < sortedKeys[Int($1.0)]
        }.map(\.0)
    }

    // MARK: - 查询

    /// 精确整词:flatKey 完全等于 buffer 的词(含跨切分读法),按 freq 降序。
    func exactWords(flatKey: String, limit: Int = 60) -> [PinyinEntry] {
        var result: [PinyinEntry] = []
        if let idxs = userByKey[flatKey] { result += idxs.map { userEntries[$0] } }
        if let store = indexedStore { result += store.lookup(flatKey, index: .pinyin, limit: limit).map(\.entry) }
        else if let idxs = byKey[flatKey] { result += idxs.map { entries[$0] } }
        var ranked = rank(result, limit: limit)
        // Flat spelling can mean one syllable or several (xian / xi'an).
        // Keep the first alternative segmentation visible without changing the first choice.
        if ranked.first?.syllableCount == 1,
           let multi = ranked.firstIndex(where: { $0.syllableCount > 1 }), multi > 5 {
            ranked.insert(ranked.remove(at: multi), at: 5)
        }
        return ranked
    }

    /// 前缀补全:flatKey 以 buffer 开头但更长的词(用户还在打整词),按 freq 降序。
    func prefixWords(flatKey: String, excludingExact: Bool = true, limit: Int = 80) -> [PinyinEntry] {
        guard !flatKey.isEmpty else { return [] }
        var result: [PinyinEntry] = []
        // 用户词前缀(热词优先冒泡)
        for (k, idxs) in userByKey where k.hasPrefix(flatKey) {
            if excludingExact && k == flatKey { continue }
            result += idxs.map { userEntries[$0] }
        }
        if let store = indexedStore {
            result += store.lookup(flatKey, index: .pinyin, prefix: true, excludingExact: excludingExact, limit: limit).map(\.entry)
            return rank(result, limit: limit)
        }
        // 内置词前缀:二分定位区间
        let range = prefixRange(flatKey)
        for ki in range {
            let k = sortedKeys[ki]
            if excludingExact && k == flatKey { continue }
            if let idxs = byKey[k] { result += idxs.map { entries[$0] } }
            if result.count > limit * 4 { break }
        }
        return rank(result, limit: limit)
    }

    /// 单音节 → 候选字(整句/逐字兜底用)。
    func chars(forSyllable syl: String, limit: Int = 40) -> [PinyinEntry] {
        var result: [PinyinEntry] = []
        if let idxs = userByKey[syl] { result += idxs.map { userEntries[$0] }.filter { $0.syllableCount == 1 } }
        if let store = indexedStore { result += store.lookup(syl, index: .pinyin, charsOnly: true, limit: limit).map(\.entry) }
        else if let idxs = byKey[syl] { result += idxs.map { entries[$0] }.filter { $0.syllableCount == 1 } }
        return rank(result, limit: limit)
    }

    /// 2–6 个声母首字母的精确简拼。词的音节数必须与输入字符数相同。
    func initialWords(_ initials: String, limit: Int = 80) -> [PinyinEntry] {
        guard (2...6).contains(initials.count) else { return [] }
        var result: [PinyinEntry] = []
        if let idxs = userByInitials[initials] { result += idxs.map { userEntries[$0] } }
        if let store = indexedStore {
            result += store.lookup(initials, index: .initials, limit: limit).map(\.entry)
            return rank(result, limit: limit)
        }
        if let code = CompactPinyinIndex.initialsCode(initials) {
            var index = lowerBoundInitial(code)
            while index < initialPostings.count, initialPostings[index].code == code {
                result.append(entries[Int(initialPostings[index].entryIndex)])
                index += 1
            }
        }
        return rank(result, limit: limit)
    }

    /// 完整拼音映射出的数字码精确匹配。
    func t9ExactWords(_ digits: String,
                      confirmedBoundaries: [Int] = [],
                      limit: Int = 80) -> [PinyinEntry] {
        var result: [PinyinEntry] = []
        if confirmedBoundaries.isEmpty, let idxs = userByT9Key[digits] {
            result += idxs.map { userEntries[$0] }
        } else if let idxs = userByT9Key[digits] {
            for idx in idxs where matchesT9Boundaries(
                flatKey: userFlatKeys[idx], boundaries: confirmedBoundaries
            ) {
                result.append(userEntries[idx])
            }
        }
        if let store = indexedStore {
            result += store.lookup(digits, index: .t9, limit: confirmedBoundaries.isEmpty ? limit : 512)
                .filter { matchesT9Boundaries(flatKey: $0.pinyin, boundaries: confirmedBoundaries) }.map(\.entry)
            return rank(result, limit: limit)
        }
        for position in t9Range(digits) {
            let key = sortedKeys[Int(t9Order[position])]
            // 精确码排在其更长前缀项之前；到第一个更长码即可停。
            guard T9KeyMap.code(for: key) == digits else { break }
            guard matchesT9Boundaries(flatKey: key, boundaries: confirmedBoundaries) else { continue }
            if let idxs = byKey[key] { result += idxs.map { entries[$0] } }
            if result.count > limit * 4 { break }
        }
        return rank(result, limit: limit)
    }

    /// 用户尚未敲完整数字码时，召回以当前数字串开头的词。
    func t9PrefixWords(_ digits: String,
                       confirmedBoundaries: [Int] = [],
                       excludingExact: Bool = true,
                       limit: Int = 100) -> [PinyinEntry] {
        guard !digits.isEmpty else { return [] }
        var result: [PinyinEntry] = []
        for (key, idxs) in userByT9Key where key.hasPrefix(digits) {
            if excludingExact && key == digits { continue }
            for idx in idxs {
                if matchesT9Boundaries(flatKey: userFlatKeys[idx], boundaries: confirmedBoundaries) {
                    result.append(userEntries[idx])
                }
            }
        }
        if let store = indexedStore {
            result += store.lookup(digits, index: .t9, prefix: true, excludingExact: excludingExact,
                                   limit: confirmedBoundaries.isEmpty ? limit : 512)
                .filter { matchesT9Boundaries(flatKey: $0.pinyin, boundaries: confirmedBoundaries) }.map(\.entry)
            return rank(result, limit: limit)
        }
        for position in t9Range(digits) {
            let key = sortedKeys[Int(t9Order[position])]
            let code = T9KeyMap.code(for: key) ?? ""
            if excludingExact && code == digits { continue }
            guard matchesT9Boundaries(flatKey: key, boundaries: confirmedBoundaries) else { continue }
            if let idxs = byKey[key] { result += idxs.map { entries[$0] } }
            if result.count > limit * 4 { break }
        }
        return rank(result, limit: limit)
    }

    func pinyin(forChar ch: Character) -> String? { charPinyin[ch] }

    /// 以某个字母开头的合法音节,短的在前(供纠错兜底挑一个最"轻"的音节起头)。
    func syllables(startingWith letter: Character) -> [String] {
        syllableSet
            .filter { $0.first == letter }
            .sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
    }

    // MARK: - 排序 / 前缀区间

    private func rank(_ items: [PinyinEntry], limit: Int) -> [PinyinEntry] {
        var seen = Set<String>()
        let sorted = items.sorted { a, b in
            if a.isUser != b.isUser { return a.isUser }            // 用户/热词优先
            if a.syllableCount != b.syllableCount, a.freq == b.freq {
                return a.syllableCount > b.syllableCount           // 同频偏长词
            }
            return a.freq > b.freq
        }
        var out: [PinyinEntry] = []
        for e in sorted {
            if seen.insert(e.word).inserted { out.append(e) }
            if out.count >= limit { break }
        }
        return out
    }

    /// sortedKeys 中以 prefix 开头的下标区间(二分)。
    private func prefixRange(_ prefix: String) -> Range<Int> {
        prefixRange(prefix, in: sortedKeys)
    }

    private func prefixRange(_ prefix: String, in keys: [String]) -> Range<Int> {
        let lo = lowerBound(prefix, in: keys)
        // 上界:prefix 的字典序「下一个」串
        guard let upperKey = nextPrefix(prefix) else {
            return lo..<keys.count
        }
        let hi = lowerBound(upperKey, in: keys)
        return lo..<hi
    }

    private func lowerBound(_ key: String, in keys: [String]) -> Int {
        var lo = 0, hi = keys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keys[mid] < key { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func lowerBoundInitial(_ code: UInt32) -> Int {
        var lo = 0, hi = initialPostings.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if initialPostings[mid].code < code { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func t9Range(_ prefix: String) -> Range<Int> {
        let lo = lowerBoundT9(prefix)
        guard let upper = nextPrefix(prefix) else { return lo..<t9Order.count }
        return lo..<lowerBoundT9(upper)
    }

    private func lowerBoundT9(_ code: String) -> Int {
        var lo = 0, hi = t9Order.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let key = sortedKeys[Int(t9Order[mid])]
            let midCode = T9KeyMap.code(for: key) ?? ""
            if midCode < code { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// 分词键确认的是数字位置对应的拼音边界。由于 T9 映射逐字母等长，数字偏移可直接
    /// 投射到 flatKey；每个被边界切开的片段都必须能由本地合法音节完整组成。
    private func matchesT9Boundaries(flatKey: String,
                                     boundaries: [Int]) -> Bool {
        guard !boundaries.isEmpty else { return true }
        let characters = Array(flatKey)
        var previous = 0
        for boundary in boundaries {
            guard boundary >= previous, boundary <= characters.count else { return false }
            if boundary > previous,
               !isFullySegmentable(Array(characters[previous..<boundary])) {
                return false
            }
            previous = boundary
        }
        guard previous < characters.count else { return true }
        return isFullySegmentable(Array(characters[previous...]))
    }

    private func isFullySegmentable(_ characters: [Character]) -> Bool {
        guard !characters.isEmpty else { return true }
        var reachable = Array(repeating: false, count: characters.count + 1)
        reachable[0] = true
        for start in 0..<characters.count where reachable[start] {
            for end in (start + 1)...min(characters.count, start + 6) {
                if syllableSet.contains(String(characters[start..<end])) {
                    reachable[end] = true
                }
            }
        }
        return reachable[characters.count]
    }

    /// 返回字典序紧邻 prefix* 之后的最小串(末位字符 +1);全 z 则无上界。
    private func nextPrefix(_ prefix: String) -> String? {
        var chars = Array(prefix.unicodeScalars)
        var i = chars.count - 1
        while i >= 0 {
            if chars[i] < "z" {
                chars[i] = Unicode.Scalar(chars[i].value + 1)!
                return String(String.UnicodeScalarView(chars[0...i]))
            }
            i -= 1
        }
        return nil
    }

    // MARK: - 用户词(语音热词同源)

    /// 用给定词表整体替换用户词(热词变更时调用)。freq 给一个高基线以压过内置词。
    func setUserWords(_ pairs: [(word: String, syllables: [String])]) {
        userEntries.removeAll(keepingCapacity: true)
        userFlatKeys.removeAll(keepingCapacity: true)
        userByKey.removeAll(keepingCapacity: true)
        userByInitials.removeAll(keepingCapacity: true)
        userByT9Key.removeAll(keepingCapacity: true)
        let base = 5_000_000  // 高于内置最高频(百万级),保证热词冒泡
        for (i, p) in pairs.enumerated() {
            let key = p.syllables.joined()
            guard !key.isEmpty else { continue }
            let idx = userEntries.count
            userEntries.append(PinyinEntry(word: p.word,
                                           syllableCount: p.syllables.count,
                                           freq: base - i, isUser: true))
            userFlatKeys.append(key)
            userByKey[key, default: []].append(idx)
            if p.syllables.count >= 2, p.syllables.count <= 6 {
                let initials = String(p.syllables.compactMap(\.first))
                userByInitials[initials, default: []].append(idx)
            }
            if let t9Key = T9KeyMap.code(for: key) {
                userByT9Key[t9Key, default: []].append(idx)
            }
        }
    }
}
