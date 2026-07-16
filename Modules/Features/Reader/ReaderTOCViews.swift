import SwiftUI
import UIKit

@MainActor
enum ReaderTOCSelectionAction {
    static func perform(
        chapter: BookChapter,
        dismiss: @MainActor () -> Void,
        stage: @MainActor (BookChapter) -> Void
    ) {
        stage(chapter)
        dismiss()
    }
}


// MARK: - Combined Bookmarks & TOC Panel

private enum VerticalTOCLayout {
    static let columnWidth: CGFloat = 46
    static let textWidth: CGFloat = 24
    static let fontSize: CGFloat = 17
    static let glyphHeight: CGFloat = 21
    static let glyphSpacing: CGFloat = 0
    static let columnSpacing: CGFloat = 3
    static let topPadding: CGFloat = 20
    static let bottomPadding: CGFloat = 18
    static let selectedCornerRadius: CGFloat = 8
    static let selectedBarWidth: CGFloat = 3
}

private struct VerticalTOCText: View {
    let text: String
    var isSelected: Bool = false
    var maxCharacters: Int = 24

    private var chars: [String] {
        let cleaned = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")

        let raw = Array(cleaned)
        let limited = raw.count > maxCharacters
            ? Array(raw.prefix(maxCharacters - 1)) + ["\u{2026}"]
            : raw

        return limited.map(String.init)
    }

    var body: some View {
        VStack(spacing: VerticalTOCLayout.glyphSpacing) {
            ForEach(Array(chars.enumerated()), id: \.offset) { _, ch in
                glyph(ch)
            }
        }
        .frame(width: VerticalTOCLayout.textWidth, alignment: .top)
    }

    @ViewBuilder
    private func glyph(_ ch: String) -> some View {
        switch VerticalGlyphClassifier.classify(Character(ch)) {
        case .cjk(let s),
             .verticalPunctuation(let s):
            cjkGlyph(s)
        case .compressedPunctuation(let s):
            compressedGlyph(s)
        case .rotatedLatin(let s):
            rotatedLatinGlyph(s)
        case .uprightLatin(let s):
            cjkGlyph(s)
        }
    }

    private func cjkGlyph(_ s: String) -> some View {
        Text(s)
            .font(DSFont.fixed(size: VerticalTOCLayout.fontSize, weight: .semibold))
            .frame(width: VerticalTOCLayout.textWidth, height: VerticalTOCLayout.glyphHeight)
    }

    private func compressedGlyph(_ s: String) -> some View {
        Text(s)
            .font(DSFont.fixed(size: VerticalTOCLayout.fontSize * 0.82, weight: .semibold))
            .frame(
                width: VerticalTOCLayout.textWidth,
                height: VerticalTOCLayout.glyphHeight * 0.55,
                alignment: .topTrailing
            )
            .offset(x: 3, y: -2)
    }

    private func rotatedLatinGlyph(_ s: String) -> some View {
        Text(s)
            .font(DSFont.fixed(size: 12, weight: .semibold))
            .rotationEffect(.degrees(90))
            .frame(width: VerticalTOCLayout.textWidth, height: VerticalTOCLayout.glyphHeight)
    }
}

private struct VerticalTOCColumn: View {
    let title: String
    let page: Int
    let isSelected: Bool
    let showsPageNumber: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                VerticalTOCText(
                    text: title,
                    isSelected: isSelected,
                    maxCharacters: 24
                )
                .foregroundStyle(isSelected ? DSColor.accent : Color.primary)
                .frame(width: VerticalTOCLayout.textWidth, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)

                Spacer(minLength: 8)

