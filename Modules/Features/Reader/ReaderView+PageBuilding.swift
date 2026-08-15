import SwiftUI
import UIKit

extension ReaderView {

    // MARK: - Loading & Page Building
    var activeReaderStyleAppearance: ReaderStyleAppearance {
        readerTheme == .night ? .dark : .light
    }

    var activeReaderDisplayMode: ReaderDisplayMode {
        effectiveScrollMode ? .scroll : .paged
    }

    var activeReaderRenderSettings: ReaderRenderSettings {
        readerRenderSettings(for: activeReaderDisplayMode)
    }

    var readerDocumentStyleFingerprint: ReaderDocumentStyleFingerprint {
        ReaderDocumentStyleFingerprint(
            commentBubbleFollowsSourceSVG: settings.commentBubbleFollowsSourceSVG,
            commentBubblePresetMode: settings.commentBubblePresetMode,
            commentBubbleCustomStyles: settings.commentBubbleCustomStyles,
            commentBubbleSelectedCustomStyleID: settings.commentBubbleSelectedCustomStyleID,
            commentBubbleScale: settings.commentBubbleScale,
            commentBubbleTextScale: settings.commentBubbleTextScale,
            readerTextUnderlineDecorationEnabled: settings.readerTextUnderlineDecorationEnabled,
            readerTextUnderlineDecorationColorHex: settings.readerTextUnderlineDecorationColorHex,
            readerTextUnderlineStyle: settings.readerTextUnderlineStyle,
            readerTextUnderlineThickness: settings.readerTextUnderlineThickness,
            readerTextUnderlineOffset: settings.readerTextUnderlineOffset
        )
    }

