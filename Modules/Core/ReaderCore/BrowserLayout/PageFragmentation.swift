import CoreGraphics
import CoreText
import Foundation
import UIKit

/// Page-local fragment: `rect` is PAGE CANVAS-local (viewport coordinates,
/// origin = viewport top-left). Selection/annotation additionally keeps the
/// DOCUMENT-absolute rect so ranges stay meaningful across pages/relayouts.
struct TextFragment {
    let sourceRange: NSRange
    let nodeID: Int
    let linkTarget: String?
    let writingMode: ReaderWritingMode
    /// Page canvas-local rect (Phase 2C contract: `PageLocalRect`).
    let rect: PageLocalRect
    /// Document-absolute rect (for cross-page selection mapping).
    let documentRect: DocumentRect
    let baselineY: CGFloat
    let font: UIFont
    let color: UIColor
    /// The shaped line this fragment's run belongs to (full, untrimmed line
    /// range), for precise string-index → typographic-offset mapping.
    let ctLine: CTLine?
}

/// A filled/bordered box in page canvas-local coordinates. A border box emits
/// ONE fill fragment carrying its full paint representation (background fill
/// + four edges + radius) — never a lone top line.
struct FillFragment {
    let rect: PageLocalRect
    let documentRect: DocumentRect
    let color: UIColor
    let cornerRadius: CGFloat
    /// Full four-edge border (Phase 2C: dotted must render all four sides).
    let borderTop: BorderEdge
    let borderBottom: BorderEdge
    let borderLeft: BorderEdge
    let borderRight: BorderEdge
    let nodeID: Int
    let writingMode: ReaderWritingMode
}

struct ImageFragment {
    let source: String
    let image: UIImage?
    let sourceRange: NSRange
    let nodeID: Int
    let linkTarget: String?
    let writingMode: ReaderWritingMode
    let rect: PageLocalRect
    let documentRect: DocumentRect
    let alt: String?
}

indirect enum Fragment {
    case text(TextFragment)
    case fill(FillFragment)
    case image(ImageFragment)
    case group([Fragment])
}

struct PageFragments {
    let index: Int
    /// The page canvas rect = the actual page viewport (Phase 2C).
    let pageRect: PageLocalRect
    let fragments: [Fragment]
}

/// Resumable page fragmentation. Walks the laid-out block tree with an
/// EXPLICIT stack (boxes + per-box child/line/run indices) so the walk can be
/// paused after every emitted fragment and resumed later — this is the single
/// source of truth for BOTH batch pagination (`fragment(box:pageSize:)`) and
/// incremental layout (`BrowserLayoutSession`): identical geometry by
/// construction.
///
/// Coordinate contract (Phase 2C):
/// - `Step` rects are DOCUMENT-absolute (relative to the root content origin).
/// - `place*` maps document → page canvas-local (subtract page block offset,
///   add `contentInsets`) so fragments land inside the real viewport.
/// - `PageFragments.pageRect` is the full viewport canvas, never the content
///   bounds — the canvas height never shrinks to the chapter's content height.
struct PageWalker {

    /// Document-space step emitted by `nextStep` (BEFORE paging).
    enum Step {
        case fill(StepFill)
        case text(StepText)
        case image(StepImage)
    }

    struct StepText {
        let sourceRange: NSRange
        let nodeID: Int
        let linkTarget: String?
        let writingMode: ReaderWritingMode
        let rect: DocumentRect
        let baselineY: CGFloat
        let font: UIFont
        let color: UIColor
        let ctLine: CTLine?
    }

    struct StepFill {
        let rect: DocumentRect
        let color: UIColor
        let cornerRadius: CGFloat
        let borderTop: BorderEdge
        let borderBottom: BorderEdge
        let borderLeft: BorderEdge
        let borderRight: BorderEdge
        let nodeID: Int
        let writingMode: ReaderWritingMode
    }

    struct StepImage {
        let source: String
        let image: UIImage?
        let sourceRange: NSRange
        let nodeID: Int
        let linkTarget: String?
        let writingMode: ReaderWritingMode
        let rect: DocumentRect
        let alt: String?
    }

