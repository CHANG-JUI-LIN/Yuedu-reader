import Testing
@testable import yuedu_app

struct ReaderOverlayIntegrationTests {
    @Test("Chapter page one selects opening overlays")
    func firstChapterPageUsesOpeningScope() {
        #expect(ReaderOverlayPageScope.resolve(chapterPage: 1) == .chapterOpening)
        #expect(ReaderOverlayPageScope.resolve(chapterPage: 2) == .chapterBody)
        #expect(ReaderOverlayPageScope.resolve(chapterPage: 0) == .chapterBody)
    }

    @Test("Paged reading shows one runtime overlay canvas")
    func pagedReadingShowsRuntimeOverlay() {
        let visibility = ReaderOverlayPresentationPolicy.visibility(
            isScrolling: false,
            isEditing: false
        )

        #expect(visibility.showsRuntimeCanvas)
        #expect(!visibility.showsEditorCanvas)
    }

    @Test("Scrolling reading hides fixed overlays")
    func scrollingReadingHidesOverlays() {
        let visibility = ReaderOverlayPresentationPolicy.visibility(
            isScrolling: true,
            isEditing: false
        )

        #expect(!visibility.showsRuntimeCanvas)
        #expect(!visibility.showsEditorCanvas)
    }

    @Test("Editor replaces the runtime overlay canvas")
    func editorDoesNotDuplicateRuntimeOverlay() {
        let visibility = ReaderOverlayPresentationPolicy.visibility(
            isScrolling: false,
            isEditing: true
        )

        #expect(!visibility.showsRuntimeCanvas)
        #expect(visibility.showsEditorCanvas)
    }

    @Test("Scrolling mode suppresses an active fixed-overlay editor")
    func scrollingModeSuppressesEditor() {
        let visibility = ReaderOverlayPresentationPolicy.visibility(
            isScrolling: true,
            isEditing: true
        )

        #expect(!visibility.showsRuntimeCanvas)
        #expect(!visibility.showsEditorCanvas)
    }

    @Test("Overlay editor always hides the system status bar")
    func overlayEditorHidesSystemStatusBar() {
        #expect(
            ReaderOverlayPresentationPolicy.hidesStatusBar(
                showsReaderChrome: true,
                isEditing: true
            )
        )
        #expect(
            ReaderOverlayPresentationPolicy.hidesStatusBar(
                showsReaderChrome: false,
                isEditing: true
            )
        )
    }

    @Test("Reader chrome controls status bar outside the editor")
    func readerChromeControlsSystemStatusBar() {
        #expect(
            !ReaderOverlayPresentationPolicy.hidesStatusBar(
                showsReaderChrome: true,
                isEditing: false
            )
        )
        #expect(
            ReaderOverlayPresentationPolicy.hidesStatusBar(
                showsReaderChrome: false,
                isEditing: false
            )
        )
    }

    @Test("Component movement never changes content reservations")
    func movementDoesNotReflow() {
        var layout = ReaderOverlayLayout.default
        let original = ReaderOverlayPaginationPolicy.insets(for: layout)

        layout.components[0].position = ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5)

        #expect(ReaderOverlayPaginationPolicy.insets(for: layout) == original)
    }

    @Test("Only explicit content reservations change pagination insets")
    func onlyReservationsChangeInsets() {
        var layout = ReaderOverlayLayout.default
        let original = ReaderOverlayPaginationPolicy.insets(for: layout)

        layout.components.append(
            ReaderOverlayComponent.make(
                kind: .customText,
                position: ReaderOverlayNormalizedPoint(x: 0.25, y: 0.75)
            )
        )
        layout.components[0].style.fontSize = 72
        #expect(ReaderOverlayPaginationPolicy.insets(for: layout) == original)

        layout.contentReservations = ReaderOverlayContentReservations(top: 44, bottom: 52)
        #expect(
            ReaderOverlayPaginationPolicy.insets(for: layout)
                == ReaderOverlayContentReservations(top: 44, bottom: 52)
        )
    }
}
