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
    var writingMode: ReaderWritingMode { legacyChunk?.writingMode ?? .horizontal }
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
        case .browser(let t): return offset <= 0 ? 0 : max(0, t.chapter.document.documentY(forCharOffset: offset) - t.documentRect.minY)
        }
    }
    func stringIndex(atLocalPoint point: CGPoint) -> Int? {
        switch self {
        case .legacy(let c): return c.stringIndex(atLocalPoint: point)
        case .browser(let t):
            let documentPoint = CGPoint(x: point.x, y: point.y + t.documentRect.minY)
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
    let attributedString: NSAttributedString
    let backgroundColor: UIColor
    let usesReaderBackground: Bool
    let paragraphRanges: [NSRange]
    let mediaAttachments: [Int: EPUBMediaAttachment]
    init(spineIndex: Int, document: BrowserScrollDocument, backgroundColor: UIColor, usesReaderBackground: Bool, paragraphRanges: [NSRange] = [], mediaAttachments: [Int: EPUBMediaAttachment] = [:]) {
        self.paragraphRanges = paragraphRanges
        self.mediaAttachments = mediaAttachments
        self.spineIndex = spineIndex
        self.document = document
        self.backgroundColor = backgroundColor
        self.usesReaderBackground = usesReaderBackground
        attributedString = NSAttributedString(string: document.sourceText)
    }

    func tiles(width: CGFloat, heightCap: CGFloat = 2000) -> [ReaderScrollItem] {
        var tiles: [ReaderScrollItem] = []
        var y: CGFloat = 0
        while y < document.contentHeight {
            let rect = CGRect(x: 0, y: y, width: width, height: min(heightCap, document.contentHeight - y))
            let list = document.items(in: rect)
            let ranges: [NSRange] = list.items.compactMap {
                switch $0 {
                case .text(let text): return text.sourceRange
                case .image(let image): return image.isBackgroundPaint ? nil : image.sourceRange
                case .fill: return nil
                }
            }.filter { $0.length > 0 }
            let start = ranges.map(\.location).min() ?? document.charOffset(atDocumentY: y)
            let end = ranges.map { NSMaxRange($0) }.max() ?? start
            tiles.append(.browser(BrowserScrollTile(chapter: self, documentRect: rect,
                charRange: CFRange(location: start, length: end - start))))
            y = rect.maxY
        }
        return tiles
    }
}

struct BrowserScrollTile {
    let chapter: BrowserScrollChapter
    let documentRect: CGRect
    let charRange: CFRange
}
