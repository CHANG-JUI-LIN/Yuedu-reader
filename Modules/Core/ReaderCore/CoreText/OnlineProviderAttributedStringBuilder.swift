import Foundation
import UIKit

/// Wraps `BookContentProvider` (online book source) as `AttributedStringBuilding`,
/// allowing `CoreTextScrollEngine` to directly consume online chapters.
///
/// Content handling:
///   - If `payload.renderHTML` is non-nil → use `HTMLAttributedStringBuilder` (preserves styling)
///   - Otherwise → fall back to TXT pattern (title + paragraphs + indent)
@MainActor
final class OnlineProviderAttributedStringBuilder: @preconcurrency AttributedStringBuilding, RenderSizeAwareAttributedStringBuilding {

    private let provider: any BookContentProvider
    private let resourceProvider: (any BookResourceProvider)?
    private let styleResolver: EPUBStyleResolver?
    private let chapterSourceHrefs: [String?]
    private var cachedPayloadSourceHrefs: [Int: String] = [:]
    private var renderSize: CGSize

    init(
        provider: any BookContentProvider,
        renderSize: CGSize,
        resourceProvider: (any BookResourceProvider)? = nil,
        chapterSourceHrefs: [String?] = [],
        fontRegistrationService: any FontRegistrationServicing = CoreTextFontRegistrationService()
    ) {
        self.provider = provider
        self.renderSize = renderSize
        self.resourceProvider = resourceProvider
        self.styleResolver = resourceProvider.map {
            EPUBStyleResolver(resourceProvider: $0, fontRegistrationService: fontRegistrationService)
        }
        if chapterSourceHrefs.count == provider.totalChapters {
            self.chapterSourceHrefs = chapterSourceHrefs
        } else {
            self.chapterSourceHrefs = Array(repeating: nil, count: provider.totalChapters)
        }
    }

    deinit {
        styleResolver?.cleanupFontFiles()
    }

    func updateRenderSize(_ size: CGSize) {
        renderSize = size
    }

    var chapterCount: Int { provider.totalChapters }

    var prefersLazyByteScan: Bool { true }

    func chapterTitle(at index: Int) -> String {
        provider.chapterTitle(at: index)
    }

    func chapterSourceHref(at index: Int) -> String? {
        guard (0..<chapterCount).contains(index) else { return nil }
        return cachedPayloadSourceHrefs[index] ?? chapterSourceHrefs[index]
    }

    func chapterIndex(for href: String) -> Int? {
        if let n = Int(href), n >= 0, n < chapterCount { return n }
        let target = normalizedURLKey(href)
        guard !target.isEmpty else { return nil }
        if let match = chapterSourceHrefs.enumerated().first(where: { normalizedURLKey($0.element) == target }) {
            return match.offset
        }
        return cachedPayloadSourceHrefs.first(where: { normalizedURLKey($0.value) == target })?.key
    }

    func chapterDataSize(at index: Int) async -> Int {
        guard (0..<chapterCount).contains(index),
              let payload = try? await provider.contentForChapter(index: index)
        else { return 0 }
        cacheSourceHref(from: payload)
        let html = payload.renderHTML ?? payload.content
        return html.lengthOfBytes(using: .utf8)
    }

    func cssResourceHrefs() -> [String] {
        resourceProvider?.cssResourceHrefs() ?? []
    }

