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

    @Test func topInsetWithHeaderReservesBand() {
        let inset = ReaderLayoutMetrics.topInset(
            safeTop: 59,
            headerVisible: true,
            headerTopPadding: 6,
            headerTextGap: 12
        )
        #expect(inset == 59 + 6 + ReaderLayoutMetrics.headerHeight + 12)
    }

    @Test func topInsetWithHeaderKeepsMinimumPadding() {
        let inset = ReaderLayoutMetrics.topInset(
            safeTop: 0,
            headerVisible: true,
            headerTopPadding: 0,
            headerTextGap: 0
        )
        #expect(inset == ReaderLayoutMetrics.minimumVerticalPadding)
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
