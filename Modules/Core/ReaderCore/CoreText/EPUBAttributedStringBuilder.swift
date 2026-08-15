import UIKit
import YueduCoreText

// MARK: - EPUBAttributedStringBuilder
//
// Decouples EPUB rendering logic from CoreTextPageEngine(resourceProvider:)
// using the unified AttributedStringBuilding interface, so EPUB, TXT, and Online
// content all use the same CoreTextPageEngine(attributedBuilder:) path.
//
// Content chapters go through HTMLBuilder pipelines to get styled ASTs,
// then convert to RenderableNode for NodeAttributedStringRenderer.
// Still reuses the HTML builder's CSS/font/image loading capabilities to avoid rewriting style parsing.
//
// renderSize: used to compute HTMLAttributedStringBuilder.Config.renderWidth (for image layout).
// EPUBPageRenderer updates this value during notifyViewportSize.

@MainActor
final class EPUBAttributedStringBuilder: @preconcurrency AttributedStringBuilding, RenderSizeAwareAttributedStringBuilding {

    // MARK: - Stored Properties

    let session: PublicationSession
    let resourceProvider: ReadiumBookResourceAdapter
    private let styleResolver: EPUBStyleResolver
    private var processedCSSCache: [String: String] = [:]
    private let stylesheetCache = HTMLStylesheetCache()

    /// Decoded book images, keyed by resolved resource URL.
    ///
    /// A chapter references the same illustration many times over — measured at 102 loads for
    /// 11 distinct images in one chapter, 58 for 2 in another — and each miss costs a full
    /// archive read (33–40ms on device, since this publication's resources are obfuscated and
    /// have to be de-transformed). Without this, `loadImage` was 97% of chapter render time.
    ///
    /// One instance per book, matching `processedCSSCache` above. `NSCache` rather than a
    /// dictionary so the entries are evictable: images are the largest thing here, and it purges
    /// itself under memory pressure.
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    /// Current render area size (injected by EPUBPageRenderer during load / notifyViewportSize).
    var renderSize: CGSize
    /// Set to true when CSS writing-mode: vertical-rl is detected from any chapter's stylesheet or body element.
    var cssDetectedVerticalWritingMode = false

    // MARK: - Initialization

    init(
        session: PublicationSession,
        renderSize: CGSize,
        fontRegistrationService: any FontRegistrationServicing = CoreTextFontRegistrationService()
    ) {
        let adapter = ReadiumBookResourceAdapter(session: session)
        self.session = session
        self.resourceProvider = adapter
        self.renderSize = renderSize
        self.styleResolver = EPUBStyleResolver(
            resourceProvider: adapter,
            fontRegistrationService: fontRegistrationService
        )
    }

    // MARK: - AttributedStringBuilding Basic Info

    var chapterCount: Int { session.chapters.count }

    func updateRenderSize(_ size: CGSize) {
        renderSize = size
    }

    func chapterTitle(at index: Int) -> String {
        guard session.chapters.indices.contains(index) else { return "" }
        return session.chapters[index].title
    }

    func chapterSourceHref(at index: Int) -> String? {
        guard session.chapters.indices.contains(index) else { return nil }
        return session.chapters[index].href
    }

    func chapterIndex(for href: String) -> Int? {
        session.chapterIndex(for: href)
    }

    func chapterDataSize(at index: Int) async -> Int {
        // Prefer pre-scanned byte sizes from SpinesCache (fast path)
        if let cached = resourceProvider.cachedChapterByteSizes(),
           cached.indices.contains(index) {
            return cached[index]
        }
        return (try? await session.chapterDataSize(at: index)) ?? 0
    }

    func cssResourceHrefs() -> [String] {
        resourceProvider.cssResourceHrefs()
    }

