import Foundation

/// A reader-chosen order over a fixed set of items: the bottom tabs (feedback #92) and the
/// reader's bottom-bar tools (#36). One resolver for both, so the two screens cannot drift
/// apart on what an old, partial or foreign saved order means.
///
/// The stored form is a list of item ids. Empty means "no saved order" — the items' default
/// order, exactly as before ordering existed — and `stored(_:defaults:id:)` writes empty again
/// whenever a reorder lands back on the default, so a later change to the default still
/// reaches readers who never moved anything.
enum CustomItemOrder {
    /// `saved` applied over `defaults`. Ids that name no default item (a tab this build does
    /// not draw, a tool from a newer version) are dropped, duplicates keep their first place,
    /// and a default item `saved` does not name — added after the order was saved — goes
    /// right after the nearest item that precedes it in `defaults`, or first if none does.
    nonisolated static func resolve<Item>(
        _ saved: [String],
        defaults: [Item],
        id: (Item) -> String
    ) -> [Item] {
        guard !saved.isEmpty else { return defaults }
        let defaultIDs = defaults.map(id)
        var byID: [String: Item] = [:]
        for (key, item) in zip(defaultIDs, defaults) where byID[key] == nil {
            byID[key] = item
        }

        var orderedIDs: [String] = []
        for key in saved where byID[key] != nil && !orderedIDs.contains(key) {
            orderedIDs.append(key)
        }
        for (index, key) in defaultIDs.enumerated() where !orderedIDs.contains(key) {
            let anchor = defaultIDs[..<index].reversed().lazy
                .compactMap { orderedIDs.firstIndex(of: $0) }
                .first
            orderedIDs.insert(key, at: anchor.map { $0 + 1 } ?? 0)
        }
        return orderedIDs.compactMap { byID[$0] }
    }

    /// What to persist for `order`: its ids, or empty when it is the default order.
    nonisolated static func stored<Item>(
        _ order: [Item],
        defaults: [Item],
        id: (Item) -> String
    ) -> [String] {
        let ids = order.map(id)
        return ids == defaults.map(id) ? [] : ids
    }

    /// `order` with the items at `source` moved to `destination` — the arguments `onMove`
    /// hands over, with `destination` meaning "before the item now at this index".
    nonisolated static func moved<Item>(
        _ order: [Item],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [Item] {
        let destination = min(max(destination, 0), order.count)
        let moving = source.filter { order.indices.contains($0) }.map { order[$0] }
        var result: [Item] = []
        for (index, item) in order.enumerated() {
            if index == destination { result.append(contentsOf: moving) }
            if !source.contains(index) { result.append(item) }
        }
        if destination == order.count { result.append(contentsOf: moving) }
        return result
    }

    /// `order` with the item at `index` swapped one place up (`-1`) or down (`+1`): the
    /// VoiceOver 上移／下移 actions, which must land where a drag would have.
    nonisolated static func shifted<Item>(_ order: [Item], at index: Int, by step: Int) -> [Item] {
        let target = index + step
        guard order.indices.contains(index), order.indices.contains(target) else { return order }
        var result = order
        result.swapAt(index, target)
        return result
    }
}
