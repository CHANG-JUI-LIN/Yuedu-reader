import SwiftUI
import UIKit

extension ReaderView {

    // MARK: - Loading & Page Building
    func currentRenderSettings(marginH: CGFloat) -> ReaderRenderSettings {
        let reservations = ReaderOverlayPaginationPolicy.insets(
            for: settings.readerOverlayLayout
        )
        // Fixed overlays are a paged-reading feature. Their coordinates, size,
        // style, and count never enter render settings; only these explicit body
        // reservations can change pagination geometry.
        let topInset = effectiveScrollMode
            ? ReaderLayoutMetrics.topInset(safeTop: effectiveReaderSafeTop)
            : CGFloat(reservations.top)
        let bottomInset = effectiveScrollMode
            ? ReaderLayoutMetrics.bottomInset(safeBottom: windowSafeBottom, footerVisible: false)
            : CGFloat(reservations.bottom)
        let lineHeightMultiple = max(1.0, readerConfig.lineHeightMultiple)
        return ReaderRenderSettings(
            theme: readerTheme.epubJSName,
            textColor: readerTheme.uiTextColor,
            backgroundColor: readerTheme.uiBackgroundColor,
            fontSize: fontSize,
            lineHeightMultiple: lineHeightMultiple,
            lineSpacing: readerConfig.lineSpacing,
            paragraphSpacing: readerConfig.paragraphSpacing,
            letterSpacing: readerConfig.letterSpacing,
            marginH: marginH,
            marginV: systemVerticalPadding,
            footerHeight: footerOverlayHeight,
            contentInsets: UIEdgeInsets(top: topInset, left: marginH, bottom: bottomInset, right: marginH),
            writingMode: effectiveWritingMode,
            fontPostScriptName: UserReaderFontResolver.selectedPostScriptName,
            isBold: readerConfig.readerFontBold,
            titleVisible: readerConfig.readerTitleVisible,
            titleSize: readerConfig.readerTitleSize,
            titleTopSpacing: readerConfig.readerTitleTopSpacing,
            titleBottomSpacing: readerConfig.readerTitleBottomSpacing,
            readerBackgroundImageURL: activeReaderBackgroundImageURL,
            dialogueHighlightColor: GlobalSettings.shared.readerDialogueHighlightEnabled
                ? GlobalSettings.uiColor(rgbHex: GlobalSettings.shared.readerDialogueHighlightColorHex)
                : nil,
            dialogueBoxColor: (GlobalSettings.shared.readerDialogueHighlightEnabled && GlobalSettings.shared.readerDialogueBoxEnabled)
                ? GlobalSettings.uiColor(rgbHex: GlobalSettings.shared.readerDialogueBoxColorHex)
                : nil
        )
    }

    func applyPublicationSession(
        _ session: PublicationSession,
        book: ReadingBook,
        settings: ReaderRenderSettings
    ) {
        let document = BookDocumentFactory.makeEPUBDocument(book: book, session: session)
        applyDocument(document)

        // Do not overwrite the tap-time CSS preflight with "unspecified"
        // package metadata. CSS-only vertical EPUBs remain right-spine through
        // loading; explicit OPF writing mode or RTL progression is still
        // authoritative (LTR progression alone does not imply horizontal text).
        if session.epubWritingMode != .unspecified
            || session.pageProgressionDirection == .rtl {
            readerNavigator?.updateOpeningDirection(
                ReaderBookOpeningDirection.resolve(
                    writingMode: session.epubWritingMode == .verticalRL ? .verticalRTL : .horizontal,
                    pageProgressionIsRTL: session.pageProgressionDirection == .rtl
                )
            )
        }

        // Start any authored background soundtrack for the chapter we're opening on.
        activePublicationSession = session
        Task { await backgroundAudioCoordinator.update(session: session, chapterIndex: currentChapterIndex) }

        // Prefer EPUB toc.ncx / nav.xhtml entries. Only fall back to spine when TOC is missing.
        if !session.tocEntries.isEmpty {
            chapters = ReaderTOCChapterMapper.chapters(from: session.tocEntries, session: session)
        } else {
            // Fallback: spine-only
            chapters = session.chapters.map { chapter in
                BookChapter(
                    index: chapter.index,
                    title: chapter.title,
                    content: "",
                    href: chapter.href,
                    level: 0
                )
            }
        }
        if chapters.isEmpty {
            chapters = [BookChapter(index: 0, title: session.bookTitle, content: "")]
        }
        allPages = [
            PageContent(
                chapterIndex: 0,
                chapterTitle: session.bookTitle,
                content: "",
                pageInChapter: 0
            )
        ]

        epubRenderer.load(
            publicationSession: session,
            bookIdentifier: session.sourceURL.standardizedFileURL.path,
            renderSize: session.layoutMode == .prePaginated ? readerViewportSize : currentReaderRenderSize,
            settings: settings
        )
        updateFixedLayoutOrientationPreference()

        currentPage = 0
        isLoadingPipeline = false
        isRestoringPosition = false
    }

