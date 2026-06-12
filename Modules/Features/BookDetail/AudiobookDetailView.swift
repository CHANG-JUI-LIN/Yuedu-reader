import SwiftUI
import os.log

/// On-device routing diagnostics (Console.app, category `audioroute`): one line per
/// detail-page tap showing every signal the audio/text routing decision used.
private let audioRouteLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.yuedu.app", category: "audioroute")

// MARK: - Audiobook Detail (unified audiobook landing page)

/// Dedicated detail page for audiobooks. Audiobooks must NOT fall into the text-book
/// `OnlineBookView`; this is the single UI every audiobook lands on regardless of
/// whether the signal comes from `bookSourceType == 1` or a per-book aggregate-source
/// payload such as `tab=听书`.
struct AudiobookDetailView: View {
    /// Aggregated search book when opened from search; `nil` from a single-source context (Discover).
    private let searchBook: SearchBook?
    private static let chapterPreviewLimit = 12

    @State private var currentBook: OnlineBook
    @EnvironmentObject var bookStore: BookStore
    @Environment(\.appDependencies) private var dependencies
    @ObservedObject private var sourceStore = BookSourceStore.shared
    @ObservedObject private var gs = GlobalSettings.shared

    @State private var chapters: [OnlineChapterRef] = []
    @State private var loading = false
    @State private var loadError: String? = nil
    @State private var detailInfo: OnlineBook? = nil
    @State private var loadedRuntimeVariables: [String: String]? = nil
    @State private var introExpanded = false
    @State private var addingToShelf = false
    @State private var addedBookId: UUID? = nil
    @State private var activePlayerBookId: UUID? = nil
    @State private var alreadyInShelf = false
    @State private var openingPlayer = false
    @State private var showPlayer = false
    @State private var showSourcePicker = false

    // MARK: Init

    /// Single-source entry (Discover).
    init(book: OnlineBook) {
        self.searchBook = nil
        _currentBook = State(initialValue: book)
    }

    /// Search entry — defaults to the first audio origin, then falls back to the first origin.
    init(searchBook: SearchBook) {
        self.searchBook = searchBook
        if let origin = searchBook.preferredOrigin(for: .audio) ?? searchBook.origins.first {
            _currentBook = State(initialValue: OnlineBook(
                name: searchBook.name, author: searchBook.author,
                intro: origin.intro, coverUrl: origin.coverUrl,
                bookUrl: origin.bookUrl, tocUrl: origin.tocUrl,
                wordCount: origin.wordCount, lastChapter: origin.lastChapter,
                kind: origin.kind, sourceId: origin.sourceId,
                sourceName: origin.sourceName, runtimeVariables: origin.runtimeVariables))
        } else {
            _currentBook = State(initialValue: OnlineBook(
                name: searchBook.name, author: searchBook.author,
                intro: "", coverUrl: "", bookUrl: "", tocUrl: "",
                wordCount: "", lastChapter: "", kind: "",
                sourceId: UUID(), sourceName: ""))
        }
    }

    private var source: BookSource? {
        sourceStore.sources.first(where: { $0.id == currentBook.sourceId })
    }

    private var sourceName: String {
        let name = currentBook.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if let s = source?.bookSourceName, !s.isEmpty { return s }
        return localized("未知書源")
    }

    private var canSwitchSource: Bool {
        (searchBook?.origins.count ?? 0) > 1
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

    // MARK: Display fallbacks (detail overrides search result, never with placeholders)

    private var displayName: String {
        if let d = detailInfo?.name.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d }
        let b = currentBook.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? localized("未知書名") : b
    }

