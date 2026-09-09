import Testing
import Foundation
import CoreGraphics
@testable import yuedu_app

struct ReaderHeaderLayoutTests {

    // MARK: - Top inset reservation

    @Test func topInsetWithoutHeaderMatchesLegacyFormula() {
        #expect(ReaderLayoutMetrics.topInset(safeTop: 59, headerVisible: false) ==
                ReaderLayoutMetrics.topInset(safeTop: 59))
        #expect(ReaderLayoutMetrics.topInset(safeTop: 0, headerVisible: false) == 24)
    }

    /// These two asserted a safe-area term and a minimum clamp that this overload
    /// has never applied, so they had been failing against the shipped
    /// implementation. Corrected rather than "fixed" in the implementation: the
    /// numbers this produces are baked into layouts already migrated on users'
    /// devices (`ReaderLayoutPresetImporter`, `GlobalSettings`' legacy chain), and
    /// changing them now would silently reflow those.
    ///
    /// The *live* reader no longer comes through here at all — it uses
    /// `ReaderLayoutMetrics.barContentInsets`, which does add the safe area.
    @Test func topInsetWithHeaderReservesBandWithoutSafeArea() {
        let inset = ReaderLayoutMetrics.topInset(
            safeTop: 59,
            headerVisible: true,
            headerTopPadding: 6,
            headerTextGap: 12
        )
        #expect(inset == 6 + ReaderLayoutMetrics.headerHeight + 12)
    }

    @Test func topInsetWithHeaderIsNotClampedToMinimumPadding() {
        let inset = ReaderLayoutMetrics.topInset(
            safeTop: 0,
            headerVisible: true,
            headerTopPadding: 0,
            headerTextGap: 0
        )
        #expect(inset == ReaderLayoutMetrics.headerHeight)
    }

    // MARK: - Field placement

    @Test func defaultPositionsShowChapterTitleOnLeft() {
        let positions = ReaderHeaderLayout.defaultFieldPositions
        #expect(ReaderHeaderLayout.fields(at: .left, in: positions) == [.chapterTitle])
        #expect(ReaderHeaderLayout.fields(at: .center, in: positions).isEmpty)
        #expect(ReaderHeaderLayout.fields(at: .right, in: positions).isEmpty)
    }

    @Test func missingOrGarbageEntriesFallBackToHidden() {
        let positions = ["time": "left", "battery": "banana"]
        #expect(ReaderHeaderLayout.fields(at: .left, in: positions) == [.time])
        #expect(ReaderHeaderLayout.fields(at: .hidden, in: positions).contains(.battery))
        #expect(ReaderHeaderLayout.fields(at: .hidden, in: positions).contains(.bookTitle))
    }

    @Test func stackedFieldsKeepDeclarationOrder() {
        let positions: [String: String] = [
            "battery": "center",
            "bookTitle": "center",
            "time": "center",
            "chapterTitle": "center"
        ]
        #expect(ReaderHeaderLayout.fields(at: .center, in: positions) ==
                [.bookTitle, .chapterTitle, .time, .battery])
    }

    @Test func defaultPositionsUseValidRawValues() {
        for (fieldRaw, positionRaw) in ReaderHeaderLayout.defaultFieldPositions {
            #expect(ReaderHeaderField(rawValue: fieldRaw) != nil)
            #expect(ReaderHeaderFieldPosition(rawValue: positionRaw) != nil)
        }
    }
}
