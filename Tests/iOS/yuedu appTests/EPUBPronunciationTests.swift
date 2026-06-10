import AVFoundation
import Foundation
import Testing
import UIKit
@testable import yuedu_app

struct EPUBPronunciationTests {
    @Test func parsesPLSLexiconEntries() {
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <lexicon version="1.0" alphabet="ipa" xml:lang="en" xmlns="http://www.w3.org/2005/01/pronunciation-lexicon">
          <lexeme><grapheme>30°</grapheme><phoneme>ˈθɜrti dɪˈgriz</phoneme></lexeme>
        </lexicon>
        """.utf8)

        let parsed = PLSLexicon.parse(data: data, href: "OPS/lexicon/en.pls")
        #expect(parsed != nil)
        guard let lexicon = parsed else { return }

        #expect(lexicon.href == "OPS/lexicon/en.pls")
        #expect(lexicon.language == "en")
        #expect(lexicon.alphabet == "ipa")
        #expect(lexicon.lexemes == [
            PLSLexicon.Lexeme(grapheme: "30°", phoneme: "ˈθɜrti dɪˈgriz")
        ])
    }

    @Test @MainActor func renderableNodeCarriesSSMLIPAAttribute() async throws {
        let epubURL = try await EPUBTestFixtures.makeArchive(entries: EPUBTestFixtures.georgia().entries)
        let session = try await PublicationSession.open(sourceURL: epubURL)

        #expect(session.pronunciationLexicons.count == 1)

        let builder = EPUBAttributedStringBuilder(
            session: session,
            renderSize: CGSize(width: 320, height: 640)
        )
        let result = try await builder.buildChapter(
            at: 1,
            settings: EPUBTestFixtures.renderSettings(),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        let range = (result.attributedString.string as NSString).range(of: "30°")

        #expect(range.location != NSNotFound)
        let ipa = result.attributedString.attribute(
            HTMLAttributedStringBuilder.ipaPronunciationAttribute,
            at: range.location,
            effectiveRange: nil
        ) as? String
        #expect(ipa == "ˈθɜrti dɪˈgriz")
    }

    @Test func annotatorPrefersSSMLOverLexiconAndAppliesRemainingLexiconMatches() {
        let text = "30° and 30°"
        let attributed = NSMutableAttributedString(string: text)
        attributed.addAttribute(
            HTMLAttributedStringBuilder.ipaPronunciationAttribute,
            value: "ssml",
            range: (text as NSString).range(of: "30°")
        )
        let lexicon = PLSLexicon(
            href: "OPS/lexicon/en.pls",
            language: "en",
            alphabet: "ipa",
            lexemes: [PLSLexicon.Lexeme(grapheme: "30°", phoneme: "lexicon")]
        )

        let hints = TTSPronunciationAnnotator.hints(
            in: attributed,
            lexicons: [lexicon],
            bookLanguage: "en"
        )

        #expect(hints == [
            TTSPronunciationHint(range: NSRange(location: 0, length: 3), ipa: "ssml"),
            TTSPronunciationHint(range: NSRange(location: 8, length: 3), ipa: "lexicon")
        ])
    }

    @Test func chunkerProjectsChapterHintsIntoChunkLocalRanges() {
        let text = "Alpha 30°. Beta"
        let hint = TTSPronunciationHint(range: (text as NSString).range(of: "30°"), ipa: "ipa")
        let chunks = TTSTextChunker.splitWithRanges(text, targetChunkLength: 10)
        let chunk = chunks.first { NSIntersectionRange($0.sourceRange, hint.range).length > 0 }
        #expect(chunk != nil)
        guard let chunk else { return }
        let projected = TTSPronunciationProjector.project([hint], into: chunk.sourceRange)

        #expect(projected == [
            TTSPronunciationHint(range: NSRange(location: 6, length: 3), ipa: "ipa")
        ])
    }

    @Test func systemUtteranceUsesIPAAttributedString() {
        let utterance = SystemTTSEngine.makeUtterance(
            text: "30°",
            rate: 0.5,
            pronunciationHints: [
                TTSPronunciationHint(range: NSRange(location: 0, length: 3), ipa: "ˈθɜrti")
            ]
        )
        let attributed = utterance.attributedSpeechString
        let key = NSAttributedString.Key(rawValue: AVSpeechSynthesisIPANotationAttribute)

        #expect(attributed.attribute(key, at: 0, effectiveRange: nil) as? String == "ˈθɜrti")
    }
}