    private struct BoxFrame {
        let box: BlockBox
        let contentOrigin: CGPoint
        let borderX: CGFloat
        let borderY: CGFloat
        var childIndex = 0
        var lineIndex = 0
        var runIndex = 0
        var fillsEmitted = false
    }

    /// Page block extent in DOCUMENT space (the content flow page height).
    let pageHeight: CGFloat
    /// The page canvas rect (full viewport).
    let pageRect: PageLocalRect
    /// Reader page margins: content sits inside these within the canvas.
    let contentInsets: UIEdgeInsets
    let writingMode: ReaderWritingMode
    private var stack: [BoxFrame] = []
    private(set) var currentIndex = 0
    private(set) var currentPage: [Fragment] = []
    private(set) var completedPages: [PageFragments] = []
    /// Defensive step budget: a corrupted box tree must never hang pagination
    /// forever. Each `nextStep` consumes one; exceeding the budget throws.
    private var stepBudget = 0
    static let maxWalkerSteps = 2_000_000

    init(
        box: BlockBox,
        pageSize: CGSize,
        writingMode: ReaderWritingMode = .horizontal,
        contentInsets: UIEdgeInsets = .zero
    ) {
        // Phase 2C: the canvas is the actual page viewport, not the content
        // bounds. pageHeight (the paging stride in document space) is the
        // content flow height inside the canvas.
        self.pageHeight = max(1, pageSize.height - contentInsets.top - contentInsets.bottom)
        self.pageRect = PageLocalRect(rawValue: CGRect(origin: .zero, size: pageSize))
        self.contentInsets = contentInsets
        self.writingMode = writingMode
        // The root box's own block-start margin (which carries any folded
        // first-child margin from `BlockLayout` margin collapsing) pushes its
        // content down — the root frame origin is fixed at (0,0).
        let rootBlockStartInset: CGFloat
        switch writingMode {
        case .horizontal: rootBlockStartInset = box.margins.top
        case .verticalRTL: rootBlockStartInset = box.margins.right
        }
        self.stack = [Self.makeFrame(box, contentOrigin: CGPoint(x: 0, y: rootBlockStartInset))]
    }

    /// Maps a document-absolute rect to page canvas-local coordinates for page
    /// `pageIndex`: subtract the page block offset, add the content insets so
    /// content lands inside the viewport margins.
    func canvasRect(forDocument doc: DocumentRect, pageIndex: Int) -> PageLocalRect {
        PageLocalRect(rawValue: CGRect(
            x: doc.minX + contentInsets.left,
            y: doc.minY - CGFloat(pageIndex) * pageHeight + contentInsets.top,
            width: doc.width,
            height: doc.height
        ))
    }

