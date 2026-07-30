import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Reader render refresh", .serialized)
@MainActor
struct ReaderRenderRefreshTests {
    @Test("refresh requests preserve their rendering contract")
    func requestPreservesRenderingContract() {
        let position = CoreTextReadingPosition(spineIndex: 3, charOffset: 144)
        let request = ReaderRenderRefreshRequest(
            intent: .layout,
            mode: .scroll,
            settings: makeSettings(fontSize: 18),
            position: position,
            viewportSize: CGSize(width: 390, height: 844)
        )

        #expect(request.mode == .scroll)
        #expect(request.position == position)
        #expect(request.intent == .layout)
    }

    @Test("only completed refresh results report completion")
    func onlyCompletedResultsReportCompletion() {
        #expect(ReaderRenderRefreshResult.completed(transactionID: 4).isCompleted)
        #expect(!ReaderRenderRefreshResult.superseded(transactionID: 5).isCompleted)
        #expect(
            !ReaderRenderRefreshResult.failed(
                transactionID: 6,
                failure: .engineUnavailable(.paged)
            ).isCompleted
        )
    }

    private func makeSettings(fontSize: CGFloat) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "sepia",
            textColor: .black,
            backgroundColor: .white,
            fontSize: fontSize,
            lineHeightMultiple: 1.6,
            lineSpacing: 10,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 24,
            marginV: 16,
            footerHeight: 24,
            contentInsets: .zero
        )
    }
}
