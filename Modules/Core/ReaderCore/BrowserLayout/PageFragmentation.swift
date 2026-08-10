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
    /// True for a CSS `background-image` painted across the page canvas.
    ///
    /// A CSS background is PAINT, not content: in a browser it has no element,
    /// so it never hit-tests, cannot be opened, and never swallows a click.
    /// The injected canvas fragment covers the whole page, so without this flag
    /// it captured every tap on the page — the reader's page-turn/menu zones
    /// stopped firing and tapping anywhere opened a full-screen preview of the
    /// wallpaper, while real `<img>` illustrations underneath became untappable.
    let isBackgroundPaint: Bool

    init(
        source: String,
        image: UIImage?,
        sourceRange: NSRange,
        nodeID: Int,
        linkTarget: String?,
        writingMode: ReaderWritingMode,
        rect: PageLocalRect,
        documentRect: DocumentRect,
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
        self.documentRect = documentRect
        self.alt = alt
        self.isBackgroundPaint = isBackgroundPaint
    }
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
        /// The root (html/body) frame. Its background belongs to the CANVAS,
        /// not to the box — see the paint guard in `nextStep`.
        var isRoot = false
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
    /// Accumulated block-axis displacement for content not yet placed.
    ///
    /// Pagination relocates a fragment that would straddle a page boundary to
    /// the next page top, and scales a replaced element that exceeds a whole
    /// page. Both change how much block space the fragment actually consumes,
    /// so everything AFTER it in document order must move by the same amount —
    /// otherwise the relocated fragment paints over its own following content
    /// (a 627.2pt gallery image landing on the caption of its own cell) or
    /// leaves a blank page behind (flow reserved 627.2pt, page consumed 400pt).
    /// One shift for every step kind: never a per-kind nudge.
    private var flowShift: CGFloat = 0

    /// How the in-progress fragmentainer was entered — the input to the CSS
    /// Fragmentation §4.2 margin rule.
    ///
    /// - `flowStart`: the first page. Not a break, so its leading margin is
    ///   retained (a body `margin-top` still shows above the first line).
    /// - `unforcedBreak`: pagination ran out of room. The block-start margin
    ///   adjoining the break is discarded.
    /// - `forcedBreak`: an author break (`break-before`/`page-break-before`).
    ///   The margin AFTER the break is retained.
    ///
    /// The engine does not parse `break-before`/`break-after` yet, so nothing
    /// produces `forcedBreak` today. The case is modeled rather than assumed so
    /// that adding forced breaks cannot silently start eating their margins.
    private enum FragmentainerEntry {
        case flowStart
        case unforcedBreak
        case forcedBreak
    }
    private var pageEntry: FragmentainerEntry = .flowStart

    /// Block-start margin adjoining the next content to be placed: the sum of
    /// the block-start margins of the boxes entered since the last emitted
    /// fragment, seeded with the root's own (collapsed) block-start margin.
    ///
    /// Only margins are accumulated — border and padding are deliberately
    /// excluded, because only margins are discardable at a break. Where a
    /// sibling margin collapsed to the PREVIOUS box's larger block-end margin,
    /// this under-counts, which is the safe direction: it can leave a gap but
    /// never eats a box's border or padding.
    private var adjoiningBlockStartMargin: CGFloat
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
        // The root's block-start margin is the margin adjoining the first
        // content; page 0 is `flowStart`, so it is retained there.
        self.adjoiningBlockStartMargin = rootBlockStartInset
        var rootFrame = Self.makeFrame(box, contentOrigin: CGPoint(x: 0, y: rootBlockStartInset))
        rootFrame.isRoot = true
        self.stack = [rootFrame]
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
                // CSS Backgrounds §2.11.2: the ROOT element's background is
                // propagated to the canvas and the root box does NOT paint it
                // again. `BrowserLayoutDocument.bodyBackground` already hoists
                // body's colour + image to the page canvas, UNDER the wallpaper.
                // Painting it here too laid an OPAQUE `background-color: #fff`
                // band back over that wallpaper — the content-column-wide white
                // stripe across 红楼梦's 回目 title pages, sized to the body's
                // content box (which is why the correctly centred 15em dotted
                // frame sat inside a much wider white plate).
                //
                // Root BORDERS are not propagated, so those still paint below.
                if let bg = frame.box.style.backgroundColor, !frame.isRoot {
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
                // Entering a box contributes its block-start margin to the
                // margin adjoining the next content. Reset by `place`, so this
                // only ever accumulates across boxes entered back-to-back with
                // nothing emitted between them.
                adjoiningBlockStartMargin += LogicalGeometry.blockStart(edge: child.margins, mode: writingMode)
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
                        #if DEBUG
                        // Gallery pagination diagnostics (画册 regression): the
                        // real DOM chain — documentY, line box, containing box
                        // frame, sibling offset, before pagination.
                        let cell = stack[index]
                        let walkLine = "\(BrowserLayoutDeviceDiagnostic.prefix) galleryImageWalk "
                            + "docY=\(String(format: "%.2f", rect.minY)) "
                            + "lineH=\(String(format: "%.2f", line.height)) "
                            + "lineTop=\(String(format: "%.2f", line.top)) "
                            + "contentX=\(String(format: "%.2f", line.contentX)) "
                            + "runX=\(String(format: "%.2f", run.x)) "
                            + "cellFrame=\(BrowserLayoutDeviceDiagnostic.rect(cell.box.frame.rawValue, space: "parentLocal")) "
                            + "cellContentOrigin=\(cell.contentOrigin.x), \(cell.contentOrigin.y) "
                            + "parentFrame=\(stack.count > 1 ? BrowserLayoutDeviceDiagnostic.rect(stack[stack.count-2].box.frame.rawValue, space: "parentLocal") : "none") "
                            + "atomicSize=\(atomic.usedSize.width)x\(atomic.usedSize.height)"
                        BrowserLayoutDeviceDiagnostic.summary(walkLine)
                        #endif
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

    /// True when the in-progress page already carries visible content (text or
    /// an image). Box backgrounds/borders alone do not count: a body-background
    /// fill spans the whole page and would otherwise make every page look
    /// occupied.
    private var currentPageHasInk: Bool {
        func hasInk(_ fragments: [Fragment]) -> Bool {
            for fragment in fragments {
                switch fragment {
                case .text, .image: return true
                case .fill: continue
                case .group(let children): if hasInk(children) { return true }
                }
            }
            return false
        }
        return hasInk(currentPage)
    }

    private mutating func advanceToPage(_ target: Int) -> PageFragments? {
        var flushed: PageFragments? = nil
        while target > currentIndex {
            let page = PageFragments(index: currentIndex, pageRect: pageRect, fragments: currentPage)
            completedPages.append(page)
            flushed = flushed ?? page
            currentIndex += 1
            currentPage = []
            // Pagination itself ran out of room: an UNFORCED break. Author
            // breaks would set `.forcedBreak` instead, and the engine does not
            // parse them yet.
            pageEntry = .unforcedBreak
        }
        return flushed
    }

    /// CSS Fragmentation §4.2 — discards the block-start margin adjoining an
    /// UNFORCED fragmentainer break, returning the possibly-raised block
    /// position. Applies to every step kind; call once per placed step, after
    /// `advanceToPage`, so the entry kind and ink state describe the page the
    /// content actually lands on.
    ///
    /// Deliberately narrow, per the three conditions the rule depends on:
    /// - only `unforcedBreak` — `flowStart` keeps the document's leading margin
    ///   and `forcedBreak` keeps the margin the author put after the break;
    /// - only while the page carries no ink, so a page with content on it can
    ///   never have a later margin swallowed;
    /// - bounded by the margin itself AND by the distance to the fragmentainer
    ///   top, so border/padding are never eaten and content never rises above
    ///   the page top.
    private mutating func discardMarginAdjoiningBreak(_ blockStart: CGFloat, target: Int) -> CGFloat {
        let margin = adjoiningBlockStartMargin
        adjoiningBlockStartMargin = 0
        guard case .unforcedBreak = pageEntry else { return blockStart }
        guard target == currentIndex, !currentPageHasInk else { return blockStart }
        let pageTop = CGFloat(target) * pageHeight
        let discard = min(margin, blockStart - pageTop)
        guard discard > 0 else { return blockStart }
        // The discarded margin is removed from the flow, so later content moves
        // up with it — same mechanism as any other displacement.
        flowShift -= discard
        return blockStart - discard
    }

    private mutating func placeText(_ step: StepText) -> PageFragments? {
        let shiftedY = step.rect.minY + flowShift
        var target = max(0, Int(floor(shiftedY / pageHeight)))
        let pageLocalY = shiftedY - CGFloat(target) * pageHeight
        var adjustedDocY = shiftedY
        // Line boxes never split: a line that fits a page but not the
        // remaining space moves wholesale to the next page, carrying every
        // later line with it (flowShift) so the pushed line cannot overlap the
        // line that used to follow it.
        if step.rect.height <= pageHeight, pageLocalY + step.rect.height > pageHeight + 0.001 {
            target += 1
            adjustedDocY = CGFloat(target) * pageHeight
            flowShift += adjustedDocY - shiftedY
        }
        let flushed = advanceToPage(target)
        adjustedDocY = discardMarginAdjoiningBreak(adjustedDocY, target: target)
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
        var shiftedRect = step.rect.rawValue
        shiftedRect.origin.y += flowShift
        let target = max(0, Int(floor(shiftedRect.minY / pageHeight)))
        let flushed = advanceToPage(target)
        shiftedRect.origin.y = discardMarginAdjoiningBreak(shiftedRect.minY, target: target)
        let canvas = canvasRect(forDocument: DocumentRect(rawValue: shiftedRect), pageIndex: currentIndex)
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
        let shiftedY = step.rect.minY + flowShift
        var target = max(0, Int(floor(shiftedY / pageHeight)))
        let pageLocalY = shiftedY - CGFloat(target) * pageHeight
        var adjustedDocY = shiftedY
        var adjustedDocRect = step.rect.rawValue
        adjustedDocRect.origin.y = shiftedY

        // Replaced-element pagination (Phase 2C):
        // 1. Fits current page remainder → place.
        // 2. Does not fit remainder but fits a full page → move whole to next.
        // 3. Intrinsic size EXCEEDS a full page → scale to fit (aspect kept),
        //    never split into fragments.
        // Cases 2 and 3 change the block space the image consumes, so both feed
        // `flowShift` — the following content moves with the image.
        let contentWidth = max(1, pageRect.width - contentInsets.left - contentInsets.right)
        if step.rect.height <= pageHeight, pageLocalY + step.rect.height > pageHeight + 0.001 {
            // Case 2: move to next page.
            target += 1
            adjustedDocY = CGFloat(target) * pageHeight
            flowShift += adjustedDocY - shiftedY
            adjustedDocRect.origin.y = adjustedDocY
        } else if step.rect.height > pageHeight || step.rect.width > contentWidth {
            // Case 3: scale to fit the full page content area, aspect preserved.
            let scale = min(
                contentWidth / step.rect.width,
                pageHeight / step.rect.height
            )
            let newW = max(1, step.rect.width * scale)
            let newH = max(1, step.rect.height * scale)
            // Block layout reserved the UNSCALED height; the page consumes only
            // `newH`. Pull the following content up by the difference, or the
            // leftover band becomes an empty page.
            flowShift -= step.rect.height - newH
            // A scaled image that still doesn't fit the CURRENT page's
            // remainder moves to its own page (top-aligned).
            let pageBottom = CGFloat(target + 1) * pageHeight
            if adjustedDocY + newH > pageBottom + 0.001 {
                target += 1
                let movedY = CGFloat(target) * pageHeight
                flowShift += movedY - adjustedDocY
                adjustedDocY = movedY
            }
            adjustedDocRect = CGRect(
                x: step.rect.minX,
                y: adjustedDocY,
                width: newW,
                height: newH
            )
        }
        #if DEBUG
        BrowserLayoutDeviceDiagnostic.summary(
            "\(BrowserLayoutDeviceDiagnostic.prefix) galleryImagePlace "
            + "origDocY=\(String(format: "%.2f", step.rect.minY)) "
            + "adjustedDocY=\(String(format: "%.2f", adjustedDocY)) "
            + "assignedPage=\(target) "
            + "flowShift=\(String(format: "%.2f", flowShift)) "
            + "imageH=\(String(format: "%.2f", step.rect.height)) "
            + "pageH=\(String(format: "%.2f", pageHeight)) "
            + "contentW=\(String(format: "%.2f", max(1, pageRect.width - contentInsets.left - contentInsets.right)))"
        )
        #endif
        let flushed = advanceToPage(target)
        adjustedDocRect.origin.y = discardMarginAdjoiningBreak(adjustedDocY, target: target)
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
