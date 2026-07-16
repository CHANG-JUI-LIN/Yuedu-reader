import Foundation
import Testing
@testable import yuedu_app

struct ReaderTOCSelectionTimingTests {
    @Test @MainActor
    func longTOCSelectionDismissesBeforeNavigation() async throws {
        let sample = EPUBTestFixtures.longTOC()
        let url = try await EPUBTestFixtures.makeArchive(entries: sample.entries)
        let session = try await PublicationSession.open(sourceURL: url)
        let chapters = ReaderTOCChapterMapper.chapters(
            from: session.tocEntries,
            session: session
        )
        let target = try #require(chapters.last)
        var isPresented = true
        var events: [String] = []

        var pendingSelection: BookChapter?
        ReaderTOCSelectionAction.perform(
            chapter: target,
            dismiss: {
                isPresented = false
                events.append("dismiss")
            },
            stage: { selected in
                pendingSelection = selected
                events.append("stage:\(selected.index)")
            }
        )

        #expect(isPresented == false)
        #expect(events == ["stage:\(target.index)", "dismiss"])
        #expect(pendingSelection?.index == target.index)

        if let selected = pendingSelection {
            pendingSelection = nil
            events.append("navigate:\(selected.index)")
        }

        #expect(events == ["stage:\(target.index)", "dismiss", "navigate:\(target.index)"])
        #expect(pendingSelection == nil)
    }
}
