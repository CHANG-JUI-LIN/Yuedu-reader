import SwiftUI

/// 閱讀器「書籤／重點」清單（Apple Books 風格）。
/// 由底部工具列的書籤按鈕開啟，列出書籤與標註（底線/螢光筆），依章節分組。
///
/// 清單本體使用 SwiftUI `List` 搭配 `selection` 綁定（見 `BookmarkSelectionList`），
/// 系統會自動支援 iOS 原生的兩指拖曳多選手勢。
/// 本檔負責 sheet 外框：分頁、工具列（checklist↔checkmark 編輯切換、關閉）、
/// 以及原生底部 toolbar 的「已選取 N 個」與刪除按鈕。
struct ReaderBookmarkListView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    enum Segment: Hashable {
        case bookmark
        case highlight
    }

    let bookTitle: String
    let bookmarks: [Bookmark]
    /// 標註在所屬章節內的頁碼（1-based）；無法解析時回傳 nil。
    let pageNumber: (Bookmark) -> Int?
    /// 章名用目前的目錄解析（含繁簡轉換），不是書籤存檔時的那一份。
    let chapterTitle: (Int) -> String
    let onSelect: (Bookmark) -> Void
    /// 點章名：跳回這一章的開頭。
    let onSelectChapter: (Int) -> Void
    let onDelete: (Bookmark) -> Void

    @Binding var isPresented: Bool

    @State private var segment: Segment = .bookmark
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive

    private var bookmarkItems: [Bookmark] {
        bookmarks.filter { $0.kind == .bookmark }
    }

    private var highlightItems: [Bookmark] {
        bookmarks.filter { $0.kind == .underline || $0.kind == .highlight }
    }

    private var currentItems: [Bookmark] {
        segment == .bookmark ? bookmarkItems : highlightItems
    }

    private var isEditing: Bool {
        editMode.isEditing
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    Text(localized("書籤")).tag(Segment.bookmark)
                    Text(localized("重點")).tag(Segment.highlight)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, DSSpacing.sm)

                content
            }
            .navigationTitle(bookTitle)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { editToggleButton }
                ToolbarItem(placement: .topBarTrailing) { closeButton }
            }
            .toolbar {
                // 原生底部 toolbar：已選取計數 + 刪除按鈕
                ToolbarItemGroup(placement: .bottomBar) {
                    if isEditing {
                        Text(selectedCountText)
                            .font(DSFont.subheadline)
                            .foregroundStyle(DSColor.textSecondary)

                        Spacer()

                        Button {
                            deleteSelected()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(selection.isEmpty)
                        .accessibilityLabel(localized("刪除"))
                    }
                }
            }
            .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
            .pageBackgroundToolbar(for: .settings)
            .environment(\.editMode, $editMode)
            .onChange(of: segment) {
                selection.removeAll()
            }
            .onChange(of: editMode) {
                // 退出編輯模式時清空選取
                if !editMode.isEditing {
                    selection.removeAll()
                }
            }
        }
    }

    // MARK: - Toolbar

    private var editToggleButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : DSAnimation.standard) {
                if editMode.isEditing {
                    editMode = .inactive
                } else {
                    editMode = .active
                }
            }
        } label: {
            Image(systemName: isEditing ? "xmark" : "checklist")
        }
        .accessibilityLabel(localized(isEditing ? "完成" : "編輯"))
    }

    private var closeButton: some View {
        Button {
            isPresented = false
        } label: {
            Image(systemName: "checkmark")
        }
        .accessibilityLabel(localized("完成"))
    }

    // MARK: - Content

    private var content: some View {
        BookmarkListSection(
            isBookmark: segment == .bookmark,
            items: currentItems,
            pageNumber: pageNumber,
            chapterTitle: chapterTitle,
            onSelect: onSelect,
            onSelectChapter: onSelectChapter,
            onDelete: onDelete,
            selection: $selection
        )
    }

    // MARK: - Editing helpers

    private var selectedCountText: String {
        let format = segment == .bookmark ? localized("已選取 %d 個書籤") : localized("已選取 %d 個重點")
        return String(format: format, selection.count)
    }

    private func deleteSelected() {
        currentItems
            .filter { selection.contains($0.id) }
            .forEach(onDelete)
        selection.removeAll()
    }
}

/// 單一種類（書籤 或 重點）的清單內容 ＋ 空狀態，供閱讀器目錄面板的分頁與書籤面板共用。
/// 不含外框（`NavigationStack`）、分頁切換與工具列——那些由容器負責。
struct BookmarkListSection: View {
    let isBookmark: Bool
    let items: [Bookmark]
    /// 標註在所屬章節內的頁碼（1-based）；無法解析時回傳 nil。
    let pageNumber: (Bookmark) -> Int?
    let chapterTitle: (Int) -> String
    let onSelect: (Bookmark) -> Void
    let onSelectChapter: (Int) -> Void
    let onDelete: (Bookmark) -> Void

