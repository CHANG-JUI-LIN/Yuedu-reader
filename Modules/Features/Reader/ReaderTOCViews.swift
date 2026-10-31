import SwiftUI
import UIKit
import YueduCoreTextTypography



// MARK: - Reader TOC Panel

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

/// 目錄's mark on a chapter that is not cached yet (回饋 #88): reading it needs the network.
/// The title keeps its full contrast; the row itself tells VoiceOver (`accessibilityValue`).
private struct TOCUncachedMark: View {
    var body: some View {
        Image(systemName: "icloud")
            .font(DSFont.fixed(size: 13))
            .foregroundStyle(DSColor.textSecondary)
            .accessibilityHidden(true)
    }
}

private struct VerticalTOCColumn: View {
    let title: String
    let page: Int
    let isSelected: Bool
    let showsPageNumber: Bool
    let isUncached: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                VerticalTOCText(
                    text: title,
                    isSelected: isSelected,
                    maxCharacters: 24
                )
                .foregroundStyle(isSelected ? DSColor.accent : DSColor.textPrimary)
                .frame(width: VerticalTOCLayout.textWidth, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)

                Spacer(minLength: 8)

                if showsPageNumber {
                    Text("\(page)")
                        .font(DSFont.fixed(size: 15, weight: .regular))
                        .foregroundStyle(isSelected ? DSColor.textPrimary : DSColor.textSecondary)
                }

                if isUncached {
                    TOCUncachedMark()
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
        }
        .buttonStyle(.plain)
        .accessibilityValue(isUncached ? localized("未下載") : "")
    }
}

private struct VerticalTOCView: View {
    let chapters: [BookChapter]
    let currentIndex: Int
    let currentChapterID: UUID?
    let pageOffsets: [UUID: Int]
    let showsPageNumbers: Bool
    let uncachedChapterIndexes: Set<Int>
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
                            showsPageNumber: showsPageNumbers,
                            isUncached: uncachedChapterIndexes.contains(chapter.index)
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

/// 閱讀器目錄面板。
///
/// 只有目錄——書籤與重點在 `ReaderBookmarkListView`。原本三者共用一個分段控制，
/// 但目錄本來就由工具列的目錄鈕進入、書籤由書籤鈕進入，分段控制只是把兩個入口
/// 再混回同一個畫面；拆開後目錄頂端讓給原生搜尋列，一直顯示。
struct ReaderTOCView: View {
    let chapters: [BookChapter]
    let bookTitle: String
    let currentPage: Int
    let totalPages: Int
    let tocLayoutMode: TOCLayoutMode
    let pageOffsets: [UUID: Int]
    let showsPageNumbers: Bool
    let currentIndex: Int
    let currentChapterID: UUID?
    /// An online book's chapters that are not cached yet, by `BookChapter.index`; empty for
    /// a local book, which has nothing to fetch.
    let uncachedChapterIndexes: Set<Int>
    let onSelectChapter: (BookChapter) -> Void

    @Binding var isPresented: Bool