    /// Emits the next fragment step in document order, or nil when the walk
    /// is exhausted.
    mutating func nextStep() -> Step? {
        stepBudget += 1
        if stepBudget > Self.maxWalkerSteps {
            assertionFailure("PageWalker exceeded step budget \(Self.maxWalkerSteps) — corrupted box tree?")
            return nil
        }
        #if DEBUG
        if stepBudget % 100_000 == 0 {
            BrowserLayoutDeviceDiagnostic.summary("🔬 BROWSER_DEVICE walkerProgress steps=\(stepBudget) stack=\(stack.count) page=\(currentIndex) fragments=\(currentPage.count) topTag=\(stack.last?.box.debugTag ?? "-")")
        }
        #endif
        while !stack.isEmpty {
            let index = stack.count - 1
            if !stack[index].fillsEmitted {
                stack[index].fillsEmitted = true
                let frame = stack[index]
                let boxRect = DocumentRect(rawValue: CGRect(
                    x: frame.borderX, y: frame.borderY,
                    width: frame.box.frame.width, height: frame.box.frame.height
                ))
                if let bg = frame.box.style.backgroundColor {
                    return .fill(StepFill(
                        rect: boxRect,
                        color: bg,
                        cornerRadius: frame.box.style.borderRadius,
                        borderTop: Self.edge(frame.box.borders.top, frame.box.style.borderTopStyle, frame.box.style.borderColor),
                        borderBottom: Self.edge(frame.box.borders.bottom, frame.box.style.borderBottomStyle, frame.box.style.borderColor),
                        borderLeft: Self.edge(frame.box.borders.left, frame.box.style.borderLeftStyle, frame.box.style.borderColor),
                        borderRight: Self.edge(frame.box.borders.right, frame.box.style.borderRightStyle, frame.box.style.borderColor),
                        nodeID: -1,
                        writingMode: writingMode
                    ))
                }
                // A box with a border but no background still emits its full
                // bordered rect.
                let hasAnyBorder = frame.box.borders.top > 0 || frame.box.borders.bottom > 0
                    || frame.box.borders.left > 0 || frame.box.borders.right > 0
                if hasAnyBorder {
                    return .fill(StepFill(
                        rect: boxRect,
                        color: .clear,
                        cornerRadius: frame.box.style.borderRadius,
                        borderTop: Self.edge(frame.box.borders.top, frame.box.style.borderTopStyle, frame.box.style.borderColor),
                        borderBottom: Self.edge(frame.box.borders.bottom, frame.box.style.borderBottomStyle, frame.box.style.borderColor),
                        borderLeft: Self.edge(frame.box.borders.left, frame.box.style.borderLeftStyle, frame.box.style.borderColor),
                        borderRight: Self.edge(frame.box.borders.right, frame.box.style.borderRightStyle, frame.box.style.borderColor),
                        nodeID: -1,
                        writingMode: writingMode
                    ))
                }
                continue
            }
            if stack[index].childIndex < stack[index].box.children.count {
                let child = stack[index].box.children[stack[index].childIndex]
                stack[index].childIndex += 1
                let parent = stack[index]
                let childOrigin = CGPoint(
                    x: parent.contentOrigin.x + child.frame.minX + child.borders.left + child.padding.left,
                    y: parent.contentOrigin.y + child.frame.minY + child.borders.top + child.padding.top
                )
                stack.append(Self.makeFrame(child, contentOrigin: childOrigin))
                continue
            }
            if let attachment = stack[index].box.imageAttachment {
                let frame = stack[index]
                stack.removeLast()
                let rect = DocumentRect(rawValue: CGRect(
                    x: frame.contentOrigin.x,
                    y: frame.contentOrigin.y,
                    width: attachment.usedSize.width,
                    height: attachment.usedSize.height
                ))
                return .image(StepImage(
                    source: attachment.source,
                    image: attachment.image,
                    sourceRange: NSRange(location: 0, length: 0),
                    nodeID: -1,
                    linkTarget: nil,
                    writingMode: writingMode,
                    rect: rect,
                    alt: nil
                ))
            }
            if stack[index].lineIndex < stack[index].box.lines.count {
                let line = stack[index].box.lines[stack[index].lineIndex]
                if stack[index].runIndex < line.runs.count {
                    let run = line.runs[stack[index].runIndex]
                    stack[index].runIndex += 1
                    let frame = stack[index]
                    if let atomic = run.atomic {
                        let rect = DocumentRect(rawValue: CGRect(
                            x: frame.contentOrigin.x + line.contentX + run.x,
                            y: frame.contentOrigin.y + line.baseline - atomic.usedSize.height,
                            width: atomic.usedSize.width,
                            height: atomic.usedSize.height
                        ))
                        return .image(StepImage(
                            source: atomic.source,
                            image: atomic.image,
                            sourceRange: run.sourceRange,
                            nodeID: run.nodeID,
                            linkTarget: run.linkTarget,
                            writingMode: writingMode,
                            rect: rect,
                            alt: nil
                        ))
                    }
                    let rect = DocumentRect(rawValue: CGRect(
                        x: frame.contentOrigin.x + line.contentX + run.x,
                        y: frame.contentOrigin.y + line.top,
                        width: run.width,
                        height: line.height
                    ))
                    return .text(StepText(
                        sourceRange: run.sourceRange,
                        nodeID: run.nodeID,
                        linkTarget: run.linkTarget,
                        writingMode: writingMode,
                        rect: rect,
                        baselineY: frame.contentOrigin.y + line.baseline,
                        font: run.font,
                        color: run.style.color ?? .black,
                        ctLine: line.ctLine
                    ))
                }
                stack[index].lineIndex += 1
                stack[index].runIndex = 0
                continue
            }
            stack.removeLast()
        }
        return nil
    }

