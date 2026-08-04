import CoreGraphics
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

/// Phase-1.5 page fragmentation: walks the laid-out block tree and pages every
/// fragment by its ABSOLUTE Y coordinate. Blocks are split at line boundaries;
/// atomic items (images) move wholesale to the next page when they do not fit.
/// No orphan/widow rules yet. Fills do not split across pages (accepted Phase 1).
enum PageFragmentation {

    struct Fragmenter {
        let pageHeight: CGFloat
        let pageRect: CGRect
        var currentIndex = 0
        var pageItems: [Fragment] = []
        var pages: [PageFragments] = []

        var pageOriginY: CGFloat { CGFloat(currentIndex) * pageHeight }

        /// Pushes completed pages until `target` becomes the current page.
        mutating func advanceToPage(_ target: Int) {
            while target > currentIndex {
                pages.append(PageFragments(index: currentIndex, pageRect: pageRect, fragments: pageItems))
                currentIndex += 1
                pageItems = []
            }
        }

        mutating func placeText(_ frag: TextFragment) {
            let target = max(0, Int(floor(frag.rect.minY / pageHeight)))
            advanceToPage(target)
            let dy = -pageOriginY
            pageItems.append(.text(TextFragment(
                sourceRange: frag.sourceRange,
                nodeID: frag.nodeID,
                linkTarget: frag.linkTarget,
                writingMode: frag.writingMode,
                rect: frag.rect.offsetBy(dx: 0, dy: dy),
                baselineY: frag.baselineY + dy,
                font: frag.font,
                color: frag.color
            )))
        }

        mutating func placeFill(_ frag: FillFragment) {
            let target = max(0, Int(floor(frag.rect.minY / pageHeight)))
            advanceToPage(target)
            let dy = -pageOriginY
            pageItems.append(.fill(FillFragment(
                rect: frag.rect.offsetBy(dx: 0, dy: dy),
                color: frag.color,
                cornerRadius: frag.cornerRadius,
                nodeID: frag.nodeID,
                writingMode: frag.writingMode
            )))
        }

        mutating func placeImage(_ frag: ImageFragment) {
            let target = max(0, Int(floor(frag.rect.minY / pageHeight)))
            advanceToPage(target)
            let dy = -pageOriginY
            pageItems.append(.image(ImageFragment(
                source: frag.source,
                image: frag.image,
                sourceRange: frag.sourceRange,
                nodeID: frag.nodeID,
                linkTarget: frag.linkTarget,
                writingMode: frag.writingMode,
                rect: frag.rect.offsetBy(dx: 0, dy: dy),
                alt: frag.alt
            )))
        }
    }

    static func fragment(
        box: BlockBox,
        pageSize: CGSize,
        writingMode: ReaderWritingMode = .horizontal
    ) -> [PageFragments] {
        var frag = Fragmenter(
            pageHeight: max(1, pageSize.height),
            pageRect: CGRect(origin: .zero, size: pageSize)
        )
        walk(box: box, contentOrigin: ContentOffset(x: 0, y: 0), fragmenter: &frag, writingMode: writingMode)
        if !frag.pageItems.isEmpty {
            frag.pages.append(PageFragments(index: frag.currentIndex, pageRect: frag.pageRect, fragments: frag.pageItems))
        }
        return frag.pages
    }

    private struct ContentOffset {
        var x: CGFloat
        var y: CGFloat
    }

    /// `contentOrigin` = absolute position of THIS box's content-box top-left.
    private static func walk(
        box: BlockBox,
        contentOrigin: ContentOffset,
        fragmenter: inout Fragmenter,
        writingMode: ReaderWritingMode
    ) {
        // Border-box rect in absolute coordinates.
        let borderX = contentOrigin.x - box.borders.left - box.padding.left
        let borderY = contentOrigin.y - box.borders.top - box.padding.top

        if let bg = box.style.backgroundColor {
            fragmenter.placeFill(FillFragment(
                rect: CGRect(x: borderX, y: borderY, width: box.frame.width, height: box.frame.height),
                color: bg,
                cornerRadius: box.style.borderRadius,
                nodeID: -1,
                writingMode: writingMode
            ))
        }
        if box.borders.top > 0 || box.borders.bottom > 0 || box.borders.left > 0 || box.borders.right > 0 {
            let borderW = max(box.borders.top, box.borders.bottom, box.borders.left, box.borders.right)
            fragmenter.placeFill(FillFragment(
                rect: CGRect(x: borderX, y: borderY, width: box.frame.width, height: borderW),
                color: box.style.borderColor ?? .black,
                cornerRadius: 0,
                nodeID: -1,
                writingMode: writingMode
            ))
        }

        for child in box.children {
            let childContent = ContentOffset(
                x: contentOrigin.x + child.frame.minX + child.borders.left + child.padding.left,
                y: contentOrigin.y + child.frame.minY + child.borders.top + child.padding.top
            )
            walk(box: child, contentOrigin: childContent, fragmenter: &fragmenter, writingMode: writingMode)
        }

        if let attachment = box.imageAttachment {
            let rect = CGRect(
                x: contentOrigin.x,
                y: contentOrigin.y,
                width: attachment.usedSize.width,
                height: attachment.usedSize.height
            )
            fragmenter.placeImage(ImageFragment(
                source: attachment.source,
                image: attachment.image,
                sourceRange: NSRange(location: 0, length: 0),
                nodeID: -1,
                linkTarget: nil,
                writingMode: writingMode,
                rect: rect,
                alt: nil
            ))
            return
        }

        for line in box.lines {
            let lineHeight = line.height
            for run in line.runs {
                if let atomic = run.atomic {
                    // Inline replaced element: baseline-aligned bottom edge.
                    let rect = CGRect(
                        x: contentOrigin.x + line.contentX + run.x,
                        y: contentOrigin.y + line.baseline - atomic.usedSize.height,
                        width: atomic.usedSize.width,
                        height: atomic.usedSize.height
                    )
                    fragmenter.placeImage(ImageFragment(
                        source: atomic.source,
                        image: atomic.image,
                        sourceRange: run.sourceRange,
                        nodeID: run.nodeID,
                        linkTarget: run.linkTarget,
                        writingMode: writingMode,
                        rect: rect,
                        alt: nil
                    ))
                    continue
                }
                let rect = CGRect(
                    x: contentOrigin.x + line.contentX + run.x,
                    y: contentOrigin.y + line.top,
                    width: run.width,
                    height: lineHeight
                )
                fragmenter.placeText(TextFragment(
                    sourceRange: run.sourceRange,
                    nodeID: run.nodeID,
                    linkTarget: run.linkTarget,
                    writingMode: writingMode,
                    rect: rect,
                    baselineY: contentOrigin.y + line.baseline,
                    font: run.font,
                    color: run.style.color ?? .black
                ))
            }
        }
    }
}
