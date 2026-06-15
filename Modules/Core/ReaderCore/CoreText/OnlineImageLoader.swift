import UIKit

/// Loads chapter images for ONLINE book sources.
///
/// Online books have no EPUB-style resource archive: illustrations, copyright-page art and
/// 段評 comment bubbles arrive embedded in the chapter HTML as `data:` URIs (base64 image or
/// inline SVG) or as absolute `http(s)` URLs. This loader resolves those to a `UIImage`,
/// rasterizing SVG payloads through the shared WebView rasterizer. Book-local resource paths
/// (which need an EPUB resource provider) are not handled here — callers fall back for those.
enum OnlineImageLoader {

    private static let seqLock = NSLock()
    nonisolated(unsafe) private static var seqValue = 0
    private static func nextSeq() -> Int {
        seqLock.lock(); defer { seqLock.unlock() }
        seqValue += 1
        return seqValue
    }

    /// Resolves an online image `src` (data: URI or remote URL) to a UIImage. Returns nil for
    /// anything that isn't a data:/http(s) source.
    ///
    /// HARD GUARANTEE: every load is bounded by a hard timeout. The chapter renderer loads images
    /// SEQUENTIALLY (`await` per node), so if ANY single image load fails to return, the whole
    /// chapter is stuck on "loading…" forever (起点 段評: 100+ bubbles, one stuck one hangs all).
    /// No matter what stalls underneath (WebView rasterizer, network), we give up after `timeout`
    /// and return nil so the render always proceeds.
    static func load(src: String, renderWidth: CGFloat, timeout: TimeInterval = 8) async -> UIImage? {
        let cleaned = cleanImageSource(src)
        guard !cleaned.isEmpty else { return nil }

        let seq = nextSeq()
        let kind = cleaned.hasPrefix("data:")
            ? (cleaned.lowercased().contains("svg") ? "svg" : "data")
            : (cleaned.hasPrefix("http") ? "http" : "other")
        let started = Date()
        AppLogger.render("⟐ imgLoad start", context: ["#": seq, "kind": kind])
        // ⟐ bubble: route the load-path signal through the bubble diag so a single "bubble"
        // Console filter shows whether 段評 imgs even reach this loader and as what kind.
        CommentBubbleSVGRecognizer.diag("load:kind=\(kind)", context: ["srcPrefix": String(cleaned.prefix(64))])

        let image = await withTimeoutOrNil(seconds: timeout) {
            await loadResolved(cleaned, renderWidth: renderWidth)
        }

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if image == nil || ms > 800 {
            AppLogger.render("⟐ imgLoad end", context: [
                "#": seq, "kind": kind, "ok": image != nil, "ms": ms,
                "timedOut": ms >= Int(timeout * 1000) - 50
            ])
        }
        return image
    }

    private static func loadResolved(_ cleaned: String, renderWidth: CGFloat) async -> UIImage? {
        if cleaned.hasPrefix("data:") {
            return await loadDataURIImage(cleaned, renderWidth: renderWidth)
        }
        if cleaned.hasPrefix("http://") || cleaned.hasPrefix("https://") {
            return await loadRemoteImage(cleaned, renderWidth: renderWidth)
        }
        return nil
    }

