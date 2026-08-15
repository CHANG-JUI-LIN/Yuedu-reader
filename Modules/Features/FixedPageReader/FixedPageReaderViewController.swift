import UIKit
import Nuke

// MARK: - Fixed page reader container
//
// Owns the active mode reader (paged or webtoon), drives chapter fetching through
// the normal `ChapterFetchManager` pipeline, persists position, and bridges
// state/actions to the SwiftUI overlay via `FixedPageReaderState`.

final class FixedPageReaderViewController: UIViewController, FixedPageReaderContainer {

    private let book: ReadingBook
    private let source: BookSource?
    private weak var store: BookStore?
    private let state: FixedPageReaderState
    private let headers: [String: String]
    private let chapters: [OnlineChapterRef]
    private let chapterFetcher: any ChapterFetching

    private var chapterIndex: Int
    private var fixedPageReaderConfiguration: FixedPageReaderConfiguration
    private var reader: (any FixedPageModeReader)?
    private var loadToken = UUID()
    private var saveTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var imagePrefetcher = ImagePrefetcher()
    private var currentPages: [FixedPage] = []
    private var targetWidth: CGFloat = 0
    /// Single-chapter documents only: the file's own table of contents, used as
    /// in-document jump targets.
    private var documentSections: [FixedPageDocumentSection] = []

