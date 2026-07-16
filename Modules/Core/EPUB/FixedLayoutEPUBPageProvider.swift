import Foundation
import UIKit
import WebKit

enum FixedLayoutEPUBPageProviderError: LocalizedError {
    case notFixedLayout
    case chapterOutOfRange(Int)
    case renderFailed(Int)

    var errorDescription: String? {
        switch self {
        case .notFixedLayout:
            return "EPUB is not fixed layout"
        case .chapterOutOfRange(let index):
            return "Fixed-layout EPUB chapter is out of range: \(index)"
        case .renderFailed(let index):
            return "Failed to render fixed-layout EPUB page: \(index + 1)"
        }
    }
}

@MainActor
enum FixedLayoutEPUBPageProvider {
    static func chapterRefs(from session: PublicationSession) -> [OnlineChapterRef] {
        session.chapters.map { descriptor in
            let title = descriptor.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return OnlineChapterRef(
                index: descriptor.index,
                title: title.isEmpty ? "Page \(descriptor.index + 1)" : title,
                url: descriptor.href
            )
        }
    }

    static func renderPageImage(
        from sourceURL: URL,
        chapterIndex: Int
    ) async throws -> UIImage {
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        guard session.layoutMode == .prePaginated else {
            throw FixedLayoutEPUBPageProviderError.notFixedLayout
        }
        return try await renderPage(
            session: session,
            chapterIndex: chapterIndex,
            renderer: FixedLayoutEPUBPageRasterizer()
        )
    }

    private static func renderPage(
        session: PublicationSession,
        chapterIndex: Int,
        renderer: FixedLayoutEPUBPageRasterizer
    ) async throws -> UIImage {
        guard session.chapters.indices.contains(chapterIndex) else {
            throw FixedLayoutEPUBPageProviderError.chapterOutOfRange(chapterIndex)
        }

        let adapter = ReadiumBookResourceAdapter(session: session)
        let resolver = FixedLayoutViewportResolver(
            defaultViewport: session.fixedLayoutViewport?.defaultViewport,
            pageViewports: session.fixedLayoutViewport?.pageViewports ?? [:]
        )
        let pageSize = await resolver.viewport(for: chapterIndex, resourceProvider: adapter)
        let preparedHTML = await FixedLayoutEPUBHTMLInliner.preparedHTML(
            resourceProvider: adapter,
            chapterIndex: chapterIndex
        )

        guard let image = await renderer.render(html: preparedHTML, pageSize: pageSize) else {
            throw FixedLayoutEPUBPageProviderError.renderFailed(chapterIndex)
        }
        return image
    }
}

@MainActor
private final class FixedLayoutEPUBPageRasterizer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var currentToken: UUID?
    private var currentSize: CGSize = .zero

    override init() {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
    }

    func render(html: String, pageSize: CGSize) async -> UIImage? {
        let size = CGSize(
            width: max(1, pageSize.width.rounded(.up)),
            height: max(1, pageSize.height.rounded(.up))
        )
        let token = UUID()
        currentToken = token
        currentSize = size
        webView.frame = CGRect(origin: .zero, size: size)

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.webView.loadHTMLString(html, baseURL: nil)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, self.currentToken == token else { return }
                self.finish(nil)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, self.continuation != nil else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: self.currentSize)
            let image = try? await webView.takeSnapshot(configuration: config)
            self.finish(image)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.finish(nil)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.finish(nil)
        }
    }

    private func finish(_ image: UIImage?) {
        guard let continuation else { return }
        self.continuation = nil
        currentToken = nil
        continuation.resume(returning: image)
    }
}

@MainActor
struct FixedLayoutEPUBHTMLInliner {
    let resourceProvider: BookResourceProvider
    let chapterHref: String

    static func preparedHTML(
        resourceProvider: BookResourceProvider,
        chapterIndex: Int
    ) async -> String {
        guard resourceProvider.chapters.indices.contains(chapterIndex) else { return "" }
        let chapter = resourceProvider.chapters[chapterIndex]
        if let response = try? await resourceProvider.response(
            for: resourceProvider.resourceURL(for: chapter.href)
        ), response.mimeType.lowercased().hasPrefix("image/") {
            let dataURL = "data:\(response.mimeType);base64,\(response.data.base64EncodedString())"
            return imageDocument(dataURL: dataURL)
        }

        let html = (try? await resourceProvider.chapterHTML(at: chapterIndex)) ?? ""
        return await Self(
            resourceProvider: resourceProvider,
            chapterHref: chapter.href
        ).inlinedHTML(html)
    }

