import CoreGraphics
import CoreText
import Foundation
import UIKit

enum TextSourceMapping: Equatable {
    /// Source and shaped UTF-16 coordinates advance together within the line.
    case linear(shapedRange: NSRange)
    /// The rendered text has no source span of its own and maps to the entire
    /// owning range (horizontal Ruby annotation → Ruby base).
    case wholeRange
}

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
    let sourceMapping: TextSourceMapping
    let renderedTextOverride: String?

    init(
        sourceRange: NSRange,
        nodeID: Int,
        linkTarget: String?,
        writingMode: ReaderWritingMode,
        rect: PageLocalRect,
        documentRect: DocumentRect,
        baselineY: CGFloat,
        font: UIFont,
        color: UIColor,
        ctLine: CTLine?,
        sourceMapping: TextSourceMapping? = nil,
        renderedTextOverride: String? = nil
    ) {
        self.sourceRange = sourceRange
        self.nodeID = nodeID
        self.linkTarget = linkTarget
        self.writingMode = writingMode
        self.rect = rect
        self.documentRect = documentRect
        self.baselineY = baselineY
        self.font = font
        self.color = color
        self.ctLine = ctLine
        self.sourceMapping = sourceMapping ?? .linear(shapedRange: sourceRange)
        self.renderedTextOverride = renderedTextOverride
    }
}

/// Physical position of one fragment of a CSS border box under the engine's
/// `box-decoration-break: slice` policy.
enum BlockDecorationFragmentPosition: Equatable {
    case single
    case first
    case middle
    case last
}