    init(
        book: ReadingBook,
        store: BookStore,
        state: FixedPageReaderState,
        chapterFetcher: any ChapterFetching
    ) {
        self.book = book
        self.store = store
        self.state = state
        self.chapterFetcher = chapterFetcher
        let resolvedSource = book.bookSourceId.flatMap { id in
            BookSourceStore.shared.sources.first { $0.id == id }
        }
        self.source = resolvedSource
        self.headers = BookCoverLoader.headers(
            sourceBaseURL: resolvedSource?.bookSourceUrl,
            sourceHeaders: resolvedSource?.parsedHeaders ?? [:]
        )
        if !book.isOnline,
           (book.resolvedPipelineKind == .manga || book.resolvedPipelineKind == .fixedPage),
           (book.onlineChapters ?? []).isEmpty {
            self.chapters = [OnlineChapterRef(index: 0, title: book.title, url: book.contentFilename)]
        } else {
            self.chapters = book.onlineChapters ?? []
        }
        self.chapterIndex = min(max(0, book.mangaChapterIndex), max(0, self.chapters.count - 1))
        self.fixedPageReaderConfiguration = FixedPageReadingMode.savedConfiguration(for: book.id)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        // Rendered pages are the largest thing this reader holds; closing the book
        // releases them along with the open document. A no-op for a manga book,
        // whose caches are empty.
        Task {
            await PDFPageRasterizer.shared.purge()
            await FixedLayoutEPUBRenderer.shared.purge()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        state.fixedPageReaderConfiguration = fixedPageReaderConfiguration
        state.chapterListItems = FixedPageChapterListItem.items(from: chapters)
        state.currentChapterIndex = chapterIndex
        state.onJumpToPage = { [weak self] page in self?.reader?.goToPage(page, animated: false) }
        state.onSelectChapter = { [weak self] index in self?.selectTableOfContentsEntry(at: index) }
        state.onSetConfiguration = { [weak self] configuration in self?.changeConfiguration(configuration) }
        state.onNextChapter = { [weak self] in self?.loadNextChapter() }
        state.onPrevChapter = { [weak self] in self?.loadPreviousChapter() }
        state.onReload = { [weak self] in
            guard let self else { return }
            self.loadChapter(at: self.chapterIndex, startPage: self.reader?.currentPageIndex() ?? 0)
        }

        store?.updateLastOpened(bookId: book.id)
        installReader()
        if isSingleChapterDocumentBook { chapterIndex = 0 }
        loadChapter(at: chapterIndex, startPage: restoredStartPage)
    }

    /// Fixed-layout EPUB used to load one page per chapter, so its saved positions
    /// carry the page number in `mangaChapterIndex` with `mangaPage` at 0. Reading
    /// those as a page keeps a mid-book position across the move to a single
    /// chapter; positions saved from now on are (chapter 0, page N). Removable once
    /// no shelf still holds a pre-2026-08 fixed-layout position.
    private var restoredStartPage: Int {
        if isSingleChapterDocumentBook, book.mangaPage == 0, book.mangaChapterIndex > 0 {
            return book.mangaChapterIndex
        }
        return book.mangaPage
    }

    /// Chapter count for progress bookkeeping. A single-chapter document reports 1,
    /// even though a fixed-layout EPUB still persists one chapter ref per page.
    private var progressChapterCount: Int {
        isSingleChapterDocumentBook ? 1 : chapters.count
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveTask?.cancel()
        let page = reader?.currentPageIndex() ?? 0
        store?.updateMangaPosition(
            bookId: book.id,
            chapter: chapterIndex,
            page: page,
            totalChapters: progressChapterCount,
            pageProgress: documentProgress(forPage: page)
        )
    }

    // MARK: Reader installation

    private func installReader() {
        reader?.willMove(toParent: nil)
        reader?.view.removeFromSuperview()
        reader?.removeFromParent()

        targetWidth = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        let newReader: any FixedPageModeReader = fixedPageReaderConfiguration.layout == .paged
            ? FixedPagePagedViewController(
                fixedPageReaderConfiguration: fixedPageReaderConfiguration,
                targetWidth: targetWidth
            )
            : FixedPageWebtoonViewController(
                fixedPageReaderConfiguration: fixedPageReaderConfiguration,
                targetWidth: targetWidth
            )
        newReader.container = self
        addChild(newReader)
        newReader.view.frame = view.bounds
        newReader.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(newReader.view, at: 0)
        newReader.didMove(toParent: self)
        reader = newReader
    }

    // MARK: Chapter loading

    private func loadChapter(at index: Int, startPage: Int) {
        guard chapters.indices.contains(index) else { return }
        chapterIndex = index
        currentPages = []
        prefetchTask?.cancel()
        state.currentChapterIndex = index
        state.isLoading = true
        state.errorMessage = nil
        state.chapterTitle = chapters[index].title

        let token = UUID()
        loadToken = token
        if isSingleChapterDocumentBook {
            loadLocalDocument(startPage: startPage, token: token)
            return
        }
        if isLocalFixedPageBook {
            loadLocalChapter(at: index, startPage: startPage, token: token)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let package = try await self.chapterFetcher.fetchChapter(
                    book: self.book, chapterIndex: index, priority: .immediate, store: self.store)
                guard self.loadToken == token else { return }
                let localDir = MangaChapterParser.chapterDirectory(bookId: self.book.id, chapterIndex: index)
                let pages = MangaChapterParser.pages(from: package.content, headers: self.headers, localDir: localDir)
                self.state.isLoading = false
                guard !pages.isEmpty else {
                    self.state.errorMessage = localized("未找到圖片")
                    return
                }
                self.currentPages = pages
                self.reader?.setPages(pages, startPage: max(0, min(startPage, pages.count - 1)))
                self.prefetchAroundChapters()
                self.prefetchCurrentChapterPages(pages: pages, currentPage: max(0, min(startPage, pages.count - 1)))
            } catch {
                guard self.loadToken == token else { return }
                self.state.isLoading = false
                self.state.errorMessage = error.localizedDescription
            }
        }
    }

    private var isLocalFixedPageBook: Bool {
        !book.isOnline
            && (book.resolvedPipelineKind == .manga || book.resolvedPipelineKind == .fixedPage)
    }

    private var isLocalFixedLayoutEPUBBook: Bool {
        isLocalFixedPageBook
            && book.source == "local_epub"
            && book.contentFilename.lowercased().hasSuffix(".epub")
    }

    private var isLocalPDFBook: Bool {
        isLocalFixedPageBook && book.source == "local_pdf"
    }

