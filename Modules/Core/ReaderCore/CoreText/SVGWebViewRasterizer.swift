import UIKit
import WebKit
import CryptoKit

enum ReaderBatterySVGRasterizerError: Error, Equatable, Sendable {
    case invalidRenderSize
}

struct ReaderBatterySVGRasterRequest: Equatable, Sendable {
    let pixelSize: CGSize
    let pointSize: CGSize
    let displayScale: CGFloat
    let displayScaleCacheKey: UInt64
}

enum ReaderBatterySVGRasterRequestValidator {
    private static let minimumDisplayScale: CGFloat = 0.5
    private static let maximumDisplayScale: CGFloat = 4
    private static let maximumDimension: CGFloat = 4_096
    private static let maximumArea: CGFloat = 8_388_608

    static func validate(
        pixelSize: CGSize,
        displayScale: CGFloat
    ) throws -> ReaderBatterySVGRasterRequest {
        guard displayScale.isFinite,
              displayScale >= minimumDisplayScale,
              displayScale <= maximumDisplayScale,
              pixelSize.width.isFinite,
              pixelSize.width > 0,
              pixelSize.height.isFinite,
              pixelSize.height > 0 else {
            throw ReaderBatterySVGRasterizerError.invalidRenderSize
        }

        let normalizedPixelSize = CGSize(
            width: max(1, pixelSize.width.rounded(.toNearestOrAwayFromZero)),
            height: max(1, pixelSize.height.rounded(.toNearestOrAwayFromZero))
        )
        guard normalizedPixelSize.width <= maximumDimension,
              normalizedPixelSize.height <= maximumDimension,
              normalizedPixelSize.width * normalizedPixelSize.height <= maximumArea else {
            throw ReaderBatterySVGRasterizerError.invalidRenderSize
        }

        let pointSize = CGSize(
            width: normalizedPixelSize.width / displayScale,
            height: normalizedPixelSize.height / displayScale
        )
        guard pointSize.width.isFinite,
              pointSize.width > 0,
              pointSize.width <= maximumDimension,
              pointSize.height.isFinite,
              pointSize.height > 0,
              pointSize.height <= maximumDimension,
              pointSize.width * pointSize.height <= maximumArea else {
            throw ReaderBatterySVGRasterizerError.invalidRenderSize
        }

        return ReaderBatterySVGRasterRequest(
            pixelSize: normalizedPixelSize,
            pointSize: pointSize,
            displayScale: displayScale,
            displayScaleCacheKey: Double(displayScale).bitPattern
        )
    }
}

@MainActor
final class SVGWebViewRasterizer: NSObject {

    static let shared = SVGWebViewRasterizer()

    /// One rasterization lane: a dedicated WKWebView plus the item it is currently drawing.
    /// A 段評-heavy 起点 chapter carries 100+ distinct bubble SVGs; a single WebView rasterizes
    /// them one-by-one, and because the chapter renderer blocks on every image, the whole chapter
    /// shows "infinite loading" for many seconds. A small pool drains the queue ~`poolSize`× faster
    /// while still rendering each SVG exactly as authored.
    private final class Worker {
        let webView: WKWebView
        var currentItem: SVGWorkItem?
        /// Identifies the navigation kicked off for `currentItem`, so a stale `didFinish` from a
        /// timed-out item can't snapshot the wrong (next) item's webView.
        var currentNavigation: WKNavigation?
        /// A snapshot may outlive `didFinish`. Keep it cancellable so this WebView is never reused
        /// by the next item while an abandoned capture/retry loop is still touching it.
        var captureTask: Task<Void, Never>?
        var captureID: UUID?
        init(webView: WKWebView) { self.webView = webView }
    }

    private var workers: [Worker] = []
    private let cache = NSCache<NSString, UIImage>()
    private let readerBatteryCache = NSCache<NSString, UIImage>()
    private var pendingItems: [SVGWorkItem] = []

    /// Number of concurrent rasterization lanes. Four parallel WKWebViews drain a 100-bubble
    /// chapter in ~¼ the wall time of the old single-WebView queue, without thrashing memory.
    private static let poolSize = 4

    /// Per-item watchdog: if a WKWebView navigation never fires didFinish/didFail (malformed
    /// SVG, stuck load) the continuation would never resume AND that lane would stall. The
    /// watchdog finishes a stuck item with nil and frees the lane so the queue keeps moving.
    private static let itemTimeout: TimeInterval = 7

    /// Workers currently busy. Drives drain telemetry and the "all lanes idle" check.
    private var activeCount = 0

    // Drain telemetry (logged once per queue drain, not per-item, to avoid 100×/chapter spam).
    private var drainStart: Date?
    private var drainProcessed = 0
    private var drainTimeouts = 0
    private var drainCacheHits = 0

