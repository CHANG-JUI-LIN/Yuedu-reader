import Foundation

// Unified library 5d-3e: 書庫順序 (Phase 5 plan, decision 21), Emby's `OrderedViews`. One
// order for the libraries (saved connections, Gutenberg, 青空文庫) wherever they are listed
// together: 範圍, 瀏覽書庫, and the turns 最新's books take. Book sources keep the order their
// own management gives them, after the libraries; the shelf is not a library here.

enum LibraryOrder {
    /// Whether a source is one of the libraries 書庫順序 orders.
    static func isLibrary(_ key: SourceInstanceKey) -> Bool {
        switch key.type {
        case .opds, .calibre, .webDAV, .gutenberg, .aozora: true
        case .library, .bibliographic, .bookSource: false
        }
    }

    /// The libraries there are now, in the order they have before the reader chooses one:
    /// saved connections as saved, then Gutenberg and 青空文庫 where they are offered.
    static func defaultKeys(connections: [RemoteLibraryConnection], librariesAvailable: Bool) -> [SourceInstanceKey] {
        var keys = connections.map { SourceInstanceKey(type: ProviderType($0.kind), id: $0.id) }
        if librariesAvailable {
            keys.append(SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue))
            keys.append(SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue))
        }
        return keys
    }

    /// `items` with their libraries in `order`; everything else keeps its place.
    /// - A library `order` names goes where `order` puts it.
    /// - One it does not name (a connection added since) follows those, in the order it came.
    /// - A key in `order` that is not among `items` (a removed connection, Gutenberg in China)
    ///   is passed over.
    /// The libraries fill the places libraries had, so the shelf's row stays first and book
    /// sources stay after.
    static func arrange<Item>(_ items: [Item], by order: [SourceInstanceKey]?, key: (Item) -> SourceInstanceKey) -> [Item] {
        guard let order, !order.isEmpty else { return items }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let slots = items.indices.filter { isLibrary(key(items[$0])) }
        let libraries = slots.enumerated()
            .sorted { lhs, rhs in
                let left = rank[key(items[lhs.element])] ?? order.count
                let right = rank[key(items[rhs.element])] ?? order.count
                return (left, lhs.offset) < (right, rhs.offset)
            }
            .map { items[$0.element] }
        var arranged = items
        for (slot, library) in zip(slots, libraries) { arranged[slot] = library }
        return arranged
    }
}
