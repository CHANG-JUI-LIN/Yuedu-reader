import UIKit
import CoreText
import YueduCoreText

/// Product rule evaluation stays in Reader; the package maps the resulting attributes
/// to its own unchanged UTF-16 source ranges before shaping.
enum BrowserReaderAttributes {
    static func transform(settings: ReaderRenderSettings) -> ((NSMutableAttributedString) -> Void)? {
        transform(configuration: settings.regexHighlightConfiguration,
                  appearance: settings.readerStyleAppearance, assetRevision: settings.readerStyleAssetRevision)
    }

    static func transform(configuration: RegexHighlightConfiguration,
                          appearance: ReaderStyleAppearance, assetRevision: UInt64) -> ((NSMutableAttributedString) -> Void)? {
        guard configuration.isEnabled else { return nil }
        return { text in
            do {
                let result = try RegexHighlightEngine.apply(configuration: configuration,
                    appearance: appearance, assetRevision: assetRevision, to: text)
                for diagnostic in result.diagnostics {
                    AppLogger.render("browser regex highlight diagnostic", context: ["diagnostic": String(describing: diagnostic)])
                }
            } catch {
                AppLogger.render("browser regex highlight apply failed", context: ["error": String(describing: error)])
            }
        }
    }
}

/// Reader-only rule decorations; HTML/CSS backgrounds/borders and all glyphs are drawn in the package.
enum ReaderDisplayListDrawer {
    /// - Parameters:
    ///   - highlightSpans: The line boxes of highlights split across items, in the space
    ///     `list` is offset from by `origin`. A list that holds whole lines (a page, a
    ///     tile) finds its own; a paint fragment holds part of a line, so its host passes
    ///     the spans of the document around it.
    ///   - origin: Where `list`'s own origin sits in `highlightSpans`' space.
    static func draw(_ list: DisplayList, in context: CGContext, skipAuthoredBackgroundPaint: Bool = false,
                     textPaintPhase: TextPaintPhase = .all,
                     highlightSpans: HighlightLineSpans? = nil, origin: CGPoint = .zero) {
        let spans = highlightSpans ?? HighlightLineSpans(list.items)
        let base = context.ctm
        list.draw(in: context, skipAuthoredBackgroundPaint: skipAuthoredBackgroundPaint, textPaintPhase: textPaintPhase) { line, text, context in
            let fragments = RegexHighlightDecorationRenderer.horizontalFragments(line: line, origin: .zero,
                attributedString: text, range: NSRange(location: 0, length: text.length))
            guard !fragments.isEmpty else { return }
            spans.paint(fragments, local: context.ctm, base: base, origin: origin, context: context)
        }
    }
}

/// One decoration box per highlighted segment per visual line.
///
/// The package calls the decoration hook once per display text item, and a line holds one
/// item per inline box — a ruby base, an `<em>`, a link. A segment crossing them used to get
/// one box per item: invisible for a flat colour, but a nine-slice frame drew two or three
/// overlapping frames around one quote (和蘭人形, 2026-10-12). The legacy engine draws a
/// whole CTLine, so it always had one box per line; this gives the browser engine the same.
///
/// Each piece paints the whole line box clipped to the stretch of the line it owns, split
/// halfway between neighbouring pieces and snapped to device pixels. Scroll mode needs
/// exactly that: it rasterises a line in several bitmaps — a ruby annotation sits on its
/// own baseline and cuts the line's run of items — and no bitmap sees the others' pieces.
/// Each bitmap's decoration bounds reach past its own piece (`inlineReach`), so the
/// halfway split always lands inside both neighbours.
///
/// Items of one segment share its `RegexHighlightDecoration` instance, which is what joins
/// them. Geometry follows `DisplayListDrawer.drawText`'s transform: horizontal items are
/// drawn at (minX, baseline) flipped; vertical ones at (baseline, minY) turned a quarter.
struct HighlightLineSpans: Sendable {
    private struct PieceKey: Hashable {
        let decoration: ObjectIdentifier
        let baseline: CGFloat
    }

    private struct Span: Sendable {
        let baseline: CGFloat
        /// The line box, padding included.
        let union: CGRect
        let isVertical: Bool
        /// Where one piece's stretch ends and the next begins, along the line, ascending.
        let boundaries: [CGFloat]
    }

    /// Segments in two or more pieces only, by decoration; a segment in one item paints as it is.
    private let spans: [ObjectIdentifier: [Span]]
    /// Items of one line share one baseline value; a bitmap recovers it through its CTM,
    /// which can be off by rounding.
    private static let baselineTolerance: CGFloat = 0.5
    /// Clip extent across the line: unbounded in effect, finite once scaled to device pixels.
    private static let far: CGFloat = 1_000_000

    var isEmpty: Bool { spans.isEmpty }

