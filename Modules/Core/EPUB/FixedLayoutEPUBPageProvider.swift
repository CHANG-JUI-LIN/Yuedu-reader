import Foundation
import UIKit
import WebKit

// MARK: - Fixed-layout EPUB rendering
//
// A fixed-layout EPUB page is HTML positioned at an exact viewport size, so it is
// rasterized through a WebView and then displayed like any other fixed page.
//
// Everything here exists once per document, not once per page: one open
// `PublicationSession`, one WKWebView, one image cache. The reader loads the whole
// book as a single chapter (see `FixedPageReaderViewController`), so turning a page
// is a cache hit or a single render — never a reopen of the publication.

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
}

@MainActor
final class FixedLayoutEPUBRenderer {

    static let shared = FixedLayoutEPUBRenderer()

    struct DocumentInfo {
        let pageCount: Int
        let sections: [FixedPageDocumentSection]
    }

    /// One book's opened publication plus the per-document helpers built from it.
    /// The viewport resolver in particular caches each page's declared size, which
    /// is thrown away every time the document is reopened.
    private final class OpenDocument {
        let sourceURL: URL
        let session: PublicationSession
        let adapter: ReadiumBookResourceAdapter
        let resolver: FixedLayoutViewportResolver

        init(sourceURL: URL, session: PublicationSession) {
            self.sourceURL = sourceURL
            self.session = session
            self.adapter = ReadiumBookResourceAdapter(session: session)
            self.resolver = FixedLayoutViewportResolver(
                defaultViewport: session.fixedLayoutViewport?.defaultViewport,
                pageViewports: session.fixedLayoutViewport?.pageViewports ?? [:]
            )
        }
    }

    /// Rendered pages, keyed by document + page + requested width. Cost is the
    /// image's byte size; a full-screen page on a 3x device is ~7 MB.
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    private let rasterizer = FixedLayoutEPUBPageRasterizer()
    private var openDocument: OpenDocument?
    /// In-flight opens, so two page loads racing on a cold document open it once.
    private var openTasks: [String: Task<OpenDocument, Error>] = [:]

    func documentInfo(sourceURL: URL) async throws -> DocumentInfo {
        let document = try await self.document(for: sourceURL)
        let sections = document.session.chapters.map { descriptor -> FixedPageDocumentSection in
            let title = descriptor.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return FixedPageDocumentSection(
                title: title.isEmpty ? String(format: localized("第 %d 頁"), descriptor.index + 1) : title,
                startPage: descriptor.index
            )
        }
        return DocumentInfo(pageCount: document.session.chapters.count, sections: sections)
    }

    /// Rasterize one page, fitted to `targetWidth` points. The WebView still lays the
    /// page out at its declared viewport — that's what makes the layout correct — but
    /// the snapshot is taken at display size instead of viewport size.
    func image(sourceURL: URL, pageIndex: Int, targetWidth: CGFloat) async -> UIImage? {
        guard targetWidth > 0 else { return nil }
        let key = cacheKey(sourceURL: sourceURL, pageIndex: pageIndex, targetWidth: targetWidth)
        if let cached = cache.object(forKey: key) { return cached }

        do {
            let document = try await self.document(for: sourceURL)
            guard document.session.layoutMode == .prePaginated else {
                throw FixedLayoutEPUBPageProviderError.notFixedLayout
            }
            guard document.session.chapters.indices.contains(pageIndex) else {
                throw FixedLayoutEPUBPageProviderError.chapterOutOfRange(pageIndex)
            }

            let chapter = document.session.chapters[pageIndex]
            let pageSize = await document.resolver.viewport(
                for: pageIndex,
                resourceProvider: document.adapter
            )
            let html = try await document.session.chapterHTML(at: pageIndex)
            let preparedHTML = await FixedLayoutEPUBHTMLInliner(
                resourceProvider: document.adapter,
                chapterHref: chapter.href
            ).inlinedHTML(html)

            guard let image = await rasterizer.render(
                html: preparedHTML,
                pageSize: pageSize,
                snapshotWidth: targetWidth
            ) else {
                throw FixedLayoutEPUBPageProviderError.renderFailed(pageIndex)
            }

            cache.setObject(image, forKey: key, cost: Self.byteCost(of: image))
            return image
        } catch {
            AppLogger.render(
                "Fixed-layout EPUB page render failed: page \(pageIndex) of \(sourceURL.lastPathComponent)",
                error: error
            )
            return nil
        }
    }

    /// Release the open publication and its rendered pages (the reader closed).
    func purge() {
        cache.removeAllObjects()
        openDocument = nil
        openTasks.removeAll()
    }