    private func cacheSourceHref(from payload: ChapterContentPayload) {
        let sourceHref = (payload.sourceHref ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceHref.isEmpty else { return }
        cachedPayloadSourceHrefs[payload.index] = sourceHref
    }

    private func normalizedURLKey(_ value: String?) -> String {
        guard let value else { return "" }
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hashIndex = trimmed.firstIndex(of: "#") {
            trimmed = String(trimmed[..<hashIndex])
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    private func fallbackChapterHref(for index: Int, payload: ChapterContentPayload) -> String {
        let sourceHref = (payload.sourceHref ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !sourceHref.isEmpty { return sourceHref }
        if let mapped = chapterSourceHref(at: index), !mapped.isEmpty { return mapped }
        return "chapter/\(index).xhtml"
    }

    private func configureResourceCallbacks(
        for builder: HTMLAttributedStringBuilder,
        chapterHref: String
    ) {
        guard let resourceProvider else { return }
        builder.resolvedFont = { [weak self] families, weight, italic, size in
            self?.styleResolver?.resolveRegisteredFont(
                families: families,
                weight: weight,
                italic: italic,
                size: size
            )
        }
        builder.resolvedFontFamily = { [weak self] rawName in
            guard let self else { return nil }
            let normalized = rawName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                .lowercased()
            return styleResolver?.registeredFontFaces[normalized]?.postScriptName
                ?? styleResolver?.registeredFontFaces[normalized]?.familyName
        }
        builder.imageLoader = { [weak self] src in
            await self?.loadImage(src: src, chapterHref: chapterHref)
        }
        builder.mediaURLResolver = { src in
            let resolved = EPUBStyleResolver.resolveImageHref(src, chapterHref: chapterHref)
            return resourceProvider.resourceURL(for: resolved).absoluteString
        }
        builder.cssLoader = { [weak self] href in
            await self?.loadCSS(href: href, chapterHref: chapterHref)
        }
    }

    private func loadImage(src: String, chapterHref: String) async -> UIImage? {
        guard let resourceProvider else { return nil }
        let resolved = EPUBStyleResolver.resolveImageHref(src, chapterHref: chapterHref)
        let url = resourceProvider.resourceURL(for: resolved)
        guard let response = try? await resourceProvider.response(for: url) else { return nil }
        return UIImage(data: response.data)
    }

    private func loadCSS(href: String, chapterHref: String) async -> String? {
        guard let resourceProvider else { return nil }
        let resolved = EPUBStyleResolver.resolveImageHref(href, chapterHref: chapterHref)
        let url = resourceProvider.resourceURL(for: resolved)
        guard let response = try? await resourceProvider.response(for: url) else { return nil }
        let cssText = String(data: response.data, encoding: .utf8) ?? ""
        guard let styleResolver else { return cssText.isEmpty ? nil : cssText }
        let processed = await styleResolver.processStylesheet(
            cssText,
            cssHref: resolved,
            chapterHref: chapterHref
        )
        return processed.isEmpty ? nil : processed
    }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        let payload = try await provider.contentForChapter(index: index)
        cacheSourceHref(from: payload)

        // HTML pipeline
        if let rawHTML = payload.renderHTML, !rawHTML.isEmpty {
            // Rewrite Legado iOS paragraph-review markers (<comment …>) into anchors the
            // renderer can carry. Idempotent + covers chapters cached before this feature.
            let html = ReaderHTMLUtilities.rewriteReviewComments(rawHTML)
            let cfg = HTMLAttributedStringBuilder.Config(
                fontSize: settings.fontSize,
                lineHeightMultiple: settings.lineHeightMultiple,
                lineSpacing: settings.lineSpacing,
                paragraphSpacing: settings.paragraphSpacing,
                firstLineIndent: 0,
                textColor: themeTextColor,
                backgroundColor: themeBackgroundColor,
                fontFamilyName: UserReaderFontResolver.selectedPostScriptName,
                renderWidth: max(0, renderSize.width),
                writingMode: settings.writingMode
            )
            let builder = HTMLAttributedStringBuilder()
            let chapterHref = fallbackChapterHref(for: index, payload: payload)
            configureResourceCallbacks(for: builder, chapterHref: chapterHref)

            guard let ast = await builder.buildStyledAST(html: html, config: cfg) else {
                return AttributedChapterBuildResult(
                    attributedString: NSAttributedString(),
                    imagePage: nil,
                    pageBackgroundImage: nil,
                    anchorOffsets: [:]
                )
            }

            if let imagePage = await builder.imagePage(from: ast) {
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
            // Only wire resource closures when a resource provider exists: a nil imageLoader makes
            // the renderer fall back to alt text, matching the legacy builder's behavior for plain
            // online chapters that have no book-local resources.
            let hasResources = resourceProvider != nil
            let renderer = NodeAttributedStringRenderer(
                config: NodeAttributedStringRenderer.Config(
                    from: settings,
                    textColor: themeTextColor,
                    fontFamily: UserReaderFontResolver.selectedPostScriptName,
                    renderWidth: cfg.renderWidth,
                    resolvedFont: styleResolver == nil ? nil : { [weak self] families, weight, italic, size in
                        self?.styleResolver?.resolveRegisteredFont(
                            families: families,
                            weight: weight,
                            italic: italic,
                            size: size
                        )
                    },
                    imageLoader: !hasResources ? nil : { [weak self] src in
                        await self?.loadImage(src: src, chapterHref: chapterHref)
                    },
                    mediaURLResolver: !hasResources ? nil : { [weak self] src in
                        guard let self, let resourceProvider = self.resourceProvider else { return nil }
                        let resolved = EPUBStyleResolver.resolveImageHref(src, chapterHref: chapterHref)
                        return resourceProvider.resourceURL(for: resolved).absoluteString
                    }
                )
            )

            let attributedString = await renderer.render(nodes)
            let pageBackgroundImage = await builder.pageBackgroundImage(from: ast)
            return AttributedChapterBuildResult(
                attributedString: attributedString,
                imagePage: nil,
                pageBackgroundImage: pageBackgroundImage,
                anchorOffsets: builder.anchorOffsets(in: attributedString)
            )
        }

        // TXT-style fallback: title + paragraphs
        let titleFont = UserReaderFontResolver.titleFont(size: settings.fontSize + 8)
        let bodyFont = UserReaderFontResolver.bodyFont(size: settings.fontSize)
        let bodyTargetLineHeight = ReaderTypographyCorrection.targetLineHeight(
            font: bodyFont,
            fontSize: settings.fontSize,
            lineHeightMultiple: settings.lineHeightMultiple
        )
        let bodyBaselineOffset = ReaderTypographyCorrection.baselineOffset(
            font: bodyFont,
            targetLineHeight: bodyTargetLineHeight
        )

        let titleParaStyle = NSMutableParagraphStyle()
        titleParaStyle.alignment = .center
        titleParaStyle.paragraphSpacing = 24

        let bodyParaStyle = NSMutableParagraphStyle()
        bodyParaStyle.alignment = .natural
        bodyParaStyle.lineBreakMode = .byWordWrapping
        bodyParaStyle.minimumLineHeight = bodyTargetLineHeight
        bodyParaStyle.maximumLineHeight = bodyTargetLineHeight
        bodyParaStyle.paragraphSpacing = settings.paragraphSpacing

        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(
            string: payload.title + "\n",
            attributes: [
                .font: titleFont,
                .foregroundColor: themeTextColor,
                .paragraphStyle: titleParaStyle,
                .kern: settings.letterSpacing as NSNumber
            ]
        ))

        let paragraphs = ReaderHTMLUtilities.bodyParagraphs(
            fromPlainText: payload.content,
            excludingLeadingTitle: payload.title
        )

        for para in paragraphs {
            let line = "\u{3000}\u{3000}" + para + "\n"
            attr.append(NSAttributedString(
                string: line,
                attributes: [
                    .font: bodyFont,
                    .foregroundColor: themeTextColor,
                    .baselineOffset: bodyBaselineOffset,
                    .paragraphStyle: bodyParaStyle,
                    .kern: settings.letterSpacing as NSNumber
                ]
            ))
        }

        return AttributedChapterBuildResult(
            attributedString: attr,
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }
}