    private override init() {
        super.init()
        for _ in 0..<Self.poolSize {
            let config = WKWebViewConfiguration()
            config.suppressesIncrementalRendering = true
            let wv = WKWebView(frame: .zero, configuration: config)
            wv.isOpaque = false
            wv.backgroundColor = .clear
            wv.scrollView.isScrollEnabled = false
            wv.navigationDelegate = self
            workers.append(Worker(webView: wv))
        }
        // A 段評-heavy 起点 chapter can carry 100+ bubble SVGs; 64 thrashed within a single
        // chapter (re-rasterizing on every page turn). Hold a whole chapter's worth.
        cache.countLimit = 1024
        readerBatteryCache.countLimit = 256
    }

    private var isDraining: Bool { activeCount > 0 }

    func render(svgString rawSVG: String, size: CGSize, baseURL: URL? = nil) async -> UIImage? {
        // WKWebView renders an `<svg>` that declares width/height but NO `viewBox` at 1:1 user
        // units. When we force a smaller CSS size to fit the column, such an SVG is CLIPPED to its
        // top-left corner instead of scaled down. 起点 本章说 cards and 版权页 banners are authored
        // `width=1080 height=H` with no viewBox, so they showed only a cropped sliver (the card
        // "vanished"; the banner's rows collapsed into a garbled strip). Injecting a matching
        // viewBox makes the content scale to the rendered size, and is a no-op for any SVG that
        // already declares one — so it never changes a correctly-authored SVG's appearance.
        let svgString = ensureViewBox(in: rawSVG)
        let key = cacheKey(svgString: svgString, size: size)
        if let cached = cache.object(forKey: key) {
            if isDraining { drainCacheHits += 1 }
            return cached
        }
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                pendingItems.append(SVGWorkItem(
                    id: requestID,
                    svgString: svgString,
                    size: size,
                    baseURL: baseURL,
                    cacheKey: key,
                    continuation: continuation
                ))
                dispatchToIdleWorkers()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWorkItem(id: requestID)
            }
        }
    }

    /// Rasterizes only a previously validated reader-battery template. Imported source must pass
    /// through `ReaderBatterySVGTemplate.init(source:)` before it can reach this entry point, so
    /// raw file contents are never forwarded to WKWebView by the overlay feature.
    func renderBattery(
        template: ReaderBatterySVGTemplate,
        level: Double,
        isCharging: Bool,
        colorHex: String,
        pixelSize: CGSize,
        displayScale: CGFloat
    ) async throws -> UIImage? {
        guard level.isFinite else {
            throw ReaderBatterySVGError.invalidLevel
        }
        let request = try ReaderBatterySVGRasterRequestValidator.validate(
            pixelSize: pixelSize,
            displayScale: displayScale
        )

        let levelBucket = Int((min(max(level, 0), 1) * 100).rounded())
        // `render` performs the authoritative finite-level and RGBA color validation. Rendering
        // the bucket rather than the raw value keeps both the SVG and cache semantics identical.
        let normalizedColor = colorHex.uppercased()
        let assetHash = SHA256.hash(data: Data(template.validatedSource.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let batteryKey = readerBatteryCacheKey(
            assetHash: assetHash,
            levelBucket: levelBucket,
            isCharging: isCharging,
            colorHex: normalizedColor,
            pixelSize: request.pixelSize,
            displayScaleCacheKey: request.displayScaleCacheKey
        )
        if let cached = readerBatteryCache.object(forKey: batteryKey) {
            return cached
        }

        let sanitizedSVG = try template.render(
            level: Double(levelBucket) / 100,
            isCharging: isCharging,
            colorHex: normalizedColor
        )
        guard let image = await render(svgString: sanitizedSVG, size: request.pointSize) else {
            return nil
        }
        let scaledImage = image.resized(to: request.pointSize, displayScale: request.displayScale)
        readerBatteryCache.setObject(scaledImage, forKey: batteryKey)
        return scaledImage
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

    /// Inserts a `viewBox="0 0 W H"` (from the declared width/height) when the root `<svg>` has
    /// none, so a forced CSS size scales the content instead of clipping it. Returns the string
    /// unchanged when a viewBox is already present or width/height aren't both numeric.
    /// (Non-private only so unit tests can verify the injection that un-clips 本章说/版权页 SVGs.)
    func ensureViewBox(in svgString: String) -> String {
        guard let svgStart = svgString.range(of: "<svg", options: .caseInsensitive)?.lowerBound else {
            return svgString
        }
        let afterSvg = svgString.index(svgStart, offsetBy: 4)
        guard let tagEnd = svgString.range(of: ">", range: afterSvg..<svgString.endIndex)?.lowerBound else {
            return svgString
        }
        let tag = String(svgString[svgStart..<tagEnd])
        if tag.range(of: "viewBox", options: .caseInsensitive) != nil { return svgString }

        let attrs = extractSVGAttributes(svgString)
        func numeric(_ raw: String?) -> Double? {
            guard let raw else { return nil }
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s.hasSuffix("px") { s = String(s.dropLast(2)) }
            guard let v = Double(s.trimmingCharacters(in: .whitespaces)), v > 0 else { return nil }
            return v
        }
        guard let w = numeric(attrs["width"]), let h = numeric(attrs["height"]) else { return svgString }

        func fmt(_ v: Double) -> String {
            v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(v)
        }
        var result = svgString
        result.insert(contentsOf: " viewBox=\"0 0 \(fmt(w)) \(fmt(h))\"", at: afterSvg)
        return result
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

        var resolved: CGSize
        if styleHeight == nil && attrH == nil && vbSize != nil {
            let ratio = vbSize!.width > 0 ? vbSize!.height / vbSize!.width : 1
            resolved = CGSize(width: w, height: w * ratio)
        } else if styleWidth == nil && attrW == nil && vbSize != nil {
            let ratio = vbSize!.height > 0 ? vbSize!.width / vbSize!.height : 1
            resolved = CGSize(width: h * ratio, height: h)
        } else {
            resolved = CGSize(width: w, height: h)
        }

        // Cap to the display column width. A full-width comment card (起點/企点 本章说 is ~1080pt
        // wide) rasterized at its intrinsic width makes WKWebView.takeSnapshot throw on the
        // oversized bitmap → the whole card silently vanished. It's displayed scaled to the column
        // anyway, so rasterize it at the column width. (Small bubbles < renderWidth are untouched.)
        if renderWidth > 0, resolved.width > renderWidth, resolved.width > 0 {
            resolved = CGSize(width: renderWidth, height: resolved.height * renderWidth / resolved.width)
        }
        return resolved
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

    /// Hands queued items to any idle lane, up to the pool size.
    private func dispatchToIdleWorkers() {
        for worker in workers where worker.currentItem == nil {
            guard !pendingItems.isEmpty else { break }
            startNext(on: worker)
        }
    }

    /// Cancels a queued or active render and resumes its caller exactly once. Active WebKit work
    /// is stopped before the lane is released so rapidly changing overlay previews do not leave
    /// stale renders blocking the newest request at the back of the queue.
    private func cancelWorkItem(id: UUID) {
        if let index = pendingItems.firstIndex(where: { $0.id == id }) {
            let item = pendingItems.remove(at: index)
            guard !item.finished else { return }
            item.finished = true
            item.continuation.resume(returning: nil)
            logDrainIfFinished()
            return
        }

        guard let worker = workers.first(where: { $0.currentItem?.id == id }),
              let item = worker.currentItem,
              !item.finished else {
            return
        }
        cancelCapture(on: worker)
        worker.webView.stopLoading()
        finishItem(item, on: worker, image: nil)
    }

    private func startNext(on worker: Worker) {
        guard !pendingItems.isEmpty else { return }
        cancelCapture(on: worker)
        if drainStart == nil { drainStart = Date() }
        let item = pendingItems.removeFirst()
        worker.currentItem = item
        activeCount += 1
        worker.webView.frame = CGRect(origin: .zero, size: item.size)
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
        worker.currentNavigation = worker.webView.loadHTMLString(html, baseURL: item.baseURL)
        // Watchdog: if this navigation never completes, finish it (nil) and free the lane so a
        // single bad SVG can't stall its worker and hang the chapter.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.itemTimeout) { [weak self, weak item, weak worker] in
            guard let self, let item, let worker, !item.finished, worker.currentItem === item else { return }
            self.drainTimeouts += 1
            AppLogger.render("⟐ svgRaster TIMEOUT", context: ["size": "\(Int(item.size.width))x\(Int(item.size.height))"])
            self.finishItem(item, on: worker, image: nil)
        }
    }

    /// Takes a `WKWebView` snapshot, retrying after a short delay when it throws. A large SVG
    /// card (起點/企点 本章说) can make `takeSnapshot` throw if it isn't fully painted at the moment
    /// `didFinish` fires; a brief settle + retry lets it render instead of vanishing. (Falling back
    /// to `layer.render` does NOT work — WKWebView content renders out-of-process and comes back
    /// blank — so retrying the real snapshot is the reliable path.)
    @MainActor
    private func captureSnapshot(_ webView: WKWebView, rect: CGRect, retriesLeft: Int) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = rect
        do {
            let image = try await webView.takeSnapshot(configuration: config)
            return Task.isCancelled ? nil : image
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled, retriesLeft > 0 else {
                if Task.isCancelled { return nil }
                AppLogger.render("⟐ svgRaster snapshot-fail", context: [
                    "size": "\(Int(rect.width))x\(Int(rect.height))",
                    "err": String(describing: error).prefix(80)
                ])
                return nil
            }
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return nil
            }
            return await captureSnapshot(webView, rect: rect, retriesLeft: retriesLeft - 1)
        }
    }

    private func beginCapture(
        webView: WKWebView,
        navigation: WKNavigation?
    ) {
        guard let worker = workers.first(where: { $0.webView === webView }),
              let item = worker.currentItem,
              navigation == worker.currentNavigation,
              !item.finished else {
            return
        }

        cancelCapture(on: worker)
        let captureID = UUID()
        worker.captureID = captureID
        worker.captureTask = Task { @MainActor [weak self, weak worker, weak item] in
            guard let self, let worker, let item else { return }
            let image = await self.captureSnapshot(
                webView,
                rect: CGRect(origin: .zero, size: item.size),
                retriesLeft: 2
            )
            guard !Task.isCancelled,
                  !item.finished,
                  worker.currentItem === item,
                  worker.currentNavigation == navigation,
                  worker.captureID == captureID else {
                return
            }
            worker.captureTask = nil
            worker.captureID = nil
            self.finishItem(item, on: worker, image: image)
        }
    }

    private func cancelCapture(on worker: Worker) {
        worker.captureTask?.cancel()
        worker.captureTask = nil
        worker.captureID = nil
    }

    private func cacheKey(svgString: String, size: CGSize) -> NSString {
        let input = "\(svgString)|\(size.width)|\(size.height)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined() as NSString
    }

    private func readerBatteryCacheKey(
        assetHash: String,
        levelBucket: Int,
        isCharging: Bool,
        colorHex: String,
        pixelSize: CGSize,
        displayScaleCacheKey: UInt64
    ) -> NSString {
        let input = [
            assetHash,
            String(levelBucket),
            isCharging ? "1" : "0",
            colorHex,
            String(format: "%.0fx%.0f", pixelSize.width, pixelSize.height),
            String(displayScaleCacheKey, radix: 16)
        ].joined(separator: "|")
        return input as NSString
    }

    private func logDrainIfFinished() {
        guard pendingItems.isEmpty, activeCount == 0, let start = drainStart else { return }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        AppLogger.render("⟐ svgRaster drained", context: [
            "rasterized": drainProcessed,
            "timeouts": drainTimeouts,
            "cacheHits": drainCacheHits,
            "lanes": Self.poolSize,
            "ms": ms
        ])
        drainStart = nil
        drainProcessed = 0
        drainTimeouts = 0
        drainCacheHits = 0
    }
}

