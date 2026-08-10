import Testing
import UIKit
@testable import yuedu_app

/// Shared helpers for the browser-layout test suites.
enum BrowserLayoutTestSupport {

    /// Runs the full pipeline and returns pages + the document (for sourceText/anchors/metrics).
    static func layout(
        _ html: String,
        cssTexts: [String] = [],
        width: CGFloat = 300,
        height: CGFloat = 400,
        rootFontSize: CGFloat = 17,
        imageLoader: ((String) -> UIImage?)? = nil
    ) async throws -> (pages: [PageFragments], doc: BrowserLayoutDocument) {
        let config = BrowserLayoutConfig(
            renderWidth: width, renderHeight: height, rootFontSize: rootFontSize,
            fontFamilies: ["PingFangSC-Regular"], textColor: .black, backgroundColor: .white
        )
        let doc = BrowserLayoutDocument(
            html: html, cssTexts: cssTexts, config: config, imageLoader: imageLoader
        )
        let pages = try await doc.renderPages(containerSize: CGSize(width: width, height: height))
        return (pages, doc)
    }

    /// All text fragments across all pages, flattened in document order.
    static func allTextFragments(_ pages: [PageFragments]) -> [TextFragment] {
        var result: [TextFragment] = []
        for page in pages {
            collectText(page.fragments, into: &result)
        }
        return result
    }

    private static func collectText(_ fragments: [Fragment], into out: inout [TextFragment]) {
        for fragment in fragments {
            switch fragment {
            case .text(let t): out.append(t)
            case .group(let children): collectText(children, into: &out)
            default: break
            }
        }
    }

    static func allImageFragments(_ pages: [PageFragments]) -> [ImageFragment] {
        var result: [ImageFragment] = []
        for page in pages {
            collectImages(page.fragments, into: &result)
        }
        return result
    }

    private static func collectImages(_ fragments: [Fragment], into out: inout [ImageFragment]) {
        for fragment in fragments {
            switch fragment {
            case .image(let i): out.append(i)
            case .group(let children): collectImages(children, into: &out)
            default: break
            }
        }
    }

    /// Concatenates fragment source slices in order; the parity check target.
    static func visibleText(_ pages: [PageFragments], sourceText: String) -> String {
        var out = ""
        let ns = sourceText as NSString
        for fragment in allTextFragments(pages) {
            guard fragment.sourceRange.length > 0,
                  fragment.sourceRange.location >= 0,
                  fragment.sourceRange.location + fragment.sourceRange.length <= ns.length else { continue }
            out += ns.substring(with: fragment.sourceRange)
        }
        return out
    }

    /// True when every fragment range is non-overlapping and in increasing order
    /// (no loss/duplication/reordering across the whole layout).
    static func rangesAreOrdered(_ pages: [PageFragments]) -> Bool {
        var cursor = -1
        for fragment in allTextFragments(pages) {
            let range = fragment.sourceRange
            guard range.length > 0 else { continue }
            guard range.location >= cursor else { return false }
            cursor = range.location + range.length
        }
        return true
    }

    /// Generates a solid-color image in memory (no files, no network).
    static func makeImage(size: CGSize, color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
