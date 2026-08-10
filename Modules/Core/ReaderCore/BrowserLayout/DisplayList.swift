import CoreGraphics
import CoreText
import Foundation
import UIKit

/// Display items carry PAGE CANVAS-local rects (Phase 2C contract).
/// The canvas equals the actual page viewport.
enum DisplayItem {
    case text(DisplayTextItem)
    case fill(DisplayFillItem)
    case image(DisplayImageItem)
}

struct DisplayTextItem {
    let sourceRange: NSRange
    let nodeID: Int
    let linkTarget: String?
    let writingMode: ReaderWritingMode
    let rect: PageLocalRect
    let baselineY: CGFloat
    let font: UIFont
    let color: UIColor
    /// The visible text slice (for rendering and hit-testing).
    let text: String
    /// The shaped line this run belongs to (untrimmed line range), for
    /// precise string-index → typographic-offset mapping.
    let ctLine: CTLine?
}

/// A bordered box: background fill + full four-edge border + radius.
/// Phase 2C: one fill item carries the COMPLETE paint representation —
/// dotted/dashed borders render all four sides, never a lone top line.
struct DisplayFillItem {
    let rect: PageLocalRect
    let color: UIColor
    let cornerRadius: CGFloat
    let borderTop: BorderEdge
    let borderBottom: BorderEdge
    let borderLeft: BorderEdge
    let borderRight: BorderEdge
    let nodeID: Int
    let writingMode: ReaderWritingMode

    var hasVisibleBorder: Bool {
        borderTop.isVisible || borderBottom.isVisible || borderLeft.isVisible || borderRight.isVisible
    }
}

struct DisplayImageItem {
    let source: String
    let image: UIImage?
    let sourceRange: NSRange
    let nodeID: Int
    let linkTarget: String?
    let writingMode: ReaderWritingMode
    let rect: PageLocalRect
    let alt: String?
    /// Painted CSS background — draws, never hit-tests. See `ImageFragment`.
    let isBackgroundPaint: Bool

    init(
        source: String,
        image: UIImage?,
        sourceRange: NSRange,
        nodeID: Int,
        linkTarget: String?,
        writingMode: ReaderWritingMode,
        rect: PageLocalRect,
        alt: String?,
        isBackgroundPaint: Bool = false
    ) {
        self.source = source
        self.image = image
        self.sourceRange = sourceRange
        self.nodeID = nodeID
        self.linkTarget = linkTarget
        self.writingMode = writingMode
        self.rect = rect
        self.alt = alt
        self.isBackgroundPaint = isBackgroundPaint
    }
}

struct DisplayList {
    let items: [DisplayItem]
    static let empty = DisplayList(items: [])
}

/// Flattens a page's fragment tree (groups are recursive) into a flat draw list.
/// Coordinates are page canvas-local already.
enum DisplayListBuilder {

    /// Builds a display list for one page. `sourceText` supplies the visible
    /// slices for text items (needed by the renderer / hit-testing).
    static func build(for page: PageFragments, sourceText: String = "") -> DisplayList {
        var items: [DisplayItem] = []
        collect(page.fragments, into: &items, sourceText: sourceText)
        return DisplayList(items: items)
    }

    private static func collect(_ fragments: [Fragment], into items: inout [DisplayItem], sourceText: String) {
        for fragment in fragments {
            switch fragment {
            case .text(let t):
                let visible = slice(sourceText, range: t.sourceRange)
                items.append(.text(DisplayTextItem(
                    sourceRange: t.sourceRange,
                    nodeID: t.nodeID,
                    linkTarget: t.linkTarget,
                    writingMode: t.writingMode,
                    rect: t.rect,
                    baselineY: t.baselineY,
                    font: t.font,
                    color: t.color,
                    text: visible,
                    ctLine: t.ctLine
                )))
            case .fill(let f):
                items.append(.fill(DisplayFillItem(
                    rect: f.rect, color: f.color, cornerRadius: f.cornerRadius,
                    borderTop: f.borderTop, borderBottom: f.borderBottom,
                    borderLeft: f.borderLeft, borderRight: f.borderRight,
                    nodeID: f.nodeID, writingMode: f.writingMode
                )))
            case .image(let i):
                items.append(.image(DisplayImageItem(
                    source: i.source, image: i.image, sourceRange: i.sourceRange,
                    nodeID: i.nodeID, linkTarget: i.linkTarget,
                    writingMode: i.writingMode, rect: i.rect, alt: i.alt,
                    isBackgroundPaint: i.isBackgroundPaint
                )))
            case .group(let children):
                collect(children, into: &items, sourceText: sourceText)
            }
        }
    }

    private static func slice(_ sourceText: String, range: NSRange) -> String {
        guard !sourceText.isEmpty, range.length > 0 else { return "" }
        let ns = sourceText as NSString
        guard range.location >= 0,
              range.location + range.length <= ns.length else { return "" }
        return ns.substring(with: range)
    }
}
