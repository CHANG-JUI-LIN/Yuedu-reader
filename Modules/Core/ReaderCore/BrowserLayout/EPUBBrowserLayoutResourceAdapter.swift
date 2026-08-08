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
    private var cssTextCache: [Int: [String]] = [:]

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

    // MARK: - CSS

    func processedCSS(forChapter index: Int) async -> [String] {
        if let cached = cssTextCache[index] { return cached }
        guard session.chapters.indices.contains(index) else { return [] }
        let chapterHref = session.chapters[index].href

        var texts: [String] = []
        // Linked stylesheets referenced from the chapter <head> — the SAME
        // source the legacy pipeline uses (collectStyles). The manifest
        // reading order alone misses most EPUB stylesheets.
        var linkedHrefs = resourceAdapter.cssResourceHrefs()
        if let html = try? await chapterHTML(at: index),
           let doc = try? SwiftSoup.parse(html),
           let head = doc.head() {
            for link in (try? head.select("link[rel=stylesheet]").array()) ?? [] {
                let href = (try? link.attr("href")) ?? ""
                if !href.isEmpty {
                    let resolved = EPUBStyleResolver.resolveCSSHref(href, cssHref: "", chapterHref: chapterHref)
                    if !linkedHrefs.contains(resolved) { linkedHrefs.append(resolved) }
                }
            }
            for styleTag in (try? head.select("style").array()) ?? [] {
                let css = (try? styleTag.html()) ?? ""
                if !css.isEmpty {
                    let processed = await styleResolver.processStylesheet(
                        css, cssHref: "", chapterHref: chapterHref
                    )
                    if !processed.isEmpty { texts.append(processed) }
                }
            }
        }
        for href in linkedHrefs {
            guard let response = try? await resourceAdapter.response(for: resourceAdapter.resourceURL(for: href)),
                  let css = String(data: response.data, encoding: .utf8) else { continue }
            let processed = await styleResolver.processStylesheet(
                css, cssHref: href, chapterHref: chapterHref
            )
            if !processed.isEmpty { texts.append(processed) }
        }
        await styleResolver.registerAllPendingFontFaces()
        cssTextCache[index] = texts
        return texts
    }

    // MARK: - Images

    func prefetchImages(forChapter index: Int, html: String) async -> [String: UIImage] {
        guard session.chapters.indices.contains(index) else { return [:] }
        let chapterHref = session.chapters[index].href
        guard let doc = try? SwiftSoup.parse(html) else { return [:] }

        var images: [String: UIImage] = [:]
        var sources = Set<String>()
        for img in (try? doc.select("img").array()) ?? [] {
            let src = (try? img.attr("src")) ?? ""
            if !src.isEmpty { sources.insert(src) }
        }
        // The EPUB cover idiom `<svg><image xlink:href="cover.jpg"/></svg>`
        // carries no <img>, so without this the box tree asks for a source that
        // was never fetched and the cover renders as an empty chapter.
        for svg in (try? doc.select("svg").array()) ?? [] {
            if let href = BoxTreeBuilder.svgWrappedImageSource(svg) { sources.insert(href) }
        }
        for src in sources {
            let resolved = EPUBStyleResolver.resolveImageHref(src, chapterHref: chapterHref)
            guard let response = try? await resourceAdapter.response(for: resourceAdapter.resourceURL(for: resolved)),
                  let image = UIImage(data: response.data) else { continue }
            images[src] = image
        }
        return images
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