    private func document(for sourceURL: URL) async throws -> OpenDocument {
        if let openDocument, openDocument.sourceURL == sourceURL { return openDocument }

        let key = sourceURL.path
        if let existing = openTasks[key] { return try await existing.value }

        let task = Task {
            let session = try await PublicationSession.open(sourceURL: sourceURL)
            return OpenDocument(sourceURL: sourceURL, session: session)
        }
        openTasks[key] = task
        defer { openTasks[key] = nil }

        let document = try await task.value
        // Only one book is read at a time; holding a second publication open would
        // keep its zip handles and resources alive for nothing.
        openDocument = document
        return document
    }

    private func cacheKey(sourceURL: URL, pageIndex: Int, targetWidth: CGFloat) -> NSString {
        "\(sourceURL.path)#\(pageIndex)@\(Int(targetWidth.rounded()))" as NSString
    }

    private static func byteCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

// MARK: - WebView rasterizer

/// Renders one page at a time in a single reused WKWebView.
///
/// Requests queue: the WebView has one document and one navigation delegate, so
/// starting a second load while a snapshot is pending would strand the first
/// caller. Serializing is what makes reuse safe.
@MainActor
private final class FixedLayoutEPUBPageRasterizer: NSObject, WKNavigationDelegate {

    private struct Request {
        let id = UUID()
        let html: String
        let pageSize: CGSize
        let snapshotWidth: CGFloat
        let continuation: CheckedContinuation<UIImage?, Never>
    }

    /// Upper bound on a single page's render. This is not a wait for state to
    /// settle — the snapshot is driven by the page's own readiness signals below.
    /// It bounds a WebView that never reports either success or failure, which
    /// would otherwise stall every queued page behind it. Delete it if WebKit ever
    /// guarantees a terminal navigation callback.
    private static let renderTimeout: Duration = .seconds(10)

    private let webView: WKWebView
    private var queue: [Request] = []
    private var active: Request?
    private var watchdog: Task<Void, Never>?

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

    func render(html: String, pageSize: CGSize, snapshotWidth: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            queue.append(
                Request(
                    html: html,
                    pageSize: CGSize(
                        width: max(1, pageSize.width.rounded(.up)),
                        height: max(1, pageSize.height.rounded(.up))
                    ),
                    snapshotWidth: max(1, snapshotWidth.rounded()),
                    continuation: continuation
                )
            )
            startNextIfIdle()
        }
    }

    private func startNextIfIdle() {
        guard active == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        active = request

        webView.frame = CGRect(origin: .zero, size: request.pageSize)
        webView.loadHTMLString(request.html, baseURL: nil)

        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.renderTimeout)
            guard let self, !Task.isCancelled else { return }
            AppLogger.render("Fixed-layout EPUB page render timed out")
            self.finish(nil, for: request.id)
        }
    }

    private func snapshotActivePage() async {
        guard let request = active else { return }

        // Wait for what actually makes the page paintable rather than for a fixed
        // delay: the inlined `data:` images decode asynchronously and web fonts
        // load asynchronously, so `didFinish` alone can capture a half-drawn page.
        _ = try? await webView.callAsyncJavaScript(
            """
            await Promise.all(
                Array.from(document.images)
                    .filter(image => !image.complete)
                    .map(image => new Promise(done => { image.onload = done; image.onerror = done }))
            );
            if (document.fonts) { await document.fonts.ready; }
            return true;
            """,
            contentWorld: .defaultClient
        )
        guard active?.id == request.id else { return }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: request.pageSize)
        // Lays out at viewport size, captures at display size: a 1200pt-wide page
        // snapshotted at 1200pt on a 3x screen is a 69 MB bitmap nobody can see.
        configuration.snapshotWidth = NSNumber(value: Double(request.snapshotWidth))

        let image = try? await webView.takeSnapshot(configuration: configuration)
        finish(image, for: request.id)
    }

    private func finish(_ image: UIImage?, for id: UUID) {
        guard let request = active, request.id == id else { return }
        watchdog?.cancel()
        watchdog = nil
        active = nil
        request.continuation.resume(returning: image)
        startNextIfIdle()
    }

    // MARK: WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            await self?.snapshotActivePage()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, let id = self.active?.id else { return }
            AppLogger.render("Fixed-layout EPUB page navigation failed", error: error)
            self.finish(nil, for: id)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor [weak self] in
            guard let self, let id = self.active?.id else { return }
            AppLogger.render("Fixed-layout EPUB page load failed", error: error)
            self.finish(nil, for: id)
        }
    }
}

// MARK: - Resource inlining

@MainActor
private struct FixedLayoutEPUBHTMLInliner {
    let resourceProvider: BookResourceProvider
    let chapterHref: String

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
