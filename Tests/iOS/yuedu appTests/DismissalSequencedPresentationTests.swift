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

    @Test("iOS 17 hands a menu's ShareLink to a first-level share sheet")
    func iOS17UsesFirstLevelShareSheet() {
        #expect(MenuShareLinkPresentationPolicy.requiresFirstLevelShareSheet(osMajorVersion: 17))
        #expect(!MenuShareLinkPresentationPolicy.requiresFirstLevelShareSheet(osMajorVersion: 18))
        #expect(!MenuShareLinkPresentationPolicy.requiresFirstLevelShareSheet(osMajorVersion: 26))
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

    /// 現代's book card is a popover, and a popover that is still dismissing drops the sheet its
    /// action asks for — 聽書 slid the card back into the cover thumbnail and never showed the TTS
    /// panel. The tap must only record the route; the popover's dismissal opens it.
    @Test("現代 book-card 聽書 waits for the popover to dismiss")
    func modernBookCardPlaybackWaitsForPopoverDismissal() {
        var sequence = DismissalSequencedPresentation<ReaderModernBookCardRoute>()

        sequence.select(.secondary(.playback))

        #expect(sequence.pendingRoute == .secondary(.playback))
        #expect(sequence.consumeAfterDismissal() == .secondary(.playback))
        // Dismissing the popover again (tap-outside, chrome hiding) must not re-open the panel.
        #expect(sequence.consumeAfterDismissal() == nil)
    }

    @Test("closing the 現代 book card without choosing opens nothing")
    func modernBookCardDismissalWithoutChoiceOpensNothing() {
        var sequence = DismissalSequencedPresentation<ReaderModernBookCardRoute>()

        #expect(sequence.consumeAfterDismissal() == nil)
    }

    @Test("every 現代 book-card action is routable")
    func modernBookCardRoutesCoverEveryAction() {
        // The popover runs its action by looking the id back up in `readerSecondaryActions`,
        // so every id has to survive the round trip through the route.
        let ids: [ReaderSecondaryAction.ID] = [.playback, .download, .changeSource, .refresh]
        for id in ids {
            var sequence = DismissalSequencedPresentation<ReaderModernBookCardRoute>()
            sequence.select(.secondary(id))
            #expect(sequence.consumeAfterDismissal() == .secondary(id))
        }

        var detail = DismissalSequencedPresentation<ReaderModernBookCardRoute>()
        detail.select(.bookDetail)
        #expect(detail.consumeAfterDismissal() == .bookDetail)
    }
}
