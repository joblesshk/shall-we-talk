import Foundation

/// 键位相邻纠错:把敲错的字母换成键盘上物理相邻的字母,让一串拼不出音节的字母重新拼得出。
///
/// 只做**等长替换**,不做插入/删除——这不是偷懒,是刻意的约束:替换保持"字母数 = 原输入字母数",
/// 于是纠正后的音节序列消耗掉几个字母,原始输入就消耗掉同样几个,`PinyinEngine.select` 里
/// 那套"音节数 → 字母数"的换算一行都不用改。插入/删除会打破这个对齐关系。
///
/// 邻接表由键盘的**真实几何**推出,不是手写的:三排字母在 iOS 竖屏布局里的横向错位分别是
/// 0 / 0.5 / 1.5 个键宽(实测 q 左缘 4.00pt、a 左缘 24.90pt、z 左缘 66.70pt,键距 41.8pt),
/// 排距 56pt = 1.34 个键宽。距离以"键宽"为单位算,阈值 1.75 恰好收进:
///   · 同排左右邻居(1.00)
///   · 斜上/斜下近邻(√(0.5²+1.34²) = 1.43,如 e↔s、e↔d)
///   · 二三排对齐的上下邻居(1.34,如 s↔z——iOS 的 z 正好在 s 正下方)
///   · 斜上/斜下远邻(√(1.0²+1.34²) = 1.67,如 a↔z)
/// 而排除掉隔一个键的同排邻居(2.00)和跨两排(2.68)——那些已经不像是手滑能碰到的。
struct PinyinCorrector {
    /// (字母, 到原键的距离);按距离升序,近的先试。
    private let neighbors: [Character: [(letter: Character, distance: Double)]]

    /// 一次纠错最多替换几个字母。两个已经能覆盖绝大多数手滑;再多会开始"猜"而不是"纠"。
    static let maxSubstitutions = 2
    /// 第二轮从第一轮里挑几条最有希望的继续替。控制住 O(L²·N²) 的爆炸。
    static let beamWidth = 6

    init() {
        neighbors = Self.buildNeighbors()
    }

    func neighborLetters(of letter: Character) -> [Character] {
        neighbors[letter]?.map(\.letter) ?? []
    }

    /// `text` 的所有单字母替换变体,按替换距离升序。
    func singleSubstitutions(of text: String) -> [(text: String, distance: Double)] {
        var chars = Array(text)
        var out: [(String, Double)] = []
        for i in chars.indices {
            let original = chars[i]
            guard let options = neighbors[original] else { continue }
            for option in options {
                chars[i] = option.letter
                out.append((String(chars), option.distance))
            }
            chars[i] = original
        }
        return out.sorted { $0.1 < $1.1 }
    }

    // MARK: - 邻接表

    private static func buildNeighbors() -> [Character: [(letter: Character, distance: Double)]] {
        /// (这一排的字母, 相对第 1 排左缘的横向错位,单位=键宽)
        let rows: [(letters: String, offset: Double)] = [
            ("qwertyuiop", 0.0),
            ("asdfghjkl", 0.5),
            ("zxcvbnm", 1.5)
        ]
        /// 排距 56pt ÷ 键距 41.8pt。
        let rowPitch = 56.0 / 41.8
        let threshold = 1.75

        var centers: [(letter: Character, x: Double, y: Double)] = []
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, letter) in row.letters.enumerated() {
                centers.append((letter,
                                row.offset + Double(columnIndex) + 0.5,
                                Double(rowIndex) * rowPitch))
            }
        }

        var table: [Character: [(letter: Character, distance: Double)]] = [:]
        for origin in centers {
            var list: [(Character, Double)] = []
            for other in centers where other.letter != origin.letter {
                let dx = other.x - origin.x
                let dy = other.y - origin.y
                let distance = (dx * dx + dy * dy).squareRoot()
                if distance <= threshold { list.append((other.letter, distance)) }
            }
            table[origin.letter] = list.sorted { $0.1 < $1.1 }
        }
        return table
    }
}
