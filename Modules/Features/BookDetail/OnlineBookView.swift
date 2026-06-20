import SwiftUI

// MARK: - Online Book Detail + TOC

struct OnlineBookView: View {
    /// The aggregated search book, when opened from search — enables source switching (換源).
    /// `nil` when opened from a single-source context (e.g. Discover).
    private let searchBook: SearchBook?

    @State private var currentBook: OnlineBook
    @EnvironmentObject var bookStore: BookStore
    @Environment(\.appDependencies) private var dependencies
    @ObservedObject private var sourceStore = BookSourceStore.shared
    @ObservedObject private var gs = GlobalSettings.shared

    @State private var chapters: [OnlineChapterRef] = []
    @State private var loadingTOC = false
    @State private var tocError: String? = nil
    @State private var addingToShelf = false
    @State private var openingReader = false
    @State private var addedBookId: UUID? = nil
    @State private var showReader = false
    @State private var alreadyInShelf = false
    @State private var temporaryReaderBookId: UUID? = nil
    @State private var detailInfo: OnlineBook? = nil
    @State private var introExpanded = false
    @State private var showSourcePicker = false

    private static let chapterPreviewLimit = 12

    // MARK: Init

    /// Single-source entry (Discover). No source switching.
    init(book: OnlineBook) {
        self.searchBook = nil
        _currentBook = State(initialValue: book)
    }

    /// Search entry — defaults to the first origin, keeps the rest for 換源.
    init(searchBook: SearchBook) {
        self.searchBook = searchBook
        if let origin = searchBook.origins.first {
            _currentBook = State(initialValue: Self.makeOnlineBook(from: searchBook, origin: origin))
        } else {
            _currentBook = State(initialValue: OnlineBook(
                name: searchBook.name, author: searchBook.author,
                intro: searchBook.intro, coverUrl: searchBook.coverUrl,
                bookUrl: "", tocUrl: "", wordCount: "",
                lastChapter: searchBook.lastChapter, kind: searchBook.kind,
                sourceId: UUID(), sourceName: ""
            ))
        }
    }

    private static func makeOnlineBook(from book: SearchBook, origin: BookOrigin) -> OnlineBook {
        OnlineBook(
            name: book.name,
            author: book.author,
            intro: origin.intro.isEmpty ? book.intro : origin.intro,
            coverUrl: origin.coverUrl.isEmpty ? book.coverUrl : origin.coverUrl,
            bookUrl: origin.bookUrl,
            tocUrl: origin.tocUrl,
            wordCount: origin.wordCount,
            lastChapter: origin.lastChapter,
            kind: origin.kind,
            sourceId: origin.sourceId,
            sourceName: origin.sourceName,
            runtimeVariables: origin.runtimeVariables
        )
    }

    private var source: BookSource? {
        sourceStore.sources.first(where: { $0.id == currentBook.sourceId })
    }

    private var canSwitchSource: Bool {
        (searchBook?.origins.count ?? 0) > 1
    }

    // MARK: Resolved display values (detail page overrides search result)

    private var displayName: String {
        let d = detailInfo?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = currentBook.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = d, !d.isEmpty { return d }
        return b.isEmpty ? localized("未知書名") : b
    }

    private var displayAuthor: String {
        let d = detailInfo?.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = currentBook.author.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = d, !d.isEmpty { return d }
        if !b.isEmpty { return b }
        let candidates = [
            detailInfo?.intro ?? "",
            currentBook.intro,
            detailInfo?.kind ?? "",
            currentBook.kind
        ].joined(separator: "\n")
        if let extracted = Self.extractAuthorFromText(candidates), !extracted.isEmpty {
            return extracted
        }
        return localized("未知作者")
    }

    private static func extractAuthorFromText(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let pattern = "作者[：:]\\s*([^\\s|、，,]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayCoverUrl: String {
        let d = detailInfo?.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = currentBook.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = d, !d.isEmpty { return d }
        return b
    }

    private var displayIntro: String {
        let d = detailInfo?.intro.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = currentBook.intro.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = if let d, !d.isEmpty { d } else { b }
        return ReaderHTMLUtilities.displayText(fromHTMLFragment: raw, preservingLineBreaks: true)
    }

