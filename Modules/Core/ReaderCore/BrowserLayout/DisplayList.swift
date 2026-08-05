import CoreGraphics
import CoreText
import Foundation
import UIKit

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
    let rect: CGRect
    let baselineY: CGFloat
    let font: UIFont
    let color: UIColor
    /// The visible text slice (for rendering and hit-testing).
    let text: String
    /// The shaped line this run belongs to (untrimmed line range), for
    /// precise string-index → typographic-offset mapping.
    let ctLine: CTLine?
}

struct DisplayFillItem {
    let rect: CGRect
    let color: UIColor
    let cornerRadius: CGFloat
    let nodeID: Int
    let writingMode: ReaderWritingMode
}

struct DisplayImageItem {
    let source: String
    let image: UIImage?
    let sourceRange: NSRange
    let nodeID: Int
    let linkTarget: String?
    let writingMode: ReaderWritingMode
    let rect: CGRect
    let alt: String?
}

struct DisplayList {
    let items: [DisplayItem]
    static let empty = DisplayList(items: [])
}

/// Flattens a page's fragment tree (groups are recursive) into a flat draw list.
/// Coordinates are page-local already. This is the boundary a future draw phase
/// renders with UIKit/CoreGraphics.
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
                    nodeID: f.nodeID, writingMode: f.writingMode
                )))
            case .image(let i):
                items.append(.image(DisplayImageItem(
                    source: i.source, image: i.image, sourceRange: i.sourceRange,
                    nodeID: i.nodeID, linkTarget: i.linkTarget,
                    writingMode: i.writingMode, rect: i.rect, alt: i.alt
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
