import CoreGraphics
import Foundation
import UIKit

/// One chapter laid out as a CONTINUOUS flow — the scroll reader's counterpart
/// to `PageFragmentation`.
///
/// The two reading modes differ only in what a fragmentainer is:
///
///   paged  → fragmentainer = one page   → many `PageFragments`
///   scroll → fragmentainer = the chapter → one `BrowserScrollDocument`
///
/// Same box tree, same `PageWalker`, same geometry rules. Scroll mode does not
/// get a second layout path, and it does NOT slice content into layout units:
/// slicing content to fit a rendering surface is what the legacy engine has to
/// do because a `CTFrame` cannot be arbitrarily tall. A browser has no such
/// notion — its document is continuous and the viewport moves over it. Anything
/// that looks like a slice in scroll mode is a PAINT TILE (a window onto this
/// document), never a piece of layout.
struct BrowserScrollDocument {

    /// Every display item of the chapter, in DOCUMENT coordinates: y = 0 is the
    /// top of the chapter's content, x already includes the reader's left inset
    /// so a tile can paint an item by translating on the block axis alone.
    let displayList: DisplayList
    /// Total block-axis extent of the chapter, including the reader's top and
    /// bottom content insets. This is the chapter's height in the scroll view.
    let contentHeight: CGFloat
    /// Collapsed chapter text the display items' `sourceRange`s point into.
    let sourceText: String
    /// Anchor id → source offset (shared with TOC / search / restore).
    let anchorOffsets: [String: Int]
    /// nodeID → owning `<a href>`, for link interaction regions.
    let linkAnchors: [Int: LinkAnchorInfo]

    static let empty = BrowserScrollDocument(
        displayList: .empty, contentHeight: 0, sourceText: "",
        anchorOffsets: [:], linkAnchors: [:]
    )

    /// Lays the chapter out into one unpaginated flow.
    ///
    /// The walker runs with NO fragmentainer bottom (`isContinuous`), so the
    /// paging rules never fire — scroll mode does not get a walker of its own
    /// that could drift from the paged one, and it is not handed a "tall enough"
    /// page either. The chapter's height is then whatever the placed content
    /// actually reaches, measured rather than predicted.
    static func make(
        pipeline: BrowserLayoutDocument.BrowserLayoutPipelineResult,
        contentWidth: CGFloat,
        contentInsets: UIEdgeInsets,
        writingMode: ReaderWritingMode = .horizontal
    ) -> BrowserScrollDocument {
        let canvasWidth = contentWidth + contentInsets.left + contentInsets.right
        var walker = PageWalker(
            box: pipeline.rootBox,
            pageSize: CGSize(width: canvasWidth, height: 1),
            writingMode: writingMode,
            contentInsets: contentInsets,
            isContinuous: true
        )
        var fragments: [Fragment] = []
        while let page = walker.layoutNextPage() {
            fragments.append(contentsOf: page.fragments)
        }

        let list = DisplayListBuilder.build(
            for: PageFragments(
                index: 0,
                pageRect: PageLocalRect(rawValue: CGRect(
                    x: 0, y: 0, width: canvasWidth, height: 1
                )),
                fragments: fragments
            ),
            sourceText: pipeline.sourceText
        )
        let contentBottom = list.items.reduce(CGFloat(0)) { acc, item in
            switch item {
            case .text(let t): return max(acc, t.rect.maxY)
            case .fill(let f): return max(acc, f.rect.maxY)
            case .image(let i): return max(acc, i.rect.maxY)
            }
        }
        return BrowserScrollDocument(
            displayList: list,
            contentHeight: contentBottom + contentInsets.bottom,
            sourceText: pipeline.sourceText,
            anchorOffsets: pipeline.anchorOffsets,
            linkAnchors: pipeline.linkAnchors
        )
    }

    // MARK: - Viewport queries