    func loadLocalEPUB(_ book: ReadingBook, marginH: CGFloat) {
        Task {
            do {
                let session = try await EPUBBookService.shared.openSession(for: book, using: store)
                await MainActor.run {
                    guard self.book?.id == book.id else { return }
                    if session.epubWritingMode == .verticalRL {
                        self.isVerticalEPUB = true
                    }
                    let settings = self.currentRenderSettings(marginH: marginH)
                    self.applyPublicationSession(session, book: book, settings: settings)
                }
            } catch {
                await MainActor.run {
                    AppLogger.render("Readium parsing failed: \(error)")
                    self.applyDocument(nil)
                    self.isLoadingPipeline = false
                    self.isRestoringPosition = false
                }
            }
        }
    }

    func loadOnlineCoreText(_ book: ReadingBook, marginH: CGFloat) {
        #if DEBUG
        AppLogger.render("onlinePipeline route", context: [
            "builder": "OnlineProviderAttributedStringBuilder",
            "bookId": book.id.uuidString,
            "chapters": book.onlineChapters?.count ?? -1
        ])
        #endif
        guard let bundle = BookContentProviderFactory.makeOnlineReaderBundle(
            book: book,
            store: store
        ) else {
            #if DEBUG
            AppLogger.render("onlinePipeline route: makeOnlineReaderBundle returned nil")
            #endif
            applyDocument(nil)
            isLoadingPipeline = false
            isRestoringPosition = false
            return
        }

        let settings = currentRenderSettings(marginH: marginH)
        let refs = book.onlineChapters ?? []
        chapters = refs.enumerated().map { idx, ref in
            let href = ref.sanitizedContentURL
            return BookChapter(index: idx, title: ref.title, content: "", href: href)
        }
        if chapters.isEmpty {
            chapters = [BookChapter(index: 0, title: book.title, content: "")]
        }
        allPages = []

        epubRenderer.loadWithProvider(
            contentProvider: bundle.provider,
            chapterSourceHrefs: bundle.chapterSourceHrefs,
            bookIdentifier: bundle.bookIdentifier,
            renderSize: currentReaderRenderSize,
            settings: settings
        )

        currentPage = 0
        isLoadingPipeline = false
        isRestoringPosition = false

        // Lazy loading: auto-fetch the initial chapter (saved position or chapter 0).
        let initialChapter = OnlineInitialChapterResolver.preferredInitialChapter(
            chapterCount: refs.count,
            savedPositionSnapshot: 0,
            restoreTargetChapter: savedCoreTextRestoreTarget?.chapterIndex
        )
        currentChapterIndex = initialChapter
        ensureChapterReady(chapterIndex: initialChapter)
        if initialChapter != 0 {
            ensureChapterReady(chapterIndex: 0)
        }
    }

