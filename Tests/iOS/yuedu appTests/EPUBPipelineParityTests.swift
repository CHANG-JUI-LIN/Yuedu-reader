import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

struct EPUBPipelineParityTests {
    @Test @MainActor func unifiedIRPipelineRendersOfficialSampleFixtures() async throws {
        let cases: [(name: String, sample: EPUBTestFixtures.Sample, probes: [String])] = [
            ("linear-algebra", EPUBTestFixtures.linearAlgebra(), ["Let", "be a vector"]),
            ("israelsailing", EPUBTestFixtures.israelSailing(), ["אבישי", "וירוס"]),
            ("georgia", EPUBTestFixtures.georgia(), ["Georgia starts here", "30°", "north latitude"]),
            ("quiz-bindings", EPUBTestFixtures.quizBindings(), ["Gas Giants"]),
            ("prose-smoke", EPUBTestFixtures.proseSmoke(), ["Start", "Simple prose paragraph"]),
        ]

        for testCase in cases {
            let epubURL = try await EPUBTestFixtures.makeArchive(entries: testCase.sample.entries)
            let session = try await PublicationSession.open(sourceURL: epubURL)
            let builder = EPUBAttributedStringBuilder(
                session: session,
                renderSize: CGSize(width: 360, height: 640)
            )
            let chapterIndex = primaryRenderableChapterIndex(in: session)
            let result = try await builder.buildChapter(
                at: chapterIndex,
                settings: EPUBTestFixtures.renderSettings(),
                themeTextColor: .black,
                themeBackgroundColor: .white
            )

            #expect(result.attributedString.length > 0, "\(testCase.name) rendered empty")
            for probe in testCase.probes {
                #expect(
                    result.attributedString.string.contains(probe),
                    "\(testCase.name) missing probe \(probe)"
                )
            }
        }
    }

    @Test @MainActor func unifiedIRPipelinePreservesSampleStructuralMarkers() async throws {
        let georgiaURL = try await EPUBTestFixtures.makeArchive(entries: EPUBTestFixtures.georgia().entries)
        let georgiaSession = try await PublicationSession.open(sourceURL: georgiaURL)
        let georgia = try await buildPrimaryChapter(from: georgiaSession)
        #expect(georgia.anchorOffsets.keys.contains("d10e85"))
        #expect(georgia.anchorOffsets.keys.contains("d10e93"))
        #expect(georgia.attribute(
            HTMLAttributedStringBuilder.ipaPronunciationAttribute,
            near: "30°"
        ) as? String == "ˈθɜrti dɪˈgriz")

        let israelURL = try await EPUBTestFixtures.makeArchive(entries: EPUBTestFixtures.israelSailing().entries)
        let israelSession = try await PublicationSession.open(sourceURL: israelURL)
        let israel = try await buildPrimaryChapter(from: israelSession)
        #expect(EPUBTestFixtures.imageRunInfos(in: israel.attributedString).isEmpty == false)

        let quizURL = try await EPUBTestFixtures.makeArchive(entries: EPUBTestFixtures.quizBindings().entries)
        let quizSession = try await PublicationSession.open(sourceURL: quizURL)
        let quiz = try await buildPrimaryChapter(from: quizSession)
        #expect(quiz.firstAttribute(
            HTMLAttributedStringBuilder.unsupportedInteractiveAttribute,
        ) as? String == "application/x-epub-quiz")
    }

    private func primaryRenderableChapterIndex(in session: PublicationSession) -> Int {
        session.chapters.firstIndex { chapter in
            chapter.href.hasSuffix("chapter1.xhtml") || chapter.href.hasSuffix("georgia.xhtml")
        } ?? 0
    }

    @MainActor
    private func buildPrimaryChapter(from session: PublicationSession) async throws -> AttributedChapterBuildResult {
        let builder = EPUBAttributedStringBuilder(
            session: session,
            renderSize: CGSize(width: 360, height: 640)
        )
        return try await builder.buildChapter(
            at: primaryRenderableChapterIndex(in: session),
            settings: EPUBTestFixtures.renderSettings(),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
    }
}

private extension AttributedChapterBuildResult {
    func firstAttribute(_ key: NSAttributedString.Key) -> Any? {
        var found: Any?
        attributedString.enumerateAttribute(
            key,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, stop in
            if let value {
                found = value
                stop.pointee = true
            }
        }
        return found
    }

    func attribute(_ key: NSAttributedString.Key, near text: String) -> Any? {
        let range = (attributedString.string as NSString).range(of: text)
        guard range.location != NSNotFound else { return nil }

        var found: Any?
        let searchStart = max(0, range.location - 1)
        let searchEnd = min(attributedString.length, range.location + max(range.length, 1) + 1)
        let searchRange = NSRange(location: searchStart, length: max(0, searchEnd - searchStart))
        attributedString.enumerateAttribute(key, in: searchRange) { value, _, stop in
            if let value {
                found = value
                stop.pointee = true
            }
        }
        return found
    }
}