    @State private var searchText = ""

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredChapters: [BookChapter] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return chapters }
        return chapters.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(bookTitle)
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isPresented = false
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .accessibilityLabel(localized("完成"))
                    }
                }
                // 兩種版面都固定顯示搜尋列。目錄一打開就捲到目前章節，`.automatic`
                // 的搜尋列跟著捲動收起來，要拉回最頂端才找得到（回饋 #46）；直排的
                // 水平欄位本來就沒有垂直捲動能把它拉出來。
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: localized("搜索章節")
                )
                .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
                .pageBackgroundToolbar(for: .settings)
        }
    }

    @ViewBuilder
    private var content: some View {
        if tocLayoutMode == .verticalRTLColumns {
            verticalContent
        } else {
            horizontalContent
        }
    }

    @ViewBuilder
    private var verticalContent: some View {
        if filteredChapters.isEmpty {
            noMatchesView
        } else {
            VStack(spacing: 0) {
                if totalPages > 0, !isSearching {
                    pageCountText
                        .padding(.vertical, DSSpacing.sm)
                }

                VerticalTOCView(
                    chapters: filteredChapters,
                    currentIndex: currentIndex,
                    currentChapterID: currentChapterID,
                    pageOffsets: pageOffsets,
                    showsPageNumbers: showsPageNumbers,
                    uncachedChapterIndexes: uncachedChapterIndexes,
                    onSelectChapter: { chapter in
                        onSelectChapter(chapter)
                        isPresented = false
                    }
                )
            }
        }
    }

    private var pageCountText: some View {
        Text(String(format: localized("第 %d 頁（共 %d 頁）"), currentPage + 1, totalPages))
            .font(DSFont.fixed(size: 14))
            .foregroundStyle(DSColor.textPrimary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var horizontalContent: some View {
        if filteredChapters.isEmpty {
            noMatchesView
        } else {
            tocList
        }
    }

    private var noMatchesView: some View {
        UnavailableSearchView(text: searchText)
    }

    private func pageNumber(for chapter: BookChapter) -> Int {
        if let offset = pageOffsets[chapter.id] {
            return offset + 1
        }
        return chapter.index + 1
    }

    private var tocList: some View {
        ScrollViewReader { proxy in
            List {
                if totalPages > 0, !isSearching {
                    pageCountText
                        .padding(.vertical, DSSpacing.sm)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }

                ForEach(filteredChapters) { chapter in
                    chapterRow(chapter)
                }
            }
            .softScrollEdges()
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
            .onAppear {
                guard !isSearching,
                      chapters.contains(where: { $0.index == currentIndex }) else { return }
                // No animation: the list opens on the current chapter, it does not travel
                // there each time the sheet comes up. Straight from onAppear, as 有聲書 and
                // the fixed-page reader's 目錄 do; the 0.1 s wait this replaced had no reason
                // on record.
                proxy.scrollTo(currentIndex, anchor: .center)
            }
        }
    }

    private func chapterRow(_ chapter: BookChapter) -> some View {
        Button {
            onSelectChapter(chapter)
            isPresented = false
        } label: {
            HStack(spacing: 0) {
                if chapter.level > 0 {
                    Color.clear
                        .frame(width: CGFloat(chapter.level) * 16)
                }

                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    Text(chapter.title)
                        .font(
                            chapter.level == 0
                            ? DSFont.fixed(size: 14, weight: .semibold)
                            : DSFont.fixed(size: 12, weight: .regular)
                        )
                        .foregroundStyle(DSColor.textPrimary)
                        .lineLimit(2)

                    // The source's 更新時間, verbatim; a row without one takes no extra line.
                    if let updateTime = chapter.updateTime {
                        Text(updateTime)
                            .font(DSFont.fixed(size: 12))
                            .foregroundStyle(DSColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, DSSpacing.xs)

                Spacer()

                if uncachedChapterIndexes.contains(chapter.index) {
                    TOCUncachedMark()
                }

                if showsPageNumbers {
                    Text("\(pageNumber(for: chapter))")
                        .font(DSFont.fixed(size: 18, weight: .regular, design: .monospaced))
                        .foregroundStyle(DSColor.textSecondary)
                }
            }
            // A minimum, not a height: a two-line title over an update time needs more.
            .frame(minHeight: 48)
            .padding(.horizontal, 30)
            .background {
                if chapter.id == currentChapterID {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(uncachedChapterIndexes.contains(chapter.index) ? localized("未下載") : "")
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden, edges: chapter.id == filteredChapters.first?.id ? .top : [])
        .listRowSeparator(.visible, edges: .bottom)
        .listRowSeparatorTint(Color.secondary.opacity(0.18))
        .id(chapter.index)
    }
}

#Preview("目錄") {
    ReaderTOCView(
        chapters: [
            BookChapter(index: 0, title: "第一章 序幕", content: ""),
            BookChapter(index: 1, title: "第二章 啟程", content: ""),
            BookChapter(index: 2, title: "第三章 抉擇", content: ""),
        ],
        bookTitle: "範例書名",
        currentPage: 1,
        totalPages: 240,
        tocLayoutMode: .horizontalList,
        pageOffsets: [:],
        showsPageNumbers: true,
        currentIndex: 0,
        currentChapterID: nil,
        uncachedChapterIndexes: [],
        onSelectChapter: { _ in },
        isPresented: .constant(true)
    )
}

#Preview("目錄・線上書更新時間") {
    ReaderTOCView(
        chapters: [
            BookChapter(index: 0, title: "第一卷 風起", content: ""),
            BookChapter(index: 1, title: "第一章 序幕", content: "", updateTime: "第一卷 | 2026-10-01 08:00"),
            BookChapter(index: 2, title: "第二章 啟程：一個長到要換行才放得下的章節標題", content: "",
                        updateTime: "第一卷 | 2026-10-02 08:00"),
            BookChapter(index: 3, title: "第三章 抉擇", content: ""),
        ],
        bookTitle: "範例書名",
        currentPage: 0,
        totalPages: 0,
        tocLayoutMode: .horizontalList,
        pageOffsets: [:],
        showsPageNumbers: false,
        currentIndex: 1,
        currentChapterID: nil,
        uncachedChapterIndexes: [2, 3],
        onSelectChapter: { _ in },
        isPresented: .constant(true)
    )
}

#Preview("目錄・直排未快取") {
    ReaderTOCView(
        chapters: [
            BookChapter(index: 0, title: "第一章 序幕", content: ""),
            BookChapter(index: 1, title: "第二章 啟程", content: ""),
            BookChapter(index: 2, title: "第三章 抉擇", content: ""),
            BookChapter(index: 3, title: "第四章 歸途", content: ""),
        ],
        bookTitle: "範例書名",
        currentPage: 0,
        totalPages: 0,
        tocLayoutMode: .verticalRTLColumns,
        pageOffsets: [:],
        showsPageNumbers: false,
        currentIndex: 1,
        currentChapterID: nil,
        uncachedChapterIndexes: [2, 3],
        onSelectChapter: { _ in },
        isPresented: .constant(true)
    )
}
