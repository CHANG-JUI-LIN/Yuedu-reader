import CoreGraphics
import CoreText
import Foundation
import UIKit

struct TextFragment {
    let sourceRange: NSRange
    let nodeID: Int
    let linkTarget: String?
    let writingMode: ReaderWritingMode
    let rect: CGRect
    let baselineY: CGFloat
    let font: UIFont
    let color: UIColor
    /// The shaped line this fragment's run belongs to (full, untrimmed line
    /// range), for precise string-index → typographic-offset mapping.
    let ctLine: CTLine?
}

struct FillFragment {
    let rect: CGRect
    let color: UIColor
    let cornerRadius: CGFloat
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
    let rect: CGRect
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
    let pageRect: CGRect
    let fragments: [Fragment]
}

/// Resumable page fragmentation. Walks the laid-out block tree with an
/// EXPLICIT stack (boxes + per-box child/line/run indices) so the walk can be
/// paused after every emitted fragment and resumed later — this is the single
/// source of truth for BOTH batch pagination (`fragment(box:pageSize:)`) and
/// incremental layout (`BrowserLayoutSession`): identical geometry by
/// construction.
struct PageWalker {

    enum Step {
        case fill(FillFragment)
        case text(TextFragment)
        case image(ImageFragment)
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

    let pageHeight: CGFloat
    let pageRect: CGRect
    let writingMode: ReaderWritingMode
    private var stack: [BoxFrame] = []
    private(set) var currentIndex = 0
    private(set) var currentPage: [Fragment] = []
    private(set) var completedPages: [PageFragments] = []

    init(box: BlockBox, pageSize: CGSize, writingMode: ReaderWritingMode = .horizontal) {
        self.pageHeight = max(1, pageSize.height)
        self.pageRect = CGRect(origin: .zero, size: pageSize)
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

    /// Emits the next fragment step in document order, or nil when the walk
    /// is exhausted.
    mutating func nextStep() -> Step? {
        while !stack.isEmpty {
            let index = stack.count - 1
            if !stack[index].fillsEmitted {
                stack[index].fillsEmitted = true
                let frame = stack[index]
                if let bg = frame.box.style.backgroundColor {
                    return .fill(FillFragment(
                        rect: CGRect(x: frame.borderX, y: frame.borderY,
                                     width: frame.box.frame.width, height: frame.box.frame.height),
                        color: bg,
                        cornerRadius: frame.box.style.borderRadius,
                        nodeID: -1,
                        writingMode: writingMode
                    ))
                }
                if frame.box.borders.top > 0 || frame.box.borders.bottom > 0
                    || frame.box.borders.left > 0 || frame.box.borders.right > 0 {
                    let borderW = max(frame.box.borders.top, frame.box.borders.bottom,
                                      frame.box.borders.left, frame.box.borders.right)
                    return .fill(FillFragment(
                        rect: CGRect(x: frame.borderX, y: frame.borderY,
                                     width: frame.box.frame.width, height: borderW),
                        color: frame.box.style.borderColor ?? .black,
                        cornerRadius: 0,
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
                let rect = CGRect(
                    x: frame.contentOrigin.x,
                    y: frame.contentOrigin.y,
                    width: attachment.usedSize.width,
                    height: attachment.usedSize.height
                )
                return .image(ImageFragment(
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
                        let rect = CGRect(
                            x: frame.contentOrigin.x + line.contentX + run.x,
                            y: frame.contentOrigin.y + line.baseline - atomic.usedSize.height,
                            width: atomic.usedSize.width,
                            height: atomic.usedSize.height
                        )
                        return .image(ImageFragment(
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
                    let rect = CGRect(
                        x: frame.contentOrigin.x + line.contentX + run.x,
                        y: frame.contentOrigin.y + line.top,
                        width: run.width,
                        height: line.height
                    )
                    return .text(TextFragment(
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

    private mutating func placeText(_ frag: TextFragment) -> PageFragments? {
        var target = max(0, Int(floor(frag.rect.minY / pageHeight)))
        let pageLocalY = frag.rect.minY - CGFloat(target) * pageHeight
        var adjustedY = pageLocalY
        // Line boxes never split: a line that fits a page but not the
        // remaining space moves wholesale to the next page.
        if frag.rect.height <= pageHeight, pageLocalY + frag.rect.height > pageHeight + 0.001 {
            target += 1
            adjustedY = 0
        }
        let flushed = advanceToPage(target)
        let dy = adjustedY - frag.rect.minY
        currentPage.append(.text(TextFragment(
            sourceRange: frag.sourceRange,
            nodeID: frag.nodeID,
            linkTarget: frag.linkTarget,
            writingMode: frag.writingMode,
            rect: frag.rect.offsetBy(dx: 0, dy: dy),
            baselineY: frag.baselineY + dy,
            font: frag.font,
            color: frag.color,
            ctLine: frag.ctLine
        )))
        return flushed
    }

    private mutating func placeFill(_ frag: FillFragment) -> PageFragments? {
        let target = max(0, Int(floor(frag.rect.minY / pageHeight)))
        let flushed = advanceToPage(target)
        let dy = -CGFloat(currentIndex) * pageHeight
        currentPage.append(.fill(FillFragment(
            rect: frag.rect.offsetBy(dx: 0, dy: dy),
            color: frag.color,
            cornerRadius: frag.cornerRadius,
            nodeID: frag.nodeID,
            writingMode: frag.writingMode
        )))
        return flushed
    }

    private mutating func placeImage(_ frag: ImageFragment) -> PageFragments? {
        var target = max(0, Int(floor(frag.rect.minY / pageHeight)))
        let pageLocalY = frag.rect.minY - CGFloat(target) * pageHeight
        var adjustedY = pageLocalY
        // Atomic items that fit a page but not the remaining space move
        // wholesale to the next page.
        if frag.rect.height <= pageHeight, pageLocalY + frag.rect.height > pageHeight + 0.001 {
            target += 1
            adjustedY = 0
        }
        let flushed = advanceToPage(target)
        let dy = adjustedY - frag.rect.minY
        currentPage.append(.image(ImageFragment(
            source: frag.source,
            image: frag.image,
            sourceRange: frag.sourceRange,
            nodeID: frag.nodeID,
            linkTarget: frag.linkTarget,
            writingMode: frag.writingMode,
            rect: frag.rect.offsetBy(dx: 0, dy: dy),
            alt: frag.alt
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
        writingMode: ReaderWritingMode = .horizontal
    ) -> [PageFragments] {
        var walker = PageWalker(box: box, pageSize: pageSize, writingMode: writingMode)
        while walker.layoutNextPage() != nil {}
        return walker.completedPages
    }
}
