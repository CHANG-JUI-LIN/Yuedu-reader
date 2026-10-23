import ImageIO
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
    /// `decode`: optional per-source byte decryptor (Legado `imageDecode`) run on
    /// downloaded bytes before image decoding; nil result keeps the originals.
    /// `bodyPointSize`: the reader's body text size, used to scale source review cards
    /// (`ReviewCardRaster`); 0 keeps the plain column-width sizing.
    /// `themeTextColor`: the reading text colour, which a card template's text follows.
    /// `headers`: the book source's request header map (Legado `header`), applied to remote
    /// fetches. Chapter illustrations live on the source's own CDN, and those CDNs gate on the
    /// source's declared User-Agent/Referer just like cover art does — legado downloads them via
    /// `AnalyzeUrl(src, source = bookSource)` for exactly this reason. Empty = built-in UA.
    /// `cachePolicy`: a captcha must come from the network every time — a cached one belongs
    /// to a session the server has already dropped.
    static func load(
        src: String,
        renderWidth: CGFloat,
        bodyPointSize: CGFloat = 0,
        themeTextColor: UIColor? = nil,
        timeout: TimeInterval = 8,
        headers: [String: String] = [:],
        cachePolicy: URLRequest.CachePolicy = .returnCacheDataElseLoad,
        decode: (@Sendable (Data, String) async -> Data?)? = nil
    ) async -> UIImage? {
        let cleaned = cleanImageSource(src)
        guard !cleaned.isEmpty else { return nil }
        // A Legado per-image `headers` option rides on the src as a fragment (the chapter
        // sanitizer had to move it off the tag). It wins over the source-wide map, exactly as
        // `AnalyzeUrl` merges url options over `source.getHeaderMap()` — and as the comic page
        // loader already does with the same option.
        let effectiveHeaders = headers.merging(OnlineImageRequestOptions.decode(src).headers) {
            _, perImage in perImage
        }

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
            await loadResolved(
                cleaned,
                renderWidth: renderWidth,
                bodyPointSize: bodyPointSize,
                themeTextColor: themeTextColor,
                headers: effectiveHeaders,
                cachePolicy: cachePolicy,
                decode: decode
            )
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

    private static func loadResolved(
        _ cleaned: String,
        renderWidth: CGFloat,
        bodyPointSize: CGFloat = 0,
        themeTextColor: UIColor? = nil,
        headers: [String: String] = [:],
        cachePolicy: URLRequest.CachePolicy,
        decode: (@Sendable (Data, String) async -> Data?)? = nil
    ) async -> UIImage? {
        if cleaned.hasPrefix("data:") {
            return await loadDataURIImage(
                cleaned,
                renderWidth: renderWidth,
                bodyPointSize: bodyPointSize,
                themeTextColor: themeTextColor,
                decode: decode
            )
        }
        if cleaned.hasPrefix("http://") || cleaned.hasPrefix("https://") {
            return await loadRemoteImage(
                cleaned,
                renderWidth: renderWidth,
                bodyPointSize: bodyPointSize,
                themeTextColor: themeTextColor,
                headers: headers,
                cachePolicy: cachePolicy,
                decode: decode
            )
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
    /// Also drops the per-image header fragment (`OnlineImageRequestOptions`), so what comes back
    /// is always the URL to actually request — every caller wants that, headers or not.
    static func cleanImageSource(_ src: String) -> String {
        var s = OnlineImageRequestOptions.decode(src).src
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    static func loadDataURIImage(
        _ uri: String,
        renderWidth: CGFloat,
        bodyPointSize: CGFloat = 0,
        themeTextColor: UIColor? = nil,
        decode: (@Sendable (Data, String) async -> Data?)? = nil
    ) async -> UIImage? {
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
                return CommentBubbleSVGRecognizer.resolvedBubbleImage(
                    src: uri,
                    svgContent: svg,
                    pointSize: pointSize,
                    themeTextColor: .secondaryLabel,
                    recognizedBubble: recognized
                ) ?? CommentBubbleSVGRecognizer.draw(svg: recognized, pointSize: pointSize, themeTextColor: .secondaryLabel)
            }
            // Render the book source's SVG exactly as authored (no native substitution) — all
            // styling must follow the source.
            return await rasterizeSVG(
                svg,
                renderWidth: renderWidth,
                bodyPointSize: bodyPointSize,
                themeTextColor: themeTextColor,
                baseURL: nil
            )
        }
        let effectiveData = await sourceDecodedBytes(data, src: uri, with: decode)
        return decodedImage(from: effectiveData)
    }

    /// The source's `imageDecode` script over downloaded bytes (on the source's host, see
    /// `SourceImageDecoder`); the original bytes when there is no decoder or it returns nothing.
    private static func sourceDecodedBytes(
        _ data: Data, src: String, with decode: (@Sendable (Data, String) async -> Data?)?
    ) async -> Data {
        guard let decode else { return data }
        return await decode(data, src) ?? data
    }

    /// Fetches a remote image. Falls back to SVG rasterization when the bytes are an SVG document.
    static func loadRemoteImage(
        _ urlString: String,
        renderWidth: CGFloat,
        bodyPointSize: CGFloat = 0,
        themeTextColor: UIColor? = nil,
        headers: [String: String] = [:],
        cachePolicy: URLRequest.CachePolicy = .returnCacheDataElseLoad,
        decode: (@Sendable (Data, String) async -> Data?)? = nil
    ) async -> UIImage? {
        guard let url = URL(string: urlString) else { return nil }
        // CRITICAL: the renderer loads images SEQUENTIALLY (await per node), so a single hung
        // remote image (段評 avatar/emoji, 版权页 photo) blocks the whole chapter → "infinite
        // loading". `URLSession.shared.data(from:)` inherits the 60s default; cap it hard.
        var request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: 10)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        // The source's own headers win over the built-in UA: illustration CDNs treat the
        // source's declared User-Agent as a pass token (幻梦轻小说's ends in a bogus
        // `Safari/537.36.3022`, and only that exact string clears its Cloudflare rule).
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let started = Date()
        AppLogger.render("⟐ imgLoad http start", context: [
            "url": String(urlString.prefix(90)),
            "srcHeaders": headers.count
        ])
        guard let (data, response) = try? await URLSession.shared.data(for: request), !data.isEmpty else {
            AppLogger.render("⟐ imgLoad http FAIL", context: [
                "url": String(urlString.prefix(90)),
                "ms": Int(Date().timeIntervalSince(started) * 1000)
            ])
            return nil
        }
        // A hotlink/bot wall answers 403 with an HTML body, which decodes to no image and is
        // otherwise indistinguishable from a broken URL. Name it, so "插图不显示" is one log away.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            AppLogger.render("⟐ imgLoad http status", context: [
                "url": String(urlString.prefix(90)),
                "status": http.statusCode,
                "srcHeaders": headers.count,
                "bytes": data.count
            ])
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if ms > 1000 {
            AppLogger.render("⟐ imgLoad http slow", context: ["url": String(urlString.prefix(90)), "ms": ms, "bytes": data.count])
        }
        // Per-source imageDecode (encrypted-image sources); falls back to the
        // raw bytes so a broken rule degrades instead of blanking the image.
        let effectiveData = await sourceDecodedBytes(data, src: urlString, with: decode)
        if let image = decodedImage(from: effectiveData) { return image }
        if let svg = String(data: effectiveData, encoding: .utf8), svg.contains("<svg") {
            // ⟐ bubble: REMOTE SVG bubbles never touch recognize() — they go straight to the
            // WebView rasterizer. If this fires for 光遇/企点, the native redraw can't help; the
            // bubble is webview-rendered and the gap/wrap fix must live in the source SVG or here.
            CommentBubbleSVGRecognizer.diag("load:remote-svg → webview", context: ["len": svg.count])
            return await rasterizeSVG(
                svg,
                renderWidth: renderWidth,
                bodyPointSize: bodyPointSize,
                themeTextColor: themeTextColor,
                baseURL: url
            )
        }
        return nil
    }

    /// Longest edge, in pixels, a chapter image is decoded at.
    ///
    /// Light-novel 插图 chapters ship print scans: the 青春豬頭少年 第一卷 插图 spread is
    /// 5392×3542 (a 607KB JPEG that decodes to ~76MB), and a chapter holds a dozen of them.
    /// The reader draws an illustration at column width — ~1170px on a 3x phone, ~1400px in an
    /// iPad column — and the widest it is ever shown is the full-screen preview at 1x, ~2064px
    /// on the largest iPad. 2048 covers every one of those at native resolution; only pinch-zoom
    /// past 1x in the preview gets softer, the same trade the comic reader already makes
    /// (`FixedPageImageLoader.maxRasterPixelWidth` = 2000). Covers have their own, much smaller
    /// ceiling in `BookCoverLoader.decodedCover` — a cover slot is 140pt, an illustration is the
    /// whole column.
    private static let maxImagePixelSize = 2048

    /// Decodes image bytes, downsampling anything above `maxImagePixelSize` and forcing the
    /// decode here (already off the main thread) so drawing a page doesn't pay for it.
    ///
    /// Never upscales: `kCGImageSourceThumbnailMaxPixelSize` is a ceiling, so the 716×1023 plates
    /// in the same chapter come back untouched. Bytes ImageIO can't open (a broken `imageDecode`
    /// rule, say) fall back to `UIImage(data:)` so they degrade exactly as before.
    static func decodedImage(from data: Data) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImagePixelSize
        ] as [CFString: Any] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    @MainActor
    private static func rasterizeSVG(
        _ svg: String,
        renderWidth: CGFloat,
        bodyPointSize: CGFloat,
        themeTextColor: UIColor?,
        baseURL: URL?
    ) async -> UIImage? {
        let column = renderWidth > 0 ? renderWidth : UIScreen.main.bounds.width
        // A source review card (神评论 / 本章说 / 作者说) draws its prose in viewBox units, so the
        // width we rasterize at IS its text size: `ReviewCardRaster` matches it to the reader's
        // body text (or redraws it from the reader's template). Anything that isn't a card is
        // rasterized exactly as before.
        let reader = bodyPointSize > 0
            ? ReviewCardRaster.Reader(
                font: UserReaderFontResolver.bodyFont(size: bodyPointSize),
                textColor: themeTextColor ?? .label
            )
            : nil
        return await ReviewCardRaster.image(
            svg: svg,
            columnWidth: column,
            reader: reader,
            baseURL: baseURL,
            path: "img-data-uri"
        )
    }
}
