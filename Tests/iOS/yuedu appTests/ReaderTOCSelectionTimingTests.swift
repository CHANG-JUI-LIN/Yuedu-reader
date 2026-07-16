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

        await confirmation("deferred navigation runs once") { navigated in
            let navigationTask = ReaderTOCSelectionAction.perform(
                chapter: target,
                dismiss: {
                    isPresented = false
                    events.append("dismiss")
                },
                navigate: { selected in
                    events.append("navigate:\(selected.index)")
                    navigated()
                }
            )

            #expect(isPresented == false)
            #expect(events == ["dismiss"])
            await navigationTask.value
        }

        #expect(events == ["dismiss", "navigate:\(target.index)"])
    }
}
