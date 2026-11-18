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
    let order: ChapterListOrder
    let onSelectChapter: (BookChapter) -> Void

    @State private var didInitialTOCScroll = false

    /// Right to left: the columns run the other way from `chapters`, which is already in the
    /// reader's 正序／倒序.
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

                if let row = ReaderTOCScrollTarget.row(currentIndex: currentIndex, in: chapters) {
                    proxy.scrollTo(row, anchor: .trailing)
                }
            }
            // Switching 正序／倒序 moves the current chapter to the other end; follow it.
            .onChange(of: order) {
                if let row = ReaderTOCScrollTarget.row(currentIndex: currentIndex, in: chapters) {
                    proxy.scrollTo(row, anchor: .trailing)
                }
            }
        }
    }
}

/// Which row a 目錄 scrolls to: the current chapter, by the `BookChapter.index` each row is
/// `.id`'d with, so it is the same row in 正序 and 倒序. Nil when the shown list does not have it
/// (a search that filtered it out, a chapter missing from the 目錄).
enum ReaderTOCScrollTarget {
    static func row(currentIndex: Int, in shown: [BookChapter]) -> Int? {
        shown.contains(where: { $0.index == currentIndex }) ? currentIndex : nil
    }
}

/// The rows a 目錄 shows: the chapters in the reader's 正序／倒序, narrowed to the titles that
/// contain the search query. One call is one pass over the 目錄, one match per chapter; the view
/// calls it once per body and hands the result down. It used to be a computed property read by
/// every row's separator check, a full ICU search of the 目錄 per row per keystroke, which held
/// a long online 目錄's main thread past the watchdog (Crashlytics 629731e7).
enum ReaderTOCFilter {
    static func shown(
        _ chapters: [BookChapter],
        order: ChapterListOrder,
        query rawQuery: String,
        matches: (_ title: String, _ query: String) -> Bool = { $0.localizedCaseInsensitiveContains($1) }
    ) -> [BookChapter] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordered = order.arranged(chapters, level: \.level)
        guard !query.isEmpty else { return ordered }
        return ordered.filter { matches($0.title, query) }
    }
}

/// 閱讀器目錄面板。
///
/// 只有目錄——書籤與重點在 `ReaderBookmarkListView`。原本三者共用一個分段控制，
/// 但目錄本來就由工具列的目錄鈕進入、書籤由書籤鈕進入，分段控制只是把兩個入口
/// 再混回同一個畫面；拆開後目錄頂端讓給原生搜尋列，一直顯示。
///
/// The app's one 目錄 (maintainer, 2026-11-12: 「現在有兩條目錄路徑」): the reader's, and the one
/// a detail page's 目錄 opens, which had a list of its own (`BookDetailChapterListSheet`). Its
/// rows are spaced and set as that list's were, which the maintainer liked; what each place
/// says differently is a parameter: the bar's title and how it closes, the line over the list,
/// what ends a row.
struct ReaderTOCView: View {
    /// How the page is left: the reader's ✓ at the trailing end, or a detail page's ✕ at the
    /// leading end, as each had it.
    enum Closing {
        case done
        case close
    }

    /// What ends a row, after its page number where it has one.
    enum Accessory {
        case none
        /// Opens the reader at the chapter.
        case disclosure
        /// Plays the chapter, as an episode row in Podcasts.
        case play
    }

    let chapters: [BookChapter]
    /// The bar's title: the book's in the reader, 目錄 from a detail page.
    let bookTitle: String
    /// Whose 正序／倒序 to read and save.
    let bookID: UUID?
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
    /// Chapters the source sells, by `BookChapter.index`: a lock, and 付費章節 for VoiceOver.
    var lockedChapterIndexes: Set<Int> = []
    var closing = Closing.done
    var accessory = Accessory.none
    /// 「共 415 章」 over the list, where no page count is shown.
    var showsChapterCount = false
    let onSelectChapter: (BookChapter) -> Void

    @Binding var isPresented: Bool

    @State private var searchText = ""
    @State private var chosenOrder: ChapterListOrder?

    private var orderBinding: Binding<ChapterListOrder> {
        ChapterListOrder.binding(chosen: $chosenOrder, for: bookID)
    }