    func loadContent() {
        guard !isLoadingPipeline else { return }
        isLoadingPipeline = true
        isRestoringPosition = true
        refreshInitialRestoreState()

        let marginH = effectivePageMarginH
        guard let b = book else {
            applyDocument(nil)
            isRestoringPosition = false
            isLoadingPipeline = false
            return
        }

        if b.isOnline {
            loadOnlineCoreText(b, marginH: marginH)
            return
        }
        
        if b.resolvedPipelineKind == .txt {
            let bookTitle = b.title
            let settings = currentRenderSettings(marginH: marginH)
            let targetBook = b

            DispatchQueue.global(qos: .userInitiated).async {
                let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let txtURL = docsURL.appendingPathComponent(targetBook.contentFilename)
                let lowercasedFilename = targetBook.contentFilename.lowercased()
                let isMarkdownFile = lowercasedFilename.hasSuffix(".md")
                    || lowercasedFilename.hasSuffix(".markdown")

                if isMarkdownFile {
                    let markdownText: String
                    do {
                        markdownText = try TXTFileReader.readTextFile(url: txtURL)
                    } catch {
                        Task { @MainActor in
                            guard self.book?.id == targetBook.id else { return }
                            self.applyDocument(nil)
                            self.isLoadingPipeline = false
                            self.isRestoringPosition = false
                        }
                        return
                    }

                    let markdownBuilder = MarkdownAttributedStringBuilder(
                        markdown: markdownText,
                        fallbackTitle: bookTitle
                    )
                    let markdownChapters = markdownBuilder.unifiedChapters

                    Task { @MainActor in
                        guard self.book?.id == targetBook.id else {
                            self.isLoadingPipeline = false
                            self.isRestoringPosition = false
                            return
                        }

                        let document = BookDocumentFactory.makeTXTDocument(
                            book: targetBook,
                            chapters: markdownChapters
                        )
                        self.applyDocument(document)

                        self.epubRenderer.loadTXT(
                            attributedBuilder: markdownBuilder,
                            bookIdentifier: targetBook.id.uuidString,
                            renderSize: self.currentReaderRenderSize,
                            settings: settings
                        )

                        if document.tableOfContents.count > 0 {
                            self.chapters = document.tableOfContents.enumerated().map { i, chapter in
                                BookChapter(index: i, title: chapter.title, content: "")
                            }
                        } else {
                            self.chapters = [BookChapter(index: 0, title: bookTitle, content: "")]
                        }

                        self.allPages = []
                        if self.savedCoreTextRestoreTarget == nil {
                            self.currentPage = 0
                        }
                        self.isLoadingPipeline = false
                        self.isRestoringPosition = false
                    }
                    return
                }

                let mappedTextFile: TXTMappedTextFile
                do {
                    mappedTextFile = try TXTFileReader.readMappedTextFile(url: txtURL)
                } catch {
                    Task { @MainActor in
                        guard self.book?.id == targetBook.id else { return }
                        self.applyDocument(nil)
                        self.isLoadingPipeline = false
                        self.isRestoringPosition = false
                    }
                    return
                }

                let bookId = targetBook.id
                let fingerprint = TXTFileReader.fileFingerprint(data: mappedTextFile.data)
                let fileSize = mappedTextFile.byteCount
                let encoding = mappedTextFile.encoding

                let mappedChapterIndexes: [TXTMappedChapterIndex]
                if let cached = TXTChapterParser.loadCachedIndexes(bookId: bookId, fileSize: fileSize, fingerprint: fingerprint, encoding: encoding) {
                    mappedChapterIndexes = cached
                } else {
                    let fresh = TXTChapterParser.parseMappedChapterIndexes(mappedTextFile, bookTitle: bookTitle)
                    TXTChapterParser.saveCachedIndexes(fresh, bookId: bookId, fileSize: fileSize, fingerprint: fingerprint, encoding: encoding)
                    mappedChapterIndexes = fresh
                }
                let lazyBuilder = TXTLazyAttributedStringBuilder(
                    mappedTextFile: mappedTextFile,
                    chapterIndexes: mappedChapterIndexes
                )

                Task { @MainActor in
                    guard self.book?.id == targetBook.id else {
                        self.isLoadingPipeline = false
                        self.isRestoringPosition = false
                        return
                    }

                    let document = BookDocumentFactory.makeTXTDocument(
                        book: targetBook,
                        mappedChapterIndexes: mappedChapterIndexes,
                        mappedTextFile: mappedTextFile
                    )
                    self.applyDocument(document)

                    self.epubRenderer.loadTXT(
                        attributedBuilder: lazyBuilder,
                        bookIdentifier: targetBook.id.uuidString,
                        renderSize: self.currentReaderRenderSize,
                        settings: settings
                    )

                    if document.tableOfContents.count > 0 {
                        self.chapters = document.tableOfContents.enumerated().map { i, chapter in
                            BookChapter(index: i, title: chapter.title, content: "")
                        }
                    } else {
                        self.chapters = [BookChapter(index: 0, title: bookTitle, content: "")]
                    }

                    self.allPages = []
                    if self.savedCoreTextRestoreTarget == nil {
                        self.currentPage = 0
                    }
                    self.isLoadingPipeline = false
                    self.isRestoringPosition = false
                }
            }
            return
        }

        guard b.resolvedPipelineKind == .epub else {
            applyDocument(nil)
            isLoadingPipeline = false
            isRestoringPosition = false
            return
        }
        let bookTitle = b.title
        self.chapters = [BookChapter(index: 0, title: bookTitle, content: "")]
        self.allPages = [PageContent(chapterIndex: 0, chapterTitle: bookTitle, content: "", pageInChapter: 0)]
        self.currentPage = 0
        loadLocalEPUB(b, marginH: marginH)
    }