    // MARK: - buildChapter

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        guard session.chapters.indices.contains(index) else {
            throw AttributedStringBuildingError.chapterOutOfRange(index)
        }
        // Phase stamps for `⏱ coreText.document.buildChapter`. Stage 0 found this function is
        // 80–98% of chapter load; the seven existing ReaderPerfTrace spans only cover its middle,
        // so the zip read, font registration, footnote indexing and anchor scan are timed here
        // too — an unattributed remainder would just restart the same investigation.
        let buildStart = SourcePerfTrace.now
        let chapterHref = session.chapters[index].href
        let html = try await session.chapterHTML(at: index)
        let afterFetch = SourcePerfTrace.now

        // ── Create HTML builder and inject callbacks ──────────────────────────────────
        let localBuilder = HTMLAttributedStringBuilder()

        localBuilder.resolvedFont = { [weak self] families, weight, italic, size in
            self?.styleResolver.resolveRegisteredFont(
                families: families,
                weight: weight,
                italic: italic,
                size: size
            )
        }

        localBuilder.resolvedFontFamily = { [weak self] rawName in
            guard let self else { return nil }
            let normalized = rawName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                .lowercased()
            return styleResolver.registeredFontFaces[normalized]?.postScriptName
                ?? styleResolver.registeredFontFaces[normalized]?.familyName
        }

        localBuilder.imageLoader = { [weak self] src in
            guard let self else { return nil }
            return await self.loadImage(src: src, chapterHref: chapterHref)
        }

        localBuilder.cssLoader = { [weak self] href in
            guard let self else { return nil }
            return await self.loadCSS(href: href, chapterHref: chapterHref)
        }

        localBuilder.mediaURLResolver = { [weak self] src in
            guard let self else { return nil }
            let resolved = EPUBStyleResolver.resolveImageHref(src, chapterHref: chapterHref)
            return self.resourceProvider.resourceURL(for: resolved).absoluteString
        }

        // ── Build NSAttributedString ────────────────────────────────────
        let config = makeConfig(
            settings: settings,
            textColor: themeTextColor,
            backgroundColor: themeBackgroundColor
        )
        CoreTextPaginator.debugVerticalLog("EPUBFLOW epubBuilder.chapter.begin index=\(index) href=\(chapterHref) htmlLen=\(html.count) settingsWritingMode=\(settings.writingMode) configWritingMode=\(config.writingMode) renderWidth=\(config.renderWidth)")

        let styledASTStart = SourcePerfTrace.now
        guard let ast = await localBuilder.buildStyledAST(
            html: html,
            config: config,
            stylesheetCache: stylesheetCache
        ) else {
            return AttributedChapterBuildResult(
                attributedString: NSAttributedString(),
                imagePage: nil,
                pageBackgroundImage: nil,
                anchorOffsets: [:]
            )
        }

        let afterStyledAST = SourcePerfTrace.now

        // Record duokan popup footnotes (`<li class="…footnote…" id="note_1">`) so a tap on the
        // reference marker shows the note in place instead of jumping to the chapter tail.
        FootnoteStore.index(body: ast, spineIndex: index)
        let afterFootnotes = SourcePerfTrace.now