    /// Races `operation` against a sleep; returns nil if the timeout wins. The losing child is
    /// cancelled — and even if the stalled operation ignores cancellation (e.g. a WebView
    /// continuation that never resumes), we still return, so the caller is never blocked.
    private static func withTimeoutOrNil(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> UIImage?
    ) async -> UIImage? {
        await withTaskGroup(of: UIImage?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// True when `src` is a data:/http(s) source this loader can resolve.
    static func canLoad(_ src: String) -> Bool {
        let s = cleanImageSource(src)
        return s.hasPrefix("data:") || s.hasPrefix("http://") || s.hasPrefix("https://")
    }

    /// Strips a trailing Legado `,{json}` click-config suffix that may survive into an image
    /// source, leaving a clean data URI / URL. (base64 + percent-encoding never contain `,{`.)
    static func cleanImageSource(_ src: String) -> String {
        var s = src.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("}"), let r = s.range(of: ",{", options: .backwards) {
            let suffix = s[r.lowerBound...]
            if suffix.contains("\"") || suffix.contains(":") {
                s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }

    /// Decodes a `data:` URI into a UIImage. SVG payloads are rasterized via the shared
    /// WebView rasterizer; everything else is treated as raw image bytes.
    static func loadDataURIImage(_ uri: String, renderWidth: CGFloat) async -> UIImage? {
        guard uri.hasPrefix("data:"), let commaIdx = uri.firstIndex(of: ",") else { return nil }
        let meta = uri[uri.index(uri.startIndex, offsetBy: 5)..<commaIdx].lowercased()
        let payload = String(uri[uri.index(after: commaIdx)...])
        let isBase64 = meta.contains(";base64")
        let isSVG = meta.contains("svg")

        let decoded: Data?
        if isBase64 {
            decoded = Data(
                base64Encoded: payload.trimmingCharacters(in: .whitespacesAndNewlines),
                options: .ignoreUnknownCharacters
            )
        } else {
            decoded = (payload.removingPercentEncoding ?? payload).data(using: .utf8)
        }
        guard let data = decoded, !data.isEmpty else { return nil }

        if isSVG {
            guard let svg = String(data: data, encoding: .utf8), svg.contains("<svg") else {
                CommentBubbleSVGRecognizer.diag("load:dataURI-svg decode-fail", context: ["bytes": data.count])
                return nil
            }
            CommentBubbleSVGRecognizer.diag("load:dataURI-svg preRecognize", context: ["len": svg.count])
            // Native comment bubble recognition — avoids WebView for simple count bubbles.
            if let recognized = CommentBubbleSVGRecognizer.recognize(src: uri, svgContent: svg) {
                let pointSize = max(14, renderWidth * 0.04)
                return CommentBubbleSVGRecognizer.draw(svg: recognized, pointSize: pointSize, themeTextColor: .secondaryLabel)
            }
            // Render the book source's SVG exactly as authored (no native substitution) — all
            // styling must follow the source.
            return await rasterizeSVG(svg, renderWidth: renderWidth, baseURL: nil)
        }
        return UIImage(data: data)
    }

    /// Fetches a remote image. Falls back to SVG rasterization when the bytes are an SVG document.
    static func loadRemoteImage(_ urlString: String, renderWidth: CGFloat) async -> UIImage? {
        guard let url = URL(string: urlString) else { return nil }
        // CRITICAL: the renderer loads images SEQUENTIALLY (await per node), so a single hung
        // remote image (段評 avatar/emoji, 版权页 photo) blocks the whole chapter → "infinite
        // loading". `URLSession.shared.data(from:)` inherits the 60s default; cap it hard.
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let started = Date()
        AppLogger.render("⟐ imgLoad http start", context: ["url": String(urlString.prefix(90))])
        guard let (data, _) = try? await URLSession.shared.data(for: request), !data.isEmpty else {
            AppLogger.render("⟐ imgLoad http FAIL", context: [
                "url": String(urlString.prefix(90)),
                "ms": Int(Date().timeIntervalSince(started) * 1000)
            ])
            return nil
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if ms > 1000 {
            AppLogger.render("⟐ imgLoad http slow", context: ["url": String(urlString.prefix(90)), "ms": ms, "bytes": data.count])
        }
        if let image = UIImage(data: data) { return image }
        if let svg = String(data: data, encoding: .utf8), svg.contains("<svg") {
            // ⟐ bubble: REMOTE SVG bubbles never touch recognize() — they go straight to the
            // WebView rasterizer. If this fires for 光遇/企点, the native redraw can't help; the
            // bubble is webview-rendered and the gap/wrap fix must live in the source SVG or here.
            CommentBubbleSVGRecognizer.diag("load:remote-svg → webview", context: ["len": svg.count])
            return await rasterizeSVG(svg, renderWidth: renderWidth, baseURL: url)
        }
        return nil
    }

    @MainActor
    private static func rasterizeSVG(_ svg: String, renderWidth: CGFloat, baseURL: URL?) async -> UIImage? {
        let width = renderWidth > 0 ? renderWidth : UIScreen.main.bounds.width
        let size = SVGWebViewRasterizer.shared.resolveSVGSize(
            styleWidth: nil,
            styleHeight: nil,
            svgString: svg,
            renderWidth: width
        )
        return await SVGWebViewRasterizer.shared.render(svgString: svg, size: size, baseURL: baseURL)
    }
}