    private static func imageDocument(dataURL: String) -> String {
        """
        <!doctype html>
        <html>
          <head>
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <style>
              html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: transparent; }
              img { display: block; width: 100%; height: 100%; object-fit: contain; }
            </style>
          </head>
          <body><img src="\(dataURL)" alt="" /></body>
        </html>
        """
    }

    func inlinedHTML(_ html: String) async -> String {
        let withStyles = await inlineStylesheets(in: html)
        return await inlineImageResources(in: withStyles)
    }

    private func inlineStylesheets(in html: String) async -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<link\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else { return html }

        let nsHTML = html as NSString
        var replacements: [(NSRange, String)] = []

        for match in regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            let tag = nsHTML.substring(with: match.range)
            let rel = attribute(named: "rel", in: tag)?.lowercased() ?? ""
            guard rel.split(whereSeparator: { $0.isWhitespace }).contains("stylesheet"),
                  let href = attribute(named: "href", in: tag),
                  let css = await stylesheetDataURLSafeCSS(href: href)
            else { continue }

            replacements.append((match.range, "<style>\n\(css)\n</style>"))
        }

        return applying(replacements: replacements, to: html)
    }

    private func stylesheetDataURLSafeCSS(href: String) async -> String? {
        let resolved = EPUBStyleResolver.resolveImageHref(href, chapterHref: chapterHref)
        guard let response = try? await resourceProvider.response(for: resourceProvider.resourceURL(for: resolved)),
              let css = String(data: response.data, encoding: .utf8)
        else { return nil }

        return await inlineCSSURLs(in: css, cssHref: resolved)
    }

    private func inlineCSSURLs(in css: String, cssHref: String) async -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"url\(\s*(['"]?)([^'")]+)\1\s*\)"#,
            options: [.caseInsensitive]
        ) else { return css }

        let nsCSS = css as NSString
        var replacements: [(NSRange, String)] = []

        for match in regex.matches(in: css, range: NSRange(location: 0, length: nsCSS.length)) {
            guard match.numberOfRanges >= 3 else { continue }
            let raw = nsCSS.substring(with: match.range(at: 2))
            guard let dataURL = await dataURL(for: raw, relativeTo: cssHref, isCSS: true) else { continue }
            replacements.append((match.range(at: 2), dataURL))
        }

        return applying(replacements: replacements, to: css)
    }

    private func inlineImageResources(in html: String) async -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<(?:img|image|source)\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else { return html }

        let nsHTML = html as NSString
        var tagReplacements: [(NSRange, String)] = []

        for match in regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            let tag = nsHTML.substring(with: match.range)
            let updated = await inlineResourceAttributes(in: tag)
            if updated != tag {
                tagReplacements.append((match.range, updated))
            }
        }

        return applying(replacements: tagReplacements, to: html)
    }

    private func inlineResourceAttributes(in tag: String) async -> String {
        var result = tag
        for name in ["src", "href", "xlink:href"] {
            guard let value = attribute(named: name, in: result),
                  let dataURL = await dataURL(for: value, relativeTo: chapterHref, isCSS: false)
            else { continue }
            result = replacingAttribute(named: name, value: dataURL, in: result)
        }
        return result
    }

    private func dataURL(for rawHref: String, relativeTo baseHref: String, isCSS: Bool) async -> String? {
        let trimmed = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !trimmed.hasPrefix("data:"),
              !trimmed.hasPrefix("http://"),
              !trimmed.hasPrefix("https://")
        else { return nil }

        let resolved = isCSS
            ? EPUBStyleResolver.resolveCSSRelativePath(trimmed, cssHref: baseHref)
            : EPUBStyleResolver.resolveImageHref(trimmed, chapterHref: baseHref)
        guard let response = try? await resourceProvider.response(for: resourceProvider.resourceURL(for: resolved)) else {
            return nil
        }

        return "data:\(response.mimeType);base64,\(response.data.base64EncodedString())"
    }

    private func applying(replacements: [(NSRange, String)], to string: String) -> String {
        var result = string
        for (range, replacement) in replacements.reversed() {
            result = (result as NSString).replacingCharacters(in: range, with: replacement)
        }
        return result
    }

    private func attribute(named name: String, in tag: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(['"])(.*?)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)),
              match.numberOfRanges >= 3
        else { return nil }
        return (tag as NSString).substring(with: match.range(at: 2))
    }

    private func replacingAttribute(named name: String, value: String, in tag: String) -> String {
        let pattern = #"(\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*['"])(.*?)(['"])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length))
        else { return tag }

        let nsTag = tag as NSString
        return nsTag.replacingCharacters(in: match.range, with: "\(nsTag.substring(with: match.range(at: 1)))\(value)\(nsTag.substring(with: match.range(at: 3)))")
    }
}
