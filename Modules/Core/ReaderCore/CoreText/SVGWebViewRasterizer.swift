import UIKit
import WebKit
import CryptoKit

@MainActor
final class SVGWebViewRasterizer: NSObject {

    static let shared = SVGWebViewRasterizer()

    private let webView: WKWebView
    private let cache = NSCache<NSString, UIImage>()
    private var pendingItems: [SVGWorkItem] = []
    private var currentItem: SVGWorkItem?
    /// Identifies the navigation kicked off for `currentItem`, so a stale `didFinish`
    /// from a timed-out item can't snapshot the wrong (next) item's webView.
    private var currentNavigation: WKNavigation?
    private var isProcessing = false

    /// Per-item watchdog: if a WKWebView navigation never fires didFinish/didFail (malformed
    /// SVG, stuck load) the continuation would never resume AND the serial queue would stall,
    /// hanging EVERY following bubble → the whole chapter shows "infinite loading". The watchdog
    /// finishes a stuck item with nil and keeps the queue moving.
    private static let itemTimeout: TimeInterval = 5

    // Drain telemetry (logged once per queue drain, not per-item, to avoid 100×/chapter spam).
    private var drainStart: Date?
    private var drainProcessed = 0
    private var drainTimeouts = 0
    private var drainCacheHits = 0

    private override init() {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        self.webView = wv
        super.init()
        webView.navigationDelegate = self
        // A 段評-heavy 起点 chapter can carry 100+ bubble SVGs; 64 thrashed within a single
        // chapter (re-rasterizing on every page turn). Hold a whole chapter's worth.
        cache.countLimit = 1024
    }

    func render(svgString: String, size: CGSize, baseURL: URL? = nil) async -> UIImage? {
        let key = cacheKey(svgString: svgString, size: size)
        if let cached = cache.object(forKey: key) {
            if isProcessing { drainCacheHits += 1 }
            return cached
        }
        return await withCheckedContinuation { continuation in
            pendingItems.append(SVGWorkItem(
                svgString: svgString,
                size: size,
                baseURL: baseURL,
                cacheKey: key,
                continuation: continuation
            ))
            if !isProcessing {
                processNext()
            }
        }
    }

    func resolveSVGSize(
        styleWidth: CGFloat?,
        styleHeight: CGFloat?,
        svgString: String,
        renderWidth: CGFloat
    ) -> CGSize {
        let attrs = extractSVGAttributes(svgString)
        return resolveSVGSize(
            styleWidth: styleWidth,
            styleHeight: styleHeight,
            attributes: attrs,
            renderWidth: renderWidth
        )
    }

    private func extractSVGAttributes(_ svgString: String) -> [String: String] {
        guard let svgStart = svgString.range(of: "<svg")?.lowerBound,
              let tagEnd = svgString[svgStart...].range(of: ">")?.upperBound else {
            return [:]
        }
        let tagContent = String(svgString[svgStart..<tagEnd])
        var attrs: [String: String] = [:]
        let pattern = try? NSRegularExpression(pattern: #"(width|height|viewBox)\s*=\s*["']([^"']*)["']"#, options: .caseInsensitive)
        if let pattern {
            let matches = pattern.matches(in: tagContent, range: NSRange(tagContent.startIndex..., in: tagContent))
            for match in matches {
                guard match.numberOfRanges >= 3,
                      let keyRange = Range(match.range(at: 1), in: tagContent),
                      let valueRange = Range(match.range(at: 2), in: tagContent) else { continue }
                attrs[String(tagContent[keyRange])] = String(tagContent[valueRange])
            }
        }
        return attrs
    }

    func resolveSVGSize(
        styleWidth: CGFloat?,
        styleHeight: CGFloat?,
        attributes: [String: String],
        renderWidth: CGFloat
    ) -> CGSize {
        let parseLen: (String?) -> CGFloat? = { raw in
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix("px") {
                return CGFloat(Double(trimmed.dropLast(2).trimmingCharacters(in: .whitespaces)) ?? 0)
            }
            if trimmed.hasSuffix("%") {
                if let pct = Double(trimmed.dropLast().trimmingCharacters(in: .whitespaces)) {
                    return renderWidth * CGFloat(pct) / 100.0
                }
                return nil
            }
            if trimmed.hasSuffix("em") {
                return nil
            }
            return CGFloat(Double(trimmed) ?? 0)
        }

        let attrW = parseLen(attributes["width"])
        let attrH = parseLen(attributes["height"])

        let vbSize = parseViewBox(attributes["viewBox"])

        let w: CGFloat = styleWidth ?? attrW ?? vbSize?.width ?? 240
        let h: CGFloat = styleHeight ?? attrH ?? vbSize?.height ?? 120

        if styleHeight == nil && attrH == nil && vbSize != nil {
            let ratio = vbSize!.width > 0 ? vbSize!.height / vbSize!.width : 1
            return CGSize(width: w, height: w * ratio)
        }
        if styleWidth == nil && attrW == nil && vbSize != nil {
            let ratio = vbSize!.height > 0 ? vbSize!.width / vbSize!.height : 1
            return CGSize(width: h * ratio, height: h)
        }

        return CGSize(width: w, height: h)
    }

    private func parseViewBox(_ value: String?) -> CGSize? {
        guard let value, !value.isEmpty else { return nil }
        let parts = value.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet.whitespaces.union(.init(charactersIn: ",")))
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4,
              parts[2] > 0, parts[3] > 0 else { return nil }
        return CGSize(width: parts[2], height: parts[3])
    }