    /// - Parameter offset: Added to each item's geometry: the items' list origin in the
    ///   spans' own space.
    init(_ items: some Sequence<DisplayItem>, offset: CGPoint = .zero) {
        var pieces: [PieceKey: (rects: [CGRect], isVertical: Bool)] = [:]
        for case .text(let item) in items where Self.lineCarriesDecoration(item) {
            let text = item.attributedText
            let fragments = RegexHighlightDecorationRenderer.horizontalFragments(
                line: CTLineCreateWithAttributedString(text), origin: .zero,
                attributedString: text, range: NSRange(location: 0, length: text.length))
            let isVertical = item.writingMode == .verticalRTL
            let baseline = item.baselineY + (isVertical ? offset.x : offset.y)
            for fragment in fragments {
                let key = PieceKey(decoration: ObjectIdentifier(fragment.decoration), baseline: baseline)
                let rect = Self.pageRect(fragment.rect, item: item).offsetBy(dx: offset.x, dy: offset.y)
                pieces[key, default: ([], isVertical)].rects.append(rect)
            }
        }
        var spans: [ObjectIdentifier: [Span]] = [:]
        for (key, value) in pieces where value.rects.count > 1 {
            let isVertical = value.isVertical
            let sorted = value.rects.sorted { isVertical ? $0.minY < $1.minY : $0.minX < $1.minX }
            let boundaries = zip(sorted, sorted.dropFirst()).map { previous, next in
                isVertical ? (previous.maxY + next.minY) / 2 : (previous.maxX + next.minX) / 2
            }
            spans[key.decoration, default: []].append(Span(
                baseline: key.baseline,
                union: sorted.dropFirst().reduce(sorted[0]) { $0.union($1) },
                isVertical: isVertical, boundaries: boundaries))
        }
        self.spans = spans
    }

    /// How far past its own piece a bitmap must reach so the line box can be split
    /// halfway between pieces: half of any gap between them, which a ruby base's inline
    /// box can leave. The piece's own thickness covers every gap an inline box makes.
    static func inlineReach(of rect: CGRect) -> CGFloat { rect.height }

    /// Paints one item's fragments: unchanged when their segment sits in one item;
    /// otherwise this item's stretch of the line box.
    func paint(
        _ fragments: [RegexHighlightDecorationRenderer.Fragment],
        local: CGAffineTransform,
        base: CGAffineTransform,
        origin: CGPoint,
        context: CGContext
    ) {
        guard !spans.isEmpty else {
            RegexHighlightDecorationRenderer.paint(fragments: fragments, writingMode: .horizontal, context: context)
            return
        }
        // Local drawing space → the list's space (the device-independent part of the CTM).
        let toList = local.concatenating(base.inverted())
        let fromList = toList.inverted()
        let isVertical = abs(toList.b) > abs(toList.a)
        let itemOrigin = CGPoint.zero.applying(toList)
        let baseline = isVertical ? itemOrigin.x + origin.x : itemOrigin.y + origin.y
        let deviceScale = max(1, hypot(base.a, base.b))

        var single: [RegexHighlightDecorationRenderer.Fragment] = []
        for fragment in fragments {
            guard let span = spans[ObjectIdentifier(fragment.decoration)]?.first(where: {
                abs($0.baseline - baseline) <= Self.baselineTolerance
            }) else {
                single.append(fragment)
                continue
            }
            let piece = fragment.rect.applying(toList).offsetBy(dx: origin.x, dy: origin.y)
            let center = isVertical ? piece.midY : piece.midX
            let index = span.boundaries.filter { $0 <= center }.count
            let inlineOrigin = isVertical ? origin.y : origin.x
            // Snapped in device pixels, so neighbouring bitmaps meet without a seam.
            func snapped(_ value: CGFloat) -> CGFloat {
                ((value - inlineOrigin) * deviceScale).rounded() / deviceScale + inlineOrigin
            }
            let far = Self.far
            let lower = index > 0 ? snapped(span.boundaries[index - 1]) : -far
            let upper = index < span.boundaries.count ? snapped(span.boundaries[index]) : far
            let owned = isVertical
                ? CGRect(x: -far, y: lower, width: far * 2, height: upper - lower)
                : CGRect(x: lower, y: -far, width: upper - lower, height: far * 2)
            context.saveGState()
            context.clip(to: owned.offsetBy(dx: -origin.x, dy: -origin.y).applying(fromList))
            let box = span.union.offsetBy(dx: -origin.x, dy: -origin.y).applying(fromList).standardized
            RegexHighlightDecorationRenderer.paint(
                fragments: [.init(range: fragment.range, rect: box, decoration: fragment.decoration)],
                writingMode: .horizontal, context: context)
            context.restoreGState()
        }
        if !single.isEmpty {
            RegexHighlightDecorationRenderer.paint(fragments: single, writingMode: .horizontal, context: context)
        }
    }

    /// `item.ctLine` is the whole shaped line, so this keeps every item of a line that
    /// carries a highlight and skips the rest without building their text.
    private static func lineCarriesDecoration(_ item: DisplayTextItem) -> Bool {
        guard let line = item.ctLine else { return true }
        return (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).contains { run in
            (CTRunGetAttributes(run) as NSDictionary)[RegexHighlightDecoration.attributeKey] != nil
        }
    }

    private static func pageRect(_ rect: CGRect, item: DisplayTextItem) -> CGRect {
        if item.writingMode == .verticalRTL {
            return CGRect(x: item.baselineY + rect.minY, y: item.rect.rawValue.minY + rect.minX,
                          width: rect.height, height: rect.width)
        }
        return CGRect(x: item.rect.rawValue.minX + rect.minX, y: item.baselineY - rect.maxY,
                      width: rect.width, height: rect.height)
    }
}
