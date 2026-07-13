import SwiftUI

/// 閱讀器「書籤／重點」清單（Apple Books 風格）。
/// 由底部工具列的書籤按鈕開啟，列出書籤與標註（底線/螢光筆）。
///
/// 清單本體使用 SwiftUI `List` 搭配 `selection` 綁定（見 `BookmarkSelectionList`），
/// 系統會自動支援 iOS 原生的兩指拖曳多選手勢。
/// 本檔負責 sheet 外框：分頁、工具列（checklist↔checkmark 編輯切換、關閉）、
/// 以及原生底部 toolbar 的「已選取 N 個」與刪除按鈕。
struct ReaderBookmarkListView: View {
    enum Segment: Hashable {
        case bookmark
        case highlight
    }

    let bookTitle: String
    let bookmarks: [Bookmark]
    /// 標註在所屬章節內的頁碼（1-based）；無法解析時回傳 nil。
    let pageNumber: (Bookmark) -> Int?
    let onSelect: (Bookmark) -> Void
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
            withAnimation(.easeInOut(duration: 0.2)) {
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

    @ViewBuilder
    private var content: some View {
        switch segment {
        case .bookmark:
            if bookmarkItems.isEmpty {
                ContentUnavailableView {
                    Label(localized("沒有書籤"), systemImage: "bookmark")
                } description: {
                    Text(localized("點一下你要加入書籤的頁面，點一下選單圖像，然後點一下書籤按鈕。"))
                }
            } else {
                table(items: bookmarkItems)
            }
        case .highlight:
            if highlightItems.isEmpty {
                ContentUnavailableView {
                    Label(localized("沒有重點"), systemImage: "highlighter")
                } description: {
                    Text(localized("在閱讀時選取文字，加入底線或螢光筆即可在此查看。"))
                }
            } else {
                table(items: highlightItems)
            }
        }
    }

    private func table(items: [Bookmark]) -> some View {
        BookmarkSelectionList(
            items: items,
            selection: $selection,
            primaryText: { bm in
                segment == .bookmark
                    ? bm.chapterTitle
                    : (bm.excerpt.isEmpty ? bm.chapterTitle : bm.excerpt)
            },
            primaryLines: segment == .bookmark ? 1 : 2,
            dateText: { Self.relativeDate($0.date) },
            pageText: { pageNumber($0).map { String($0) } },
            onSelect: onSelect,
            onDelete: onDelete
        )
    }

    // MARK: - Editing helpers

    private var selectedCountText: String {
        let noun = segment == .bookmark ? localized("書籤") : localized("重點")
        return String(format: localized("已選取 %1$d 個%2$@"), selection.count, noun)
    }

    private func deleteSelected() {
        currentItems
            .filter { selection.contains($0.id) }
            .forEach(onDelete)
        selection.removeAll()
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
        bookTitle: "ナミヤ雑貨店の奇蹟",
        bookmarks: [
            Bookmark(
                chapterIndex: 2,
                chapterTitle: "第三章 シビックで朝まで",
                position: CoreTextReadingPosition(spineIndex: 2, charOffset: 1200),
                excerpt: "敦也たちが怒りと苛立ちを込めて書いた手紙",
                date: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            ),
            Bookmark(
                chapterIndex: 1,
                chapterTitle: "第二章",
                position: CoreTextReadingPosition(spineIndex: 1, charOffset: 800),
                length: 12,
                kind: .underline,
                excerpt: "ナミヤ雑貨店の相談",
                annotationStyle: .underline,
                annotationColor: .yellow
            ),
        ],
        pageNumber: { _ in 139 },
        onSelect: { _ in },
        onDelete: { _ in },
        isPresented: .constant(true)
    )
}

#Preview("空狀態") {
    ReaderBookmarkListView(
        bookTitle: "ナミヤ雑貨店の奇蹟",
        bookmarks: [],
        pageNumber: { _ in nil },
        onSelect: { _ in },
        onDelete: { _ in },
        isPresented: .constant(true)
    )
}