                if showsPageNumber {
                    Text("\(page)")
                        .font(DSFont.fixed(size: 15, weight: .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                }
            }
            .frame(width: VerticalTOCLayout.columnWidth, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, VerticalTOCLayout.topPadding)
            .padding(.bottom, VerticalTOCLayout.bottomPadding)
            .background {
                if isSelected {
                    RoundedRectangle(
                        cornerRadius: VerticalTOCLayout.selectedCornerRadius,
                        style: .continuous
                    )
                    .fill(isSelected ? Color.primary.opacity(0.07) : Color.clear)
                }
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(DSColor.accent)
                        .frame(width: VerticalTOCLayout.selectedBarWidth)
                }
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: VerticalTOCLayout.selectedCornerRadius,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct VerticalTOCView: View {
    let chapters: [BookChapter]
    let currentIndex: Int
    let currentChapterID: UUID?
    let pageOffsets: [UUID: Int]
    let showsPageNumbers: Bool
    let onSelectChapter: (BookChapter) -> Void

    @State private var didInitialTOCScroll = false

    private var reversedChapters: [BookChapter] {
        Array(chapters.reversed())
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: VerticalTOCLayout.columnSpacing) {
                    ForEach(Array(reversedChapters.enumerated()), id: \.element.id) { _, chapter in
                        let pageNumber: Int = {
                            if let offset = pageOffsets[chapter.id] {
                                return offset + 1
                            }
                            return chapter.index + 1
                        }()
                        VerticalTOCColumn(
                            title: chapter.title,
                            page: pageNumber,
                            isSelected: chapter.id == currentChapterID,
                            showsPageNumber: showsPageNumbers
                        ) {
                            onSelectChapter(chapter)
                        }
                        .id(chapter.index)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
            }
            .onAppear {
                guard !didInitialTOCScroll else { return }
                didInitialTOCScroll = true

                if chapters.first(where: { $0.index == currentIndex }) != nil {
                    proxy.scrollTo(currentIndex, anchor: .trailing)
                }
            }
        }
    }
}

struct ReaderMenuView: View {
    enum Tab: Hashable {
        case toc
        case bookmark
        case highlight
    }

    // 目錄
    let chapters: [BookChapter]
    let coverImagePath: String?
    let bookTitle: String
    let currentPage: Int
    let totalPages: Int
    let tocLayoutMode: TOCLayoutMode
    let pageOffsets: [UUID: Int]
    let showsPageNumbers: Bool
    let currentIndex: Int
    let currentChapterID: UUID?
    let onSelectChapter: (BookChapter) -> Void

    // 書籤／重點
    let bookmarks: [Bookmark]
    /// 標註在所屬章節內的頁碼（1-based）；無法解析時回傳 nil。
    let bookmarkPageNumber: (Bookmark) -> Int?
    let onSelectBookmark: (Bookmark) -> Void
    let onDeleteBookmark: (Bookmark) -> Void

    @Binding var isPresented: Bool
    @Binding var selectedTab: Tab

    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive

    private var bookmarkItems: [Bookmark] {
        bookmarks.filter { $0.kind == .bookmark }
    }

    private var highlightItems: [Bookmark] {
        bookmarks.filter { $0.kind == .underline || $0.kind == .highlight }
    }

    private var currentItems: [Bookmark] {
        selectedTab == .bookmark ? bookmarkItems : highlightItems
    }

