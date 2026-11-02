import SwiftUI

/// 目錄's 正序／倒序 (回饋 #37), shared by every chapter list: the reader's 目錄, the comic
/// reader's 目錄 and 作品詳情's full 目錄.
///
/// Display only. legado and Sigma reverse the stored table of contents and renumber it — a
/// repair for sources that list newest first, which also flips 上一章／下一章. MD3 reverses the
/// rows it shows and leaves the chapters alone; this follows MD3, so `BookChapter.index`,
/// reading positions and chapter navigation never see the order.
enum ChapterListOrder: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: Self { self }

    var title: String {
        switch self {
        case .ascending: localized("正序")
        case .descending: localized("倒序")
        }
    }

    /// `items` in this order. Descending keeps each heading above the entries nested under it
    /// (`level` deeper than the heading's) and reverses every level on its own — MD3's
    /// `reverseTocHierarchy` — so a volume's chapters stay under that volume.
    func arranged<Item>(_ items: [Item], level: (Item) -> Int = { _ in 0 }) -> [Item] {
        guard self == .descending, items.count > 1 else { return items }

        typealias Node = ChapterListOrderNode<Item>
        var roots: [Node] = []
        var ancestors: [Node] = []
        for item in items {
            // A level deeper than its parent's +1 (a malformed EPUB nav) hangs under the deepest
            // open ancestor rather than inventing missing levels.
            while ancestors.count > max(level(item), 0) { ancestors.removeLast() }
            let node = Node(item)
            if let parent = ancestors.last { parent.children.append(node) } else { roots.append(node) }
            ancestors.append(node)
        }

        var result: [Item] = []
        result.reserveCapacity(items.count)
        func appendReversed(_ nodes: [Node]) {
            for node in nodes.reversed() {
                result.append(node.item)
                appendReversed(node.children)
            }
        }
        appendReversed(roots)
        return result
    }

    // MARK: Per-book memory

    /// The books whose 目錄 is 倒序, by book id. Per book, as legado, Sigma and MD3 keep it
    /// (`Book.ReadConfig.reverseToc`): the order is about one book's source, not a reading habit.
    static let descendingBooksKey = "yd_toc_descending_books"

    /// The order last chosen for `bookID`; ascending for a book never switched, and for a book
    /// that is not on the shelf (no id), whose choice lasts only while its 目錄 is open.
    static func stored(for bookID: UUID?, defaults: UserDefaults = .standard) -> ChapterListOrder {
        guard let bookID else { return .ascending }
        let descending = defaults.stringArray(forKey: descendingBooksKey) ?? []
        return descending.contains(bookID.uuidString) ? .descending : .ascending
    }

    /// A 目錄's order control: reads `stored(for:)` until the reader picks one, then holds the
    /// pick in `chosen` and saves it for the book.
    static func binding(chosen: Binding<ChapterListOrder?>, for bookID: UUID?) -> Binding<ChapterListOrder> {
        Binding(
            get: { chosen.wrappedValue ?? stored(for: bookID) },
            set: { order in
                chosen.wrappedValue = order
                store(order, for: bookID)
            }
        )
    }

    static func store(_ order: ChapterListOrder, for bookID: UUID?, defaults: UserDefaults = .standard) {
        guard let bookID else { return }
        var descending = defaults.stringArray(forKey: descendingBooksKey) ?? []
        descending.removeAll { $0 == bookID.uuidString }
        if order == .descending { descending.append(bookID.uuidString) }
        defaults.set(descending, forKey: descendingBooksKey)
    }
}

private final class ChapterListOrderNode<Item> {
    let item: Item
    var children: [ChapterListOrderNode] = []
    init(_ item: Item) { self.item = item }
}

/// The 目錄 toolbar's 正序／倒序 control: a native menu holding a picker, so the choice shows a
/// checkmark and VoiceOver reads 排序 with the current order as its value.
struct ChapterListOrderMenu: View {
    @Binding var order: ChapterListOrder

    var body: some View {
        Menu {
            Picker(localized("排序"), selection: $order) {
                ForEach(ChapterListOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(localized("排序"), systemImage: "arrow.up.arrow.down")
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel(localized("排序"))
        .accessibilityValue(order.title)
        .accessibilityIdentifier("toc.order")
    }
}

#Preview("目錄排序選單") {
    @Previewable @State var order = ChapterListOrder.descending
    NavigationStack {
        List(order.arranged(Array(1...20)), id: \.self) { number in
            Text(String(format: localized("第 %d 章"), number))
        }
        .navigationTitle(localized("目錄"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ChapterListOrderMenu(order: $order)
            }
        }
    }
}
