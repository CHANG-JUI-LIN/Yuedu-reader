import Foundation
import Testing
import UIKit
@testable import yuedu_app

struct EPUBInteractivePlaceholderTests {
    @Test @MainActor func quizBindingsRenderInteractivePlaceholderAndFallbackText() async throws {
        let epubURL = try await EPUBTestFixtures.makeArchive(entries: EPUBTestFixtures.quizBindings().entries)
        let session = try await PublicationSession.open(sourceURL: epubURL)
        let builder = EPUBAttributedStringBuilder(
            session: session,
            renderSize: CGSize(width: 320, height: 640)
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: EPUBTestFixtures.renderSettings(),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )

        #expect(result.attributedString.string.contains("Gas Giants"))

        var foundPlaceholder = false
        result.attributedString.enumerateAttribute(
            HTMLAttributedStringBuilder.unsupportedInteractiveAttribute,
            in: NSRange(location: 0, length: result.attributedString.length)
        ) { value, _, _ in
            if value as? String == "application/x-epub-quiz" {
                foundPlaceholder = true
            }
        }

        #expect(foundPlaceholder)
    }
}
