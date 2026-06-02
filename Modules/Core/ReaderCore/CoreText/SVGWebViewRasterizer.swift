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
    private var isProcessing = false

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
        cache.countLimit = 64
    }

    func render(svgString: String, size: CGSize, baseURL: URL? = nil) async -> UIImage? {
        let key = cacheKey(svgString: svgString, size: size)
        if let cached = cache.object(forKey: key) {
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
            isProcessing = false
            return
        }
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
        webView.loadHTMLString(html, baseURL: item.baseURL)
    }

    private func finishCurrentItem(image: UIImage?) {
        guard let item = currentItem else {
            processNext()
            return
        }
        currentItem = nil
        if let image {
            cache.setObject(image, forKey: item.cacheKey)
        }
        item.continuation.resume(returning: image)
        processNext()
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
            guard let item = self.currentItem else {
                self.processNext()
                return
            }
            self.currentItem = nil
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
            guard let item = self.currentItem else { return }
            self.currentItem = nil
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
        if let image {
            cache.setObject(image, forKey: item.cacheKey)
        }
        item.continuation.resume(returning: image)
        processNext()
    }
}
