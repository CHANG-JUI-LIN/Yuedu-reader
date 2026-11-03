import CoreGraphics

/// The page size the reader last asked to be laid out at, counted from the moment the
/// layout refresh is submitted rather than from when it reaches the engine.
///
/// `submitReaderRefresh` hands its request to a `Task`, so `engine.renderSize` only moves a
/// hop later. Measured on the iPhone Duo simulator (iOS 27.2, 2026-11-03): sent to the
/// background, the window turns to landscape for the app-switcher snapshot and straight
/// back, two size reports a few milliseconds apart. The first submitted a 951×669 layout;
/// the second compared 466×678 against an engine still at 466×678, saw nothing to do, and
/// the landscape layout landed afterwards — drawn squeezed into the portrait page until the
/// book was reopened (FB-131). Comparing against what was submitted keeps the last size
/// reported the one laid out.
struct ReaderSubmittedLayoutSize {
    private(set) var size: CGSize?

    /// Remembers the size of a refresh that lays the book out again at its viewport.
    mutating func record(_ request: ReaderRenderRefreshRequest) {
        switch request.intent {
        case .layout, .documentStyle:
            guard request.viewportSize.width > 0, request.viewportSize.height > 0 else { return }
            size = request.viewportSize
        case .appearance, .chapterContent, .modeActivation:
            break
        }
    }

    /// Whether a page of `target` size needs a layout refresh: against the size last asked
    /// for, or — before anything was — the size the engine started at.
    func needsLayout(toFit target: CGSize, engineRenderSize: CGSize) -> Bool {
        let current = size ?? engineRenderSize
        return abs(target.width - current.width) > 0.5 || abs(target.height - current.height) > 0.5
    }
}
