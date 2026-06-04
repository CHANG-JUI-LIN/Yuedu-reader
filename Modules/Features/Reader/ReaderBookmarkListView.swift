import SwiftUI

/// 閱讀器「書籤／重點」清單（Apple Books 風格）。
/// 由底部工具列的書籤按鈕開啟，列出書籤與標註（底線/螢光筆）。
/// 復用自早期被移除的書籤分頁（commit e58dac2），改為雙分頁排版。
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

    private var isEditing: Bool { editMode.isEditing }

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
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                content
            }
            .navigationTitle(bookTitle)
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !currentItems.isEmpty {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(localized("完成"))
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if isEditing {
                        Button(role: .destructive) {
                            deleteSelected()
                        } label: {
                            Text(localized("刪除"))
                        }
                        .disabled(selection.isEmpty)
                        Spacer()
                        Button(localized("全選")) {
                            selection = Set(currentItems.map(\.id))
                        }
                    }
                }
            }
            .onChange(of: segment) { selection.removeAll() }
            .onChange(of: editMode) { if !editMode.isEditing { selection.removeAll() } }
        }
        .environment(\.editMode, $editMode)
    }

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
                list(items: bookmarkItems) { bookmarkRow($0) }
            }
        case .highlight:
            if highlightItems.isEmpty {
                ContentUnavailableView {
                    Label(localized("沒有重點"), systemImage: "highlighter")
                } description: {
                    Text(localized("在閱讀時選取文字，加入底線或螢光筆即可在此查看。"))
                }
            } else {
                list(items: highlightItems) { highlightRow($0) }
            }
        }
    }

    private func list<Row: View>(
        items: [Bookmark],
        @ViewBuilder row: @escaping (Bookmark) -> Row
    ) -> some View {
        List(selection: $selection) {
            ForEach(items) { bm in
                row(bm)
                    .tag(bm.id)
                    .contentShape(Rectangle())
                    .onTapWhenNotEditing(isEditing) { onSelect(bm) }
            }
            .onDelete { offsets in
                offsets.map { items[$0] }.forEach(onDelete)
            }
        }
        .listStyle(.plain)
    }

    private func bookmarkRow(_ bm: Bookmark) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(bm.chapterTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let page = pageNumber(bm) {
                    Text("\(page)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if !bm.excerpt.isEmpty {
                Text(bm.excerpt)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(Self.relativeDate(bm.date))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func highlightRow(_ bm: Bookmark) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(bm.excerpt.isEmpty ? bm.chapterTitle : bm.excerpt)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let page = pageNumber(bm) {
                    Text("\(page)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(Self.relativeDate(bm.date))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
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

private extension View {
    /// 非編輯模式時才加上點擊手勢，讓編輯模式下的多選不被攔截。
    @ViewBuilder
    func onTapWhenNotEditing(_ isEditing: Bool, perform: @escaping () -> Void) -> some View {
        if isEditing {
            self
        } else {
            self.onTapGesture(perform: perform)
        }
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