private extension UIImage {
    func resized(to pointSize: CGSize, displayScale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        format.opaque = false
        return UIGraphicsImageRenderer(size: pointSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: pointSize))
        }
    }
}

extension SVGWebViewRasterizer: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.beginCapture(webView: webView, navigation: navigation)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            guard let worker = self.workers.first(where: { $0.webView === webView }),
                  let item = worker.currentItem,
                  navigation == worker.currentNavigation,
                  !item.finished else {
                return
            }
            self.finishItem(item, on: worker, image: nil)
        }
    }
}

private final class SVGWorkItem {
    let id: UUID
    let svgString: String
    let size: CGSize
    let baseURL: URL?
    let cacheKey: NSString
    let continuation: CheckedContinuation<UIImage?, Never>
    /// Set once the item's continuation has been resumed (by snapshot, failure, or watchdog).
    var finished = false

    init(
        id: UUID,
        svgString: String,
        size: CGSize,
        baseURL: URL?,
        cacheKey: NSString,
        continuation: CheckedContinuation<UIImage?, Never>
    ) {
        self.id = id
        self.svgString = svgString
        self.size = size
        self.baseURL = baseURL
        self.cacheKey = cacheKey
        self.continuation = continuation
    }
}

private extension SVGWebViewRasterizer {
    private func finishItem(_ item: SVGWorkItem, on worker: Worker, image: UIImage?) {
        // Guard against double-finish: the watchdog and a late didFinish can both fire.
        guard !item.finished else { return }
        item.finished = true
        cancelCapture(on: worker)
        if worker.currentItem === item {
            worker.currentItem = nil
            worker.currentNavigation = nil
        }
        activeCount -= 1
        drainProcessed += 1
        if let image {
            cache.setObject(image, forKey: item.cacheKey)
        }
        item.continuation.resume(returning: image)
        // Free lane → pull the next queued item, or log the drain if everything is done.
        if !pendingItems.isEmpty {
            startNext(on: worker)
        } else {
            logDrainIfFinished()
        }
    }
}