    private func processNext() {
        guard !pendingItems.isEmpty else {
            if isProcessing, let start = drainStart {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                AppLogger.render("⟐ svgRaster drained", context: [
                    "rasterized": drainProcessed,
                    "timeouts": drainTimeouts,
                    "cacheHits": drainCacheHits,
                    "ms": ms
                ])
            }
            isProcessing = false
            currentNavigation = nil
            drainStart = nil
            drainProcessed = 0
            drainTimeouts = 0
            drainCacheHits = 0
            return
        }
        if drainStart == nil { drainStart = Date() }
        isProcessing = true
        let item = pendingItems.removeFirst()
        currentItem = item
        webView.frame = CGRect(origin: .zero, size: item.size)
        let size = item.size
        let html = """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=\(size.width), initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
        html, body {
            margin: 0; padding: 0;
            width: \(size.width)px; height: \(size.height)px;
            background: transparent; overflow: hidden;
        }
        svg {
            width: \(size.width)px; height: \(size.height)px;
            display: block;
        }
        </style>
        </head>
        <body>
        \(item.svgString)
        </body>
        </html>
        """
        currentNavigation = webView.loadHTMLString(html, baseURL: item.baseURL)
        // Watchdog: if this navigation never completes, finish it (nil) and keep going so a
        // single bad SVG can't stall the whole queue and hang the chapter.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.itemTimeout) { [weak self, weak item] in
            guard let self, let item, !item.finished, self.currentItem === item else { return }
            self.drainTimeouts += 1
            AppLogger.render("⟐ svgRaster TIMEOUT", context: ["size": "\(Int(item.size.width))x\(Int(item.size.height))"])
            self.finishItem(item, image: nil)
        }
    }

    private func cacheKey(svgString: String, size: CGSize) -> NSString {
        let input = "\(svgString)|\(size.width)|\(size.height)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined() as NSString
    }
}

extension SVGWebViewRasterizer: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Ignore a stale callback whose navigation no longer matches the in-flight item
            // (e.g. a watchdog already timed it out and moved on).
            guard let item = self.currentItem, navigation == self.currentNavigation, !item.finished else {
                return
            }
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: item.size)
            do {
                let image = try await webView.takeSnapshot(configuration: config)
                self.finishItem(item, image: image)
            } catch {
                self.finishItem(item, image: nil)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            guard let item = self.currentItem, navigation == self.currentNavigation, !item.finished else {
                return
            }
            self.finishItem(item, image: nil)
        }
    }
}

private final class SVGWorkItem {
    let svgString: String
    let size: CGSize
    let baseURL: URL?
    let cacheKey: NSString
    let continuation: CheckedContinuation<UIImage?, Never>
    /// Set once the item's continuation has been resumed (by snapshot, failure, or watchdog).
    var finished = false

    init(svgString: String, size: CGSize, baseURL: URL?, cacheKey: NSString, continuation: CheckedContinuation<UIImage?, Never>) {
        self.svgString = svgString
        self.size = size
        self.baseURL = baseURL
        self.cacheKey = cacheKey
        self.continuation = continuation
    }
}

private extension SVGWebViewRasterizer {
    func finishItem(_ item: SVGWorkItem, image: UIImage?) {
        // Guard against double-finish: the watchdog and a late didFinish can both fire.
        guard !item.finished else { return }
        item.finished = true
        if currentItem === item { currentItem = nil }
        currentNavigation = nil
        drainProcessed += 1
        if let image {
            cache.setObject(image, forKey: item.cacheKey)
        }
        item.continuation.resume(returning: image)
        processNext()
    }
}