        let pageBackgroundImage = await localBuilder.pageBackgroundImage(from: ast)
        let pageBackgroundColor = localBuilder.pageBackgroundColor(from: ast)
        let afterBackground = SourcePerfTrace.now
        if pageBackgroundImage == nil, let imagePage = await localBuilder.imagePage(from: ast) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: settings.fontSize),
                .foregroundColor: themeTextColor,
                .backgroundColor: themeBackgroundColor,
            ]
            SourcePerfTrace.record(
                "coreText.document.buildChapter",
                "spine=\(index) html=\(html.utf16.count) kind=imagePage "
                    + "fetch=\(Self.ms(afterFetch - buildStart)) "
                    + "styledAST=\(Self.ms(afterStyledAST - styledASTStart)) "
                    + "footnote=\(Self.ms(afterFootnotes - afterStyledAST)) "
                    + "background=\(Self.ms(afterBackground - afterFootnotes))",
                since: buildStart,
                thresholdMs: 0
            )
            return AttributedChapterBuildResult(
                attributedString: NSAttributedString(string: "\u{FFFC}", attributes: attrs),
                imagePage: imagePage,
                pageBackgroundImage: nil,
                pageBackgroundColor: pageBackgroundColor,
                anchorOffsets: [:]
            )
        }

        // `CTFontManagerRegisterGraphicsFont` per embedded face. Untimed until now and a prime
        // suspect for the heavy-CSS book, where a chapter costs seconds.
        let fontsStart = SourcePerfTrace.now
        let fontRequests = HTMLStyledASTRenderableNodeConverter.referencedFonts(in: ast)
        await styleResolver.registerFontFaces(requests: fontRequests)
        let afterFonts = SourcePerfTrace.now

        let nodes = ReaderPerfTrace.span(
            .irConvert,
            metadata: ReaderPerfMetadata(
                spineIndex: index,
                characterCount: html.utf16.count,
                writingMode: String(describing: settings.writingMode),
                executor: Thread.isMainThread ? "main" : "background"
            )
        ) {
            HTMLStyledASTRenderableNodeConverter.convert(body: ast)
        }
        let afterIR = SourcePerfTrace.now
        let renderer = NodeAttributedStringRenderer(
            config: NodeAttributedStringRenderer.Config(
                from: settings,
                textColor: themeTextColor,
                renderWidth: config.renderWidth,
                renderHeight: max(
                    1,
                    renderSize.height - settings.contentInsets.top - settings.contentInsets.bottom
                ),
                resolvedFont: { [weak self] families, weight, italic, size in
                    self?.styleResolver.resolveRegisteredFont(
                        families: families,
                        weight: weight,
                        italic: italic,
                        size: size
                    )
                },
                imageLoader: { [weak self] src in
                    guard let self else { return nil }
                    return await self.loadImage(src: src, chapterHref: chapterHref)
                },
                mediaURLResolver: { [weak self] src in
                    guard let self else { return nil }
                    let resolved = EPUBStyleResolver.resolveImageHref(src, chapterHref: chapterHref)
                    return self.resourceProvider.resourceURL(for: resolved).absoluteString
                },
                baseWritingDirection: config.baseWritingDirection
            )
        )
        if localBuilder.detectedVerticalWritingMode {
            cssDetectedVerticalWritingMode = true
        }
        CoreTextPaginator.debugVerticalLog("EPUBFLOW epubBuilder.ast index=\(index) href=\(chapterHref) bodyClass=\(ast.classes.joined(separator: ".")) bodyVertical=\(ast.resolvedStyle.isVerticalWritingMode) cssDetectedVertical=\(localBuilder.detectedVerticalWritingMode) nodeCount=\(nodes.count)")

        let renderInterval = ReaderPerfTrace.begin(
            .attributedRender,
            metadata: ReaderPerfMetadata(
                spineIndex: index,
                writingMode: String(describing: settings.writingMode),
                executor: Thread.isMainThread ? "main" : "background"
            )
        )
        let renderStart = SourcePerfTrace.now
        let attributedString = await renderer.render(nodes)
        let afterRender = SourcePerfTrace.now
        ReaderPerfTrace.end(renderInterval)
        CoreTextPaginator.debugVerticalLog("EPUBFLOW epubBuilder.rendered index=\(index) href=\(chapterHref) attrLen=\(attributedString.length) cssDetectedVerticalGlobal=\(cssDetectedVerticalWritingMode) prefix=\"\(debugTextPreview(attributedString.string))\"")
        let anchorOffsets = localBuilder.anchorOffsets(in: attributedString)
        let afterAnchors = SourcePerfTrace.now

        // `styledAST` is itself broken down by the `coreText.document.{htmlParse,cssCollect,
        // cssParse,cssMatch,astBuild}` lines; `other` is whatever none of the stamps cover
        // (builder/renderer construction, the callback wiring above).
        let accounted = (afterFetch - buildStart) + (afterStyledAST - styledASTStart)
            + (afterFootnotes - afterStyledAST) + (afterBackground - afterFootnotes)
            + (afterFonts - fontsStart) + (afterIR - afterFonts)
            + (afterRender - renderStart) + (afterAnchors - afterRender)
        SourcePerfTrace.record(
            "coreText.document.buildChapter",
            "spine=\(index) html=\(html.utf16.count) chars=\(attributedString.length) "
                + "nodes=\(nodes.count) fontFaces=\(fontRequests.count) kind=text "
                + "fetch=\(Self.ms(afterFetch - buildStart)) "
                + "styledAST=\(Self.ms(afterStyledAST - styledASTStart)) "
                + "footnote=\(Self.ms(afterFootnotes - afterStyledAST)) "
                + "background=\(Self.ms(afterBackground - afterFootnotes)) "
                + "fonts=\(Self.ms(afterFonts - fontsStart)) "
                + "ir=\(Self.ms(afterIR - afterFonts)) "
                + "render=\(Self.ms(afterRender - renderStart)) "
                + "anchors=\(Self.ms(afterAnchors - afterRender)) "
                + "other=\(Self.ms(max(0, (afterAnchors - buildStart) - accounted)))",
            since: buildStart,
            thresholdMs: 0
        )

        return AttributedChapterBuildResult(
            attributedString: attributedString,
            imagePage: nil,
            pageBackgroundImage: pageBackgroundImage,
            pageBackgroundColor: pageBackgroundColor,
            anchorOffsets: anchorOffsets
        )
    }

    /// Formats a `systemUptime` delta for the `⏱` breakdown fields.
    private static func ms(_ seconds: Double) -> String {
        String(format: "%.1fms", seconds * 1000)
    }

    // MARK: - Private Helpers

    /// Resolves an `<img src>` / CSS `url()` value to the resource URL to read.
    ///
    /// CSS url() values arrive pre-resolved by `EPUBStyleResolver.rewriteResourceURLs` into the
    /// resource provider's absolute form (reader-book://…). Those are used directly — running
    /// them through the chapter-relative resolution would mangle the URL.
    private func imageResourceURL(src: String, chapterHref: String) -> URL {
        if let absolute = URL(string: src),
           let scheme = absolute.scheme,
           scheme != "http", scheme != "https", scheme != "data" {
            return absolute
        }
        let resolved = EPUBStyleResolver.resolveImageHref(src, chapterHref: chapterHref)
        return resourceProvider.resourceURL(for: resolved)
    }

    private func loadImage(src: String, chapterHref: String) async -> UIImage? {
        let url = imageResourceURL(src: src, chapterHref: chapterHref)
        // Noted before the cache lookup so `u<N>` in the log means "distinct images referenced",
        // independent of how many of those the cache served.
        ReaderDocumentTrace.note("imageLoad", key: url.absoluteString)

        let cacheKey = url.absoluteString as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        return await ReaderPerfTrace.spanAsync(
            .imageLoad,
            metadata: ReaderPerfMetadata(
                executor: Thread.isMainThread ? "main" : "background"
            )
        ) {
            // Buckets kept from the stage-0.6 investigation. `imageLoad.zip` now counts only
            // cache misses, so its call count against the outer `imageLoad` count is the hit rate.
            let response: PublicationResourceResponse
            do {
                response = try await ReaderDocumentTrace.measuring("imageLoad.zip") {
                    try await resourceProvider.response(for: url)
                }
            } catch {
                // Was a silent `try?`. A missing or unreadable image renders as a gap with no
                // trace of why, and on-device diagnosis has no other signal.
                AppLogger.render(
                    "epub.image.readFailed",
                    error: error,
                    context: ["url": url.absoluteString]
                )
                return nil
            }

            guard let image = ReaderDocumentTrace.measuringSync("imageLoad.decode", {
                UIImage(data: response.data)
            }) else {
                AppLogger.render(
                    "epub.image.decodeFailed",
                    context: ["url": url.absoluteString, "bytes": response.data.count]
                )
                return nil
            }

            // Cost is the decoded pixel budget, not the archived byte count: `UIImage(data:)` is
            // lazy, so what eventually occupies memory is width × height × scale² × 4.
            let scale = image.scale
            let cost = Int(image.size.width * scale * image.size.height * scale * 4)
            imageCache.setObject(image, forKey: cacheKey, cost: max(cost, 1))
            return image
        }
    }

    private func loadCSS(href: String, chapterHref: String) async -> String? {
        let resolved = EPUBStyleResolver.resolveImageHref(href, chapterHref: chapterHref)
        if let cached = processedCSSCache[resolved] {
            return cached
        }
        let url = resourceProvider.resourceURL(for: resolved)
        CoreTextPaginator.debugVerticalLog("EPUBFLOW epubBuilder.css.fetch href=\(href) chapter=\(chapterHref) resolved=\(resolved)")
        let response = try? await SourcePerfTrace.spanAsync(
            "epub.css.fetch",
            resolved
        ) {
            try await resourceProvider.response(for: url)
        }
        guard let response else {
            CoreTextPaginator.debugVerticalLog("EPUBFLOW epubBuilder.css.failed href=\(href) resolved=\(resolved)")
            return nil
        }
        let cssText = SourcePerfTrace.span("epub.css.decode", resolved) {
            String(data: response.data, encoding: .utf8) ?? ""
        }
        let processed = await SourcePerfTrace.spanAsync("epub.css.process", resolved) {
            await styleResolver.processStylesheet(
                cssText, cssHref: resolved, chapterHref: chapterHref
            )
        }
        if !processed.isEmpty {
            processedCSSCache[resolved] = processed
        }
        CoreTextPaginator.debugVerticalLog("EPUBFLOW epubBuilder.css.loaded href=\(href) resolved=\(resolved) rawLen=\(cssText.count) processedLen=\(processed.count) hasVertical=\(Self.cssContainsVerticalWritingMode(processed))")
        return processed.isEmpty ? nil : processed
    }

    private func resolvedPageBackgroundImage(
        initial: UIImage?,
        source: String?,
        chapterHref: String
    ) async -> UIImage? {
        if let initial {
            return initial
        }
        guard let source, !source.isEmpty else { return nil }
        return await loadImage(src: source, chapterHref: chapterHref)
    }

    private static func cssContainsVerticalWritingMode(_ css: String) -> Bool {
        let patterns = [
            #"-epub-writing-mode\s*:\s*vertical-rl"#,
            #"-webkit-writing-mode\s*:\s*vertical-rl"#,
            #"(^|[;\s{])writing-mode\s*:\s*vertical-rl"#,
        ]
        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return false
            }
            return regex.firstMatch(in: css, range: NSRange(css.startIndex..., in: css)) != nil
        }
    }

    private func debugTextPreview(_ text: String, limit: Int = 80) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{FFFC}", with: "OBJ")
            .replacingOccurrences(of: "\u{3000}", with: "IDEOSPACE")
        return String(normalized.prefix(limit))
    }

    private func makeConfig(
        settings: ReaderRenderSettings,
        textColor: UIColor,
        backgroundColor: UIColor
    ) -> HTMLAttributedStringBuilder.Config {
        let fontSize = settings.fontSize
        let horizontalInsets = settings.contentInsets.left + settings.contentInsets.right
        let effectiveWidth = renderSize.width > 0
            ? renderSize.width
            : UIScreen.main.bounds.width
        return HTMLAttributedStringBuilder.Config(
            fontSize: fontSize,
            lineHeightMultiple: settings.lineHeightMultiple,
            lineSpacing: settings.lineSpacing,
            paragraphSpacing: settings.paragraphSpacing,
            firstLineIndent: 0,
            textColor: textColor,
            backgroundColor: backgroundColor,
            fontFamilyName: nil,
            renderWidth: max(1, effectiveWidth - horizontalInsets),
            writingMode: settings.writingMode,
            baseWritingDirection: HTMLWritingDirectionResolver.defaultDirection(forLanguage: session.language)
        )
    }
}
