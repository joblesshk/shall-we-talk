import AppKit

@main
enum PasteboardSnapshotSmoke {
    static func main() {
        // Use a private board: never read or overwrite the user's clipboard.
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
        }
        func representations() -> [[NSPasteboard.PasteboardType: Data]] {
            (board.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.map { ($0, item.data(forType: $0)!) })
            }
        }
        let examples: [[[(NSPasteboard.PasteboardType, Data)]]] = [
            [],
            [[(.string, Data("中文 👩🏽‍💻\ntext".utf8))]],
            [[(.string, Data("styled".utf8)), (.rtf, Data("{\\rtf1 styled}".utf8))]],
            [[(.png, Data([137, 80, 78, 71, 13, 10, 26, 10]))]],
            [[(.fileURL, Data("file:///tmp/example-one.txt".utf8))],
             [(.fileURL, Data("file:///tmp/example-two.txt".utf8))]],
            [[(.string, Data("one".utf8))], [(.string, Data("two".utf8))]],
        ]
        for (index, example) in examples.enumerated() {
            board.clearContents()
            let items = example.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { require(board.writeObjects(items), "seed board \(index)") }
            let expected = representations()
            guard let saved = PasteboardSnapshot.capture(from: board) else {
                fatalError("snapshot failed for case \(index)")
            }
            board.clearContents()
            require(board.setString("dictation", forType: .string), "write dictation")
            require(saved.restore(to: board, ifUnchangedSince: board.changeCount), "restore case \(index)")
            require(representations() == expected, "lost pasteboard data in case \(index)")
        }
        board.clearContents()
        board.setString("before", forType: .string)
        let saved = PasteboardSnapshot.capture(from: board)!
        board.clearContents()
        board.setString("dictation", forType: .string)
        let ours = board.changeCount
        board.clearContents()
        board.setString("new copy", forType: .string)
        require(!saved.restore(to: board, ifUnchangedSince: ours), "must reject stale restoration")
        require(board.string(forType: .string) == "new copy", "overwrote a newer copy")
        print("PASS: pasteboard snapshot (text/RTF/image/files/multiple items/empty/newer copy)")
    }
}
