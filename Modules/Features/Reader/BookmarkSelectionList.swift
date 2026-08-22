import SwiftUI

struct BookmarkSelectionList: View {
    var items: [Bookmark]
    @Binding var selection: Set<UUID>
    var primaryText: (Bookmark) -> String
    var primaryLines: Int
    var dateText: (Bookmark) -> String
    var pageText: (Bookmark) -> String?
    /// 這條標註的筆記；沒有筆記回傳 nil。
    var noteText: (Bookmark) -> String? = { _ in nil }
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
                    page: pageText(bm),
                    note: noteText(bm)
                )
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    onDelete(bm)
                } label: {
                    Label(localized("刪除"), systemImage: "trash")
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Row

/// 書籤列：主標題＋日期（次行）＋頁碼（靠右），純 SwiftUI 實作。
private struct BookmarkRow: View {
    let primary: String
    let primaryLines: Int
    let date: String
    let page: String?
    let note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(primary)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(primaryLines)
                if let note, !note.isEmpty {
                    Label(note, systemImage: "note.text")
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(2)
                        .accessibilityLabel(String(format: localized("筆記：%@"), note))
                }
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