    @Binding var selection: Set<UUID>

    var body: some View {
        if items.isEmpty {
            if isBookmark {
                ContentUnavailableView {
                    UnavailableLabel(localized("沒有書籤"), systemImage: "bookmark")
                } description: {
                    Text(localized("在想記住的那一頁向下滑動，或點一下右上角的書籤按鈕。")).foregroundStyle(DSColor.textSecondary)
                }
            } else {
                ContentUnavailableView {
                    UnavailableLabel(localized("沒有重點"), systemImage: "highlighter")
                } description: {
                    Text(localized("在閱讀時選取文字，加入底線或螢光筆即可在此查看。")).foregroundStyle(DSColor.textSecondary)
                }
            }
        } else {
            BookmarkSelectionList(
                groups: ReaderBookmarkChapterGroup.group(items),
                selection: $selection,
                chapterTitle: resolvedChapterTitle,
                primaryText: { bm in
                    guard !bm.excerpt.isEmpty else { return bm.chapterTitle }
                    // 章首那一頁的摘錄開頭就是排進版面的章名，而它正上方的分組標題
                    // 已經寫著同一句；重複兩次等於這張卡片沒說出這一頁講什麼。
                    return ReaderBookmarkExcerpt.body(
                        of: bm.excerpt,
                        chapterTitle: resolvedChapterTitle(
                            ReaderBookmarkChapterGroup(chapterIndex: bm.chapterIndex, items: [bm])
                        )
                    )
                },
                icon: { bm in
                    switch bm.kind {
                    case .bookmark: return "bookmark"
                    case .underline: return "underline"
                    case .highlight: return "highlighter"
                    }
                },
                dateText: { Self.relativeDate($0.date) },
                pageText: { pageNumber($0).map { String($0) } },
                noteText: { bm in
                    let note = bm.note.trimmingCharacters(in: .whitespacesAndNewlines)
                    return note.isEmpty ? nil : note
                },
                onSelect: onSelect,
                onSelectChapter: { onSelectChapter($0.chapterIndex) },
                onDelete: onDelete
            )
        }
    }

    /// 章名優先用目前的目錄；解析不出來（章節已被移除、離線書換源）就退回書籤
    /// 存檔時的章名，總比一個空標題好。
    private func resolvedChapterTitle(_ group: ReaderBookmarkChapterGroup) -> String {
        let resolved = chapterTitle(group.chapterIndex)
        return resolved.isEmpty ? (group.items.first?.chapterTitle ?? "") : resolved
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        f.unitsStyle = .full
        return f
    }()

    private static func relativeDate(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview("有資料") {
    ReaderBookmarkListView(
        bookTitle: "劍來",
        bookmarks: [
            Bookmark(
                chapterIndex: 118,
                chapterTitle: "第 119 章 觀劍大會",
                position: CoreTextReadingPosition(spineIndex: 118, charOffset: 0),
                excerpt: "他能在「一表人才」之外特地強調一句「天賦上佳」，那便說明這個年輕人的天賦不是一般的好。",
                date: Date().addingTimeInterval(-60)
            ),
            Bookmark(
                chapterIndex: 118,
                chapterTitle: "第 119 章 觀劍大會",
                position: CoreTextReadingPosition(spineIndex: 118, charOffset: 1240),
                excerpt: "陸歡得了許可，立刻便像一隻得了赦令的小貓，輕手輕腳地跨過門檻，小碎步溜到沈回身邊站好。",
                date: Date().addingTimeInterval(-90)
            ),
            Bookmark(
                chapterIndex: 119,
                chapterTitle: "第 120 章 劍氣長城",
                position: CoreTextReadingPosition(spineIndex: 119, charOffset: 640),
                excerpt: "城頭上的風，吹了千年。",
                date: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            ),
        ],
        pageNumber: { _ in 3 },
        chapterTitle: { index in index == 118 ? "第 119 章 觀劍大會" : "第 120 章 劍氣長城" },
        onSelect: { _ in },
        onSelectChapter: { _ in },
        onDelete: { _ in },
        isPresented: .constant(true)
    )
}

#Preview("空狀態") {
    ReaderBookmarkListView(
        bookTitle: "劍來",
        bookmarks: [],
        pageNumber: { _ in nil },
        chapterTitle: { _ in "" },
        onSelect: { _ in },
        onSelectChapter: { _ in },
        onDelete: { _ in },
        isPresented: .constant(true)
    )
}