    private static func edge(_ width: CGFloat, _ style: BorderStyle, _ color: UIColor?) -> BorderEdge {
        BorderEdge(width: width, color: color ?? .black, style: width > 0 ? style : .none)
    }

    /// Feeds one step through the paging rules; returns a COMPLETED page when
    /// the step crosses a page boundary (or nil otherwise).
    mutating func place(_ step: Step) -> PageFragments? {
        MemoryTracker.record(.fragmentTree, bytes: 60)  // ~60B per fragment (estimate)
        switch step {
        case .fill(let frag):
            return placeFill(frag)
        case .text(let frag):
            return placeText(frag)
        case .image(let frag):
            return placeImage(frag)
        }
    }

    /// Walks until the next page completes. Returns the page, or nil when the
    /// walk is exhausted (flushing the final partial page).
    mutating func layoutNextPage() -> PageFragments? {
        while let step = nextStep() {
            if let page = place(step) { return page }
        }
        if !currentPage.isEmpty {
            let page = PageFragments(index: currentIndex, pageRect: pageRect, fragments: currentPage)
            completedPages.append(page)
            currentPage = []
            currentIndex += 1
            return page
        }
        return nil
    }

    /// Source range of the last completed page (for offset-targeted layout).
    func sourceRange(ofPage page: PageFragments, sourceText: String) -> NSRange {
        let ns = sourceText as NSString
        var minLocation = ns.length
        var maxEnd = 0
        func walk(_ fragments: [Fragment]) {
            for fragment in fragments {
                switch fragment {
                case .text(let t):
                    if t.sourceRange.length > 0 {
                        minLocation = min(minLocation, t.sourceRange.location)
                        maxEnd = max(maxEnd, t.sourceRange.location + t.sourceRange.length)
                    }
                case .group(let children): walk(children)
                default: break
                }
            }
        }
        walk(page.fragments)
        guard maxEnd > minLocation else { return NSRange(location: minLocation, length: 0) }
        return NSRange(location: minLocation, length: maxEnd - minLocation)
    }

    // MARK: - Paging rules (single source of truth with the batch path)

    private mutating func advanceToPage(_ target: Int) -> PageFragments? {
        var flushed: PageFragments? = nil
        while target > currentIndex {
            let page = PageFragments(index: currentIndex, pageRect: pageRect, fragments: currentPage)
            completedPages.append(page)
            flushed = flushed ?? page
            currentIndex += 1
            currentPage = []
        }
        return flushed
    }

    private mutating func placeText(_ step: StepText) -> PageFragments? {
        var target = max(0, Int(floor(step.rect.minY / pageHeight)))
        let pageLocalY = step.rect.minY - CGFloat(target) * pageHeight
        var adjustedDocY = step.rect.minY
        // Line boxes never split: a line that fits a page but not the
        // remaining space moves wholesale to the next page.
        if step.rect.height <= pageHeight, pageLocalY + step.rect.height > pageHeight + 0.001 {
            target += 1
            adjustedDocY = CGFloat(target) * pageHeight
        }
        let flushed = advanceToPage(target)
        let adjustedDoc = DocumentRect(rawValue: CGRect(
            x: step.rect.minX, y: adjustedDocY,
            width: step.rect.width, height: step.rect.height
        ))
        let canvas = canvasRect(forDocument: adjustedDoc, pageIndex: currentIndex)
        currentPage.append(.text(TextFragment(
            sourceRange: step.sourceRange,
            nodeID: step.nodeID,
            linkTarget: step.linkTarget,
            writingMode: step.writingMode,
            rect: canvas,
            documentRect: step.rect,
            baselineY: canvas.minY + (step.baselineY - step.rect.minY),
            font: step.font,
            color: step.color,
            ctLine: step.ctLine
        )))
        return flushed
    }

