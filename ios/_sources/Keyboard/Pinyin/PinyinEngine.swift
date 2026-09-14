import Foundation

enum PinyinInputMode: Equatable {
    case twentySixKey
    case nineKey
}

/// 词条不保存输入位置；同一个词在全拼、简拼、补全和T9中消耗的输入不同。
/// 此快照只随当前候选生成，不增加整本词库的常驻大小。
struct PinyinCandidate {
    let entry: PinyinEntry
    let consumedInputCount: Int
    let composition: String
    let inputMode: PinyinInputMode

    var word: String { entry.word }
}

/// 纯 Swift 全拼输入引擎。
/// 组合态:buffer 存已敲字母;candidates 为当前候选;commit 后可留「整句剩余」继续。
///
/// 候选生成策略(轻量但够用):
///  1. 精确整词 exactWords(flatKey=buffer) —— 覆盖 xian→先/现/西安 等跨切分读法
///  2. 整句贪心 —— 对切分序列做「最长词优先」拼一条整句候选,置于精确词之后
///  3. 前缀补全 prefixWords —— 用户还在打整词时给更长词
///  4. 首音节单字兜底 —— 保证任何输入都能逐字选
final class PinyinEngine {
    /// 词库改为可整体替换:加载装进一份全新实例、在主线程一次指针交换;卸载就是换回空实例。
    /// 这样后台线程从不触碰正在被主线程读的那一份,不需要锁,也不存在半加载态。
    private(set) var dictionary = PinyinDictionary()
    private(set) var segmenter: PinyinSegmenter?
    private let corrector = PinyinCorrector()
    /// 加载代次:每次 loadAsync / unload 自增。在途的后台加载回到主线程时若代次已变,
    /// 说明期间发生过卸载或新的加载,这一份直接丢弃。
    private var loadGeneration = 0

    private(set) var inputMode: PinyinInputMode = .twentySixKey

    private(set) var buffer = ""            // 用户**实际敲下**的字母(纯小写),永不被纠错改写
    private(set) var candidates: [PinyinCandidate] = []
    /// 纠错后用于查词/切分/显示的拼写。没纠错时就等于 buffer。
    ///
    /// ★ 为什么不把纠错结果写回 `buffer`:纠错在**每次敲键**都会重算,而中途的半截输入
    /// (`zhok`,还差 `gguo`)常常会被纠成某个当下更"读得通"的东西(`zuok`)。一旦写回,
    /// 后面敲的字母就长在这个错误的词根上,整串彻底跑偏(实测 `zhokgguo` 会变成「做哦贵哦」)。
    /// 保留原始输入、每次从它重新纠错,中间态再离谱也不会污染后续输入。
    /// 替换是等长的，所以候选记录的字符覆盖长度可用于原始 buffer。
    /// 如果以后增加插入/删除纠错，必须同时提供回到原始输入的偏移映射。
    private(set) var effectiveKey = ""
    var correctionApplied: Bool { effectiveKey != buffer }

    var isReady: Bool { dictionary.isReady }
    /// 词库是否真的加载到词条(资源缺失/被杀时为 false,用于给出可见提示而非静默走英文)。
    var dictionaryReady: Bool { dictionary.isReady && dictionary.loadedEntryCount > 0 }
    var isComposing: Bool { !buffer.isEmpty }

