import CoreFoundation
import Testing
@testable import yuedu_app

struct ReaderOverlayIntegrationTests {
    @Test("Chapter page one selects opening overlays")
    func firstChapterPageUsesOpeningScope() {
        #expect(ReaderOverlayPageScope.resolve(chapterPage: 1) == .chapterOpening)
        #expect(ReaderOverlayPageScope.resolve(chapterPage: 2) == .chapterBody)
        #expect(ReaderOverlayPageScope.resolve(chapterPage: 0) == .chapterBody)
    }

    /// The whole point of the bar model: `visibility` has no scroll parameter, so
    /// there is no expression in which scroll mode loses its bars. This test would
    /// stop compiling — not merely fail — if one were reintroduced.
    @Test("Both bars show whenever they are enabled and carry a field")
    func enabledBarsShow() {
        let visibility = ReaderOverlayPresentationPolicy.visibility(
            layout: .default,
            headerEnabled: true,
            footerEnabled: true,
            isChapterOpeningPage: false
        )

        #expect(visibility.showsHeader)
        #expect(visibility.showsFooter)
    }

    @Test("A bar with no assigned field reserves nothing")
    func emptyBarIsHidden() {
        var layout = ReaderBarLayout.default
        for kind in ReaderOverlayComponentKind.allCases {
            layout.setSlot(.hidden, for: kind)
        }

        let visibility = ReaderOverlayPresentationPolicy.visibility(
            layout: layout,
            headerEnabled: true,
            footerEnabled: true,
            isChapterOpeningPage: false
        )

        #expect(!visibility.showsHeader)
        #expect(!visibility.showsFooter)
    }

    @Test("Turning a bar off hides it even when fields are assigned")
    func disabledBarIsHidden() {
        let visibility = ReaderOverlayPresentationPolicy.visibility(
            layout: .default,
            headerEnabled: false,
            footerEnabled: true,
            isChapterOpeningPage: false
        )

        #expect(!visibility.showsHeader)
        #expect(visibility.showsFooter)
    }

    @Test("Chapter-opening pages can drop the header without touching the footer")
    func chapterOpeningHidesHeaderOnly() {
        let visibility = ReaderOverlayPresentationPolicy.visibility(
            layout: .default,
            headerEnabled: true,
            footerEnabled: true,
            isChapterOpeningPage: true
        )

        #expect(!visibility.showsHeader)
        #expect(visibility.showsFooter)
    }

    /// Pagination must reserve the header band on every page. If the chapter's
    /// first page kept its band back, that page would fit more lines than the
    /// rest and the paginator would disagree with itself at every chapter
    /// boundary — which is why `ReaderView.readerBarContentInsets` always asks
    /// with `isChapterOpeningPage: false`.
    @Test("Hiding the header on chapter openings never changes reserved height")
    func chapterOpeningDoesNotReflow() {
        let reserved = ReaderOverlayPresentationPolicy.visibility(
            layout: .default,
            headerEnabled: true,
            footerEnabled: true,
            isChapterOpeningPage: false
        )
        let insets = ReaderLayoutMetrics.barContentInsets(
            safeTop: 59,
            safeBottom: 34,
            showsHeader: reserved.showsHeader,
            showsFooter: reserved.showsFooter,
            verticalMargin: 12
        )

        #expect(insets.top > 59)
        #expect(insets.bottom > 34)
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

    @Test("Home indicator hides with the reader chrome and the editor")
    func homeIndicatorFollowsImmersiveState() {
        #expect(
            !ReaderOverlayPresentationPolicy.hidesHomeIndicator(
                showsReaderChrome: true,
                isEditing: false
            )
        )
        #expect(
            ReaderOverlayPresentationPolicy.hidesHomeIndicator(
                showsReaderChrome: false,
                isEditing: false
            )
        )
        #expect(
            ReaderOverlayPresentationPolicy.hidesHomeIndicator(
                showsReaderChrome: true,
                isEditing: true
            )
        )
    }


    /// The free-position model needed a policy to promise that dragging a
    /// component never reflowed the text — position and pagination were separate
    /// systems that had to be kept in step by hand. Slots removed the problem:
    /// what changes the reserved band is whether a bar is shown, nothing else.
    @Test("Only a bar appearing or disappearing changes the reserved band")
    func onlyBarPresenceChangesReservation() {
        var layout = ReaderBarLayout.default
        let baseline = ReaderLayoutMetrics.barContentInsets(
            safeTop: 59,
            safeBottom: 34,
            showsHeader: true,
            showsFooter: true,
            verticalMargin: 12
        )

        // Moving a field between slots, restyling it, adding another one — none of
        // these touch the band.
        layout.setSlot(.headerRight, for: .chapterTitle)
        layout.setSlot(.headerCenter, for: .bookTitle)
        layout.style.fontSize = ReaderBarStyle.fontSizeRange.upperBound
        let visibility = ReaderOverlayPresentationPolicy.visibility(
            layout: layout,
            headerEnabled: true,
            footerEnabled: true,
            isChapterOpeningPage: false
        )
        #expect(
            ReaderLayoutMetrics.barContentInsets(
                safeTop: 59,
                safeBottom: 34,
                showsHeader: visibility.showsHeader,
                showsFooter: visibility.showsFooter,
                verticalMargin: 12
            ) == baseline
        )

        // Emptying the header does.
        for kind in ReaderOverlayComponentKind.allCases {
            layout.setSlot(ReaderBarSlot.slots(in: .footer).contains(layout.slot(for: kind))
                ? layout.slot(for: kind)
                : .hidden,
                for: kind)
        }
        let emptied = ReaderOverlayPresentationPolicy.visibility(
            layout: layout,
            headerEnabled: true,
            footerEnabled: true,
            isChapterOpeningPage: false
        )
        #expect(!emptied.showsHeader)
        #expect(
            ReaderLayoutMetrics.barContentInsets(
                safeTop: 59,
                safeBottom: 34,
                showsHeader: emptied.showsHeader,
                showsFooter: emptied.showsFooter,
                verticalMargin: 12
            ).top < baseline.top
        )
    }
}