    private var order: ChapterListOrder { orderBinding.wrappedValue }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // Once per body: everything below reads this list, never the filter itself.
        let shown = ReaderTOCFilter.shown(chapters, order: order, query: searchText)
        NavigationStack {
            content(shown)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(bookTitle)
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    if closing == .close {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                isPresented = false
                            } label: {
                                Label(localized("關閉"), systemImage: "xmark")
                                    .labelStyle(.iconOnly)
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ChapterListOrderMenu(order: orderBinding)
                    }
                    if closing == .done {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                isPresented = false
                            } label: {
                                Image(systemName: "checkmark")
                            }
                            .accessibilityLabel(localized("完成"))
                        }
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
    private func content(_ shown: [BookChapter]) -> some View {
        if tocLayoutMode == .verticalRTLColumns {
            verticalContent(shown)
        } else {
            horizontalContent(shown)
        }
    }

    @ViewBuilder
    private func verticalContent(_ shown: [BookChapter]) -> some View {
        if shown.isEmpty {
            noMatchesView
        } else {
            VStack(spacing: 0) {
                if totalPages > 0, !isSearching {
                    pageCountText
                        .padding(.vertical, DSSpacing.sm)
                }

                VerticalTOCView(
                    chapters: shown,
                    currentIndex: currentIndex,
                    currentChapterID: currentChapterID,
                    pageOffsets: pageOffsets,
                    showsPageNumbers: showsPageNumbers,
                    uncachedChapterIndexes: uncachedChapterIndexes,
                    order: order,
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
    private func horizontalContent(_ shown: [BookChapter]) -> some View {
        if shown.isEmpty {
            noMatchesView
        } else {
            tocList(shown)
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

    private func tocList(_ shown: [BookChapter]) -> some View {
        return ScrollViewReader { proxy in
            List {
                if totalPages > 0, !isSearching {
                    pageCountText
                        .padding(.vertical, DSSpacing.sm)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }

                Section {
                    ForEach(shown) { chapter in
                        chapterRow(chapter)
                    }
                } header: {
                    if showsChapterCount, totalPages <= 0, !isSearching {
                        Text(String(format: localized("共 %d 章"), chapters.count))
                    }
                }
            }
            .softScrollEdges()
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
            .onAppear {
                guard !isSearching,
                      let row = ReaderTOCScrollTarget.row(currentIndex: currentIndex, in: shown)
                else { return }
                // No animation: the list opens on the current chapter, it does not travel
                // there each time the sheet comes up. Straight from onAppear, as 有聲書 and
                // the fixed-page reader's 目錄 do; the 0.1 s wait this replaced had no reason
                // on record.
                proxy.scrollTo(row, anchor: .center)
            }
            // Switching 正序／倒序 moves the current chapter to the other end; follow it.
            .onChange(of: order) {
                guard let row = ReaderTOCScrollTarget.row(currentIndex: currentIndex, in: shown)
                else { return }
                proxy.scrollTo(row, anchor: .center)
            }
        }
    }

    /// One row, set as a detail page's 目錄 was (maintainer, 2026-11-12): the title in body
    /// text, a hairline between rows. Spaced as a List spaces its rows (2026-11-18).
    private func chapterRow(_ chapter: BookChapter) -> some View {
        let isLocked = lockedChapterIndexes.contains(chapter.index)
        let isUncached = uncachedChapterIndexes.contains(chapter.index)
        return Button {
            onSelectChapter(chapter)
            isPresented = false
        } label: {
            HStack(spacing: DSSpacing.md) {
                if chapter.level > 0 {
                    Color.clear
                        .frame(width: CGFloat(chapter.level) * DSSpacing.lg - DSSpacing.md)
                }

                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text(chapter.title)
                        .font(chapter.level == 0 ? DSFont.body : DSFont.subheadline)
                        .foregroundStyle(DSColor.textPrimary)
                        .lineLimit(2)

                    // The source's 更新時間, verbatim; a row without one takes no extra line.
                    if let updateTime = chapter.updateTime {
                        Text(updateTime)
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: DSSpacing.sm)

                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.warning)
                        .accessibilityHidden(true)
                }

                if isUncached {
                    TOCUncachedMark()
                }

                if showsPageNumbers {
                    Text("\(pageNumber(for: chapter))")
                        .font(DSFont.body)
                        .monospacedDigit()
                        .foregroundStyle(DSColor.textSecondary)
                }

                switch accessory {
                case .none:
                    EmptyView()
                case .disclosure:
                    Image(systemName: "chevron.right")
                        .font(DSFont.caption.weight(.semibold))
                        .foregroundStyle(DSColor.textTertiary)
                        .accessibilityHidden(true)
                case .play:
                    Image(systemName: "play.circle")
                        .font(DSFont.title3)
                        .foregroundStyle(DSColor.textSecondary)
                        .accessibilityHidden(true)
                }
            }
        }
        // The list's own row: its height, its insets, the whole row the button (maintainer,
        // 2026-11-18: the rows' own padding stood them too far apart).
        .accessibilityValue([isLocked ? localized("付費章節") : nil, isUncached ? localized("未下載") : nil]
            .compactMap { $0 }.joined(separator: "，"))
        .accessibilityAddTraits(isCurrent(chapter) ? .isSelected : [])
        .listRowBackground(
            // Where reading stands: a quiet ground behind the row, inside the list's margins.
            RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                .fill(isCurrent(chapter) ? DSColor.textPrimary.opacity(DSLayout.tocCurrentRowOpacity) : Color.clear)
                .padding(.horizontal, DSSpacing.sm)
        )
        .id(chapter.index)
    }

    /// The chapter being read: by its id in the reader, whose 目錄 can name one spine item more
    /// than once; by its place where only that is known (a detail page).
    private func isCurrent(_ chapter: BookChapter) -> Bool {
        if let currentChapterID { return chapter.id == currentChapterID }
        return currentIndex >= 0 && chapter.index == currentIndex
    }
}

extension ReaderTOCView {
    /// A detail page's 目錄: a book source's chapters as they stand, each at its place in the
    /// list (the place `onSelect` is given, in 倒序 too), under the title 目錄 with ✕ to close.
    /// - Parameter current: the place reading stands at, when the page knows it.
    init(detailChapters refs: [OnlineChapterRef], bookID: UUID?, current: Int? = nil, accessory: Accessory,
         isPresented: Binding<Bool>, onSelect: @escaping (_ offset: Int) -> Void) {
        self.init(
            chapters: Self.entries(refs), bookTitle: localized("目錄"), bookID: bookID,
            currentPage: 0, totalPages: 0, tocLayoutMode: .horizontalList, pageOffsets: [:], showsPageNumbers: false,
            currentIndex: current ?? -1, currentChapterID: nil, uncachedChapterIndexes: [],
            lockedChapterIndexes: Set(refs.indices.filter { refs[$0].isVip || refs[$0].isPay }),
            closing: .close, accessory: accessory, showsChapterCount: true,
            onSelectChapter: { onSelect($0.index) }, isPresented: isPresented
        )
    }

    /// A source's chapters as 目錄 rows: each keeps its own id, takes its place in the list as
    /// its index, and reads 「第 N 章」 where the source left its title empty. Values only, so
    /// off the main actor the view is on.
    nonisolated static func entries(_ refs: [OnlineChapterRef]) -> [BookChapter] {
        refs.enumerated().map { offset, ref in
            BookChapter(id: ref.id, index: offset, title: BookDetailChapterTitle.display(ref, offset: offset), content: "")
        }
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
        bookID: nil,
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
        bookID: nil,
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
        bookID: nil,
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

/// 倒序 with volumes: each volume stays above its own chapters, the volumes run last to first.
#Preview("目錄・倒序分卷") {
    let bookID = UUID()
    ChapterListOrder.store(.descending, for: bookID)
    return ReaderTOCView(
        chapters: [
            BookChapter(index: 0, title: "第一卷 風起", content: ""),
            BookChapter(index: 1, title: "第一章 序幕", content: "", level: 1),
            BookChapter(index: 2, title: "第二章 啟程", content: "", level: 1),
            BookChapter(index: 3, title: "第二卷 雲湧", content: ""),
            BookChapter(index: 4, title: "第三章 抉擇", content: "", level: 1),
            BookChapter(index: 5, title: "第四章 歸途", content: "", level: 1),
        ],
        bookTitle: "範例書名",
        bookID: bookID,
        currentPage: 0,
        totalPages: 0,
        tocLayoutMode: .horizontalList,
        pageOffsets: [:],
        showsPageNumbers: false,
        currentIndex: 2,
        currentChapterID: nil,
        uncachedChapterIndexes: [],
        onSelectChapter: { _ in },
        isPresented: .constant(true)
    )
}