    /// The display items intersecting a document-space rect, with their rects
    /// translated into that rect's local space.
    ///
    /// This is the whole of "rendering" in scroll mode: no relayout, no slicing,
    /// no per-tile display list to keep in sync — a tile is a window, and this
    /// is the window's contents. Items are returned in document order so paint
    /// order (backgrounds before text) is preserved.
    func items(in documentRect: CGRect) -> DisplayList {
        var result: [DisplayItem] = []
        for item in displayList.items {
            switch item {
            case .text(let t):
                guard t.rect.rawValue.intersects(documentRect) else { continue }
                result.append(.text(DisplayTextItem(
                    sourceRange: t.sourceRange, nodeID: t.nodeID, linkTarget: t.linkTarget,
                    writingMode: t.writingMode,
                    rect: PageLocalRect(rawValue: t.rect.rawValue.offsetBy(
                        dx: -documentRect.minX, dy: -documentRect.minY
                    )),
                    baselineY: t.baselineY - documentRect.minY,
                    font: t.font, color: t.color, text: t.text, ctLine: t.ctLine
                )))
            case .fill(let f):
                guard f.rect.rawValue.intersects(documentRect) else { continue }
                result.append(.fill(DisplayFillItem(
                    rect: PageLocalRect(rawValue: f.rect.rawValue.offsetBy(
                        dx: -documentRect.minX, dy: -documentRect.minY
                    )),
                    color: f.color, cornerRadius: f.cornerRadius,
                    borderTop: f.borderTop, borderBottom: f.borderBottom,
                    borderLeft: f.borderLeft, borderRight: f.borderRight,
                    nodeID: f.nodeID, writingMode: f.writingMode
                )))
            case .image(let i):
                guard i.rect.rawValue.intersects(documentRect) else { continue }
                result.append(.image(DisplayImageItem(
                    source: i.source, image: i.image, sourceRange: i.sourceRange,
                    nodeID: i.nodeID, linkTarget: i.linkTarget, writingMode: i.writingMode,
                    rect: PageLocalRect(rawValue: i.rect.rawValue.offsetBy(
                        dx: -documentRect.minX, dy: -documentRect.minY
                    )),
                    alt: i.alt, isBackgroundPaint: i.isBackgroundPaint
                )))
            }
        }
        return DisplayList(items: result)
    }

    /// Link regions for the whole chapter, in DOCUMENT coordinates. A tile
    /// hit-tests by offsetting the touch point, so one region set serves every
    /// tile and no region is ever rebuilt per tile.
    func interactionRegions(spineIndex: Int) -> LinkInteractionRegionSet {
        LinkInteractionRegionSet.build(
            from: displayList, spineIndex: spineIndex, anchors: linkAnchors
        )
    }

    /// Document-space y of the first item at or after `charOffset` — the scroll
    /// position that shows a source offset. Restoring a reading position, a TOC
    /// jump and a link target all land here.
    func documentY(forCharOffset charOffset: Int) -> CGFloat {
        var best: CGFloat?
        for item in displayList.items {
            guard case .text(let t) = item, t.sourceRange.length > 0 else { continue }
            let end = t.sourceRange.location + t.sourceRange.length
            if t.sourceRange.location <= charOffset, charOffset < end {
                return t.rect.minY
            }
            if t.sourceRange.location >= charOffset {
                best = min(best ?? t.rect.minY, t.rect.minY)
            }
        }
        return best ?? 0
    }

    /// The source offset at a document-space y — the inverse of
    /// `documentY(forCharOffset:)`, for reporting reading progress while
    /// scrolling.
    func charOffset(atDocumentY y: CGFloat) -> Int {
        var best: (distance: CGFloat, offset: Int)?
        for item in displayList.items {
            guard case .text(let t) = item, t.sourceRange.length > 0 else { continue }
            let distance = abs(t.rect.minY - y)
            if best == nil || distance < best!.distance {
                best = (distance, t.sourceRange.location)
            }
        }
        return best?.offset ?? 0
    }
}