    func rebuildPages() {
        isLoadingPipeline = false
        loadContent()
    }

    func applyDocument(_ document: (any BookDocument)?) {
        bookDocument = document
        if let document {
            contentProvider = BookDocumentContentProviderAdapter(document: document)
            readerCapabilities = document.capabilities
        } else {
            contentProvider = nil
            readerCapabilities = .reflowableText
        }
    }

    func handleReaderConfigRefresh(_ kind: ReaderConfigRefreshKind) {
        switch kind {
        case .layout:
            performUnifiedRelayout()
        case .appearance:
            applyUnifiedAppearanceUpdate()
        }
    }

    func performUnifiedRelayout(targetSize: CGSize? = nil) {
        guard let engine = epubRenderer.engine else {
            rebuildPages()
            return
        }
        let size = targetSize ?? engine.renderSize
        let newSettings = currentRenderSettings(marginH: effectivePageMarginH)
        if targetSize != nil,
           abs(size.width - engine.renderSize.width) < 0.5,
           abs(size.height - engine.renderSize.height) < 0.5 {
            AppLogger.render("[FlipTrace] performUnifiedRelayout skip sameSize size=\(size)")
            return
        }
        if let coreEngine = engine as? CoreTextPageEngine,
           targetSize == nil,
           newSettings == coreEngine.renderSettings {
            AppLogger.render("[FlipTrace] performUnifiedRelayout skip sameSettings size=\(size)")
            return
        }
        epubRenderer.updateRenderSettings(newSettings)
        Task { await engine.invalidateLayout(newSize: size) }
    }

    func forceReaderRenderableContentRefresh() {
        if effectiveScrollMode, epubRenderer.scrollEngine != nil {
            scheduleScrollReslice()
            return
        }

        guard let engine = epubRenderer.engine else {
            rebuildPages()
            return
        }

        epubRenderer.updateRenderSettings(currentRenderSettings(marginH: effectivePageMarginH))
        Task { await engine.invalidateLayout(newSize: engine.renderSize) }
    }

    func applyUnifiedAppearanceUpdate() {
        guard let engine = epubRenderer.engine else { return }
        epubRenderer.updateRenderSettings(currentRenderSettings(marginH: effectivePageMarginH))
        engine.applyThemeChange(
            textColor: readerTheme.uiTextColor,
            backgroundColor: readerTheme.uiBackgroundColor
        )
    }

}
