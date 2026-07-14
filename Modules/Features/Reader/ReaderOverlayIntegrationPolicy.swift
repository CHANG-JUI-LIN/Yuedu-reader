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
}

enum ReaderOverlayPaginationPolicy {
    static func insets(
        for layout: ReaderOverlayLayout
    ) -> ReaderOverlayContentReservations {
        layout.contentReservations.normalized
    }
}
