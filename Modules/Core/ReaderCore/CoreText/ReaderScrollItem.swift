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
    func applyBuiltFrame(_ frame: CoreTextChunk.BuiltFrame) { legacyChunk?.applyBuiltFrame(frame) }
    func evictFrame() { legacyChunk?.evictFrame() }
    func topOffset(forCharacterIndex offset: Int) -> CGFloat? {
        switch self {
        case .legacy(let c): return c.topOffset(forCharacterIndex: offset)
        case .browser(let t):
            guard !t.chapter.writingMode.isVertical else { return nil }
            return offset <= 0 ? 0 : max(0, t.chapter.documentY(for: offset) - t.documentRect.minY)
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

/// One chapter on the browser engine.
///
/// A vertical-writing chapter carries its final, fully laid-out document. A
/// viewport-driven chapter lays out on its `layoutOwner`'s thread: the scroll
/// host asks for regions with `requestViewport` and keeps scrolling with the
/// snapshot it has; each laid-out snapshot comes back through `onSnapshot`, and
/// the host installs it with `apply` inside its geometry transaction.
final class BrowserScrollChapter {
    let spineIndex: Int
    private(set) var document: BrowserScrollDocument
    /// Lays this chapter out off the main thread; nil for a final document.
    let layoutOwner: BrowserViewportLayoutOwner?
    /// The committed geometry of a viewport-driven chapter.
    private(set) var snapshot: BrowserViewportSnapshot?
    private(set) var layoutRevision: UInt64 = 0
    let writingMode: ReaderWritingMode
    let attributedString: NSAttributedString
    let backgroundColor: UIColor
    let usesReaderBackground: Bool
    let paragraphRanges: [NSRange]
    let mediaAttachments: [Int: EPUBMediaAttachment]
    /// The html/body background's image, decoded for display. The host draws the
    /// page background behind the chapter; the chapter's documents leave it out.
    let pageBackgroundImage: UIImage?
    /// Each snapshot the layout thread publishes, on the main actor. The scroll
    /// engine installs this so the host can read the visible anchor before the
    /// geometry changes; without it a snapshot is applied as it arrives.
    var onSnapshot: ((BrowserViewportSnapshot) -> Void)?

    private enum Request {
        case layout(CGRect, anchorOffset: Int?)
        case discard
    }
    /// One request at a time; while it runs, only the latest next one is kept.
    private var inFlight: Task<Void, Never>?
    private var inFlightRequest: Request?
    private var pending: Request?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(spineIndex: Int, document: BrowserScrollDocument, writingMode: ReaderWritingMode = .horizontal, backgroundColor: UIColor, usesReaderBackground: Bool, paragraphRanges: [NSRange] = [], mediaAttachments: [Int: EPUBMediaAttachment] = [:]) {
        self.paragraphRanges = paragraphRanges
        self.mediaAttachments = mediaAttachments
        self.spineIndex = spineIndex
        self.document = document
        self.writingMode = writingMode
        self.backgroundColor = backgroundColor
        self.usesReaderBackground = usesReaderBackground
        layoutOwner = nil
        pageBackgroundImage = nil
        attributedString = NSAttributedString(string: document.sourceText)
    }

    /// A viewport-driven chapter, starting from the snapshot its owner published.
    init(spineIndex: Int, layoutOwner: BrowserViewportLayoutOwner, snapshot: BrowserViewportSnapshot,
         backgroundColor: UIColor, usesReaderBackground: Bool, pageBackgroundImage: UIImage? = nil,
         mediaAttachments: [Int: EPUBMediaAttachment] = [:]) {
        self.spineIndex = spineIndex
        self.layoutOwner = layoutOwner
        self.snapshot = snapshot
        document = snapshot.document
        writingMode = .horizontal
        self.backgroundColor = backgroundColor
        self.usesReaderBackground = usesReaderBackground
        self.pageBackgroundImage = pageBackgroundImage
        paragraphRanges = layoutOwner.facts.paragraphRanges
        self.mediaAttachments = mediaAttachments
        attributedString = NSAttributedString(string: layoutOwner.facts.sourceText)
    }

    deinit { inFlight?.cancel() }

    var isViewportDriven: Bool { layoutOwner != nil }
    var facts: BrowserViewportChapterFacts? { layoutOwner?.facts }
    /// What the host paints behind a viewport-driven chapter; nil when the
    /// reader's own background image replaces the publication's.
    var pageBackground: BrowserPageBackground? { usesReaderBackground ? nil : facts?.pageBackground }
    /// Laid-out region of the committed snapshot; `.null` when nothing is.
    var materializedBounds: CGRect { snapshot?.materializedBounds ?? .null }
    var retainedLineCount: Int { snapshot?.retainedLineCount ?? 0 }
    var hasViewportWork: Bool { inFlight != nil }

    func documentY(for offset: Int) -> CGFloat {
        snapshot?.documentY(for: offset) ?? document.documentY(forCharOffset: offset)
    }

    func sourceOffset(at y: CGFloat) -> Int {
        snapshot?.sourceOffset(at: y) ?? document.charOffset(atDocumentY: y)
    }

    /// Asks the layout thread for `bounds` and a runway around it, unless the
    /// committed snapshot already covers them. Never waits: until the snapshot
    /// arrives, the region shows what the current one has (no text where
    /// nothing is laid out yet), which is the chosen trade-off for a scroll
    /// frame that never lays out.
    func requestViewport(_ bounds: CGRect, anchorOffset: Int? = nil) {
        guard isViewportDriven else { return }
        // What the chapter will hold once its requests land: the last one's region, or
        // nothing after a retirement; the committed snapshot only when none is on its
        // way. A layout still on its way replaces the committed region with its own, so
        // a quick reversal into a region committed now would otherwise land blank.
        let covered = switch pending ?? inFlightRequest {
        case .discard?: false
        case .layout(let region, _)?: region.contains(bounds)
        case nil: materializedBounds.contains(bounds)
        }
        if covered, anchorOffset == nil || document.documentPoint(forCharOffset: anchorOffset!) != nil { return }
        submit(.layout(bounds.insetBy(dx: 0, dy: -min(900, max(300, bounds.height * 0.5))), anchorOffset: anchorOffset))
    }

    /// Retires resident lines and their drawing resources; geometry stays.
    func discardViewportResources() {
        guard isViewportDriven, retainedLineCount > 0 || inFlight != nil else { return }
        submit(.discard)
    }

    /// Installs a published snapshot. The scroll host calls this inside its
    /// geometry transaction, after reading the visible anchor.
    func apply(_ snapshot: BrowserViewportSnapshot) {
        self.snapshot = snapshot
        document = snapshot.document
        layoutRevision &+= 1
    }

    /// Tests and explicit readiness checks only — never awaited from a scroll callback.
    func waitForViewportIdle() async {
        while inFlight != nil {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    private func submit(_ request: Request) {
        guard inFlight == nil else { pending = request; return }
        guard let layoutOwner else { return }
        let spine = spineIndex
        inFlightRequest = request
        inFlight = Task { @MainActor [weak self] in
            var published: BrowserViewportSnapshot?
            switch request {
            case .layout(let bounds, let anchorOffset):
                let start = SourcePerfTrace.now
                do {
                    published = try await layoutOwner.layout(in: bounds, anchorOffset: anchorOffset)
                    SourcePerfTrace.record("browser.viewport.layout", "spine=\(spine) demand=\(bounds)",
                                           since: start, thresholdMs: 0)
                } catch is CancellationError {
                } catch HTMLLayoutError.cancelled {
                } catch {
                    // The committed snapshot stays; the next request for this
                    // region lays it out again.
                    AppLogger.render("browser viewport layout failed",
                                     context: ["spine": "\(spine)", "error": String(describing: error)])
                }
            case .discard:
                published = await layoutOwner.discardRenderingResources()
            }
            guard let self else { return }
            let next = pending
            pending = nil
            inFlight = nil
            inFlightRequest = nil
            if let published, !Task.isCancelled {
                if let onSnapshot { onSnapshot(published) } else { apply(published) }
            }
            // A request made while delivering reflects the newer viewport.
            if inFlight == nil, let next { submit(next) }
            if inFlight == nil {
                let waiters = idleWaiters
                idleWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
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
            let start = ranges.map(\.location).min() ?? (writingMode.isVertical ? ((document.sourceText as NSString).length) : sourceOffset(at: advance))
            let end = ranges.map { NSMaxRange($0) }.max() ?? (snapshot?.sourceOffset(at: advance + length) ?? start)
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
