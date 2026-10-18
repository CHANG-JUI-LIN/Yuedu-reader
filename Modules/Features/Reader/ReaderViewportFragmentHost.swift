import CoreText
import os
import UIKit
import YueduCoreText

/// Content-space paint ownership, independent of collection cell recycling.
/// Browser and CoreText inputs share the same retention budget and surfaces.
/// Cells continue to own hit testing/selection; source format is not a policy.
@MainActor
final class ReaderViewportFragmentHost: UIView {
    struct Input {
        let chapter: BrowserScrollChapter
        let origin: CGPoint
        let width: CGFloat
    }
    struct CoreTextInput {
        let chunk: CoreTextChunk
        let origin: CGPoint
    }
    private enum FragmentID: Hashable {
        /// `BrowserPaintFragment.ID`'s fields. The package type is not Sendable, and a `Key`
        /// rides along with each raster job to the worker and back.
        case browser(node: Int, sourceOffset: Int, kind: Int, occurrence: Int, part: Int)
        case coreText(Int)

        init(_ id: BrowserPaintFragment.ID) {
            self = .browser(node: id.node, sourceOffset: id.sourceOffset, kind: id.kind,
                            occurrence: id.occurrence, part: id.part)
        }
    }
    private struct Key: Hashable {
        let owner: ObjectIdentifier
        let fragment: FragmentID
    }
    @MainActor private final class CoreTextState {
        let owner: CoreTextChunk
        let view = UIView()
        let backdrop = CoreTextChunkBackdropView()
        var scale: CGFloat = 0
        var underline: ReaderTextUnderlineDecoration?
        var fragments: [CoreTextPaintFragment] = []
        init(_ owner: CoreTextChunk) {
            self.owner = owner
            view.isUserInteractionEnabled = false
            backdrop.chunk = owner
            view.addSubview(backdrop)
        }
    }
    @MainActor private final class ChapterState {
        let owner: BrowserScrollChapter
        let view = UIView()
        /// Behind every chapter's content, only while the chapter has a page background.
        var backdrop: BrowserChapterBackdropView?
        var revision: UInt64?
        var scale: CGFloat = 0
        var query = CGRect.null
        var fragments: [BrowserPaintFragment] = []
        /// Highlight line boxes around `query`, in document space.
        var highlightSpans = HighlightLineSpans([DisplayItem]())
        init(_ owner: BrowserScrollChapter) {
            self.owner = owner
            view.isUserInteractionEnabled = false
            view.clipsToBounds = true
        }
    }
    @MainActor private final class Entry {
        let surface = BrowserFragmentSurface()
        var touched: UInt64 = 0
        var pixels = 0
        /// What the requested or installed bitmap depicts.
        var raster: RasterIdentity?
        /// Non-nil while that bitmap is being painted off the main thread.
        var ticket: ReaderFragmentRasterizer.Ticket?
        /// Browser only: advances whenever the surface's display list changes.
        var contentRevision: UInt64 = 0
        var hasInstalledRaster: Bool { raster != nil && ticket == nil }
    }
    /// Everything a fragment bitmap depends on. A mismatch discards the installed
    /// bitmap: a stale bitmap in new geometry would show wrong text.
    private struct RasterIdentity: Equatable {
        enum Content: Equatable {
            case coreText(renderingRect: CGRect, lineIndices: IndexSet, underline: ReaderTextUnderlineDecoration?)
            /// The surface compares browser display lists (`configure`).
            case browser(revision: UInt64)
        }
        let content: Content
        let scale: CGFloat
    }
    private let rasterizer = ReaderFragmentRasterizer()
    private var rasterFormat: (scale: CGFloat, format: UIGraphicsImageRendererFormat)?
    private var inFlightRasters = 0
    private var rasterIdleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Visible fragments whose bitmap had not arrived at the last update.
    private(set) var lateFragmentCount = 0
    var mainThreadRasterCount: Int { rasterizer.mainThreadRenderCount }
    private var lastViewportMinY: CGFloat?
    private var prepaintLead: CGFloat = 0
    private var prepaintDirection: CGFloat = 1
    private var coreTextChunks: [ObjectIdentifier: CoreTextState] = [:]
    private var chapters: [ObjectIdentifier: ChapterState] = [:]
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private var active = Set<Key>()
    /// Offscreen surfaces are disposable. Visible surfaces are never dropped
    /// to meet a budget (that would replace a complex page with missing content).
    static let retainedByteLimit = 24 * 1024 * 1024
    static let retainedSurfaceLimit = 256
    private(set) var createdCount = 0
    private(set) var redrawCount = 0
    private(set) var evictedCount = 0
    var retainedSurfaceCount: Int { entries.count }
    var estimatedBackingBytes: Int { entries.values.reduce(0) { $0 + $1.pixels * 4 } }
    var visibleSurfaces: [BrowserFragmentSurface] {
        active.compactMap { entries[$0]?.surface }
    }
    struct TextAnchor {
        let spine: Int
        let offset: Int
        /// The session's line origin, positioned using the actual paint surface.
        let lineY: CGFloat
    }
    func textAnchor(in view: UIView, visible: CGRect) -> TextAnchor? {
        var best: (owner: BrowserScrollChapter, offset: Int, baseline: CGFloat, documentBaseline: CGFloat)?
        for key in active {
            guard let entry = entries[key], let owner = chapters[key.owner]?.owner,
                  let candidate = entry.surface.textAnchor(in: view, visible: visible) else { continue }
            if best == nil || candidate.baseline < best!.baseline {
                best = (owner, candidate.offset, candidate.baseline, candidate.documentBaseline)
            }
        }
        guard let best else { return nil }
        let y = best.baseline - best.documentBaseline + best.owner.documentY(for: best.offset)
        return TextAnchor(spine: best.owner.spineIndex, offset: best.offset, lineY: y)
    }
    private static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "YueduReader", category: "ReaderPerformance")

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(memoryPressure),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func reset() {
        entries.values.forEach { $0.ticket?.cancel() }
        entries.removeAll()
        chapters.values.forEach { $0.view.removeFromSuperview(); $0.backdrop?.removeFromSuperview() }
        chapters.removeAll()
        coreTextChunks.values.forEach { $0.view.removeFromSuperview() }
        coreTextChunks.removeAll()
        active.removeAll()
        lastViewportMinY = nil
        prepaintLead = 0
    }

    func update(_ inputs: [Input], coreText: [CoreTextInput] = [], viewport: CGRect, scale: CGFloat) {
        let start = SourcePerfTrace.now
        let previousCreates = createdCount, previousRedraws = redrawCount, previousEvictions = evictedCount
        clock &+= 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let owners = Set(inputs.map { ObjectIdentifier($0.chapter) }
            + coreText.map { ObjectIdentifier($0.chunk) })
        for key in Array(entries.keys) where !owners.contains(key.owner) { evict(key) }
        for owner in Array(chapters.keys) where !owners.contains(owner) {
            let state = chapters.removeValue(forKey: owner)
            state?.view.removeFromSuperview()
            state?.backdrop?.removeFromSuperview()
        }
        for owner in Array(coreTextChunks.keys) where !owners.contains(owner) {
            coreTextChunks.removeValue(forKey: owner)?.view.removeFromSuperview()
        }
        var nextActive = Set<Key>()
        // Prepare individual lines just ahead of the viewport, rather than an
        // entire screen when its cell is dequeued. Residency is a separate bound.
        let paintWindow = viewport.insetBy(dx: 0, dy: -viewport.height * 0.2)
        let retention = viewport.insetBy(dx: 0, dy: -viewport.height)
        // Bitmaps are painted off the main thread, so they are also requested
        // ahead of the paint window in the direction of travel: about 12 updates
        // (~100 ms at 120 Hz) of the current per-update movement, at most half a
        // screen, which stays inside `retention`. A geometry-only update (no
        // movement) keeps the previous lead instead of dropping it.
        let movement = lastViewportMinY.map { viewport.minY - $0 } ?? 0
        lastViewportMinY = viewport.minY
        if movement != 0 {
            prepaintLead = min(viewport.height * 0.5, abs(movement) * 12)
            prepaintDirection = movement > 0 ? 1 : -1
        }
        let prepaintWindow = CGRect(x: paintWindow.minX,
            y: prepaintDirection > 0 ? paintWindow.minY : paintWindow.minY - prepaintLead,
            width: paintWindow.width, height: paintWindow.height + prepaintLead)
        let underline = ReaderTextUnderlineDecoration.current()
        var wanted = Set<Key>()
        var late = 0
        var prepaintCandidates: [(global: CGRect, cost: Int, admit: () -> Void)] = []
        func backingPixels(_ rect: CGRect) -> Int {
            Int(ceil(rect.width * scale) * ceil(rect.height * scale))
        }
        func makeEntry(_ key: Key, in ownerView: UIView) -> Entry {
            let entry = Entry()
            entries[key] = entry
            entry.surface.isHidden = true
            ownerView.addSubview(entry.surface)
            createdCount += 1
            return entry
        }
        /// Wanted by this update: asks for a new bitmap when what it depicts changed.
        func want(_ entry: Entry, key: Key, identity: RasterIdentity, renderingRect: CGRect,
                  global: CGRect, content: () -> ReaderFragmentRasterizer.Content) {
            if entry.raster != identity {
                requestRaster(for: entry, key: key, identity: identity,
                              renderingRect: renderingRect, content: content())
            }
            entry.ticket?.priority = Self.distance(global, viewport)
            wanted.insert(key)
            entry.touched = clock
            entry.pixels = backingPixels(renderingRect)
        }
        /// Paint-window fragments get a surface now and are shown. Ahead of the
        /// paint window only an existing surface is prepared; a new one waits for
        /// spare budget below, and neither is shown or protected from the budget.
        func place(_ key: Key, global: CGRect, renderingRect: CGRect, in ownerView: UIView,
                   prepare: @escaping (Entry) -> Void) {
            let inPaintWindow = global.intersects(paintWindow)
            guard let entry = entries[key] ?? (inPaintWindow ? makeEntry(key, in: ownerView) : nil) else {
                prepaintCandidates.append((global, backingPixels(renderingRect) * 4,
                                           { prepare(makeEntry(key, in: ownerView)) }))
                return
            }
            prepare(entry)
            guard inPaintWindow else { return }
            if entry.surface.isHidden { entry.surface.isHidden = false }
            nextActive.insert(key)
            if global.intersects(viewport), !entry.hasInstalledRaster { late += 1 }
        }
        for input in inputs {
            let owner = ObjectIdentifier(input.chapter)
            let state = chapters[owner] ?? ChapterState(input.chapter)
            if chapters[owner] == nil {
                chapters[owner] = state
                addSubview(state.view)
            }
            // The clip spans the screen width, so what CSS puts in the reader's
            // margins (a negative margin, a hanging heading) shows as on a page;
            // document x = 0 stays at the content inset. Its height does not
            // multiply the last antialiased border pixel by a second fractional
            // chapter clip; logical content height and scroll/anchor geometry
            // remain unchanged.
            state.view.frame = CGRect(x: viewport.minX, y: input.origin.y, width: viewport.width,
                                      height: ceil(input.chapter.document.contentHeight * scale) / scale)
            state.view.bounds.origin = CGPoint(x: viewport.minX - input.origin.x, y: 0)
            if let background = input.chapter.pageBackground {
                let backdrop = state.backdrop ?? BrowserChapterBackdropView()
                if state.backdrop == nil {
                    state.backdrop = backdrop
                    insertSubview(backdrop, at: 0)
                }
                backdrop.frame = state.view.frame
                backdrop.update(background: background, image: input.chapter.pageBackgroundImage,
                                viewport: viewport, retention: retention)
                state.view.backgroundColor = .clear
            } else {
                state.backdrop?.removeFromSuperview()
                state.backdrop = nil
                state.view.backgroundColor = input.chapter.usesReaderBackground ? .clear : input.chapter.backgroundColor
            }
            // Fragments cover everything this update may paint, the lead included.
            let demand = prepaintWindow.offsetBy(dx: -input.origin.x, dy: -input.origin.y)
            if state.revision != input.chapter.layoutRevision || state.scale != scale || !state.query.contains(demand) {
                let prepare = Self.signposter.beginInterval("viewport.paintPrepare",
                    "backend=browser spine=\(input.chapter.spineIndex) revision=\(input.chapter.layoutRevision)")
                state.query = demand.insetBy(dx: 0, dy: -viewport.height * 0.5)
                state.fragments = input.chapter.document.paintFragments(in: state.query, scale: scale,
                    textDecorationBounds: Self.decorationBounds)
                // A line's pieces can land in different fragments, each painted alone; the
                // spans see every item of every line those fragments draw. The margin takes
                // in a line that only grazes the query.
                let lines = state.query.insetBy(dx: 0, dy: -viewport.height)
                state.highlightSpans = HighlightLineSpans(input.chapter.document.displayList.items.lazy.filter { item in
                    guard case .text(let text) = item else { return false }
                    return text.rect.rawValue.maxY >= lines.minY && text.rect.rawValue.minY <= lines.maxY
                })
                Self.signposter.endInterval("viewport.paintPrepare", prepare,
                    "fragments=\(state.fragments.count)")
                state.revision = input.chapter.layoutRevision
                state.scale = scale
            }
            let skipBackground = input.chapter.usesReaderBackground
            let spine = input.chapter.spineIndex
            for fragment in state.fragments {
                let global = fragment.documentRect.offsetBy(dx: input.origin.x, dy: input.origin.y)
                guard global.intersects(prepaintWindow) else { continue }
                let key = Key(owner: owner, fragment: FragmentID(fragment.id))
                place(key, global: global, renderingRect: fragment.renderingRect, in: state.view) { entry in
                    // A moved but otherwise identical display list keeps its bitmap.
                    if entry.surface.configure(fragment, scale: scale, skipBackground: skipBackground) {
                        entry.contentRevision &+= 1
                    }
                    let order = CGFloat(fragment.paintOrder)
                    if entry.surface.layer.zPosition != order { entry.surface.layer.zPosition = order }
                    want(entry, key: key,
                         identity: RasterIdentity(content: .browser(revision: entry.contentRevision), scale: scale),
                         renderingRect: fragment.renderingRect, global: global) {
                        .browser(.init(fragment: fragment, skipBackground: skipBackground, spine: spine,
                                       highlightSpans: state.highlightSpans))
                    }
                }
            }
        }
        for input in coreText {
            let owner = ObjectIdentifier(input.chunk)
            let state = coreTextChunks[owner] ?? CoreTextState(input.chunk)
            if coreTextChunks[owner] == nil {
                coreTextChunks[owner] = state
                addSubview(state.view)
            }
            state.view.frame = CGRect(origin: input.origin,
                size: CGSize(width: input.chunk.width, height: input.chunk.height))
            let backdropFrame = CGRect(x: -input.origin.x, y: 0,
                                       width: viewport.width, height: input.chunk.height)
            if state.backdrop.frame != backdropFrame || state.backdrop.viewportSize != viewport.size {
                state.backdrop.frame = backdropFrame
                state.backdrop.viewportSize = viewport.size
                state.backdrop.setNeedsDisplay()
            }
            // Partition halos include the reader underline, so a changed underline
            // re-partitions as well as repaints.
            if state.scale != scale || state.fragments.isEmpty || state.underline != underline {
                state.underline = underline
                let start = SourcePerfTrace.now
                let prepare = Self.signposter.beginInterval("viewport.paintPrepare",
                    "backend=coreText spine=\(input.chunk.chapterIndex) offset=\(input.chunk.charRange.location)")
                state.fragments = CoreTextPaintFragment.make(chunk: input.chunk, scale: scale)
                Self.signposter.endInterval("viewport.paintPrepare", prepare,
                    "fragments=\(state.fragments.count)")
                state.scale = scale
                SourcePerfTrace.record("scroll.paint.prepare", "spine=\(input.chunk.chapterIndex) fragments=\(state.fragments.count)", since: start)
            }
            let chunk = input.chunk
            for fragment in state.fragments {
                let global = fragment.rect.offsetBy(dx: input.origin.x, dy: input.origin.y)
                guard global.intersects(prepaintWindow) else { continue }
                let key = Key(owner: owner, fragment: .coreText(fragment.index))
                place(key, global: global, renderingRect: fragment.renderingRect, in: state.view) { entry in
                    entry.surface.configure(fragment)
                    want(entry, key: key,
                         identity: RasterIdentity(content: .coreText(renderingRect: fragment.renderingRect,
                             lineIndices: fragment.lineIndices, underline: underline), scale: scale),
                         renderingRect: fragment.renderingRect, global: global) {
                        .coreText(.init(chunk: chunk, content: CoreTextChunkPainter.Content(chunk: chunk, frame: nil),
                                        lineIndices: fragment.lineIndices, underline: underline, part: fragment.index))
                    }
                }
            }
        }
        for key in active.subtracting(nextActive) { entries[key]?.surface.isHidden = true }
        active = nextActive
        for key in Array(entries.keys) where !active.contains(key) {
            guard let entry = entries[key],
                  let ownerView = chapters[key.owner]?.view ?? coreTextChunks[key.owner]?.view else { continue }
            if !ownerView.convert(entry.surface.frame, to: self).intersects(retention) { evict(key) }
        }
        trimBudget(viewport: viewport)
        // New surfaces ahead of the paint window only use budget to spare, nearest
        // first. Painting ahead never evicts a retained surface: those serve the
        // small reversals a reader makes constantly, the lead may never be reached.
        var bytes = estimatedBackingBytes
        for candidate in prepaintCandidates.sorted(by: { Self.distance($0.global, viewport) < Self.distance($1.global, viewport) }) {
            guard entries.count < Self.retainedSurfaceLimit, bytes + candidate.cost <= Self.retainedByteLimit else { break }
            candidate.admit()
            bytes += candidate.cost
        }
        // A bitmap still being painted for a fragment that is no longer wanted is
        // wasted worker time; the fragment requests it again if it comes back.
        for (key, entry) in entries where entry.ticket != nil && !wanted.contains(key) {
            entry.ticket?.cancel()
            entry.ticket = nil
            entry.raster = nil
            // Holds no bitmap now; it must not crowd the budget.
            entry.pixels = 0
        }
        lateFragmentCount = late
        if late > 0, Self.signposter.isEnabled {
            Self.signposter.emitEvent("viewport.fragmentLate", "late=\(late) inFlight=\(self.inFlightRasters)")
        }
        if createdCount != previousCreates || redrawCount != previousRedraws || evictedCount != previousEvictions {
            if Self.signposter.isEnabled {
                Self.signposter.emitEvent("viewport.fragments",
                    "created=\(self.createdCount - previousCreates) redraw=\(self.redrawCount - previousRedraws) evicted=\(self.evictedCount - previousEvictions) active=\(self.active.count) retained=\(self.entries.count) bytes=\(self.estimatedBackingBytes)")
            }
            SourcePerfTrace.record("scroll.viewport.fragments", "active=\(active.count) retained=\(entries.count)", since: start)
        }
    }

    @objc private func memoryPressure() {
        for key in Array(entries.keys) where !active.contains(key) { evict(key) }
        rasterizer.purgeCaches()
    }
    /// Least recently shown first; among equals (e.g. fragments painted ahead in
    /// the same update) the farthest from the viewport goes first.
    private func trimBudget(viewport: CGRect) {
        var bytes = estimatedBackingBytes
        guard entries.count > Self.retainedSurfaceLimit || bytes > Self.retainedByteLimit else { return }
        let inactive = entries.filter { !active.contains($0.key) }.map { key, entry -> (Key, Entry, CGFloat) in
            let ownerView = chapters[key.owner]?.view ?? coreTextChunks[key.owner]?.view
            let rect = ownerView?.convert(entry.surface.frame, to: self) ?? entry.surface.frame
            return (key, entry, Self.distance(rect, viewport))
        }.sorted { $0.1.touched != $1.1.touched ? $0.1.touched < $1.1.touched : $0.2 > $1.2 }
        for (key, entry, _) in inactive {
            guard entries.count > Self.retainedSurfaceLimit || bytes > Self.retainedByteLimit else { break }
            bytes -= entry.pixels * 4
            evict(key)
        }
    }
    private func evict(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.ticket?.cancel()
        entry.surface.removeFromSuperview()
        evictedCount += 1
    }

    private static func distance(_ rect: CGRect, _ viewport: CGRect) -> CGFloat {
        max(0, rect.minY - viewport.maxY, viewport.minY - rect.maxY)
    }

    private func rasterFormat(for scale: CGFloat) -> UIGraphicsImageRendererFormat {
        if let rasterFormat, rasterFormat.scale == scale { return rasterFormat.format }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        // 8-bit sRGB, 4 bytes a pixel as `estimatedBackingBytes` assumes. Reader
        // text and theme colors are sRGB; an automatic range may pick a 64-bit
        // extended format on P3 displays at twice the memory.
        format.preferredRange = .standard
        rasterFormat = (scale, format)
        return format
    }

    /// Clears what is shown (a bitmap of other content or geometry would be wrong
    /// text) and asks the worker for the new one. Blank until it arrives.
    private func requestRaster(for entry: Entry, key: Key, identity: RasterIdentity,
                               renderingRect: CGRect, content: ReaderFragmentRasterizer.Content) {
        entry.ticket?.cancel()
        entry.surface.clearRaster()
        let ticket = ReaderFragmentRasterizer.Ticket()
        entry.raster = identity
        entry.ticket = ticket
        redrawCount += 1
        inFlightRasters += 1
        let job = ReaderFragmentRasterizer.Job(ticket: ticket, renderingRect: renderingRect,
            format: rasterFormat(for: identity.scale), content: content)
        rasterizer.submit(job) { [weak self] image in
            MainActor.assumeIsolated {
                self?.finishRaster(key: key, ticket: ticket, image: image)
            }
        }
    }

    private func finishRaster(key: Key, ticket: ReaderFragmentRasterizer.Ticket, image: CGImage?) {
        defer {
            inFlightRasters -= 1
            if inFlightRasters == 0 {
                let waiters = rasterIdleWaiters
                rasterIdleWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        // Evicted, no longer wanted, or superseded by a newer request.
        guard let entry = entries[key], entry.ticket === ticket else { return }
        entry.ticket = nil
        guard let image, let identity = entry.raster else {
            entry.raster = nil
            entry.pixels = 0
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        entry.surface.install(image, scale: identity.scale)
        CATransaction.commit()
    }

    /// Tests and explicit readiness checks only — never awaited from a scroll callback.
    func waitForRasterIdle() async {
        while inFlightRasters > 0 {
            await withCheckedContinuation { rasterIdleWaiters.append($0) }
        }
    }
    private static func decorationBounds(_ line: CTLine, _ text: NSAttributedString) -> CGRect {
        RegexHighlightDecorationRenderer.horizontalFragments(line: line, origin: .zero,
            attributedString: text, range: NSRange(location: 0, length: text.length)).reduce(.null) { result, fragment in
                let spread = fragment.decoration.style.shadows.map {
                    max(8, CGFloat($0.radius) * 4 + abs(CGFloat($0.x)) + abs(CGFloat($0.y)))
                }.max() ?? 0
                // Reaching along the line lets a piece paint its share of a line box
                // that spans several fragments (`HighlightLineSpans`).
                let reach = HighlightLineSpans.inlineReach(of: fragment.rect)
                return result.union(fragment.rect.insetBy(dx: -max(spread, reach), dy: -spread))
            }
    }
}

/// A clip surface retained by content ID. It shows one bitmap painted off the
/// main thread by `ReaderFragmentRasterizer`: a browser paint fragment or a
/// CoreText chunk fragment.
@MainActor
final class BrowserFragmentSurface: UIView {
    /// Placed at the fragment's rendering rect, the space its display list and
    /// bitmap use. A plain view: UIKit only redisplays views that override
    /// `draw(_:)`, and a redisplay would replace the bitmap with an empty backing store.
    private let rendering = UIView()
    private(set) var fragment: BrowserPaintFragment?
    private(set) var coreTextFragment: CoreTextPaintFragment?
    private var skipBackground = false
    private var scale: CGFloat = 0
    private var installedRasterCount = 0
    /// Bitmaps installed on this surface.
    var drawCount: Int { installedRasterCount }
    var hasRaster: Bool { rendering.layer.contents != nil }
    private(set) var redrawCount = 0
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        rendering.isUserInteractionEnabled = false
        rendering.isOpaque = false
        addSubview(rendering)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func textAnchor(in view: UIView, visible: CGRect) -> (offset: Int, baseline: CGFloat, documentBaseline: CGFloat)? {
        guard let fragment, fragment.textPaintPhase == .glyphs else { return nil }
        for case .text(let text) in fragment.displayList.items {
            guard text.sourceRange.length > 0, case .linear = text.sourceMapping else { continue }
            let baseline = rendering.convert(CGPoint(x: text.rect.minX, y: text.baselineY), to: view).y
            guard baseline >= visible.minY, baseline < visible.maxY else { continue }
            return (text.sourceRange.location, baseline, fragment.renderingRect.minY + text.baselineY)
        }
        return nil
    }
    /// Places the fragment and reports whether its paint changed — the installed
    /// bitmap then depicts something else. Moving it does not change its paint.
    @discardableResult
    func configure(_ fragment: BrowserPaintFragment, scale: CGFloat, skipBackground: Bool) -> Bool {
        let previous = self.fragment
        // Subtraction after a document-space translation can differ by a few
        // ULPs. This is far below a pixel; actual glyph/style changes still dirty.
        let epsilon: CGFloat = 0.0000001
        let sizeChanged = previous.map {
            abs($0.renderingRect.width - fragment.renderingRect.width) > epsilon
                || abs($0.renderingRect.height - fragment.renderingRect.height) > epsilon
        } ?? true
        let changed = sizeChanged
            || previous?.textPaintPhase != fragment.textPaintPhase
            || previous?.displayList.hasSameContents(as: fragment.displayList, geometryTolerance: epsilon) == false
            || self.skipBackground != skipBackground || self.scale != scale
        frame = fragment.documentRect
        rendering.frame.origin = CGPoint(x: fragment.renderingRect.minX - fragment.documentRect.minX,
                                         y: fragment.renderingRect.minY - fragment.documentRect.minY)
        self.fragment = fragment
        self.skipBackground = skipBackground
        self.scale = scale
        if changed { redrawCount += 1 }
        return changed
    }
    /// Geometry only. The host decides whether the bitmap must be repainted.
    func configure(_ fragment: CoreTextPaintFragment) {
        frame = fragment.rect
        rendering.frame.origin = CGPoint(x: fragment.renderingRect.minX - fragment.rect.minX,
                                         y: fragment.renderingRect.minY - fragment.rect.minY)
        coreTextFragment = fragment
    }
    /// Shows a finished bitmap at its natural size: the rendering rect in whole
    /// device pixels, so nothing is resampled.
    func install(_ image: CGImage, scale: CGFloat) {
        rendering.contentScaleFactor = scale
        rendering.frame.size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        rendering.layer.contents = image
        installedRasterCount += 1
    }
    func clearRaster() {
        rendering.layer.contents = nil
    }
}