    private var displayAuthor: String {
        if let d = detailInfo?.author.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d }
        let b = currentBook.author.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? localized("未知作者") : b
    }

    private var displayCoverUrl: String {
        if let d = detailInfo?.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d }
        return currentBook.coverUrl
    }

    private var displayIntro: String {
        if let d = detailInfo?.intro.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d }
        return currentBook.intro.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayLatestChapter: String {
        if let d = detailInfo?.lastChapter.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
            return d
        }
        return currentBook.lastChapter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
        if let detailed = detailInfo?.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines), !detailed.isEmpty {
            return detailed
        }
        let fallback = currentBook.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    private var resolvedRuntimeVariables: [String: String]? {
        loadedRuntimeVariables ?? detailInfo?.runtimeVariables ?? currentBook.runtimeVariables
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.xl) {
                header
                if !tags.isEmpty { tagStrip }
                if !displayIntro.isEmpty { introSection }
                sourceSection
                chapterSection
            }
            .padding(.vertical, DSSpacing.md)
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
        .fullScreenCover(isPresented: $showPlayer) {
            if let bid = activePlayerBookId {
                if bookStore.books.contains(where: { $0.id == bid }) {
                    BookReaderView(bookId: bid).environmentObject(bookStore)
                } else {
                    AudiobookReaderView(bookId: bid).environmentObject(bookStore)
                }
            }
        }
        .onAppear {
            checkAlreadyInShelf()
            if chapters.isEmpty, loadError == nil { load() }
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
                    .foregroundStyle(.primary)
                    .font(.title2.weight(.bold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Text(displayAuthor)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

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
            .tint(.green)
            .disabled(chapters.isEmpty || addingToShelf || alreadyInShelf)

            Button { play(chapterIndex: resumeChapterIndex) } label: {
                HStack(spacing: DSSpacing.sm) {
                    if openingPlayer {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(resumeChapterIndex > 0 ? localized("繼續播放") : localized("開始播放"))
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(DSColor.accent)
            .disabled(chapters.isEmpty || openingPlayer || addingToShelf)
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.sm)
        .background(.bar)
    }

    /// Resume from the saved audio position when this book is already on the shelf.
    private var resumeChapterIndex: Int {
        guard let id = addedBookId ?? existingShelfBookId(),
              let book = bookStore.books.first(where: { $0.id == id })
        else { return 0 }
        return min(max(0, book.audioChapterIndex), max(0, chapters.count - 1))
    }

    // MARK: Intro

    private var introSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(localized("簡介")).font(.headline)
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

    // MARK: Source

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

    // MARK: Chapters

    private var chapterSection: some View {
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

            chapterBody
        }
        .padding(.horizontal, DSSpacing.lg)
    }

    @ViewBuilder
    private var chapterBody: some View {
        if loading && chapters.isEmpty {
            HStack {
                Spacer()
                ProgressView(localized("載入目錄…"))
                Spacer()
            }
            .padding(.vertical, DSSpacing.xl)
        } else if let loadError, chapters.isEmpty {
            VStack(spacing: DSSpacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(DSColor.warning)
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(localized("重試")) { load() }
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
                Button { play(chapterIndex: index) } label: {
                    HStack(spacing: DSSpacing.md) {
                        Text(chapter.title.isEmpty
                             ? String(format: localized("第 %d 章"), index + 1)
                             : chapter.title)
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
                Button { play(chapterIndex: resumeChapterIndex) } label: {
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

    // MARK: Load (detail + TOC via the shared fetcher API)

    private func switchToOrigin(_ origin: BookOrigin) {
        guard let searchBook else { return }
        let newBook = Self.makeOnlineBook(from: searchBook, origin: origin)
        guard newBook.bookUrl != currentBook.bookUrl else { return }

        currentBook = newBook
        detailInfo = nil
        chapters = []
        loadError = nil
        loadedRuntimeVariables = nil
        addedBookId = nil
        activePlayerBookId = nil
        alreadyInShelf = false
        introExpanded = false
        checkAlreadyInShelf()
        load()
    }

    private func load() {
        guard let source else { loadError = localized("書源已被刪除"); return }
        loading = true
        loadError = nil
        loadedRuntimeVariables = nil
        let request = currentBook
        Task {
            do {
                var tocURL = request.bookUrl
                var runtimeVars = request.runtimeVariables
                if !request.bookUrl.isEmpty {
                    let pkg = try await dependencies.bookSourceFetcher.fetchBookInfoPackage(
                        url: request.bookUrl, source: source, runtimeVariables: runtimeVars)
                    runtimeVars = Self.mergedRuntimeVariables(runtimeVars, pkg.runtimeVariables)
                    await MainActor.run {
                        guard request.bookUrl == currentBook.bookUrl else { return }
                        detailInfo = pkg.onlineBook
                    }
                    if !pkg.tocUrl.isEmpty { tocURL = pkg.tocUrl }
                }
                let tocPkg = try await dependencies.bookSourceFetcher.fetchTOCPackage(
                    tocUrl: tocURL, source: source, runtimeVariables: runtimeVars)
                runtimeVars = Self.mergedRuntimeVariables(runtimeVars, tocPkg.runtimeVariables)
                await MainActor.run {
                    guard request.bookUrl == currentBook.bookUrl else { return }
                    chapters = tocPkg.chapters
                    loadedRuntimeVariables = runtimeVars
                    loading = false
                }
            } catch {
                await MainActor.run {
                    guard request.bookUrl == currentBook.bookUrl else { return }
                    loadError = error.localizedDescription
                    loading = false
                }
            }
        }
    }

    private static func mergedRuntimeVariables(
        _ base: [String: String]?,
        _ next: [String: String]?
    ) -> [String: String]? {
        var merged = base ?? [:]
        if let next {
            merged.merge(next) { _, new in new }
        }
        return merged.isEmpty ? nil : merged
    }

    // MARK: Play

    private func existingShelfBookId() -> UUID? {
        bookStore.books.first(where: { $0.bookInfoURL == currentBook.bookUrl })?.id
    }

    private func checkAlreadyInShelf() {
        addedBookId = existingShelfBookId()
        alreadyInShelf = addedBookId != nil
    }

    private func addToShelfOnly() {
        guard !alreadyInShelf, !addingToShelf, !chapters.isEmpty, let source else { return }
        addingToShelf = true
        let newBook = bookStore.addOnlineBook(
            name: displayName,
            author: displayAuthor == localized("未知作者") ? "" : displayAuthor,
            sourceId: source.id,
            bookInfoURL: currentBook.bookUrl,
            tocURL: resolvedTOCURL,
            coverUrl: displayCoverUrl,
            runtimeVariables: resolvedRuntimeVariables,
            contentKind: .audio,
            chapters: chapters)
        addedBookId = newBook.id
        activePlayerBookId = newBook.id
        alreadyInShelf = true
        addingToShelf = false
    }

    private func preparePlayerCoverFallback(bookId: UUID, source: BookSource) {
        AudiobookPlayer.shared.prepareCoverFallback(
            bookId: bookId,
            coverUrl: displayCoverUrl,
            sourceBaseURL: source.bookSourceUrl,
            sourceHeaders: source.parsedHeaders
        )
    }

    private func transientAudiobook(
        source: BookSource,
        runtimeVariables: [String: String]?,
        chapterIndex: Int
    ) -> ReadingBook {
        var book = ReadingBook(
            title: displayName,
            author: displayAuthor == localized("未知作者") ? "" : displayAuthor,
            source: currentBook.bookUrl,
            contentFilename: "")
        book.isOnline = true
        book.contentPipelineKind = .audio
        book.bookSourceId = source.id
        book.bookInfoURL = currentBook.bookUrl
        book.tocURL = resolvedTOCURL
        book.runtimeVariables = runtimeVariables
        book.onlineChapters = chapters.map { chapter in
            var sanitized = chapter
            sanitized.title = ReaderHTMLUtilities.displayText(fromHTMLFragment: chapter.title)
            return sanitized
        }
        book.audioChapterIndex = chapterIndex
        return book
    }

    /// Open playback. Only the explicit "加入書架" action creates a permanent shelf item.
    private func play(chapterIndex: Int) {
        guard !chapters.isEmpty, let source, !openingPlayer else { return }
        openingPlayer = true

        let runtimeVars = resolvedRuntimeVariables
        if let existing = existingShelfBookId() {
            addedBookId = existing
            alreadyInShelf = true
            bookStore.updateOnlineBookContentKind(bookId: existing, kind: .audio)
            bookStore.updateOnlineChapters(
                bookId: existing,
                chapters: chapters,
                runtimeVariables: runtimeVars
            )
            bookStore.updateAudioPosition(
                bookId: existing, chapter: chapterIndex, time: 0,
                totalChapters: chapters.count, forceSave: true)
            preparePlayerCoverFallback(bookId: existing, source: source)
            activePlayerBookId = existing
        } else {
            let transient = transientAudiobook(
                source: source,
                runtimeVariables: runtimeVars,
                chapterIndex: chapterIndex
            )
            preparePlayerCoverFallback(bookId: transient.id, source: source)
            AudiobookPlayer.shared.startTransient(book: transient, store: bookStore)
            activePlayerBookId = transient.id
        }
        openingPlayer = false
        showPlayer = true
    }
}

// MARK: - Source-type routing helper

extension BookSourceStore {
    /// True when the source backing this id is a dedicated audiobook source.
    func isAudiobookSource(id: UUID?) -> Bool {
        guard let id else { return false }
        return sources.first { $0.id == id }?.bookSourceType == 1
    }

    func isAudiobook(_ book: OnlineBook) -> Bool {
        let source = sources.first { $0.id == book.sourceId }
        let kind = book.inferredContentKind(source: source)
        let modes = OnlineBookContentInference.sourceRuntimeModeMarkers(for: source)
        audioRouteLog.notice(
            "⟐ route \(book.name, privacy: .public) → \(String(describing: kind), privacy: .public) srcType=\(source?.bookSourceType ?? -1) modes=\(modes.joined(separator: ","), privacy: .public) vars=\(book.runtimeVariables?.keys.joined(separator: ",") ?? "-", privacy: .public) url=\(String(book.bookUrl.prefix(160)), privacy: .public)"
        )
        return kind == .audio
    }

    func isAudiobook(_ searchBook: SearchBook) -> Bool {
        let kind = searchBook.inferredContentKind(sourceStore: self)
        let origin = searchBook.origins.first
        let source = sources.first { $0.id == origin?.sourceId }
        let modes = OnlineBookContentInference.sourceRuntimeModeMarkers(for: source)
        audioRouteLog.notice(
            "⟐ route(search) \(searchBook.name, privacy: .public) → \(String(describing: kind), privacy: .public) origins=\(searchBook.origins.count) srcType=\(source?.bookSourceType ?? -1) modes=\(modes.joined(separator: ","), privacy: .public) url=\(String(origin?.bookUrl.prefix(160) ?? ""), privacy: .public)"
        )
        return kind == .audio
    }

    // Quiet variants for list/cover badges — the logging `isAudiobook` methods above are
    // routing diagnostics and must not fire per-cell while a list scrolls.
    func isAudiobookForBadge(_ book: OnlineBook) -> Bool {
        book.inferredContentKind(source: sources.first { $0.id == book.sourceId }) == .audio
    }

    func isAudiobookForBadge(_ searchBook: SearchBook) -> Bool {
        searchBook.inferredContentKind(sourceStore: self) == .audio
    }
}

// MARK: - Flow Layout (wrapping tag chips)

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

#Preview {
    NavigationStack {
        AudiobookDetailView(book: OnlineBook(
            name: "斗羅大陸",
            author: "唐家三少",
            intro: "唐門外門弟子唐三，因偷學內門絕學為唐門所不容，跳崖明志卻來到了另一個世界——斗羅大陸。",
            coverUrl: "",
            bookUrl: "https://example.com/audiobook/1",
            tocUrl: "https://example.com/audiobook/1/toc",
            wordCount: "",
            lastChapter: "",
            kind: "玄幻",
            sourceId: UUID(),
            sourceName: "示範有聲書源"))
        .environmentObject(BookStore())
    }
}
