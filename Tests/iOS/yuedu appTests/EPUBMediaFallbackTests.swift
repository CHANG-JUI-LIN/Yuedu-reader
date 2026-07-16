import Testing
import UIKit
@testable import yuedu_app

@Suite("EPUB media fallback")
struct EPUBMediaFallbackTests {
    @Test @MainActor
    func controlslessBackgroundAudioPreservesAuthoredFallbackAndBody() async throws {
        let archiveURL = try await EPUBTestFixtures.makeArchive(
            entries: EPUBTestFixtures.controlslessAudioFallback().entries
        )
        let session = try await PublicationSession.open(sourceURL: archiveURL)
        let result = try await EPUBAttributedStringBuilder(
            session: session,
            renderSize: CGSize(width: 390, height: 640)
        ).buildChapter(
            at: 0,
            settings: EPUBTestFixtures.renderSettings(),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )

        let text = result.attributedString.string
        let before = try #require(text.range(of: "Before media."))
        let fallback = try #require(
            text.range(of: "Your Reading System does not support (this) audio")
        )
        let after = try #require(text.range(of: "After media."))
        #expect(before.lowerBound < fallback.lowerBound)
        #expect(fallback.lowerBound < after.lowerBound)

        var mediaAttachmentFound = false
        result.attributedString.enumerateAttribute(
            HTMLAttributedStringBuilder.mediaAttachmentAttribute,
            in: NSRange(location: 0, length: result.attributedString.length)
        ) { value, _, stop in
            if value != nil {
                mediaAttachmentFound = true
                stop.pointee = true
            }
        }
        #expect(!mediaAttachmentFound)
    }
}
