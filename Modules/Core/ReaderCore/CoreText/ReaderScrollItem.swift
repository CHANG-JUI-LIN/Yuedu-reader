import YueduCoreText
import CoreText
import UIKit

protocol ScrollFragmentMeasuring {
    var chapterIndex: Int { get }
    var charRange: CFRange { get }
}

extension CoreTextChunk: ScrollFragmentMeasuring {}

/// A Browser paint tile and a Legacy layout chunk remain distinct owners.
/// The collection's ordering/geometry contract does not depend on either layout engine.
enum ReaderScrollItem: ScrollFragmentMeasuring {
    case legacy(CoreTextChunk)
    case browser(BrowserScrollTile)

    var legacyChunk: CoreTextChunk? { if case .legacy(let chunk) = self { return chunk }; return nil }
    var chapterIndex: Int { switch self { case .legacy(let c): c.chapterIndex; case .browser(let t): t.chapter.spineIndex } }
    var charRange: CFRange { switch self { case .legacy(let c): c.charRange; case .browser(let t): t.charRange } }
    var height: CGFloat { switch self { case .legacy(let c): c.height; case .browser(let t): t.documentRect.height } }
    var width: CGFloat { switch self { case .legacy(let c): c.width; case .browser(let t): t.documentRect.width } }
    var attributedString: NSAttributedString { switch self { case .legacy(let c): c.attributedString; case .browser(let t): t.chapter.attributedString } }
    var writingMode: ReaderWritingMode {
        switch self { case .legacy(let c): c.writingMode; case .browser(let t): t.chapter.writingMode }
    }
    var isMaterialized: Bool { legacyChunk?.isMaterialized ?? true }
    var isImageOnly: Bool { legacyChunk?.isImageOnly ?? false }
    var frame: CTFrame? { legacyChunk?.frame }
    var attachments: [CoreTextPaginator.RenderedAttachment] { legacyChunk?.attachments ?? [] }
    var blockRenderables: [CoreTextPaginator.RenderedBlockRenderable] { legacyChunk?.blockRenderables ?? [] }
    var pageBackgroundColor: UIColor? { legacyChunk?.pageBackgroundColor }
    var pageBackgroundImage: UIImage? { legacyChunk?.pageBackgroundImage }
    func materializeFrameIfNeeded() { legacyChunk?.materializeFrameIfNeeded() }
    func buildFrameData() -> CoreTextChunk.BuiltFrame? { legacyChunk?.buildFrameData() }
    func applyBuiltFrame(_ frame: CoreTextChunk.BuiltFrame) { legacyChunk?.applyBuiltFrame(frame) }
    func evictFrame() { legacyChunk?.evictFrame() }
    func topOffset(forCharacterIndex offset: Int) -> CGFloat? {
        switch self {
        case .legacy(let c): return c.topOffset(forCharacterIndex: offset)
        case .browser(let t):
            guard !t.chapter.writingMode.isVertical else { return nil }
            return offset <= 0 ? 0 : max(0, t.chapter.document.documentY(forCharOffset: offset) - t.documentRect.minY)
        }
    }
    func stringIndex(atLocalPoint point: CGPoint) -> Int? {
        switch self {
        case .legacy(let c): return c.stringIndex(atLocalPoint: point)
        case .browser(let t):
            let documentPoint = CGPoint(x: point.x + t.documentRect.minX, y: point.y + t.documentRect.minY)
            if t.chapter.document.sourceText.isEmpty { return 0 }
            for item in t.chapter.document.displayList.items {
                if case .image(let image) = item, !image.isBackgroundPaint,
                   image.rect.rawValue.contains(documentPoint) { return image.sourceRange.location }
            }
            return BrowserTextGeometry.range(at: documentPoint,
                in: t.chapter.document.displayList, source: t.chapter.document.sourceText as NSString, nearest: true)?.location
        }
    }
}

final class BrowserScrollChapter {
    let spineIndex: Int
    let document: BrowserScrollDocument
    let writingMode: ReaderWritingMode
    let attributedString: NSAttributedString
    let backgroundColor: UIColor
    let usesReaderBackground: Bool
    let paragraphRanges: [NSRange]
    let mediaAttachments: [Int: EPUBMediaAttachment]
    init(spineIndex: Int, document: BrowserScrollDocument, writingMode: ReaderWritingMode = .horizontal, backgroundColor: UIColor, usesReaderBackground: Bool, paragraphRanges: [NSRange] = [], mediaAttachments: [Int: EPUBMediaAttachment] = [:]) {
        self.paragraphRanges = paragraphRanges
        self.mediaAttachments = mediaAttachments
        self.spineIndex = spineIndex
        self.document = document
        self.writingMode = writingMode
        self.backgroundColor = backgroundColor
        self.usesReaderBackground = usesReaderBackground
        attributedString = NSAttributedString(string: document.sourceText)
    }

    func tiles(width: CGFloat, heightCap: CGFloat = 2000) -> [ReaderScrollItem] {
        var tiles: [ReaderScrollItem] = []
        // Collection order is reading order: vertical-rl starts at the document's
        // right edge. Tiles are paint windows, never separately laid-out pages.
        let extent = writingMode.isVertical ? document.contentWidth : document.contentHeight
        let cap = max(1, heightCap)
        var advance: CGFloat = 0
        while advance < extent {
            let length = min(cap, extent - advance)
            let rect = writingMode.isVertical
                ? CGRect(x: extent - advance - length, y: 0, width: length, height: document.contentHeight)
                : CGRect(x: 0, y: advance, width: width, height: length)
            let list = document.items(in: rect)
            let ranges: [NSRange] = list.items.compactMap {
                switch $0 {
                case .text(let text): return text.sourceRange
                case .image(let image): return image.isBackgroundPaint ? nil : image.sourceRange
                case .fill: return nil
                }
            }.filter { $0.length > 0 }
            let start = ranges.map(\.location).min() ?? (writingMode.isVertical ? ((document.sourceText as NSString).length) : document.charOffset(atDocumentY: advance))
            let end = ranges.map { NSMaxRange($0) }.max() ?? start
            tiles.append(.browser(BrowserScrollTile(chapter: self, documentRect: rect,
                charRange: CFRange(location: start, length: end - start))))
            advance += length
        }
        return tiles
    }
}

struct BrowserScrollTile {
    let chapter: BrowserScrollChapter
    let documentRect: CGRect
    let charRange: CFRange
}
