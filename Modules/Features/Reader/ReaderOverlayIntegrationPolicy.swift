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
}

enum ReaderOverlayPaginationPolicy {
    static func insets(
        for layout: ReaderOverlayLayout
    ) -> ReaderOverlayContentReservations {
        layout.contentReservations.normalized
    }
}
