import CoreGraphics
import Foundation
import UIKit

// MARK: - ReaderTransitionSource
//
// Describes the book being opened and where the card transition should expand
// from. `frame` is the tap-time fallback while `frameProvider` resolves the
// shelf's latest geometry at transition start, so sorting and rotation do not
// send a closing book toward a stale position. `direction` selects the hinge.

struct ReaderTransitionSource {
    let bookID: UUID
    let cornerRadius: CGFloat
    /// 來源書封的全球座標 frame,nil 時 fallback 為置中卡片。
    let frame: CGRect?
    /// Latest source frame. Kept MainActor-bound because it reads live SwiftUI
    /// shelf geometry; nil falls back to the tap-time `frame` above.
    private let frameProvider: (@MainActor () -> CGRect?)?
    /// 書封快照,nil 時用純色卡片。
    let snapshot: UIImage?
    /// 開書方向。
    let direction: ReaderBookOpeningDirection

    init(
        bookID: UUID,
        cornerRadius: CGFloat = 8,
        frame: CGRect? = nil,
        frameProvider: (@MainActor () -> CGRect?)? = nil,
        snapshot: UIImage? = nil,
        direction: ReaderBookOpeningDirection = .leftSpine
    ) {
        self.bookID = bookID
        self.cornerRadius = cornerRadius
        self.frame = frame
        self.frameProvider = frameProvider
        self.snapshot = snapshot
        self.direction = direction
    }

    /// Resolve a snapshot of the geometry, or nil when unavailable.
    func resolveGeometry() -> ReaderCardGeometry? {
        guard let frame else { return nil }
        return ReaderCardGeometry(frame: frame, cornerRadius: cornerRadius)
    }

    /// Resolve live shelf geometry when available. Opening may use the
    /// tap-time frame before the destination exists; closing treats a nil live
    /// provider as source-unavailable and lets the animator center its fallback
    /// instead of flying toward stale coordinates.
    @MainActor
    func resolvedFrame(allowingTapFallback: Bool = true) -> CGRect? {
        guard let frameProvider else {
            return allowingTapFallback ? frame : nil
        }
        if let liveFrame = frameProvider() { return liveFrame }
        return allowingTapFallback ? frame : nil
    }

    func replacingDirection(_ direction: ReaderBookOpeningDirection) -> ReaderTransitionSource {
        ReaderTransitionSource(
            bookID: bookID,
            cornerRadius: cornerRadius,
            frame: frame,
            frameProvider: frameProvider,
            snapshot: snapshot,
            direction: direction
        )
    }

    /// A source whose geometry never resolves; used as a non-nil placeholder
    /// so the coordinator can record a book identity without a visible card.
    static func fallback(bookID: UUID) -> ReaderTransitionSource {
        ReaderTransitionSource(bookID: bookID)
    }

    /// True when this source can supply live geometry for the transition.
    var hasGeometry: Bool { frame != nil || frameProvider != nil }
}
