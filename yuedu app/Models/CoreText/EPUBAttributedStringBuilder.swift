import UIKit

// MARK: - EPUBAttributedStringBuilder
//
// Phase 7：把 EPUB 渲染邏輯從 CoreTextPageEngine(resourceProvider:) 中解耦，
// 用統一的 AttributedStringBuilding 介面包裝，讓 EPUB 與 TXT/Online 走相同的
// CoreTextPageEngine(attributedBuilder:) 路徑。
//
// 內容章節透過 HTMLBuilder pipelines 先得到 styled AST，
// 再轉成 RenderableNode 交給 NodeAttributedStringRenderer。
// 仍重用 HTML builder 的 CSS / 字型 / 圖片載入能力，避免重寫整套樣式解析。
//
// renderSize：用於計算 HTMLAttributedStringBuilder.Config.renderWidth（圖片排版用）。
// EPUBPageRenderer 在 notifyViewportSize 時更新此值。

@MainActor
final class EPUBAttributedStringBuilder: @preconcurrency AttributedStringBuilding {

    // MARK: - 儲存屬性

    let session: PublicationSession
    let resourceProvider: ReadiumBookResourceAdapter
    private let styleResolver: EPUBStyleResolver
    /// 目前的渲染區域尺寸（由 EPUBPageRenderer 在 load / notifyViewportSize 時注入）。
    var renderSize: CGSize

    // MARK: - 初始化

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

    // MARK: - AttributedStringBuilding 基本資訊

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
        // 優先使用 SpinesCache 中預掃描的位元組大小（快速路徑）
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

        // ── 建立 HTML 構建器並注入回呼 ──────────────────────────────────
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

        // ── 構建 NSAttributedString ────────────────────────────────────
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

    // MARK: - 私有輔助

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
            renderWidth: max(1, effectiveWidth - horizontalInsets)
        )
    }
}
