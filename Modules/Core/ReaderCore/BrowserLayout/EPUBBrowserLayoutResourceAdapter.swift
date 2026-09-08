import Foundation
import SwiftSoup
import UIKit

/// EPUB implementation of `BrowserLayoutResourceProviding`. Wraps the same
/// `PublicationSession` + `EPUBStyleResolver` machinery the legacy engine uses
/// (one data path for CSS/fonts/images — no parallel loaders).
@MainActor
final class EPUBBrowserLayoutResourceAdapter: BrowserLayoutResourceProviding {

    private let session: PublicationSession
    private let resourceAdapter: ReadiumBookResourceAdapter
    private let styleResolver: EPUBStyleResolver
    private var cssInputCache: [Int: CSSFrontendInput] = [:]

    init(
        session: PublicationSession,
        fontRegistrationService: any FontRegistrationServicing = CoreTextFontRegistrationService()
    ) {
        self.session = session
        self.resourceAdapter = ReadiumBookResourceAdapter(session: session)
        self.styleResolver = EPUBStyleResolver(
            resourceProvider: resourceAdapter,
            fontRegistrationService: fontRegistrationService
        )
    }

    var chapterCount: Int { session.chapters.count }

    /// Debug aid: how many CSS entries the manifest reading order declares.
    func manifestCSSCount() -> Int {
        resourceAdapter.cssResourceHrefs().count
    }

    func chapterTitle(at index: Int) -> String {
        guard session.chapters.indices.contains(index) else { return "" }
        return session.chapters[index].title
    }

    func chapterSourceHref(at index: Int) -> String? {
        guard session.chapters.indices.contains(index) else { return nil }
        return session.chapters[index].href
    }

    func chapterHTML(at index: Int) async throws -> String {
        try await session.chapterHTML(at: index)
    }

    func resolveMediaAttachment(forChapter index: Int, media: EPUBMediaAttachment) -> EPUBMediaAttachment {
        guard let chapterHref = chapterSourceHref(at: index) else { return media }
        func resolve(_ source: String) -> String {
            if let url = URL(string: source), url.scheme != nil { return source }
            let href = EPUBStyleResolver.resolveImageHref(source, chapterHref: chapterHref)
            return resourceAdapter.resourceURL(for: href).absoluteString
        }
        return EPUBMediaAttachment(
            kind: media.kind, sourceHref: resolve(media.sourceHref), mediaType: media.mediaType,
            title: media.title, posterHref: media.posterHref.map(resolve)
        )
    }

    // MARK: - CSS

    func processedCSS(forChapter index: Int) async -> [String] {
        // Compatibility projection for pre-migration corpus diagnostics.
        if let cached = cssInputCache[index] {
            return CurrentCSSFrontendSupport.stylesheetsForCurrentCompatibility(cached.stylesheets)
        }
        do {
            let html = try await chapterHTML(at: index)
            let input = await cssFrontendInput(forChapter: index, html: html)
            return CurrentCSSFrontendSupport.stylesheetsForCurrentCompatibility(input.stylesheets)
        } catch {
            AppLogger.parse("[EPUBStylesheetIngestion] chapter load failed: \(error)")
            return []
        }
    }

    func cssFrontendInput(forChapter index: Int, html: String) async -> CSSFrontendInput {
        if let cached = cssInputCache[index], cached.html == html { return cached }
        guard session.chapters.indices.contains(index) else {
            return CSSFrontendInput(html: html, stylesheets: [])
        }
        let input = await EPUBStylesheetIngestion.collect(
            html: html, chapterHref: session.chapters[index].href,
            resourceProvider: resourceAdapter, styleResolver: styleResolver
        )
        cssInputCache[index] = input
        return input
    }

    // MARK: - Images

