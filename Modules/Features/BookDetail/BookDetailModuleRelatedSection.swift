import SwiftUI

/// 相關作品 on 作品詳情 (format 3.0.2): the works a module's site relates to the work, as a row
/// of covers under the module's name. Not shown until read, nor when no module relates any
/// (`WorkRelated`): no header over a spinner that could then vanish and move the page.
struct BookDetailModuleRelatedSection: View {
    let related: WorkRelatedSet?
    let onSelect: (WorkDetailRoute) -> Void
    @EnvironmentObject private var store: BookStore

    var body: some View {
        if let related, !related.entries.isEmpty {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                BookDetailSectionHeader(title: localized("相關作品"), trailing: related.moduleTitle)
                    .padding(.horizontal, DSSpacing.lg)
                    .accessibilityIdentifier("detail.moduleRelated.header")
                BookDetailCoverShelf(cards: HomeRowContent(entries: related.entries, store: store).cards,
                                     identifier: "detail.moduleRelated.book", onSelect: onSelect)
                BookDetailSectionRule()
                    .padding(.horizontal, DSSpacing.lg)
            }
        }
    }
}

#if DEBUG
#Preview("相關作品") {
    let index = AozoraCatalogIndex.preview
    return ScrollView {
        BookDetailModuleRelatedSection(
            related: WorkRelatedSet(moduleID: "preview.module", moduleTitle: "豆瓣讀書",
                                    entries: index.newWorks.map { CollectionEntry.aozora($0, index: index) }),
            onSelect: { _ in })
    }
    .environmentObject(BookStore())
}
#endif
