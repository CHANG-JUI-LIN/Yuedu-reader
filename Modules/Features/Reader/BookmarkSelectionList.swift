import SwiftUI

struct BookmarkSelectionList: View {
    var items: [Bookmark]
    @Binding var selection: Set<UUID>
    var primaryText: (Bookmark) -> String
    var primaryLines: Int
    var dateText: (Bookmark) -> String
    var pageText: (Bookmark) -> String?
    var onSelect: (Bookmark) -> Void
    var onDelete: (Bookmark) -> Void

    var body: some View {
        List(items, selection: $selection) { bm in
            Button {
                onSelect(bm)
            } label: {
                BookmarkRow(
                    primary: primaryText(bm),
                    primaryLines: primaryLines,
                    date: dateText(bm),
                    page: pageText(bm)
                )
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    onDelete(bm)
                } label: {
                    Label(localized("刪除"), systemImage: "trash")
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Row

/// 書籤列：主標題＋日期（次行）＋頁碼（靠右），純 SwiftUI 實作。
private struct BookmarkRow: View {
    let primary: String
    let primaryLines: Int
    let date: String
    let page: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(primary)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(primaryLines)
                Text(date)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
            }

            Spacer(minLength: 0)

            if let page {
                Text(page)
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
            }
        }
        .padding(.vertical, DSSpacing.xs)
    }
}