    /// 后台加载词库;完成回主线程回调。**加载期间旧词库仍是当前词库**(卸载后就是空的),
    /// 主线程读到的始终是一个完整状态。被 unload 作废的那一份不会回调 completion。
    func loadAsync(bundle: Bundle = .main, completion: @escaping () -> Void) {
        loadGeneration &+= 1
        let generation = loadGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fresh = PinyinDictionary()
            fresh.load(bundle: bundle)
            let seg = PinyinSegmenter(syllables: fresh.syllableSet)
            DispatchQueue.main.async {
                guard let self, generation == self.loadGeneration else { return }
                self.dictionary = fresh
                self.segmenter = seg
                completion()
            }
        }
    }

    /// 卸载词库,把内存整体还给系统。
    ///
    /// 词库只在**字母键盘的中文模式**下用得到:语音面、英文模式一行都不碰它。而键盘扩展
    /// 的内存上限是硬约束,以语音为主的会话里没有理由让整本词库常驻(见 工程规划.md §11.1d)。
    /// 换成空实例而不是逐个容器 `removeAll()`:后者会保留底层缓冲区,一个字节都还不回去。
    func unload() {
        loadGeneration &+= 1   // 作废在途加载
        dictionary = PinyinDictionary()
        segmenter = nil
        buffer = ""
        effectiveKey = ""
        candidates = []
    }

    // MARK: - 输入编辑

    /// 追加一个字母;返回是否被引擎接管(未就绪或非字母则不接管,交由键盘直接上屏)。
    @discardableResult
    func input(_ letter: Character) -> Bool {
        guard inputMode == .twentySixKey,
              isReady, letter.isLetter, letter.isASCII else { return false }
        buffer.append(Character(letter.lowercased()))
        recompute()
        return true
    }

    /// 九宫格一次点击只记录一个真实数字码，不猜测该键上的具体字母。
    @discardableResult
    func inputT9Digit(_ digit: Character) -> Bool {
        guard inputMode == .nineKey, isReady, T9KeyMap.isInputDigit(digit) else { return false }
        buffer.append(digit)
        recompute()
        return true
    }

    /// 显式分词边界只影响显示和后续扩展；查词时数字码仍保持同一串。
    @discardableResult
    func inputSeparator() -> Bool {
        guard inputMode == .nineKey, !buffer.isEmpty, buffer.last != "'" else { return false }
        buffer.append("'")
        recompute()
        return true
    }

    func setInputMode(_ mode: PinyinInputMode) {
        guard mode != inputMode else { return }
        clear()
        inputMode = mode
    }

    /// 退格:有 buffer 则删一个字母并重算,返回 true;否则 false(交键盘删文档)。
    @discardableResult
    func backspace() -> Bool {
        guard !buffer.isEmpty else { return false }
        buffer.removeLast()
        recompute()
        return true
    }

    func clear() {
        buffer = ""
        effectiveKey = ""
        candidates = []
    }

    /// 供显示的分段拼音(ni'hao)。
    /// 显示纠错后的拼写:用户看得见我们把他敲的字母当成了什么,不至于选出个莫名其妙的词。
    var displayComposition: String {
        if inputMode == .nineKey { return buffer }
        guard let segmenter else { return effectiveKey }
        return segmenter.display(effectiveKey)
    }

    // MARK: - 选词

    /// 选中候选只消费其实际覆盖的原始输入；过期快照拒绝提交，返回空text。
    struct Selection { let text: String; let hasRemainder: Bool }

    func select(_ candidate: PinyinCandidate) -> Selection {
        guard candidate.composition == buffer, candidate.inputMode == inputMode,
              candidate.consumedInputCount > 0,
              candidate.consumedInputCount <= buffer.count else {
            return Selection(text: "", hasRemainder: isComposing)
        }
        buffer = String(buffer.dropFirst(candidate.consumedInputCount))
        recompute()
        return Selection(text: candidate.word, hasRemainder: isComposing)
    }

    /// 直接把当前 buffer 当英文字母上屏(无候选或用户要打英文时)。
    func commitRaw() -> String {
        let raw = buffer
        clear()
        return raw
    }

    // MARK: - 候选计算

    private func recompute() {
        guard isReady, !buffer.isEmpty else { candidates = []; effectiveKey = buffer; return }
        if inputMode == .nineKey {
            recomputeT9()
            return
        }
        effectiveKey = buffer

        var result = generateCandidates(for: effectiveKey)
        let hasAbbreviationExactMatch = isInitialAbbreviation(effectiveKey)
            && !dictionary.initialWords(effectiveKey, limit: 1).isEmpty

        // ① 错点纠正:这串字母读不出来时,认为其中有键敲偏了,试着换成相邻键。
        //    只改查词用的 effectiveKey,不动 buffer(理由见 effectiveKey 的注释)。
        if needsCorrection(effectiveKey,
                           hasCandidates: !result.isEmpty,
                           hasAbbreviationExactMatch: hasAbbreviationExactMatch),
           let fixed = bestCorrection(for: effectiveKey) {
            effectiveKey = fixed
            result = generateCandidates(for: effectiveKey)
        }

        // ② 最后兜底:候选栏**永远不能空**(用户 2026-08-04 定的硬规则)。
        if result.isEmpty {
            result = lastResortCandidates(for: effectiveKey)
        }

        candidates = Array(result.prefix(200))
    }

    private func recomputeT9() {
        effectiveKey = T9KeyMap.normalizedDigits(buffer)
        let digits = effectiveKey
        guard !digits.isEmpty else { candidates = []; return }
        let boundaries = confirmedT9Boundaries()

        var result: [PinyinCandidate] = []
        var seen = Set<String>()
        func add(_ entries: [PinyinEntry], consumingDigits count: Int) {
            let consumed = rawT9PrefixLength(digitCount: count)
            for entry in entries where seen.insert(entry.word).inserted {
                result.append(candidate(entry, consuming: consumed))
            }
        }

        add(dictionary.t9ExactWords(digits, confirmedBoundaries: boundaries), consumingDigits: digits.count)
        let exactCount = result.count
        add(dictionary.t9PrefixWords(digits, confirmedBoundaries: boundaries), consumingDigits: digits.count)
        let completionEnd = result.count
        var explicitFirstPart: PinyinCandidate?

        // 已完整输入的前段词；选中后继续解码余串。
        // 与“当前输入是更长词的前缀”的补全不同，这些词不能消耗整个buffer。
        if digits.count > 1 {
            var partials: [(entries: [PinyinEntry], count: Int)] = []
            for length in stride(from: digits.count - 1, through: 1, by: -1) {
                let prefix = String(digits.prefix(length))
                let prefixBoundaries = boundaries.filter { $0 <= length }
                let entries = dictionary.t9ExactWords(prefix, confirmedBoundaries: prefixBoundaries, limit: 24)
                if !entries.isEmpty { partials.append((entries, length)) }
                if length == boundaries.first, let entry = entries.first {
                    explicitFirstPart = candidate(entry, consuming: rawT9PrefixLength(digitCount: length))
                }
            }
            // 候选栏只显示六个词。先为各覆盖长度各给一个位置，避免同一长码的
            // 大量同音字把“我”等较短前段挤到永远无法点击的位置。
            partialRanks: for rank in 0..<24 {
                for partial in partials where rank < partial.entries.count {
                    add([partial.entries[rank]], consumingDigits: partial.count)
                    if result.count >= 200 { break partialRanks }
                }
            }
        }
        // 大词库可能有大量补全：为最长已完成的前段保留一个可见位置。
        // 全码精确词仍优先，不让未来的长词补全挤掉用户已经打完的词。
        if let explicitFirstPart {
            // Explicitly separated input must allow committing its first segment even
            // when the larger dictionary offers a complete phrase such as 我明天.
            let longestPart = completionEnd < result.count ? result[completionEnd] : nil
            let promoted = [explicitFirstPart, longestPart].compactMap { $0 }
                .reduce(into: [PinyinCandidate]()) { rows, row in
                    if !rows.contains(where: { $0.word == row.word }) { rows.append(row) }
                }
            for row in promoted { result.removeAll { $0.word == row.word } }
            result.insert(contentsOf: promoted, at: min(4, result.count))
        } else if exactCount < 6, completionEnd > 5, completionEnd < result.count {
            result.insert(result.remove(at: completionEnd), at: max(exactCount, 5))
        }
        // 极端数字串仍保持候选栏非空，但兜底只消费首个数字。
        if result.isEmpty, let first = digits.first {
            add(dictionary.t9PrefixWords(String(first), excludingExact: false, limit: 24), consumingDigits: 1)
        }
        candidates = Array(result.prefix(200))
    }

    /// 数字偏移映射回含分隔符的原始输入；末尾紧邻的分隔符一并消费，
    /// 余串内部的其他分隔符保持原样。
    private func rawT9PrefixLength(digitCount: Int) -> Int {
        var digits = 0
        var length = 0
        for character in buffer {
            if T9KeyMap.isInputDigit(character) {
                if digits == digitCount { break }
                digits += 1
            }
            length += 1
        }
        return length
    }

    private func candidate(_ entry: PinyinEntry, consuming count: Int) -> PinyinCandidate {
        PinyinCandidate(entry: entry, consumedInputCount: count,
                        composition: buffer, inputMode: inputMode)
    }

    private func confirmedT9Boundaries() -> [Int] {
        var digitCount = 0
        var result: [Int] = []
        for character in buffer {
            if T9KeyMap.isInputDigit(character) {
                digitCount += 1
            } else if character == "'", digitCount > 0, result.last != digitCount {
                result.append(digitCount)
            }
        }
        return result
    }

    private func generateCandidates(for key: String) -> [PinyinCandidate] {
        var result: [PinyinCandidate] = []
        var seen = Set<String>()
        func add(_ arr: [PinyinEntry], consuming count: Int) {
            for entry in arr where seen.insert(entry.word).inserted {
                result.append(candidate(entry, consuming: count))
            }
        }

        add(dictionary.exactWords(flatKey: key), consuming: key.count)

        if let sentence = sentenceCandidate(for: key), seen.insert(sentence.word).inserted {
            // 整句放在精确单词之后、前缀之前
            result.append(sentence)
        }

        if isInitialAbbreviation(key) {
            add(dictionary.initialWords(key), consuming: key.count)
        }

        add(dictionary.prefixWords(flatKey: key), consuming: key.count)

        // 首音节单字兜底
        if let segmenter {
            let seg = segmenter.segment(key)
            if let first = seg.syllables.first {
                add(dictionary.chars(forSyllable: first), consuming: first.count)
            }
        }

        return result
    }

    /// 首版接受 2–6 个合法音节首字母。零声母音节允许 a/e/o；i/u/v 不能起普通话音节。
    /// zh/ch/sh 按首字母 z/c/s 建索引。
    private func isInitialAbbreviation(_ text: String) -> Bool {
        guard (2...6).contains(text.count) else { return false }
        let initials = Set("abcdefghijklmnopqrstuvwxyz".filter { !"iuv".contains($0) })
        return text.allSatisfy { initials.contains($0) }
    }

    // MARK: - 错点纠正

    /// 什么时候认定"这串字母读不出来、该纠错了":
    ///  ① 一个候选都给不出;或
    ///  ② 切不完,而且尾巴上那截**连某个合法音节的前缀都不是**。
    ///
    /// ② 里的前缀判断是关键的克制点。`nih` 的尾巴 `h` 是 `ha/hao/hen…` 的前缀,说明用户
    /// 还在打这个音节,这时候纠错就是抢答;而 `nihqo` 的尾巴 `hqo` 不可能是任何音节的开头,
    /// 那就不是"还在打",是真敲偏了。
    ///
    /// 已知限制:`xiezup`(想打 xiezuo)这类——尾巴 `p` 本身是合法声母——从信息上无法与
    /// "打完 xiezu 正要接着打 p…" 区分,因此**不触发**纠错。要覆盖这类只能把纠错结果作为
    /// 额外候选并排进列表(而不是改写 buffer),那是另一个设计,见 工程规划.md §11.10。
    private func needsCorrection(_ text: String,
                                 hasCandidates: Bool,
                                 hasAbbreviationExactMatch: Bool) -> Bool {
        guard let segmenter else { return false }
        if hasAbbreviationExactMatch { return false }
        if !hasCandidates { return true }
        let seg = segmenter.segment(text)
        guard !seg.remainder.isEmpty else { return false }
        return !segmenter.isSyllablePrefix(seg.remainder)
    }

    /// 在"替换 ≤ maxSubstitutions 个字母为键盘相邻键"的空间里,找拼得最通顺的一条。
    ///
    /// 打分优先级:能切出的音节覆盖长度 → 是否全覆盖 → 词频 → 替换个数 → 替换距离。
    /// 覆盖长度排第一是刻意的:纠错的目的是让这串字母**能读**,而不是去找一个高频词。
    private func bestCorrection(for text: String) -> String? {
        guard let segmenter, text.count >= 1 else { return nil }

        struct Scored {
            let text: String
            let coverage: Int
            let fullyCovered: Bool
            /// 命中层级:2 = 整串就是词库里的一个词,1 = 是某个更长词的前缀,0 = 只能逐字拼。
            ///
            /// ★ 必须排在词频前面。单字的词频和词的词频**不可比**——「我」这类字的频次比
            /// 绝大多数词高几个数量级,只比频次的话 `qoanyue` 会被纠成 `woanyue`(我按月)
            /// 而不是 `qianyue`(签约),`higou` 会被纠成 `nigou`(你够)而不是 `jigou`(机构)。
            /// 先比"是不是真凑出了一个词",再在同层级内比频次。
            let matchTier: Int
            let topFreq: Int
            let substitutions: Int
            let distance: Double
        }

        func score(_ variant: String, substitutions: Int, distance: Double) -> Scored? {
            let seg = segmenter.segment(variant)
            // "读得出来的长度":切成完整音节的部分,加上尾巴——尾巴只有在它还是某个合法音节的
            // 前缀时才算数(用户还没敲完这个音节)。
            //
            // ★ 这条尾巴是关键。只看 `seg.consumed` 会让"半截但走在正道上"的变体得 0 分被丢掉:
            // `zhok` 想纠成 `zhon`(zhong 打了一半)时 consumed=0,而歪掉的 `zuok` 反而
            // consumed=2 胜出。把合法前缀计入长度后 `zhon` 得 4 分,正道才赢得了歪路。
            let tailCounts = !seg.remainder.isEmpty && segmenter.isSyllablePrefix(seg.remainder)
            let readable = seg.consumed + (tailCounts ? seg.remainder.count : 0)
            guard readable > 0 else { return nil }
            let tier: Int
            let freq: Int
            if let exact = dictionary.exactWords(flatKey: variant, limit: 1).first {
                tier = 2
                freq = exact.freq
            } else if let prefix = dictionary.prefixWords(flatKey: variant, limit: 1).first {
                tier = 1
                freq = prefix.freq
            } else {
                tier = 0
                freq = seg.syllables.first
                    .flatMap { dictionary.chars(forSyllable: $0, limit: 1).first?.freq } ?? 0
            }
            return Scored(text: variant,
                          coverage: readable,
                          fullyCovered: seg.remainder.isEmpty,
                          matchTier: tier,
                          topFreq: freq,
                          substitutions: substitutions,
                          distance: distance)
        }

        func isBetter(_ lhs: Scored, than rhs: Scored) -> Bool {
            if lhs.coverage != rhs.coverage { return lhs.coverage > rhs.coverage }
            if lhs.fullyCovered != rhs.fullyCovered { return lhs.fullyCovered }
            if lhs.matchTier != rhs.matchTier { return lhs.matchTier > rhs.matchTier }
            if lhs.topFreq != rhs.topFreq { return lhs.topFreq > rhs.topFreq }
            if lhs.substitutions != rhs.substitutions { return lhs.substitutions < rhs.substitutions }
            return lhs.distance < rhs.distance
        }

        // 基线 = 原样不改。所有变体都必须**赢过它**才配替换,否则宁可不动用户敲的字母。
        var best: Scored? = score(text, substitutions: 0, distance: 0)
        var firstRound: [Scored] = []
        for variant in corrector.singleSubstitutions(of: text) {
            guard let scored = score(variant.text, substitutions: 1, distance: variant.distance) else { continue }
            firstRound.append(scored)
            if best == nil || isBetter(scored, than: best!) { best = scored }
        }
        if let best, best.fullyCovered { return best.text }

        // 第二轮:只在第一轮最有希望的几条上再替一个字母,避免 O(L²·N²) 爆炸。
        if PinyinCorrector.maxSubstitutions >= 2 {
            let beam = firstRound
                .sorted { isBetter($0, than: $1) }
                .prefix(PinyinCorrector.beamWidth)
            for seed in beam {
                for variant in corrector.singleSubstitutions(of: seed.text) {
                    guard let scored = score(variant.text,
                                             substitutions: 2,
                                             distance: seed.distance + variant.distance) else { continue }
                    if best == nil || isBetter(scored, than: best!) { best = scored }
                }
            }
        }
        // 基线胜出 → 不改写。
        guard let winner = best, winner.text != text else { return nil }
        return winner.text
    }

    /// 绝对兜底:连纠错都拼不出音节时,至少给出首字母(或它最近的能起头的邻居)对应的单字。
    /// 例如 `i`/`u`/`v` 在普通话里不能起头,它们的邻居 `o`/`y`/`c` 可以——所以任何输入都有汉字可选。
    private func lastResortCandidates(for text: String) -> [PinyinCandidate] {
        guard let first = text.first else { return [] }
        for letter in [first] + corrector.neighborLetters(of: first) {
            let syllables = dictionary.syllables(startingWith: letter)
            var result: [PinyinEntry] = []
            var seen = Set<String>()
            for syllable in syllables {
                for entry in dictionary.chars(forSyllable: syllable, limit: 8)
                where seen.insert(entry.word).inserted {
                    result.append(entry)
                }
                if result.count >= 12 { break }
            }
            if !result.isEmpty {
                return result.sorted { $0.freq > $1.freq }.map { candidate($0, consuming: 1) }
            }
        }
        return []
    }

    /// 整句贪心:对完整切分序列,反复取「当前起点最长可成词的前缀」拼接。
    private func sentenceCandidate(for key: String) -> PinyinCandidate? {
        guard let segmenter else { return nil }
        let seg = segmenter.segment(key)
        let sylls = seg.syllables
        guard sylls.count >= 2 else { return nil }

        var pieces: [String] = []
        var i = 0
        while i < sylls.count {
            var matched: PinyinEntry?
            var matchLen = 0
            // 从最长可能词到单字
            var j = sylls.count
            while j > i {
                let key = sylls[i..<j].joined()
                if let best = dictionary.exactWords(flatKey: key, limit: 1).first {
                    matched = best; matchLen = j - i; break
                }
                j -= 1
            }
            if let m = matched, matchLen > 0 {
                pieces.append(m.word)
                i += matchLen
            } else {
                // 不能跳过无词音节，否则会消费没有上屏的输入。
                break
            }
        }
        guard pieces.count >= 1 else { return nil }
        let sentence = pieces.joined()
        // 若整句就等于某个已在精确里的单词,则不重复
        guard sentence.count >= 2 else { return nil }
        let consumed = sylls.prefix(i).reduce(0) { $0 + $1.count }
        return candidate(PinyinEntry(word: sentence, syllableCount: i, freq: 1), consuming: consumed)
    }

    // MARK: - 语音热词同源

    /// 把中文热词表转成拼音用户词并注入(英文/混写词跳过)。
    func setHotwords(_ words: [String]) {
        var pairs: [(word: String, syllables: [String])] = []
        for w in words {
            let trimmed = w.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var sylls: [String] = []
            var ok = true
            for ch in trimmed {
                if let p = dictionary.pinyin(forChar: ch) {
                    sylls.append(p)
                } else { ok = false; break }   // 含非中文字符,跳过整词
            }
            if ok && !sylls.isEmpty { pairs.append((trimmed, sylls)) }
        }
        dictionary.setUserWords(pairs)
    }
}