    func prefetchImages(forChapter index: Int, html: String, renderWidth: CGFloat) async -> [String: UIImage] {
        guard session.chapters.indices.contains(index) else { return [:] }
        guard let doc = try? SwiftSoup.parse(html) else { return [:] }

        var images: [String: UIImage?] = [:]
        var sources = Set<String>()
        for img in (try? doc.select("img").array()) ?? [] {
            let src = (try? img.attr("src")) ?? ""
            if !src.isEmpty { sources.insert(src) }
        }
        // The EPUB cover idiom `<svg><image xlink:href="cover.jpg"/></svg>`
        // carries no <img>, so without this the box tree asks for a source that
        // was never fetched and the cover renders as an empty chapter.
        for svg in (try? doc.select("svg").array()) ?? [] {
            let snapshot = SwiftSoupHTMLSemanticAdapter.snapshot(svg)
            if let href = BoxTreeBuilder.svgWrappedImageSource(snapshot) { sources.insert(href) }
        }
        // NOTE: the root background-image is deliberately NOT collected here.
        // It is paint-only (never affects layout), and scanning the stylesheets
        // for it meant a SECOND parser deciding what the source string is —
        // which is exactly how the fetched key and the painted key drifted
        // apart. The engine now asks the COMPUTED style tree for that source
        // and fetches it through `loadImage`, so the two cannot disagree.
        for src in sources {
            images[src] = await loadImage(forChapter: index, source: src, renderWidth: renderWidth)
        }
        return images.compactMapValues { $0 }
    }

    func loadImage(forChapter index: Int, source src: String, renderWidth: CGFloat) async -> UIImage? {
        guard session.chapters.indices.contains(index) else { return nil }
        let chapterHref = session.chapters[index].href
        // `data:` and `http(s)` are NOT publication resources, and a browser
        // renders both: the first carries its bytes in the document, the second
        // is fetched. `OnlineImageLoader` already owns exactly that — bounded by
        // a hard timeout, and it rasterizes SVG data URIs through the shared
        // WebView rasterizer. Reused rather than re-implemented so the reader
        // keeps ONE remote/inline image path.
        if OnlineImageLoader.canLoad(src) {
            let image = await OnlineImageLoader.load(src: src, renderWidth: renderWidth)
            if image == nil {
                AppLogger.render("[BrowserLayout] loadImage: online loader returned nil spine=\(index) prefix=\(src.prefix(60))")
            }
            return image
        }
        guard let url = requestURL(forSource: src, chapterHref: chapterHref) else {
            AppLogger.render("[BrowserLayout] loadImage: unresolvable source spine=\(index) prefix=\(src.prefix(60))")
            return nil
        }
        do {
            let response = try await resourceAdapter.response(for: url)
            guard let image = UIImage(data: response.data) else {
                AppLogger.render("[BrowserLayout] loadImage: undecodable image spine=\(index) bytes=\(response.data.count) url=\(url.lastPathComponent)")
                return nil
            }
            return image
        } catch {
            AppLogger.render("[BrowserLayout] loadImage: fetch failed spine=\(index) url=\(url.lastPathComponent) error=\(error)")
            return nil
        }
    }

    /// Publication request URL for one PUBLICATION-LOCAL image source
    /// (`data:` / `http(s)` never reach here — `OnlineImageLoader` owns those).
    ///
    /// The two local source kinds do NOT live in the same space and must not be
    /// resolved the same way:
    /// - a DOM source (`<img src>`, `<image xlink:href>`) is an href RELATIVE to
    ///   the chapter, and needs `resolveImageHref` + `resourceURL(for:)`;
    /// - a CSS source has already been rewritten to an ABSOLUTE
    ///   `reader-book://<id>/…` URL by `EPUBStyleResolver.rewriteResourceURLs`
    ///   before the stylesheet ever reaches us. Feeding that back through
    ///   `resourceURL(for:)` percent-encoded the whole URL into the path
    ///   (`reader-book://id/reader-book:/id/…`), so every stylesheet-declared
    ///   background 404'd inside the publication.
    ///   `EPUBAttributedStringBuilder.loadImage` already carried this same
    ///   split; the browser adapter was the copy that never got it.
    ///
    /// The map key stays the source string verbatim either way — that is what
    /// the box tree hands to `imageLoader`.
    private func requestURL(forSource src: String, chapterHref: String) -> URL? {
        if let url = URL(string: src), let scheme = url.scheme {
            guard scheme == resourceAdapter.customScheme else { return nil }
            return url
        }
        let resolved = EPUBStyleResolver.resolveImageHref(src, chapterHref: chapterHref)
        guard !resolved.isEmpty else { return nil }
        return resourceAdapter.resourceURL(for: resolved)
    }

    // MARK: - Fonts

    func fontResolver() -> (([String], Int, Bool, CGFloat) -> UIFont?)? {
        { [styleResolver] families, weight, italic, size in
            styleResolver.resolveRegisteredFont(
                families: families, weight: weight, italic: italic, size: size
            )
        }
    }
}
