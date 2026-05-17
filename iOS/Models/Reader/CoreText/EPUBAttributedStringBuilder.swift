import UIKit

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
final class EPUBAttributedStringBuilder: @preconcurrency AttributedStringBuilding {

    // MARK: - Stored Properties

    let session: PublicationSession
    let resourceProvider: ReadiumBookResourceAdapter
    private let styleResolver: EPUBStyleResolver
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
        let chapterHref = session.chapters[index].href
        let html = try await session.chapterHTML(at: index)

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

        // ── Build NSAttributedString ────────────────────────────────────
        let config = makeConfig(
            settings: settings,
            textColor: themeTextColor,
            backgroundColor: themeBackgroundColor
        )

        guard let ast = await localBuilder.buildStyledAST(html: html, config: config) else {
            return AttributedChapterBuildResult(
                attributedString: NSAttributedString(),
                imagePage: nil,
                pageBackgroundImage: nil,
                anchorOffsets: [:]
            )
        }

        if let imagePage = await localBuilder.imagePage(from: ast) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: settings.fontSize),
                .foregroundColor: themeTextColor,
                .backgroundColor: themeBackgroundColor,
            ]
            return AttributedChapterBuildResult(
                attributedString: NSAttributedString(string: "\u{FFFC}", attributes: attrs),
                imagePage: imagePage,
                pageBackgroundImage: nil,
                anchorOffsets: [:]
            )
        }

        let nodes = HTMLStyledASTRenderableNodeConverter.convert(body: ast)
        let renderer = NodeAttributedStringRenderer(
            config: NodeAttributedStringRenderer.Config(
                from: settings,
                textColor: themeTextColor,
                renderWidth: config.renderWidth,
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
                }
            )
        )
        if localBuilder.detectedVerticalWritingMode {
            cssDetectedVerticalWritingMode = true
        }

        let attributedString = await renderer.render(nodes)
        let pageBackgroundImage = await localBuilder.pageBackgroundImage(from: ast)
        let anchorOffsets = localBuilder.anchorOffsets(in: attributedString)

        return AttributedChapterBuildResult(
            attributedString: attributedString,
            imagePage: nil,
            pageBackgroundImage: pageBackgroundImage,
            anchorOffsets: anchorOffsets
        )
    }

    // MARK: - Private Helpers

    private func loadImage(src: String, chapterHref: String) async -> UIImage? {
        let resolved = EPUBStyleResolver.resolveImageHref(src, chapterHref: chapterHref)
        let url = resourceProvider.resourceURL(for: resolved)
        guard let response = try? await resourceProvider.response(for: url) else { return nil }
        return UIImage(data: response.data)
    }

    private func loadCSS(href: String, chapterHref: String) async -> String? {
        let resolved = EPUBStyleResolver.resolveImageHref(href, chapterHref: chapterHref)
        let url = resourceProvider.resourceURL(for: resolved)
        guard let response = try? await resourceProvider.response(for: url) else { return nil }
        let cssText = String(data: response.data, encoding: .utf8) ?? ""
        let processed = await styleResolver.processStylesheet(
            cssText, cssHref: resolved, chapterHref: chapterHref
        )
        return processed.isEmpty ? nil : processed
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
            firstLineIndent: fontSize * 2,
            textColor: textColor,
            backgroundColor: backgroundColor,
            fontFamilyName: nil,
            renderWidth: max(1, effectiveWidth - horizontalInsets),
            writingMode: settings.writingMode
        )
    }
}