    func readerRenderSettings(for mode: ReaderDisplayMode) -> ReaderRenderSettings {
        let input = ReaderRenderSettingsSnapshotInput(
            theme: readerTheme.epubJSName,
            textColor: readerTheme.uiTextColor,
            backgroundColor: readerTheme.uiBackgroundColor,
            fontSize: readerConfig.fontSize,
            lineHeightMultiple: max(1.0, readerConfig.lineHeightMultiple),
            lineSpacing: readerConfig.lineSpacing,
            paragraphSpacing: readerConfig.paragraphSpacing,
            letterSpacing: readerConfig.letterSpacing,
            marginH: effectivePageMarginH,
            writingMode: effectiveWritingMode,
            fontPostScriptName: UserReaderFontResolver.selectedPostScriptName,
            isBold: readerConfig.readerFontBold,
            chapterTitleStyle: readerConfig.chapterTitleStyle,
            readerBackgroundImageURL: activeReaderBackgroundImageURL,
            regexHighlightConfiguration: settings.regexHighlightConfiguration,
            readerStyleAppearance: activeReaderStyleAppearance,
            readerStyleAssetRevision: settings.readerStyleAssetRevision
        )

        let surface: ReaderRenderSurface
        switch mode {
        case .paged:
            let reservations = ReaderOverlayPaginationPolicy.insets(
                for: settings.readerOverlayLayout
            )
            // Fixed overlays are a paged-reading feature. Their coordinates, size,
            // style, and count never enter render settings; only these explicit body
            // reservations can change pagination geometry.
            surface = .paged(
                contentInsets: UIEdgeInsets(
                    top: CGFloat(reservations.top),
                    left: effectivePageMarginH,
                    bottom: CGFloat(reservations.bottom),
                    right: effectivePageMarginH
                ),
                marginV: systemVerticalPadding,
                footerHeight: footerOverlayHeight
            )
        case .scroll:
            surface = .scroll(
                contentInsets: UIEdgeInsets(
                    top: ReaderLayoutMetrics.topInset(safeTop: effectiveReaderSafeTop),
                    left: effectivePageMarginH,
                    bottom: ReaderLayoutMetrics.bottomInset(
                        safeBottom: 0,
                        footerBottomPadding: readerConfig.footerBottomPadding,
                        footerTextGap: readerConfig.footerTextGap
                    ),
                    right: effectivePageMarginH
                ),
                marginV: readerConfig.pageMarginV,
                footerHeight: ReaderLayoutMetrics.footerHeight
            )
        }

        return ReaderRenderSettingsSnapshotBuilder.make(input: input, surface: surface)
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

    func loadLocalEPUB(_ book: ReadingBook) {
        Task {
            do {
                let session = try await EPUBBookService.shared.openSession(for: book, using: store)
                await MainActor.run {
                    guard self.book?.id == book.id else { return }
                    if session.epubWritingMode == .verticalRL {
                        self.isVerticalEPUB = true
                    }
                    let settings = self.readerRenderSettings(for: self.activeReaderDisplayMode)
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

    func loadOnlineCoreText(_ book: ReadingBook) {
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

        let settings = readerRenderSettings(for: activeReaderDisplayMode)
        let refs = book.onlineChapters ?? []
        chapters = refs.enumerated().map { idx, ref in
            let href = ref.sanitizedContentURL
            return BookChapter(index: idx, title: ref.title, content: "", href: href)
        }
        if chapters.isEmpty {
            chapters = [BookChapter(index: 0, title: book.title, content: "")]
        }
        allPages = []

        // Per-source content-image decryptor (Legado `ruleContent.imageDecode`):
        // only sources declaring the rule pay anything; the closure runs the
        // source's JS over downloaded image bytes.
        var imageDecode: (@Sendable (Data, String) -> Data?)? = nil
        if let sourceId = book.bookSourceId,
           let source = BookSourceStore.shared.sources.first(where: { $0.id == sourceId }),
           !source.ruleContent.imageDecode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let ruleJs = source.ruleContent.imageDecode
            imageDecode = { data, src in
                SourceImageDecoder.decode(data, src: src, ruleJs: ruleJs, source: source)
            }
        }

        epubRenderer.loadWithProvider(
            contentProvider: bundle.provider,
            chapterSourceHrefs: bundle.chapterSourceHrefs,
            bookIdentifier: bundle.bookIdentifier,
            renderSize: currentReaderRenderSize,
            settings: settings,
            imageDecode: imageDecode
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
        // ⟐ infinite-loading probe: if reloads are being swallowed here, the
        // pipeline flag was left dangling by an earlier aborted load.
        guard !isLoadingPipeline else {
            AppLogger.render("⟐ loadContent blocked: isLoadingPipeline still true")
            return
        }
        isLoadingPipeline = true
        isRestoringPosition = true
        refreshInitialRestoreState()

        guard let b = book else {
            applyDocument(nil)
            isRestoringPosition = false
            isLoadingPipeline = false
            return
        }

        if b.isOnline {
            loadOnlineCoreText(b)
            return
        }
        
        if b.resolvedPipelineKind == .txt {
            let bookTitle = b.title
            let settings = readerRenderSettings(for: activeReaderDisplayMode)
            let targetBook = b
            let targetBookID = targetBook.id
            let txtURL = StorageLocations.bookFile(targetBook.contentFilename)
            let lowercasedFilename = targetBook.contentFilename.lowercased()
            let isMarkdownFile = lowercasedFilename.hasSuffix(".md")
                || lowercasedFilename.hasSuffix(".markdown")

            if isMarkdownFile {
                DispatchQueue.global(qos: .userInitiated).async {
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
                }
                return
            }

            Task { @MainActor in
                do {
                    let preparation = try await Task.detached(priority: .userInitiated) {
                        try TXTReaderPreparationService.prepare(
                            url: txtURL,
                            bookId: targetBookID,
                            bookTitle: bookTitle
                        )
                    }.value

                    guard self.book?.id == targetBook.id else {
                        self.isLoadingPipeline = false
                        self.isRestoringPosition = false
                        return
                    }

                    if preparation.cachedChapterIndexes == nil {
                        let previewIndexes = TXTChapterParser.parseChapterIndexes(
                            preparation.previewText,
                            bookTitle: bookTitle
                        )
                        let previewBuilder = TXTLazyAttributedStringBuilder(
                            text: preparation.previewText,
                            chapterIndexes: previewIndexes
                        )
                        let previewDocument = BookDocumentFactory.makeTXTDocument(
                            book: targetBook,
                            chapterIndexes: previewIndexes,
                            text: preparation.previewText
                        )
                        self.applyTXTReaderPhase(
                            book: targetBook,
                            title: bookTitle,
                            document: previewDocument,
                            builder: previewBuilder,
                            settings: settings,
                            completesPipeline: false
                        )
                    }

                    let mappedChapterIndexes = await Task.detached(priority: .userInitiated) {
                        TXTReaderPreparationService.completeChapterIndexes(
                            for: preparation
                        )
                    }.value

                    guard self.book?.id == targetBook.id else { return }
                    let finalBuilder = TXTLazyAttributedStringBuilder(
                        mappedTextFile: preparation.mappedTextFile,
                        chapterIndexes: mappedChapterIndexes
                    )
                    let finalDocument = BookDocumentFactory.makeTXTDocument(
                        book: targetBook,
                        mappedChapterIndexes: mappedChapterIndexes,
                        mappedTextFile: preparation.mappedTextFile
                    )
                    self.applyTXTReaderPhase(
                        book: targetBook,
                        title: bookTitle,
                        document: finalDocument,
                        builder: finalBuilder,
                        settings: self.readerRenderSettings(for: self.activeReaderDisplayMode)
                    )
                } catch {
                    guard self.book?.id == targetBook.id else { return }
                    AppLogger.error("TXT reader preparation failed", error: error)
                    self.applyDocument(nil)
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
        loadLocalEPUB(b)
    }

    func applyTXTReaderPhase(
        book: ReadingBook,
        title: String,
        document: any BookDocument,
        builder: any AttributedStringBuilding,
        settings: ReaderRenderSettings,
        completesPipeline: Bool = true
    ) {
        applyDocument(document)
        epubRenderer.loadTXT(
            attributedBuilder: builder,
            bookIdentifier: book.id.uuidString,
            renderSize: currentReaderRenderSize,
            settings: settings
        )

        if document.tableOfContents.isEmpty {
            chapters = [BookChapter(index: 0, title: title, content: "")]
        } else {
            chapters = document.tableOfContents.enumerated().map { index, chapter in
                BookChapter(index: index, title: chapter.title, content: "")
            }
        }
        allPages = []
        if savedCoreTextRestoreTarget == nil {
            currentPage = 0
        }
        if completesPipeline {
            isLoadingPipeline = false
            isRestoringPosition = false
        }
    }

    /// Builds the reader pipeline for a chapter that arrived before one existed.
    ///
    /// This used to begin with `isLoadingPipeline = false`, force-clearing the single guard that
    /// stops `loadContent` running twice. Opening a book fetches chapters N, N-1 and N+1 together
    /// and each arrival reaches here, so each got its own pipeline — a device capture showed four
    /// `CoreTextScrollEngine` instances for one book open, each with its own reader view restoring
    /// the reading position independently. That is a large part of what the user sees as jumping.
    ///
    /// Not clearing it is the correct reading of the caller's intent. "No engine yet" means either
    /// a build is in flight — in which case that build will produce the engine and starting a
    /// second one is pure damage — or the flag is stranded from an aborted load, which is a
    /// *different* bug that force-clearing was hiding. `loadContent`'s `⟐ loadContent blocked`
    /// line is what surfaces the stranded case, so it can be fixed rather than papered over.
    ///
    /// Note this is a no-op change for online books: `loadOnlineCoreText` clears the flag
    /// synchronously before it returns, so it is already false by the time any chapter callback
    /// runs. It matters for the TXT/EPUB paths, which hold the flag across async work — exactly
    /// where "a load really is in flight" is true.
    func rebuildPages() {
        AppLogger.render(
            "⟐ rebuildPages loading=\(isLoadingPipeline) engine=\(epubRenderer.engine != nil) "
                + "scrollEngine=\(epubRenderer.scrollEngine != nil)"
        )
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

    func submitReaderRefresh(
        intent: ReaderRenderRefreshIntent,
        settings: ReaderRenderSettings? = nil,
        viewportSize: CGSize? = nil,
        mode: ReaderDisplayMode? = nil,
        position: CoreTextReadingPosition? = nil
    ) {
        guard epubRenderer.engine != nil || epubRenderer.scrollEngine != nil else { return }
        let resolvedSettings = settings ?? activeReaderRenderSettings
        let resolvedMode = mode ?? activeReaderDisplayMode
        let request = ReaderRenderRefreshRequest(
            intent: intent,
            mode: resolvedMode,
            settings: resolvedSettings,
            position: position ?? currentReaderRefreshPosition,
            viewportSize: viewportSize ?? currentReaderRenderSize
        )
        Task { @MainActor in
            await ReaderStyleAssetStore.shared.prewarmRegexHighlightAssets(
                configuration: resolvedSettings.regexHighlightConfiguration,
                appearance: resolvedSettings.readerStyleAppearance
            )
            let result = await epubRenderer.refresh(request)
            if case let .failed(transactionID, failure) = result {
                AppLogger.render(
                    "reader refresh failed transaction=\(transactionID) failure=\(failure)"
                )
            }
        }
    }

    var currentReaderRefreshPosition: CoreTextReadingPosition {
        if let position = readerSessionCoordinator?.state.location.coreTextPosition {
            return position
        }
        if let pendingScrollJumpTarget {
            return pendingScrollJumpTarget
        }
        if let engine = epubRenderer.engine,
           let position = engine.readingPosition(forPage: currentPage) {
            return position
        }
        return CoreTextReadingPosition(
            spineIndex: max(0, currentChapterIndex),
            charOffset: 0
        )
    }

}