    private var isEditing: Bool {
        editMode.isEditing
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if totalPages > 0 {
                    Text(String(format: localized("第 %d 頁（共 %d 頁）"), currentPage + 1, totalPages))
                        .font(DSFont.fixed(size: 14))
                        .foregroundColor(.primary)
                        .padding(.vertical, DSSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Picker("", selection: $selectedTab) {
                    Text(localized("目錄")).tag(Tab.toc)
                    Text(localized("書籤")).tag(Tab.bookmark)
                    Text(localized("重點")).tag(Tab.highlight)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, DSSpacing.sm)

                Group {
                    switch selectedTab {
                    case .toc:
                        tocTab
                    case .bookmark:
                        BookmarkListSection(
                            isBookmark: true,
                            items: bookmarkItems,
                            pageNumber: bookmarkPageNumber,
                            onSelect: onSelectBookmark,
                            onDelete: onDeleteBookmark,
                            selection: $selection
                        )
                    case .highlight:
                        BookmarkListSection(
                            isBookmark: false,
                            items: highlightItems,
                            pageNumber: bookmarkPageNumber,
                            onSelect: onSelectBookmark,
                            onDelete: onDeleteBookmark,
                            selection: $selection
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(bookTitle)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selectedTab != .toc {
                        editToggleButton
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
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    if selectedTab != .toc, isEditing {
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
            .onChange(of: selectedTab) {
                selection.removeAll()
                editMode = .inactive
            }
            .onChange(of: editMode) {
                if !editMode.isEditing {
                    selection.removeAll()
                }
            }
        }
    }

    // MARK: - 目錄分頁

    @ViewBuilder
    private var tocTab: some View {
        VStack(spacing: 0) {
            if tocLayoutMode == .verticalRTLColumns {
                VerticalTOCView(
                    chapters: chapters,
                    currentIndex: currentIndex,
                    currentChapterID: currentChapterID,
                    pageOffsets: pageOffsets,
                    showsPageNumbers: showsPageNumbers,
                    onSelectChapter: { chapter in
                        ReaderTOCSelectionAction.perform(
                            chapter: chapter,
                            dismiss: { isPresented = false },
                            stage: onSelectChapter
                        )
                    }
                )
            } else {
                tocContent
            }
        }
    }

    // MARK: - 書籤／重點編輯

    private var editToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                editMode = editMode.isEditing ? .inactive : .active
            }
        } label: {
            Image(systemName: isEditing ? "xmark" : "checklist")
        }
        .accessibilityLabel(localized(isEditing ? "完成" : "編輯"))
    }

    private var selectedCountText: String {
        let noun = selectedTab == .bookmark ? localized("書籤") : localized("重點")
        return String(format: localized("已選取 %1$d 個%2$@"), selection.count, noun)
    }

    private func deleteSelected() {
        currentItems
            .filter { selection.contains($0.id) }
            .forEach(onDeleteBookmark)
        selection.removeAll()
    }

    private func pageNumber(for chapter: BookChapter) -> Int {
        if let offset = pageOffsets[chapter.id] {
            return offset + 1
        }
        return chapter.index + 1
    }

    private var tocContent: some View {
        ScrollViewReader { proxy in
            List(chapters) { chapter in
                Button {
                    ReaderTOCSelectionAction.perform(
                        chapter: chapter,
                        dismiss: { isPresented = false },
                        stage: onSelectChapter
                    )
                } label: {
                    HStack(spacing: 0) {
                        if chapter.level > 0 {
                            Color.clear
                                .frame(width: CGFloat(chapter.level) * 16)
                        }

                        Text(chapter.title)
                            .font(
                                chapter.level == 0
                                ? .system(size: 14, weight: .semibold)
                                : .system(size: 12, weight: .regular)
                            )
                            .foregroundColor(.primary)
                            .lineLimit(2)

                        Spacer()

                        if showsPageNumbers {
                            Text("\(pageNumber(for: chapter))")
                                .font(DSFont.fixed(size: 18, weight: .regular, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(height: 48)
                    .padding(.horizontal, 30)
                    .contentShape(Rectangle())
                    .background {
                        if chapter.id == currentChapterID {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden, edges: chapter.id == chapters.first?.id ? .top : [])
                .listRowSeparator(.visible, edges: .bottom)
                .listRowSeparatorTint(Color.secondary.opacity(0.18))
                .id(chapter.index)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if chapters.first(where: { $0.index == currentIndex }) != nil {
                        withAnimation {
                            proxy.scrollTo(currentIndex, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var tab: ReaderMenuView.Tab = .toc
    ReaderMenuView(
        chapters: [
            BookChapter(index: 0, title: "第一章 序幕", content: ""),
            BookChapter(index: 1, title: "第二章 啟程", content: ""),
            BookChapter(index: 2, title: "第三章 抉擇", content: ""),
        ],
        coverImagePath: nil,
        bookTitle: "範例書名",
        currentPage: 1,
        totalPages: 240,
        tocLayoutMode: .horizontalList,
        pageOffsets: [:],
        showsPageNumbers: true,
        currentIndex: 0,
        currentChapterID: nil,
        onSelectChapter: { _ in },
        bookmarks: [
            Bookmark(
                chapterIndex: 0,
                chapterTitle: "第一章 序幕",
                position: CoreTextReadingPosition(spineIndex: 0, charOffset: 0)
            ),
            Bookmark(
                chapterIndex: 1,
                chapterTitle: "第二章 啟程",
                position: CoreTextReadingPosition(spineIndex: 1, charOffset: 420),
                kind: .highlight,
                excerpt: "值得記住的一段話"
            ),
        ],
        bookmarkPageNumber: { _ in 18 },
        onSelectBookmark: { _ in },
        onDeleteBookmark: { _ in },
        isPresented: .constant(true),
        selectedTab: $tab
    )
}
