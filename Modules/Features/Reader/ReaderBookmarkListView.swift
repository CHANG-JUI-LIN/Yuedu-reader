import SwiftUI

/// 閱讀器「書籤／重點」清單（Apple Books 風格）。
/// 由底部工具列的書籤按鈕開啟，列出書籤與標註（底線/螢光筆）。
///
/// 清單本體改用 UIKit `UITableView`（見 `BookmarkSelectionList`），以支援原生的
/// 兩指拖曳多選；本檔只負責 sheet 外框：分頁、工具列（checklist→xmark 編輯切換、
/// 關閉）、底部「已選取 N 個」與浮動垃圾桶。不使用 SwiftUI 的 `EditMode`。
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
    @State private var isEditing = false

    private var bookmarkItems: [Bookmark] {
        bookmarks.filter { $0.kind == .bookmark }
    }

    private var highlightItems: [Bookmark] {
        bookmarks.filter { $0.kind == .underline || $0.kind == .highlight }
    }

    private var currentItems: [Bookmark] {
        segment == .bookmark ? bookmarkItems : highlightItems
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
            .safeAreaInset(edge: .bottom) { editingBottomBar }
            .onChange(of: segment) { selection.removeAll() }
        }
    }

    // MARK: - Toolbar

    private var editToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isEditing.toggle()
                if !isEditing { selection.removeAll() }
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
            isEditing: $isEditing,
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

    // MARK: - Editing bottom bar (centered count + floating trash)

    @ViewBuilder
    private var editingBottomBar: some View {
        if isEditing {
            ZStack {
                Text(selectedCountText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)

                HStack {
                    Spacer()
                    Button {
                        deleteSelected()
                    } label: {
                        Image(systemName: "trash")
                            .font(.title3)
                            .foregroundStyle(selection.isEmpty ? Color(.tertiaryLabel) : Color(.label))
                            .frame(width: 52, height: 52)
                            .background(
                                Circle()
                                    .fill(Color(.systemBackground))
                                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                            )
                    }
                    .disabled(selection.isEmpty)
                    .accessibilityLabel(localized("刪除"))
                }
                .padding(.trailing, DSSpacing.lg)
            }
            .padding(.vertical, DSSpacing.md)
        }
    }

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
