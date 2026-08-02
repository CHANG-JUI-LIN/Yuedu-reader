import Foundation

struct ReaderOverlayVisibility: Equatable, Sendable {
    var showsRuntimeCanvas: Bool
    var showsEditorCanvas: Bool
}

enum ReaderOverlayPresentationPolicy {
    static func visibility(
        isScrolling: Bool,
        isEditing: Bool
    ) -> ReaderOverlayVisibility {
        ReaderOverlayVisibility(
            showsRuntimeCanvas: !isScrolling && !isEditing,
            showsEditorCanvas: !isScrolling && isEditing
        )
    }

    static func hidesStatusBar(
        showsReaderChrome: Bool,
        isEditing: Bool
    ) -> Bool {
        isEditing || !showsReaderChrome
    }

    /// The home indicator follows the status bar: both are system chrome that has
    /// to clear out of the immersive reading page and come back together with the
    /// reader's own bars. It gets its own entry point (rather than the call site
    /// reusing `hidesStatusBar`) so the two can diverge later without the reader
    /// reading a status-bar rule to decide a home-indicator question.
    static func hidesHomeIndicator(
        showsReaderChrome: Bool,
        isEditing: Bool
    ) -> Bool {
        hidesStatusBar(showsReaderChrome: showsReaderChrome, isEditing: isEditing)
    }
}

enum ReaderOverlayPaginationPolicy {
    static func insets(
        for layout: ReaderOverlayLayout
    ) -> ReaderOverlayContentReservations {
        layout.contentReservations.normalized
    }
}
