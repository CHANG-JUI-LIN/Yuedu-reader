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
    @State private var addedBookId: UUID? = nil
    @State private var openingPlayer = false
    @State private var showPlayer = false

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
                playButton
                if !displayIntro.isEmpty { introSection }
                chapterSection
            }
            .padding(.vertical, DSSpacing.md)
        }
        .scrollIndicators(.hidden)
        .background(DSColor.background)
        .toolbarTitleDisplayMode(.large)
        .toolbar(.hidden, for: .tabBar)
        .environment(\.locale, Locale(identifier: gs.localeIdentifier))
        .fullScreenCover(isPresented: $showPlayer) {
            if let bid = addedBookId {
                BookReaderView(bookId: bid).environmentObject(bookStore)
            }
        }
        .onAppear { if chapters.isEmpty, loadError == nil { load() } }
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
            .frame(width: 112, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.md)
                    .stroke(DSColor.separator, lineWidth: 0.5)
            )
            .shadow(color: DSColor.shadow, radius: 6, y: 3)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "headphones")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(DSColor.accent, in: Circle())
                    .padding(4)
            }

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(displayName)
                    .font(.title2.weight(.bold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(displayAuthor)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !chapters.isEmpty {
                    Text(String(format: localized("共 %d 章"), chapters.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DSSpacing.lg)
    }

    // MARK: Play button

    private var playButton: some View {
        Button {
            play(chapterIndex: resumeChapterIndex)
        } label: {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: "play.fill")
                Text(resumeChapterIndex > 0 ? localized("繼續播放") : localized("開始播放"))
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(DSColor.accent, in: RoundedRectangle(cornerRadius: DSRadius.md))
            .foregroundStyle(.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(chapters.isEmpty || openingPlayer)
        .opacity(chapters.isEmpty ? 0.5 : 1)
        .padding(.horizontal, DSSpacing.lg)
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

    // MARK: Chapters

    private var chapterSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack {
                Text(localized("目錄")).font(.headline)
                Spacer()
                if !chapters.isEmpty {
                    Text(String(format: localized("共 %d 章"), chapters.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, DSSpacing.lg)

            if let loadError {
                Text(loadError)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.vertical, DSSpacing.lg)
            } else if chapters.isEmpty && loading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DSSpacing.xl)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { idx, chapter in
                        Button {
                            play(chapterIndex: idx)
                        } label: {
                            HStack(spacing: DSSpacing.md) {
                                Text(chapter.title.isEmpty
                                     ? String(format: localized("第 %d 章"), idx + 1)
                                     : chapter.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "play.circle")
                                    .foregroundStyle(DSColor.accent)
                            }
                            .padding(.vertical, DSSpacing.sm)
                            .padding(.horizontal, DSSpacing.lg)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, DSSpacing.lg)
                    }
                }
            }
        }
    }

    // MARK: Load (detail + TOC via the shared fetcher API)

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

    /// Ensure the book is on the shelf (as an `.audio` book), seek to `chapterIndex`,
    /// then open the shared audiobook player.
    private func play(chapterIndex: Int) {
        guard !chapters.isEmpty, let source, !openingPlayer else { return }
        openingPlayer = true

        let bookId: UUID
        let runtimeVars = resolvedRuntimeVariables
        if let existing = existingShelfBookId() {
            bookId = existing
            bookStore.updateOnlineBookContentKind(bookId: existing, kind: .audio)
            bookStore.updateOnlineChapters(
                bookId: existing,
                chapters: chapters,
                runtimeVariables: runtimeVars
            )
        } else {
            let newBook = bookStore.addOnlineBook(
                name: displayName,
                author: displayAuthor == localized("未知作者") ? "" : displayAuthor,
                sourceId: source.id,
                bookInfoURL: currentBook.bookUrl,
                tocURL: resolvedTOCURL,
                coverUrl: displayCoverUrl,
                runtimeVariables: runtimeVars,
                contentKind: .audio,
                chapters: chapters)
            bookId = newBook.id
        }
        addedBookId = bookId
        bookStore.updateAudioPosition(
            bookId: bookId, chapter: chapterIndex, time: 0,
            totalChapters: chapters.count, forceSave: true)
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