    private mutating func placeFill(_ step: StepFill) -> PageFragments? {
        let target = max(0, Int(floor(step.rect.minY / pageHeight)))
        let flushed = advanceToPage(target)
        let canvas = canvasRect(forDocument: step.rect, pageIndex: currentIndex)
        currentPage.append(.fill(FillFragment(
            rect: canvas,
            documentRect: step.rect,
            color: step.color,
            cornerRadius: step.cornerRadius,
            borderTop: step.borderTop,
            borderBottom: step.borderBottom,
            borderLeft: step.borderLeft,
            borderRight: step.borderRight,
            nodeID: step.nodeID,
            writingMode: step.writingMode
        )))
        return flushed
    }

    private mutating func placeImage(_ step: StepImage) -> PageFragments? {
        var target = max(0, Int(floor(step.rect.minY / pageHeight)))
        let pageLocalY = step.rect.minY - CGFloat(target) * pageHeight
        var adjustedDocY = step.rect.minY
        var adjustedDocRect = step.rect.rawValue

        // Replaced-element pagination (Phase 2C):
        // 1. Fits current page remainder → place.
        // 2. Does not fit remainder but fits a full page → move whole to next.
        // 3. Intrinsic size EXCEEDS a full page → scale to fit (aspect kept),
        //    never split into fragments.
        let contentWidth = max(1, pageRect.width - contentInsets.left - contentInsets.right)
        // A line box pushed above the page top (tall inline image whose top
        // strip overflows) must move to the TOP of page 0 — the image's top
        // must never be cut off by the viewport edge.
        if step.rect.minY < 0 {
            target = 0
            adjustedDocY = 0
            adjustedDocRect.origin.y = 0
        }
        if step.rect.height <= pageHeight, pageLocalY + step.rect.height > pageHeight + 0.001 {
            // Case 2: move to next page.
            target += 1
            adjustedDocY = CGFloat(target) * pageHeight
            adjustedDocRect.origin.y = adjustedDocY
        } else if step.rect.height > pageHeight || step.rect.width > contentWidth {
            // Case 3: scale to fit the full page content area, aspect preserved.
            let scale = min(
                contentWidth / step.rect.width,
                pageHeight / step.rect.height
            )
            let newW = max(1, step.rect.width * scale)
            let newH = max(1, step.rect.height * scale)
            // A scaled image that still doesn't fit the CURRENT page's
            // remainder moves to its own page (top-aligned).
            let pageBottom = CGFloat(target + 1) * pageHeight
            if adjustedDocY + newH > pageBottom + 0.001 {
                target += 1
                adjustedDocY = CGFloat(target) * pageHeight
            }
            adjustedDocRect = CGRect(
                x: step.rect.minX,
                y: adjustedDocY,
                width: newW,
                height: newH
            )
        }
        let flushed = advanceToPage(target)
        let adjustedDoc = DocumentRect(rawValue: adjustedDocRect)
        let canvas = canvasRect(forDocument: adjustedDoc, pageIndex: currentIndex)
        currentPage.append(.image(ImageFragment(
            source: step.source,
            image: step.image,
            sourceRange: step.sourceRange,
            nodeID: step.nodeID,
            linkTarget: step.linkTarget,
            writingMode: step.writingMode,
            rect: canvas,
            documentRect: step.rect,
            alt: step.alt
        )))
        return flushed
    }

    private static func makeFrame(_ box: BlockBox, contentOrigin: CGPoint) -> BoxFrame {
        BoxFrame(
            box: box,
            contentOrigin: contentOrigin,
            borderX: contentOrigin.x - box.borders.left - box.padding.left,
            borderY: contentOrigin.y - box.borders.top - box.padding.top
        )
    }
}

/// Batch pagination: runs the walker to completion. Geometry is identical to
/// incremental layout by construction (same walker).
enum PageFragmentation {

    static func fragment(
        box: BlockBox,
        pageSize: CGSize,
        writingMode: ReaderWritingMode = .horizontal,
        contentInsets: UIEdgeInsets = .zero
    ) -> [PageFragments] {
        var walker = PageWalker(
            box: box, pageSize: pageSize, writingMode: writingMode,
            contentInsets: contentInsets
        )
        while walker.layoutNextPage() != nil {}
        return walker.completedPages
    }
}