    /// A local document whose pages are rasterized on demand — a PDF or a
    /// fixed-layout EPUB. Both load as a single chapter holding every page, so page
    /// numbers stay absolute and turning a page never reopens the document; their
    /// table of contents moves within that chapter instead of loading another one.
    private var isSingleChapterDocumentBook: Bool {
        isLocalPDFBook || isLocalFixedLayoutEPUBBook
    }

    // MARK: Single-chapter documents (PDF / fixed-layout EPUB)

    private func loadLocalDocument(startPage: Int, token: UUID) {
        let filename = book.contentFilename
        let isPDF = isLocalPDFBook
        let fileURL = isPDF
            ? LocalPDFArchive.archiveURL(for: filename)
            : LocalMangaArchive.archiveURL(for: filename)

        Task { [weak self] in
            guard let self else { return }

            var pageCount = 0
            var sections: [FixedPageDocumentSection] = []
            if isPDF {
                pageCount = await PDFPageRasterizer.shared.pageCount(fileURL: fileURL)
                sections = await PDFPageRasterizer.shared.sections(fileURL: fileURL)
            } else {
                do {
                    let info = try await FixedLayoutEPUBRenderer.shared.documentInfo(sourceURL: fileURL)
                    pageCount = info.pageCount
                    sections = info.sections
                } catch {
                    AppLogger.render("Fixed-layout EPUB could not be opened: \(filename)", error: error)
                }
            }
            guard self.loadToken == token else { return }

            self.state.isLoading = false
            guard pageCount > 0 else {
                AppLogger.error("Fixed-page document has no readable pages: \(filename)")
                self.state.errorMessage = isPDF
                    ? LocalPDFArchiveError.cannotReadDocument.errorDescription
                    : localized("無法讀取這本書的頁面")
                return
            }

            let pages = (0..<pageCount).map { pageIndex in
                FixedPage(
                    id: pageIndex,
                    imageURL: fileURL.absoluteString,
                    headers: [:],
                    localURL: nil,
                    renderSource: isPDF
                        ? .pdf(sourceFilename: filename, pageIndex: pageIndex)
                        : .fixedLayoutEPUB(sourceFilename: filename, chapterIndex: pageIndex)
                )
            }
            let resolvedStart = max(0, min(startPage, pageCount - 1))
            self.currentPages = pages
            self.documentSections = sections
            // No bookmarks means no table of contents to show, which the overlay
            // reads as "hide the 目錄 button".
            self.state.chapterListItems = sections.enumerated().map { offset, section in
                FixedPageChapterListItem(id: UUID(), index: offset, title: section.title)
            }
            self.reader?.setPages(pages, startPage: resolvedStart)
            self.syncDocumentSection(forPage: resolvedStart)
            self.prefetchCurrentChapterPages(pages: pages, currentPage: resolvedStart)
        }
    }

    /// Keep the top bar's title and the table of contents' checkmark on the section
    /// containing the current page.
    private func syncDocumentSection(forPage page: Int) {
        guard !documentSections.isEmpty else { return }
        let index = documentSections.lastIndex { $0.startPage <= page } ?? 0
        guard state.currentChapterIndex != index || state.chapterTitle != documentSections[index].title else { return }
        state.currentChapterIndex = index
        state.chapterTitle = documentSections[index].title
    }

    private func jumpToDocumentSection(at index: Int) {
        guard documentSections.indices.contains(index) else { return }
        reader?.goToPage(documentSections[index].startPage, animated: false)
        syncDocumentSection(forPage: documentSections[index].startPage)
    }

    /// The current page's section, or nil when the document has no table of contents.
    private var currentDocumentSectionIndex: Int? {
        guard !documentSections.isEmpty else { return nil }
        let page = reader?.currentPageIndex() ?? 0
        return documentSections.lastIndex { $0.startPage <= page } ?? 0
    }