/// A filled/bordered box fragment in page canvas-local coordinates.
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
    let fragmentPosition: BlockDecorationFragmentPosition
    /// Walker-private identity used to replace a provisional fragment once the
    /// box end is known. It never participates in layout, paint, or hit-test.
    let decorationID: Int

    init(
        rect: PageLocalRect,
        documentRect: DocumentRect,
        color: UIColor,
        cornerRadius: CGFloat,
        borderTop: BorderEdge,
        borderBottom: BorderEdge,
        borderLeft: BorderEdge,
        borderRight: BorderEdge,
        nodeID: Int,
        writingMode: ReaderWritingMode,
        fragmentPosition: BlockDecorationFragmentPosition = .single,
        decorationID: Int = -1
    ) {
        self.rect = rect
        self.documentRect = documentRect
        self.color = color
        self.cornerRadius = cornerRadius
        self.borderTop = borderTop
        self.borderBottom = borderBottom
        self.borderLeft = borderLeft
        self.borderRight = borderRight
        self.nodeID = nodeID
        self.writingMode = writingMode
        self.fragmentPosition = fragmentPosition
        self.decorationID = decorationID
    }
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
        case floatBoundary(StepFloat)
        case fill(StepFill)
        case fillEnd(StepFillEnd)
        case text(StepText)
        case ruby(StepRuby)
        case image(StepImage)
    }

    struct StepFloat {
        let marginRect: DocumentRect
        let nodeID: Int
        let isReplaced: Bool
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
        let sourceMapping: TextSourceMapping
        let renderedTextOverride: String?
    }

    struct StepRuby {
        let placementRect: DocumentRect
        let baseBaselineY: CGFloat
        let ruby: RubyBox
        let originX: CGFloat
        let writingMode: ReaderWritingMode
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

    struct StepFillEnd {
        let nodeID: Int
        let originalEndY: CGFloat
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
        var decorationStarted = false
        var decorationEndEmitted = false
        var imageEmitted = false
        var floatBoundaryEmitted = false
        /// The root (html/body) frame. Its background belongs to the CANVAS,
        /// not to the box — see the paint guard in `nextStep`.
        var isRoot = false
    }

    /// Page block extent in DOCUMENT space (the content flow page height).
    let pageHeight: CGFloat
    /// The fragmentainer has NO bottom: the whole chapter is one continuous
    /// flow (scroll mode).
    ///
    /// Not "a page tall enough to never break". A height large enough today is
    /// still a height, and the first chapter that exceeds it silently paginates
    /// — which is exactly how this went wrong: bounding the fragmentainer by the
    /// laid-out content height was short by the root's block-start margin, so
    /// the tail of every chapter wrapped back to the top. Scroll mode has no
    /// page, so the paging rules are SKIPPED rather than given a number.
    let isContinuous: Bool
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

    /// Decorations stay active until their owning box exits. Content may add a
    /// pagination displacement after the box start, so the final block-end is
    /// only known at that exit. Earlier pages can still be finalized safely:
    /// an active slice always reaches that fragmentainer's block-end.
    private struct ActiveDecoration {
        let id: Int
        let step: StepFill
        let startY: CGFloat
    }
    private var activeDecorations: [ActiveDecoration] = []
    private var nextDecorationID = 0

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
        contentInsets: UIEdgeInsets = .zero,
        isContinuous: Bool = false
    ) {
        // Phase 2C: the canvas is the actual page viewport, not the content
        // bounds. pageHeight (the paging stride in document space) is the
        // content flow height inside the canvas.
        self.isContinuous = isContinuous
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
        // `BlockLayout` resolves the root content width after subtracting its
        // physical left/right margin, border and padding. Fragmentation must
        // place that already-resolved content box at the matching physical
        // inline origin; starting it at x=0 moved every left-side root inset
        // to the right edge instead. Reader contentInsets are added later by
        // `canvasRect`, so authored body geometry remains inside (and does not
        // replace) the reader's symmetric page viewport policy.
        let rootContentOriginX: CGFloat
        switch writingMode {
        case .horizontal:
            rootContentOriginX = box.margins.left + box.borders.left + box.padding.left
        case .verticalRTL:
            // Vertical root inline geometry is outside this horizontal
            // correctness phase; preserve its established coordinate contract.
            rootContentOriginX = 0
        }
        var rootFrame = Self.makeFrame(
            box,
            contentOrigin: CGPoint(x: rootContentOriginX, y: rootBlockStartInset)
        )
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
            if stack[index].box.isFloated, !stack[index].floatBoundaryEmitted {
                stack[index].floatBoundaryEmitted = true
                let frame = stack[index]
                let borderRect = CGRect(
                    x: frame.borderX,
                    y: frame.borderY,
                    width: frame.box.frame.width,
                    height: frame.box.frame.height
                )
                return .floatBoundary(StepFloat(
                    marginRect: DocumentRect(rawValue: CGRect(
                        x: borderRect.minX - frame.box.margins.left,
                        y: borderRect.minY - frame.box.margins.top,
                        width: borderRect.width + frame.box.margins.horizontal,
                        height: borderRect.height + frame.box.margins.vertical
                    )),
                    nodeID: frame.box.debugNodeID,
                    isReplaced: frame.box.imageAttachment != nil
                ))
            }
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
                // stripe across title pages, sized to the body's
                // content box (which is why the correctly centred 15em dotted
                // frame sat inside a much wider white plate).
                //
                // Root BORDERS are not propagated, so those still paint below.
                if let bg = frame.box.style.backgroundColor, !frame.isRoot {
                    stack[index].decorationStarted = true
                    return .fill(StepFill(
                        rect: boxRect,
                        color: bg,
                        cornerRadius: frame.box.style.borderRadius,
                        borderTop: Self.edge(frame.box.borders.top, frame.box.style.borderTopStyle, frame.box.style.borderColor),
                        borderBottom: Self.edge(frame.box.borders.bottom, frame.box.style.borderBottomStyle, frame.box.style.borderColor),
                        borderLeft: Self.edge(frame.box.borders.left, frame.box.style.borderLeftStyle, frame.box.style.borderColor),
                        borderRight: Self.edge(frame.box.borders.right, frame.box.style.borderRightStyle, frame.box.style.borderColor),
                        nodeID: frame.box.debugNodeID,
                        writingMode: writingMode
                    ))
                }
                // A box with a border but no background still emits its full
                // bordered rect.
                let hasAnyBorder = frame.box.borders.top > 0 || frame.box.borders.bottom > 0
                    || frame.box.borders.left > 0 || frame.box.borders.right > 0
                if hasAnyBorder {
                    stack[index].decorationStarted = true
                    return .fill(StepFill(
                        rect: boxRect,
                        color: .clear,
                        cornerRadius: frame.box.style.borderRadius,
                        borderTop: Self.edge(frame.box.borders.top, frame.box.style.borderTopStyle, frame.box.style.borderColor),
                        borderBottom: Self.edge(frame.box.borders.bottom, frame.box.style.borderBottomStyle, frame.box.style.borderColor),
                        borderLeft: Self.edge(frame.box.borders.left, frame.box.style.borderLeftStyle, frame.box.style.borderColor),
                        borderRight: Self.edge(frame.box.borders.right, frame.box.style.borderRightStyle, frame.box.style.borderColor),
                        nodeID: frame.box.debugNodeID,
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
            if let attachment = stack[index].box.imageAttachment,
               !stack[index].imageEmitted {
                stack[index].imageEmitted = true
                let frame = stack[index]
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
                    // A block-level replaced element has no line run, so the
                    // attachment is the ONLY carrier of its DOM identity. These
                    // were hardcoded to `-1`/`nil`, which erased the ancestor
                    // anchor of every `<a href><img style="display:block"></a>`.
                    nodeID: attachment.nodeID,
                    linkTarget: attachment.linkTarget,
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
                    if let ruby = run.ruby {
                        return .ruby(StepRuby(
                            placementRect: DocumentRect(rawValue: CGRect(
                                x: frame.contentOrigin.x + line.contentX + run.x,
                                y: frame.contentOrigin.y + line.top,
                                width: run.width,
                                height: line.height
                            )),
                            baseBaselineY: frame.contentOrigin.y + line.baseline,
                            ruby: ruby,
                            originX: frame.contentOrigin.x + line.contentX + run.x,
                            writingMode: writingMode
                        ))
                    }
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
                        ctLine: line.ctLine,
                        sourceMapping: .linear(shapedRange: run.shapedRange ?? run.sourceRange),
                        renderedTextOverride: nil
                    ))
                }
                stack[index].lineIndex += 1
                stack[index].runIndex = 0
                continue
            }
            if stack[index].decorationStarted, !stack[index].decorationEndEmitted {
                stack[index].decorationEndEmitted = true
                let frame = stack[index]
                return .fillEnd(StepFillEnd(
                    nodeID: frame.box.debugNodeID,
                    originalEndY: frame.borderY + frame.box.frame.height
                ))
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
        // Fragment bytes are accounted by `BrowserChapterLayout`
        // (`refreshFragmentBytes`), which counts the finished pages and is the
        // only place that can release them again on eviction. Recording here as
        // well double-counted every fragment, and since eviction releases only
        // the layout's own figure, the second copy stayed on the tracker
        // forever — a chapter laid out and evicted leaked fragmentCount * 60
        // bytes of *accounting*, which is exactly the monotonic growth
        // MemoryTracker exists to disprove. One owner per artifact type.
        switch step {
        case .floatBoundary(let marker):
            return placeFloatBoundary(marker)
        case .fill(let frag):
            return placeFill(frag)
        case .fillEnd(let end):
            return placeFillEnd(end)
        case .text(let frag):
            return placeText(frag)
        case .ruby(let ruby):
            return placeRuby(ruby)
        case .image(let frag):
            return placeImage(frag)
        }
    }

    /// A float that fits a full fragmentainer is atomic. The structural marker
    /// is emitted before any of the float's paint/content, so one flowShift
    /// relocates the complete float and every following sibling together.
    /// Oversized replaced floats stay on the generic image scale-to-fit path;
    /// non-replaced oversized/complex floats are rejected by the scanner.
    private mutating func placeFloatBoundary(_ step: StepFloat) -> PageFragments? {
        guard !isContinuous else { return nil }

        let shiftedY = step.marginRect.minY + flowShift
        var target = max(0, Int(floor(shiftedY / pageHeight)))
        let pageLocalY = shiftedY - CGFloat(target) * pageHeight
        if step.marginRect.height <= pageHeight,
           pageLocalY + step.marginRect.height > pageHeight + 0.001 {
            target += 1
            let movedY = CGFloat(target) * pageHeight
            flowShift += movedY - shiftedY
        }
        return advanceToPage(target)
    }

    /// Walks until the next page completes. Returns the page, or nil when the
    /// walk is exhausted (flushing the final partial page).
    mutating func layoutNextPage() -> PageFragments? {
        while let step = nextStep() {
            if let page = place(step) { return page }
        }
        if !currentPage.isEmpty {
            finalizeActiveDecorationsForCurrentPage()
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
            finalizeActiveDecorationsForCurrentPage()
            let page = PageFragments(index: currentIndex, pageRect: pageRect, fragments: currentPage)
            completedPages.append(page)
            flushed = flushed ?? page
            currentIndex += 1
            currentPage = []
            appendActiveDecorationFragmentsForCurrentPage()
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
        if isContinuous {
            // No break can occur, so nothing is ever relocated and `flowShift`
            // stays zero: the document position IS the final position.
            let canvas = canvasRect(forDocument: step.rect, pageIndex: 0)
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
                ctLine: step.ctLine,
                sourceMapping: step.sourceMapping,
                renderedTextOverride: step.renderedTextOverride
            )))
            return nil
        }
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
            ctLine: step.ctLine,
            sourceMapping: step.sourceMapping,
            renderedTextOverride: step.renderedTextOverride
        )))
        return flushed
    }

    private mutating func placeRuby(_ step: StepRuby) -> PageFragments? {
        if isContinuous {
            currentPage.append(makeRubyGroup(step, displacementY: 0, pageIndex: 0))
            return nil
        }

        let shiftedY = step.placementRect.minY + flowShift
        var target = max(0, Int(floor(shiftedY / pageHeight)))
        let pageLocalY = shiftedY - CGFloat(target) * pageHeight
        var adjustedDocY = shiftedY
        if step.placementRect.height <= pageHeight,
           pageLocalY + step.placementRect.height > pageHeight + 0.001 {
            target += 1
            adjustedDocY = CGFloat(target) * pageHeight
            flowShift += adjustedDocY - shiftedY
        }
        let flushed = advanceToPage(target)
        adjustedDocY = discardMarginAdjoiningBreak(adjustedDocY, target: target)
        currentPage.append(makeRubyGroup(
            step,
            displacementY: adjustedDocY - step.placementRect.minY,
            pageIndex: currentIndex
        ))
        return flushed
    }

    private func makeRubyGroup(
        _ step: StepRuby,
        displacementY: CGFloat,
        pageIndex: Int
    ) -> Fragment {
        let ruby = step.ruby
        let baseBaseline = step.baseBaselineY + displacementY
        var children: [Fragment] = ruby.base.pieces.map { piece in
            let document = DocumentRect(rawValue: CGRect(
                x: step.originX + ruby.baseOffsetX + piece.x,
                y: baseBaseline - ruby.base.ascent,
                width: piece.width,
                height: ruby.base.ascent + ruby.base.descent
            ))
            let canvas = canvasRect(forDocument: document, pageIndex: pageIndex)
            return .text(TextFragment(
                sourceRange: piece.sourceRange,
                nodeID: piece.nodeID,
                linkTarget: piece.linkTarget,
                writingMode: step.writingMode,
                rect: canvas,
                documentRect: document,
                baselineY: canvas.minY + ruby.base.ascent,
                font: piece.font,
                color: piece.style.color ?? .black,
                ctLine: ruby.base.line,
                sourceMapping: .linear(shapedRange: piece.shapedRange),
                renderedTextOverride: nil
            ))
        }

        let annotationBaseline = baseBaseline + ruby.annotationBaselineOffset
        children.append(contentsOf: ruby.annotation.pieces.map { piece in
            let document = DocumentRect(rawValue: CGRect(
                x: step.originX + ruby.annotationOffsetX + piece.x,
                y: annotationBaseline - ruby.annotation.ascent,
                width: piece.width,
                height: ruby.annotation.ascent + ruby.annotation.descent
            ))
            let canvas = canvasRect(forDocument: document, pageIndex: pageIndex)
            return .text(TextFragment(
                sourceRange: ruby.unit.sourceRange,
                nodeID: piece.nodeID,
                linkTarget: piece.linkTarget ?? ruby.unit.linkTarget,
                writingMode: step.writingMode,
                rect: canvas,
                documentRect: document,
                baselineY: canvas.minY + ruby.annotation.ascent,
                font: piece.font,
                color: piece.style.color ?? .black,
                ctLine: ruby.annotation.line,
                sourceMapping: .wholeRange,
                renderedTextOverride: piece.text
            ))
        })
        return .group(children)
    }

    private mutating func placeFill(_ step: StepFill) -> PageFragments? {
        if isContinuous {
            currentPage.append(.fill(FillFragment(
                rect: canvasRect(forDocument: step.rect, pageIndex: 0),
                documentRect: step.rect,
                color: step.color,
                cornerRadius: step.cornerRadius,
                borderTop: step.borderTop, borderBottom: step.borderBottom,
                borderLeft: step.borderLeft, borderRight: step.borderRight,
                nodeID: step.nodeID,
                writingMode: step.writingMode
            )))
            return nil
        }
        let shiftedStartY = step.rect.minY + flowShift
        let target = max(0, Int(floor(shiftedStartY / pageHeight)))
        let flushed = advanceToPage(target)
        let adjustedStartY = discardMarginAdjoiningBreak(shiftedStartY, target: target)
        let decoration = ActiveDecoration(
            id: nextDecorationID,
            step: step,
            startY: adjustedStartY
        )
        nextDecorationID += 1
        activeDecorations.append(decoration)
        upsertDecorationFragment(
            decoration,
            endY: step.rect.maxY + flowShift,
            isFinal: false,
            pageIndex: currentIndex
        )
        return flushed
    }

    private mutating func placeFillEnd(_ step: StepFillEnd) -> PageFragments? {
        guard !isContinuous else { return nil }
        let decorations = activeDecorations.filter { $0.step.nodeID == step.nodeID }
        guard !decorations.isEmpty else {
            return nil
        }
        let finalEndY = max(
            decorations.map(\.startY).max() ?? 0,
            step.originalEndY + flowShift
        )
        let finalPage = max(0, Int(floor((finalEndY - 0.001) / pageHeight)))
        let flushed = advanceToPage(finalPage)
        for decoration in decorations {
            upsertDecorationFragment(
                decoration,
                endY: max(decoration.startY, finalEndY),
                isFinal: true,
                pageIndex: currentIndex
            )
        }
        activeDecorations.removeAll { $0.step.nodeID == step.nodeID }
        return flushed
    }

    /// Finalizes the open slices on a page that is about to be emitted. Their
    /// owning boxes have not ended, therefore each slice reaches the page's
    /// block-end and cannot carry a block-end border or lower corner radius.
    private mutating func finalizeActiveDecorationsForCurrentPage() {
        let pageEnd = CGFloat(currentIndex + 1) * pageHeight
        for decoration in activeDecorations {
            upsertDecorationFragment(
                decoration,
                endY: pageEnd,
                isFinal: false,
                pageIndex: currentIndex
            )
        }
    }

    /// A continuation decoration paints before the continued descendants on a
    /// new fragmentainer. Active decorations are kept in ancestor/start order,
    /// preserving the same background stacking as the document walk.
    private mutating func appendActiveDecorationFragmentsForCurrentPage() {
        let provisionalEnd = CGFloat(currentIndex + 1) * pageHeight
        for decoration in activeDecorations {
            upsertDecorationFragment(
                decoration,
                endY: provisionalEnd,
                isFinal: false,
                pageIndex: currentIndex
            )
        }
    }

    private mutating func upsertDecorationFragment(
        _ decoration: ActiveDecoration,
        endY: CGFloat,
        isFinal: Bool,
        pageIndex: Int
    ) {
        guard pageIndex == currentIndex,
              let fragment = makeDecorationFragment(
                decoration,
                endY: endY,
                isFinal: isFinal,
                pageIndex: pageIndex
              ) else { return }

        if let existing = currentPage.lastIndex(where: { item in
            guard case .fill(let fill) = item else { return false }
            return fill.decorationID == decoration.id
        }) {
            currentPage[existing] = .fill(fragment)
        } else {
            currentPage.append(.fill(fragment))
        }
    }

    private func makeDecorationFragment(
        _ decoration: ActiveDecoration,
        endY: CGFloat,
        isFinal: Bool,
        pageIndex: Int
    ) -> FillFragment? {
        let pageStart = CGFloat(pageIndex) * pageHeight
        let pageEnd = pageStart + pageHeight
        let fragmentStart = max(decoration.startY, pageStart)
        let fragmentEnd = min(max(endY, fragmentStart), pageEnd)
        guard fragmentEnd - fragmentStart > 0.0001 else { return nil }

        let firstPage = max(0, Int(floor(decoration.startY / pageHeight)))
        let isFirst = pageIndex == firstPage
        let isLast = isFinal && endY <= pageEnd + 0.001
        let position: BlockDecorationFragmentPosition
        switch (isFirst, isLast) {
        case (true, true): position = .single
        case (true, false): position = .first
        case (false, true): position = .last
        case (false, false): position = .middle
        }

        let document = DocumentRect(rawValue: CGRect(
            x: decoration.step.rect.minX,
            y: fragmentStart,
            width: decoration.step.rect.width,
            height: fragmentEnd - fragmentStart
        ))
        return FillFragment(
            rect: canvasRect(forDocument: document, pageIndex: pageIndex),
            documentRect: document,
            color: decoration.step.color,
            cornerRadius: decoration.step.cornerRadius,
            borderTop: isFirst ? decoration.step.borderTop : .zero,
            borderBottom: isLast ? decoration.step.borderBottom : .zero,
            borderLeft: decoration.step.borderLeft,
            borderRight: decoration.step.borderRight,
            nodeID: decoration.step.nodeID,
            writingMode: decoration.step.writingMode,
            fragmentPosition: position,
            decorationID: decoration.id
        )
    }

    private mutating func placeImage(_ step: StepImage) -> PageFragments? {
        if isContinuous {
            // Deliberately NO scale-to-fit here. The three replaced-element
            // rules below all exist to make an image fit a PAGE; with no page
            // there is nothing to fit it to, and block layout already resolved
            // the used size against the container width. An image that still
            // overflows overflows — which is what a browser does too.
            currentPage.append(.image(ImageFragment(
                source: step.source,
                image: step.image,
                sourceRange: step.sourceRange,
                nodeID: step.nodeID,
                linkTarget: step.linkTarget,
                writingMode: step.writingMode,
                rect: canvasRect(forDocument: step.rect, pageIndex: 0),
                documentRect: step.rect,
                alt: step.alt
            )))
            return nil
        }
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
