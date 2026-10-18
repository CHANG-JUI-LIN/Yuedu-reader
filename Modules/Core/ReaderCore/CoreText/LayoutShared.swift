import CoreText
import Foundation

/// A reference type the layout pipeline treats as frozen once a chapter's layout exists:
/// built on one executor, then only read — by the main thread and by background renders.
///
/// Only `NSAttributedString`, `CTFramesetter` and `CTFrame` conform. Do not add more: every
/// conformance widens the one unchecked promise `LayoutShared` makes.
protocol ImmutableAfterLayout: AnyObject {}

extension NSAttributedString: ImmutableAfterLayout {}
extension CTFramesetter: ImmutableAfterLayout {}
extension CTFrame: ImmutableAfterLayout {}

/// The single escape hatch that lets layout values (`ChapterLayout`, `ChapterDocument`,
/// `PageLayoutArtifact`, …) be checked `Sendable` while they hold Foundation / Core Text
/// objects the SDK does not mark `Sendable`.
///
/// The promise: the wrapped object is never mutated after it is wrapped. Nothing is copied
/// on the way in, so a caller holding an `NSMutableAttributedString` (which inherits the
/// conformance) must stop mutating it before wrapping it.
///
/// Caveat, unchanged by this type: the main thread and the background prerender
/// (`CoreTextPageEngine.renderImage` from `prefetchPageImage` / `generateSnapshot`) already
/// draw the same `CTFrame` / `CTFramesetter` concurrently, while Apple documents Core Text
/// layout objects as belonging to one thread. Wrapping them here neither fixes nor worsens
/// that; it only states, in one place, what the code already does. Measured 2026-10-18 in
/// the shared-CTFrame investigation: racing draws of a ruby frame can misplace an annotation
/// and leave it wrong; frames without ruby showed no difference in any run.
///
/// Delete this type, and the conformances above, once Apple marks `NSAttributedString`
/// `Sendable` and the concurrent-draw question is settled for `CTFrame` / `CTFramesetter`.
@propertyWrapper
struct LayoutShared<Object: ImmutableAfterLayout>: @unchecked Sendable {
    let object: Object

    init(wrappedValue: Object) {
        object = wrappedValue
    }

    init(_ object: Object) {
        self.object = object
    }

    var wrappedValue: Object { object }
}