    private func loadLocalChapter(at index: Int, startPage: Int, token: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let chapterURL = self.chapters[index].url
                let archiveFilename = chapterURL.isEmpty ? self.book.contentFilename : chapterURL
                let archiveURL = LocalMangaArchive.archiveURL(for: archiveFilename)
                var pages = LocalMangaArchive.pagesForExtractedChapter(
                    bookId: self.book.id,
                    chapterIndex: index
                )
                if pages.isEmpty {
                    pages = try await LocalMangaArchive.extractPages(
                        from: archiveURL,
                        to: LocalMangaArchive.chapterDirectory(bookId: self.book.id, chapterIndex: index)
                    )
                }
                guard self.loadToken == token else { return }
                self.state.isLoading = false
                guard !pages.isEmpty else {
                    self.state.errorMessage = localized("未找到圖片")
                    return
                }
                self.reader?.setPages(pages, startPage: max(0, min(startPage, pages.count - 1)))
            } catch {
                guard self.loadToken == token else { return }
                self.state.isLoading = false
                self.state.errorMessage = error.localizedDescription
            }
        }
    }

    /// A table-of-contents row: a chapter load for every book except a PDF, whose
    /// rows are bookmarks inside the single loaded chapter.
    private func selectTableOfContentsEntry(at index: Int) {
        if isSingleChapterDocumentBook {
            jumpToDocumentSection(at: index)
        } else {
            selectChapter(at: index)
        }
    }

    private func selectChapter(at index: Int) {
        guard chapters.indices.contains(index), index != chapterIndex else { return }
        loadChapter(at: index, startPage: 0)
    }

    private func loadNextChapter() {
        if isSingleChapterDocumentBook {
            guard let current = currentDocumentSectionIndex else { return }
            jumpToDocumentSection(at: current + 1)
            return
        }
        guard chapterIndex + 1 < chapters.count else { return }
        loadChapter(at: chapterIndex + 1, startPage: 0)
    }

    private func loadPreviousChapter() {
        if isSingleChapterDocumentBook {
            guard let current = currentDocumentSectionIndex else { return }
            // Already past a section's first page: go back to that page first.
            let page = reader?.currentPageIndex() ?? 0
            jumpToDocumentSection(at: documentSections[current].startPage < page ? current : current - 1)
            return
        }
        guard chapterIndex - 1 >= 0 else { return }
        loadChapter(at: chapterIndex - 1, startPage: 0)
    }

    private func changeConfiguration(_ newConfiguration: FixedPageReaderConfiguration) {
        guard newConfiguration != fixedPageReaderConfiguration else { return }
        let page = reader?.currentPageIndex() ?? 0
        fixedPageReaderConfiguration = newConfiguration
        FixedPageReadingMode.save(newConfiguration.mode, for: book.id)
        state.fixedPageReaderConfiguration = newConfiguration
        installReader()
        loadChapter(at: chapterIndex, startPage: page)
    }

    // MARK: FixedPageReaderContainer

    func reader(didMoveToPage page: Int, total: Int) {
        state.currentPage = page
        state.totalPages = total
        scheduleSave(page: page)
        if isSingleChapterDocumentBook { syncDocumentSection(forPage: page) }
        guard !currentPages.isEmpty else { return }
        prefetchCurrentChapterPages(pages: currentPages, currentPage: page)
        if total > 3, page >= total * 3 / 4 {
            prefetchNextChapterImages()
        }
    }

    func readerRequestsNextChapter() { loadNextChapter() }
    func readerRequestsPreviousChapter() { loadPreviousChapter() }
    func readerToggleControls() { state.showControls.toggle() }
    func readerToggleBookmark() {
        guard chapters.indices.contains(chapterIndex) else { return }
        let page = reader?.currentPageIndex() ?? 0
        // These books are a single chapter, so `chapterStart` would collapse every
        // page onto one bookmark; carry the page in the offset slot instead.
        let position: CoreTextReadingPosition = isSingleChapterDocumentBook
            ? CoreTextReadingPosition(spineIndex: chapterIndex, charOffset: page)
            : .chapterStart(chapterIndex)
        let title = isSingleChapterDocumentBook
            ? (currentDocumentSectionIndex.map { documentSections[$0].title } ?? chapters[chapterIndex].title)
            : chapters[chapterIndex].title
        store?.toggleBookmark(
            bookId: book.id,
            chapterIndex: chapterIndex,
            chapterTitle: title,
            position: position,
            excerpt: isSingleChapterDocumentBook ? String(format: localized("第 %d 頁"), page + 1) : ""
        )
    }
    func readerShowTableOfContents() { state.showChapterList = true }

    // MARK: Prefetching

    private func prefetchAroundChapters() {
        guard book.isOnline, let refs = book.onlineChapters, !refs.isEmpty else { return }
        let last = refs.count - 1

        let forwardIndices = [chapterIndex + 1, chapterIndex + 2]
            .filter { $0 >= 0 && $0 <= last }
        let backwardIndices = [chapterIndex - 1, chapterIndex - 2]
            .filter { $0 >= 0 && $0 <= last }

        if !forwardIndices.isEmpty {
            Task(priority: .utility) {
                for index in forwardIndices {
                    do {
                        _ = try await chapterFetcher.fetchChapter(
                            book: book,
                            chapterIndex: index,
                            priority: .prefetch,
                            store: store
                        )
                    } catch {
                        AppLogger.error("Manga chapter prefetch failed", error: error)
                    }
                }
            }
        }
        if !backwardIndices.isEmpty {
            Task(priority: .background) {
                for index in backwardIndices {
                    do {
                        _ = try await chapterFetcher.fetchChapter(
                            book: book,
                            chapterIndex: index,
                            priority: .background,
                            store: store
                        )
                    } catch {
                        AppLogger.error("Manga chapter prefetch failed", error: error)
                    }
                }
            }
        }
    }

    private func prefetchCurrentChapterPages(pages: [FixedPage], currentPage: Int) {
        let start = currentPage + 1
        // Rasterized pages are megabytes each and are produced by our own CPU work,
        // unlike the network-bound image pages Nuke streams in.
        let lookahead = isSingleChapterDocumentBook ? 2 : 5
        let end = min(start + lookahead, pages.count)
        guard start < end else { return }
        FixedPageImageLoader.prefetch(
            Array(pages[start..<end]), targetWidth: targetWidth, using: imagePrefetcher)
    }

    private func prefetchNextChapterImages() {
        guard book.isOnline else { return }
        let nextIndex = chapterIndex + 1
        guard nextIndex < chapters.count else { return }

        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            let package: ChapterPackage
            do {
                package = try await chapterFetcher.fetchChapter(
                    book: book,
                    chapterIndex: nextIndex,
                    priority: .prefetch,
                    store: store
                )
            } catch {
                AppLogger.error("Next manga chapter prefetch failed", error: error)
                return
            }
            let localDir = MangaChapterParser.chapterDirectory(bookId: book.id, chapterIndex: nextIndex)
            let pages = MangaChapterParser.pages(from: package.content, headers: headers, localDir: localDir)
            let prefetchCount = min(3, pages.count)
            guard prefetchCount > 0 else { return }
            await MainActor.run {
                FixedPageImageLoader.prefetch(
                    Array(pages.prefix(prefetchCount)),
                    targetWidth: self.targetWidth,
                    using: self.imagePrefetcher)
            }
        }
    }

    private func scheduleSave(page: Int) {
        saveTask?.cancel()
        let index = chapterIndex
        let total = progressChapterCount
        let progress = documentProgress(forPage: page)
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, !Task.isCancelled else { return }
            self.store?.updateMangaPosition(
                bookId: self.book.id,
                chapter: index,
                page: page,
                totalChapters: total,
                pageProgress: progress
            )
        }
    }

    /// These books are one chapter, so chapter-count progress would sit at 0
    /// forever; report the page's share of the document instead. Nil for every other
    /// book, which keeps their existing chapter-based progress untouched.
    private func documentProgress(forPage page: Int) -> Double? {
        guard isSingleChapterDocumentBook, currentPages.count > 1 else { return nil }
        return Double(page) / Double(currentPages.count - 1)
    }
}