    private var displayWordCount: String {
        let d = detailInfo?.wordCount.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = d, !d.isEmpty { return d }
        return currentBook.wordCount.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayLatestChapter: String {
        let d = detailInfo?.lastChapter.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = d, !d.isEmpty { return d }
        return currentBook.lastChapter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sourceName: String {
        let name = currentBook.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if let s = source?.bookSourceName, !s.isEmpty { return s }
        return localized("未知書源")
    }

    /// Category string split into individual genre tags, junk filtered out.
    private var tags: [String] {
        let d = detailInfo?.kind.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = d.isEmpty ? currentBook.kind : d
        let separators = CharacterSet(charactersIn: ",，|｜、/／;；\t\n ")
        var seen = Set<String>()
        return raw.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { tag in
                !tag.isEmpty && tag.count <= 10 && !tag.contains("作者")
                    && !tag.contains("字") && seen.insert(tag).inserted
            }
            .prefix(6)
            .map { $0 }
    }

    private var resolvedTOCURL: String? {
        let detailed = detailInfo?.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let detailed, !detailed.isEmpty { return detailed }
        let fallback = currentBook.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.xl) {
                header
                if !tags.isEmpty { tagStrip }
                if !displayIntro.isEmpty { introSection }
                sourceSection
                tocSection
            }
            .padding(.top, DSSpacing.md)
            .padding(.bottom, DSSpacing.md)
        }
        .scrollIndicators(.hidden)
        .background(DSColor.background)
        .toolbarTitleDisplayMode(.large)
        .toolbar(.hidden, for: .tabBar)
        .environment(\.locale, Locale(identifier: gs.localeIdentifier))
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showSourcePicker) {
            if let searchBook {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                    SourcePickerSheet(
                        searchBook: searchBook,
                        onSelectOrigin: { origin in switchToOrigin(origin) }
                    )
                }
            }
        }
        .fullScreenCover(isPresented: $showReader, onDismiss: {
            if let tempId = temporaryReaderBookId {
                if shouldKeepTemporaryReaderBook(tempId) {
                    temporaryReaderBookId = nil
                    addedBookId = tempId
                    alreadyInShelf = true
                } else {
                    bookStore.delete(bookId: tempId)
                    temporaryReaderBookId = nil
                    if addedBookId == tempId {
                        addedBookId = nil
                    }
                    checkAlreadyInShelf()
                }
            }
        }) {
            if let bid = addedBookId {
                BookReaderView(bookId: bid)
                    .environmentObject(bookStore)
            }
        }
        .onAppear {
            checkAlreadyInShelf()
            if chapters.isEmpty { loadTOC() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: DSSpacing.lg) {
            BookCoverImage(
                coverURL: displayCoverUrl,
                title: displayName,
                sourceBaseURL: source?.bookSourceUrl,
                sourceHeaders: source?.parsedHeaders ?? [:]
            )
            .frame(width: 96, height: 132)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.md)
                    .stroke(DSColor.separator, lineWidth: 0.5)
            )
            .shadow(color: DSColor.shadow, radius: 6, y: 3)

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(displayName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Text(displayAuthor)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !displayWordCount.isEmpty {
                    Text(displayWordCount)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DSSpacing.lg)
    }

    // MARK: Tags

    private var tagStrip: some View {
        FlowLayout(spacing: DSSpacing.sm) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.vertical, 6)
                    .background(DSColor.surface, in: Capsule())
            }
        }
        .padding(.horizontal, DSSpacing.lg)
    }

    // MARK: Intro

    private var introSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(localized("簡介"))
                .font(.headline)

            Text(displayIntro)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .lineLimit(introExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)

            if displayIntro.count > 80 {
                Button {
                    withAnimation(DSAnimation.standard) { introExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DSColor.accent)
                        .rotationEffect(.degrees(introExpanded ? 180 : 0))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(introExpanded ? localized("收合") : localized("展開"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DSSpacing.lg)
    }

    // MARK: Source Section ("來源" header outside; box shows source name, tap to switch)

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(localized("來源"))
                .font(.headline)

            Button {
                if canSwitchSource { showSourcePicker = true }
            } label: {
                HStack(spacing: DSSpacing.md) {
                    Image(systemName: "globe")
                        .font(.subheadline)
                        .foregroundStyle(DSColor.accent)

                    Text(sourceName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: DSSpacing.sm)

                    if canSwitchSource {
                        Text(localized("換源"))
                            .font(.caption)
                            .foregroundStyle(DSColor.accent)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, DSSpacing.md)
                .frame(maxWidth: .infinity)
                .background(DSColor.surface)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(canSwitchSource)
            .accessibilityLabel(localized("來源") + " " + sourceName)
            .accessibilityHint(canSwitchSource ? localized("換源") : "")
        }
        .padding(.horizontal, DSSpacing.lg)
    }

    // MARK: TOC

    private var tocSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(localized("目錄"))
                    .font(.headline)
                Spacer()
                if !chapters.isEmpty {
                    Text("\(chapters.count) " + localized("章"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !displayLatestChapter.isEmpty {
                Label(displayLatestChapter, systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            tocBody
        }
        .padding(.horizontal, DSSpacing.lg)
    }

    @ViewBuilder
    private var tocBody: some View {
        if loadingTOC && chapters.isEmpty {
            HStack {
                Spacer()
                ProgressView(localized("載入目錄…"))
                Spacer()
            }
            .padding(.vertical, DSSpacing.xl)
        } else if let err = tocError, chapters.isEmpty {
            VStack(spacing: DSSpacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(DSColor.warning)
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(localized("重試")) { loadTOC() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DSColor.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DSSpacing.lg)
        } else if chapters.isEmpty {
            Text(localized("目錄為空"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpacing.lg)
        } else {
            chapterCard
        }
    }

    private var chapterCard: some View {
        let preview = Array(chapters.prefix(Self.chapterPreviewLimit))
        return VStack(spacing: 0) {
            ForEach(Array(preview.enumerated()), id: \.element.id) { index, chapter in
                Button { openReader() } label: {
                    HStack(spacing: DSSpacing.md) {
                        Text(chapter.title)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: DSSpacing.sm)
                        if chapter.isVip || chapter.isPay {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(DSColor.warning)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.vertical, DSSpacing.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < preview.count - 1 {
                    Divider().padding(.leading, DSSpacing.lg)
                }
            }

            if chapters.count > preview.count {
                Divider().padding(.leading, DSSpacing.lg)
                Button { openReader() } label: {
                    HStack {
                        Text(localized("共") + " \(chapters.count) " + localized("章"))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DSColor.accent)
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.vertical, DSSpacing.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(DSColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
    }

    // MARK: Bottom Action Bar

    private var bottomBar: some View {
        HStack(spacing: DSSpacing.md) {
            Button { addToShelfOnly() } label: {
                HStack(spacing: DSSpacing.sm) {
                    if addingToShelf {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: alreadyInShelf ? "checkmark" : "plus")
                    }
                    Text(alreadyInShelf
                        ? localized("已加入書架")
                        : (addingToShelf ? localized("加入中…") : localized("加入書架")))
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(DSColor.accent)
            .disabled(chapters.isEmpty || addingToShelf || alreadyInShelf)

            Button { openReader() } label: {
                HStack(spacing: DSSpacing.sm) {
                    if openingReader {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "book.fill")
                    }
                    Text(openingReader
                        ? localized("打開中…")
                        : (alreadyInShelf ? localized("繼續閱讀") : localized("立即閱讀")))
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(DSColor.accent)
            .disabled(chapters.isEmpty || openingReader || addingToShelf)
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.sm)
        .background(.bar)
    }

    // MARK: Logic

    /// Switch to a different source (origin) and reload the detail + TOC from scratch.
    private func switchToOrigin(_ origin: BookOrigin) {
        guard let searchBook else { return }
        let newBook = Self.makeOnlineBook(from: searchBook, origin: origin)
        guard newBook.bookUrl != currentBook.bookUrl else { return }

        currentBook = newBook
        detailInfo = nil
        chapters = []
        tocError = nil
        addedBookId = nil
        alreadyInShelf = false
        introExpanded = false
        checkAlreadyInShelf()
        loadTOC()
    }

    private func checkAlreadyInShelf() {
        alreadyInShelf = bookStore.books.contains(where: { $0.bookInfoURL == currentBook.bookUrl })
        if alreadyInShelf {
            addedBookId = bookStore.books.first(where: { $0.bookInfoURL == currentBook.bookUrl })?.id
        }
    }

    private func loadTOC() {
        guard let source else {
            tocError = localized("書源已被刪除")
            return
        }

        loadingTOC = true
        tocError = nil
        let requestBook = currentBook

        Task {
            do {
                var finalTocURL = requestBook.bookUrl
                var currentRuntimeVariables = requestBook.runtimeVariables
                // Always fetch the detail page to get full info (author, title, etc.) and extract the real TOC URL
                if !requestBook.bookUrl.isEmpty {
                    let infoPackage = try await dependencies.bookSourceFetcher.fetchBookInfoPackage(
                        url: requestBook.bookUrl,
                        source: source,
                        runtimeVariables: currentRuntimeVariables
                    )
                    currentRuntimeVariables = infoPackage.runtimeVariables
                    await MainActor.run {
                        guard requestBook.bookUrl == currentBook.bookUrl else { return }
                        detailInfo = infoPackage.onlineBook
                    }
                    if !infoPackage.tocUrl.isEmpty {
                        finalTocURL = infoPackage.tocUrl
                    }
                }
                let tocPackage = try await dependencies.bookSourceFetcher.fetchTOCPackage(
                    tocUrl: finalTocURL,
                    source: source,
                    runtimeVariables: currentRuntimeVariables,
                    onFirstPageReady: { firstChapters in
                        // First page ready — show immediately, don't wait for multi-page fetch
                        Task { @MainActor in
                            guard requestBook.bookUrl == self.currentBook.bookUrl else { return }
                            if self.chapters.isEmpty {
                                self.chapters = firstChapters
                                self.loadingTOC = false
                            }
                            if let bookId = self.addedBookId {
                                self.bookStore.updateOnlineChapters(bookId: bookId, chapters: firstChapters)
                            }
                        }
                    }
                )
                await MainActor.run {
                    guard requestBook.bookUrl == currentBook.bookUrl else { return }
                    chapters = tocPackage.chapters
                    loadingTOC = false
                    if let bookId = addedBookId {
                        bookStore.updateOnlineChapters(bookId: bookId, chapters: tocPackage.chapters)
                    }
                }
            } catch {
                await MainActor.run {
                    guard requestBook.bookUrl == currentBook.bookUrl else { return }
                    tocError = error.localizedDescription
                    loadingTOC = false
                }
            }
        }
    }

    /// Add to shelf without opening the reader.
    private func addToShelfOnly() {
        guard !alreadyInShelf, !chapters.isEmpty, let source else { return }
        addingToShelf = true
        let newBook = bookStore.addOnlineBook(
            name: displayName,
            author: displayAuthor == localized("未知作者") ? "" : displayAuthor,
            sourceId: source.id,
            bookInfoURL: currentBook.bookUrl,
            tocURL: resolvedTOCURL,
            coverUrl: displayCoverUrl,
            runtimeVariables: detailInfo?.runtimeVariables ?? currentBook.runtimeVariables,
            chapters: chapters
        )
        addedBookId = newBook.id
        addingToShelf = false
        alreadyInShelf = true
    }

    private func shouldKeepTemporaryReaderBook(_ bookId: UUID) -> Bool {
        guard let book = bookStore.books.first(where: { $0.id == bookId }) else { return false }
        return book.offlineDownloadState != .none || book.offlineDownloadTask != nil
    }

    /// Ensure the book is on the shelf before opening, so the reader has a valid bookId.
    private func openReader() {
        guard !chapters.isEmpty, let source, !openingReader else { return }
        openingReader = true

        if alreadyInShelf, let existingId = addedBookId,
            let existing = bookStore.books.first(where: { $0.id == existingId })
        {
            if existing.onlineChapters?.isEmpty != false, !chapters.isEmpty {
                bookStore.updateOnlineChapters(bookId: existingId, chapters: chapters)
            }
            temporaryReaderBookId = nil
        } else {
            let tempBook = bookStore.addOnlineBook(
                name: displayName,
                author: displayAuthor == localized("未知作者") ? "" : displayAuthor,
                sourceId: source.id,
                bookInfoURL: currentBook.bookUrl,
                tocURL: resolvedTOCURL,
                coverUrl: displayCoverUrl,
                runtimeVariables: detailInfo?.runtimeVariables ?? currentBook.runtimeVariables,
                chapters: chapters
            )
            addedBookId = tempBook.id
            temporaryReaderBookId = tempBook.id
        }

        openingReader = false
        showReader = true
    }
}

// MARK: - Flow Layout (wrapping tag chips)

/// Left-to-right wrapping layout for a small set of chips. Lighter than a
/// horizontal `ScrollView` and keeps every tag visible.
private struct FlowLayout: Layout {
    var spacing: CGFloat = DSSpacing.sm

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > maxWidth, origin.x > 0 {
                origin.x = 0
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, origin.x - spacing)
        }
        let width = maxWidth.isFinite ? maxWidth : totalWidth
        return CGSize(width: width, height: origin.y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > bounds.maxX, origin.x > bounds.minX {
                origin.x = bounds.minX
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Preview

#Preview {
    let sample = OnlineBook(
        name: "修仙聊天群",
        author: "世味煮作茶",
        intro: "某一天，剛被開除的上班族余小安偶然進入了一個奇怪的修仙聊天群，接受了一個種藥草的委託，從此，他變成了一個種地的……不過他的顧客名字都很奇怪，比如：白帝仙王、青龍仙君、太上仙尊。",
        coverUrl: "",
        bookUrl: "https://example.com/book/1",
        tocUrl: "https://example.com/book/1/toc",
        wordCount: "34.8萬字",
        lastChapter: "第703章 大結局",
        kind: "都市腦洞 | 都市 | 系統 | 神豪 | 諸天萬界",
        sourceId: UUID(),
        sourceName: "晴天小說"
    )
    return NavigationStack {
        OnlineBookView(book: sample)
            .environmentObject(BookStore())
    }
}
