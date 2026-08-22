import Testing
@testable import yuedu_app

@Suite("Dismissal-sequenced modal presentation")
struct DismissalSequencedPresentationTests {
    private enum Route: Equatable {
        case local
        case network
    }

    @Test("iOS 17 uses a chooser that waits for dismissal")
    func iOS17UsesDismissalSequencedChooser() {
        #expect(MenuModalPresentationPolicy.requiresDismissalSequencedChooser(osMajorVersion: 17))
        #expect(!MenuModalPresentationPolicy.requiresDismissalSequencedChooser(osMajorVersion: 18))
        #expect(!MenuModalPresentationPolicy.requiresDismissalSequencedChooser(osMajorVersion: 26))
    }

    @Test("iOS 17 pushes book-source management to avoid a nested sheet")
    func iOS17PushesBookSourceManagement() {
        #expect(
            BookSourceManagementPresentationPolicy.prefersNavigationDestination(
                osMajorVersion: 17
            )
        )
        #expect(
            !BookSourceManagementPresentationPolicy.prefersNavigationDestination(
                osMajorVersion: 18
            )
        )
    }

    @Test("iOS 17 dismisses book-source import before opening the document picker")
    func iOS17UsesFirstLevelBookSourceImporter() {
        #expect(
            BookSourceImportPresentationPolicy.requiresFirstLevelImporter(
                osMajorVersion: 17
            )
        )
        #expect(
            !BookSourceImportPresentationPolicy.requiresFirstLevelImporter(
                osMajorVersion: 18
            )
        )
    }

    @Test("iOS 17 pushes 書籍資訊 so its cover pickers are first-level")
    func iOS17PushesBookInfoEdit() {
        #expect(
            BookInfoEditPresentationPolicy.prefersNavigationDestination(
                osMajorVersion: 17
            )
        )
        #expect(
            !BookInfoEditPresentationPolicy.prefersNavigationDestination(
                osMajorVersion: 18
            )
        )
    }

    @Test("iOS 17 presents reader font import from the reader level")
    func iOS17UsesFirstLevelReaderFontImporter() {
        #expect(
            ReaderSettingsPresentationPolicy.requiresFirstLevelImporter(
                osMajorVersion: 17
            )
        )
        #expect(
            !ReaderSettingsPresentationPolicy.requiresFirstLevelImporter(
                osMajorVersion: 18
            )
        )
    }

    @Test("selected route stays pending until the chooser dismisses")
    func routeActivatesOnlyAfterDismissal() {
        var sequence = DismissalSequencedPresentation<Route>()

        sequence.select(.network)

        #expect(sequence.pendingRoute == .network)
        #expect(sequence.consumeAfterDismissal() == .network)
        #expect(sequence.pendingRoute == nil)
        #expect(sequence.consumeAfterDismissal() == nil)
    }

    @Test("cancelled chooser does not activate a route")
    func cancelledChooserDoesNotPresent() {
        var sequence = DismissalSequencedPresentation<Route>()
        sequence.select(.local)

        sequence.cancel()

        #expect(sequence.pendingRoute == nil)
        #expect(sequence.consumeAfterDismissal() == nil)
    }
}
