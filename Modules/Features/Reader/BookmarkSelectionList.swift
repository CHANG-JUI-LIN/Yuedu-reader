import SwiftUI

/// 章節分組的書籤／重點清單：每章一個 `Section`，章名可點（跳回本章開頭），
/// 底下是這章的卡片，每張卡片跳回它自己那一頁。
///
/// 用 `List` 搭配 `selection` 綁定，系統就會自帶 iOS 原生的兩指拖曳多選手勢；
/// 卡片外觀走 `listRowBackground`，不是自己疊一層 `ScrollView`，所以滑動刪除、
/// 編輯模式、VoiceOver 的清單語意都還在。
struct BookmarkSelectionList: View {
    var groups: [ReaderBookmarkChapterGroup]
    @Binding var selection: Set<UUID>
    /// 章名用目前的目錄解析，不是書籤存檔時的那份——換源或目錄更新後才不會顯示舊章名。
    var chapterTitle: (ReaderBookmarkChapterGroup) -> String
    var primaryText: (Bookmark) -> String
    var icon: (Bookmark) -> String
    var dateText: (Bookmark) -> String
    var pageText: (Bookmark) -> String?
    /// 這條標註的筆記；沒有筆記回傳 nil。
    var noteText: (Bookmark) -> String? = { _ in nil }
    var onSelect: (Bookmark) -> Void
    var onSelectChapter: (ReaderBookmarkChapterGroup) -> Void
    var onDelete: (Bookmark) -> Void
    /// 這條書籤的位置是不是對著這台裝置讀的文字（`ConvertedTextVersions`）。轉換書換了
    /// 轉換版本後，另一版的書籤照列、變灰、不能跳，編輯模式照樣能選取刪除。
    var indexesReadText: (Bookmark) -> Bool = { _ in true }

    @Environment(\.editMode) private var editMode

    /// 多選期間整張清單只做一件事：選取。卡片與章名的跳轉在這時候收起來，
    /// 否則勾選第三張卡片的手指會把 sheet 關掉、跳走。
    private var isEditing: Bool { editMode?.wrappedValue.isEditing ?? false }

    var body: some View {
        List(selection: $selection) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { bm in
                        BookmarkCardRow(
                            icon: icon(bm),
                            primary: primaryText(bm),
                            date: dateText(bm),
                            page: pageText(bm),
                            note: noteText(bm),
                            indexesReadText: indexesReadText(bm),
                            isEditing: isEditing,
                            onSelect: { onSelect(bm) },
                            onDelete: { onDelete(bm) }
                        )
                        .listRowInsets(EdgeInsets(
                            top: DSSpacing.xs, leading: DSSpacing.lg,
                            bottom: DSSpacing.xs, trailing: DSSpacing.lg
                        ))
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                                .fill(DSColor.surface)
                                .padding(.vertical, DSSpacing.xs)
                        )
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                onDelete(bm)
                            } label: {
                                Label(localized("刪除"), systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    chapterHeader(group)
                }
            }
        }
        .softScrollEdges()
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func chapterHeader(_ group: ReaderBookmarkChapterGroup) -> some View {
        let title = Text(chapterTitle(group))
            .font(DSFont.title3)
            .foregroundStyle(DSColor.textPrimary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

        Group {
            if isEditing {
                title.accessibilityAddTraits(.isHeader)
            } else {
                Button { onSelectChapter(group) } label: { title }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHint(localized("點兩下跳至本章開頭"))
            }
        }
        .textCase(nil)
        .listRowInsets(EdgeInsets(
            top: DSSpacing.lg, leading: DSSpacing.lg,
            bottom: DSSpacing.sm, trailing: DSSpacing.lg
        ))
        .listRowBackground(Color.clear)
    }
}

// MARK: - Row

/// 一張書籤卡片：圖示＋時間＋頁碼一行，底下是摘錄。右上角「⋯」放刪除，
/// 和滑動刪除是同一個動作的兩個入口（手勢不好發現，選單好發現）。
private struct BookmarkCardRow: View {
    let icon: String
    let primary: String
    let date: String
    let page: String?
    let note: String?
    let indexesReadText: Bool
    let isEditing: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    private var metaText: String {
        guard let page, !page.isEmpty else { return date }
        return "\(date) · \(String(format: localized("第 %@ 頁"), page))"
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(spacing: DSSpacing.xs) {
                Image(systemName: icon)
                    .font(DSFont.footnote)
                    .accessibilityHidden(true)
                Text(metaText)
                    .font(DSFont.footnote)
            }
            .foregroundStyle(DSColor.textSecondary)

            Text(primary)
                .font(DSFont.body)
                .foregroundStyle(indexesReadText ? DSColor.textPrimary : DSColor.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if !indexesReadText {
                Text(localized("建立在這本書另一版的轉換文字上，無法跳轉"))
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
            }

            if let note, !note.isEmpty {
                Label(note, systemImage: "note.text")
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(2)
                    .accessibilityLabel(String(format: localized("筆記：%@"), note))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    var body: some View {
        HStack(alignment: .top, spacing: DSSpacing.sm) {
            if isEditing {
                content
            } else if !indexesReadText {
                // Nothing to jump to: read as one element, with no 「點兩下跳至此頁」.
                content.accessibilityElement(children: .combine)
                moreMenu
            } else {
                Button(action: onSelect) { content }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(primary)，\(metaText)")
                    .accessibilityHint(localized("點兩下跳至此頁"))

                moreMenu
            }
        }
        .padding(.vertical, DSSpacing.md)
        .padding(.leading, DSSpacing.md)
        .padding(.trailing, isEditing ? DSSpacing.md : DSSpacing.xs)
    }

    private var moreMenu: some View {
        Menu {
            Button(role: .destructive, action: onDelete) {
                Label(localized("刪除"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(localized("更多"))
    }
}
