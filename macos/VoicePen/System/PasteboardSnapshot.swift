import AppKit

/// Materialize all advertised representations before replacing the pasteboard.
/// A failed or racing read must not turn into a partial, destructive backup.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        let version = pasteboard.changeCount
        guard let sourceItems = pasteboard.pasteboardItems else {
            guard pasteboard.types?.isEmpty == true,
                  pasteboard.changeCount == version else { return nil }
            return PasteboardSnapshot(items: [])
        }
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in sourceItems {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                representations[type] = data
            }
            items.append(representations)
        }
        guard pasteboard.changeCount == version else { return nil }
        return PasteboardSnapshot(items: items)
    }

    @discardableResult
    func restore(to pasteboard: NSPasteboard, ifUnchangedSince version: Int) -> Bool {
        let restored = items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        guard pasteboard.changeCount == version else { return false }
        pasteboard.clearContents()
        return restored.isEmpty || pasteboard.writeObjects(restored)
    }
}
