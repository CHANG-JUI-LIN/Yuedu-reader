import UIKit
import os

final class FixedLayoutViewportResolver: Sendable {
    let defaultViewport: CGSize?
    private let pageViewports: [Int: CGSize]
    private let pageCache = OSAllocatedUnfairLock(initialState: [Int: CGSize]())

    init(defaultViewport: CGSize?, pageViewports: [Int: CGSize] = [:]) {
        self.defaultViewport = defaultViewport
        self.pageViewports = pageViewports
    }

    func viewport(
        for spineIndex: Int,
        resourceProvider: BookResourceProvider
    ) async -> CGSize {
        if let cached = pageCache.withLock({ $0[spineIndex] }) {
            return cached
        }

        let result: CGSize
        if let configured = pageViewports[spineIndex] {
            result = configured
        } else {
            let parsed = await parseViewportFromXHTML(spineIndex: spineIndex, resourceProvider: resourceProvider)
            result = parsed ?? defaultViewport ?? CGSize(width: 600, height: 800)
        }

        pageCache.withLock { $0[spineIndex] = result }

        return result
    }

    func prewarm(
        spineIndices: [Int],
        resourceProvider: BookResourceProvider
    ) async {
        for i in spineIndices {
            let isCached = pageCache.withLock { $0[i] != nil }
            if isCached { continue }

            let result: CGSize
            if let configured = pageViewports[i] {
                result = configured
            } else {
                let parsed = await parseViewportFromXHTML(spineIndex: i, resourceProvider: resourceProvider)
                result = parsed ?? defaultViewport ?? CGSize(width: 600, height: 800)
            }

            pageCache.withLock { $0[i] = result }
        }
    }

    private func parseViewportFromXHTML(
        spineIndex: Int,
        resourceProvider: BookResourceProvider
    ) async -> CGSize? {
        guard let html = try? await resourceProvider.chapterHTML(at: spineIndex) else { return nil }
        return Self.parseMetaViewport(in: html)
    }

    private static func parseMetaViewport(in html: String) -> CGSize? {
        let pattern = #"<meta[^>]*name\s*=\s*"viewport"[^>]*content\s*=\s*"([^"]+)"[^>]*>"#
        guard let rx = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = rx.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges >= 2,
              let contentRange = Range(match.range(at: 1), in: html)
        else { return nil }

        let content = String(html[contentRange])
        return parseViewportString(content)
    }

    private static func parseViewportString(_ raw: String) -> CGSize? {
        let parts = raw.components(separatedBy: CharacterSet(charactersIn: ",; "))
        var w: CGFloat?
        var h: CGFloat?
        for part in parts {
            let kv = part.components(separatedBy: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0].lowercased() {
            case "width": w = CGFloat(Double(kv[1]) ?? 0)
            case "height": h = CGFloat(Double(kv[1]) ?? 0)
            default: break
            }
        }
        guard let w, let h, w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }
}
