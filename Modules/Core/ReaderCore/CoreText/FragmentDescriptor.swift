import CoreGraphics
import CoreText

/// One unit of content in the viewport model — a paragraph-sized span of the chapter, described
/// cheaply enough to enumerate the whole chapter without laying any of it out.
///
/// `Technotes/ViewportScrollArchitecture.md` §4.2. The states mirror TextKit 2's
/// `NSTextLayoutFragment.State`:
///
/// | ours | TextKit 2 | holds |
/// |---|---|---|
/// | `.described` | `.none` | charRange |
/// | `.estimated` | `.estimatedUsageBounds` | ＋ estimatedHeight |
/// | `.measured` | `.calculatedUsageBounds` | ＋ actualHeight (laid out once, frame since dropped) |
/// | `.laidOut` | `.layoutAvailable` | ＋ CTFrame ＋ renderables (held by `CoreTextChunk`) |
///
/// `.measured` is the state TextKit 2 can be vague about and we cannot: once a fragment's real
/// height is known it must never fall back to the estimate, or scrolling back up would make
/// already-settled content jump a second time.
struct FragmentDescriptor: Equatable {

    enum State: Equatable {
        case described
        case estimated
        case measured
        case laidOut
    }

    /// Chapter-relative UTF-16 range. **Boundary authority**: once the outline sets this, real
    /// layout may not change it (§8.2). A descriptor whose range disagrees with its chunk breaks
    /// selection and reading position, which is the single most dangerous failure in this design.
    let charRange: CFRange

    /// Exact, known height that needs no estimating — a block image or table, whose size is
    /// already fixed in the attributed string (§4.1). `nil` for ordinary text.
    let intrinsicHeight: CGFloat?

    private(set) var state: State
    private(set) var estimatedHeight: CGFloat
    private(set) var actualHeight: CGFloat?

    init(charRange: CFRange, estimatedHeight: CGFloat, intrinsicHeight: CGFloat? = nil) {
        self.charRange = charRange
        self.intrinsicHeight = intrinsicHeight
        self.estimatedHeight = max(0, estimatedHeight)
        self.actualHeight = nil
        self.state = estimatedHeight > 0 ? .estimated : .described
    }

    /// Height to lay out with: the real one when known, the estimate otherwise.
    var height: CGFloat {
        actualHeight ?? estimatedHeight
    }

    /// Whether `height` is still a guess. Scroll-geometry code uses this to decide whether a
    /// total is provisional.
    var isEstimate: Bool {
        actualHeight == nil
    }

    /// Records the height real layout produced.
    ///
    /// Monotonic by construction: recording again with the same value is a no-op, and the state
    /// never walks back toward `.estimated`. Invariant 2 of §9.
    mutating func recordActualHeight(_ height: CGFloat, laidOut: Bool) {
        actualHeight = max(0, height)
        state = laidOut ? .laidOut : .measured
    }

    /// Drops the rendering surface while keeping the measured height (§4.2, stage 4). Called when
    /// a fragment scrolls far enough away that its `CTFrame` is evicted.
    mutating func demoteToMeasured() {
        guard state == .laidOut else { return }
        state = .measured
    }

    /// Written out rather than synthesized because `CFRange` is a plain C struct with no
    /// `Equatable` conformance. Declaring one retroactively would be a conformance to a type this
    /// project does not own, so the comparison stays local instead.
    static func == (lhs: FragmentDescriptor, rhs: FragmentDescriptor) -> Bool {
        lhs.charRange.location == rhs.charRange.location
            && lhs.charRange.length == rhs.charRange.length
            && lhs.intrinsicHeight == rhs.intrinsicHeight
            && lhs.state == rhs.state
            && lhs.estimatedHeight == rhs.estimatedHeight
            && lhs.actualHeight == rhs.actualHeight
    }
}
