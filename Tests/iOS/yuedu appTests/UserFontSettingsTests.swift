import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("User reader fonts", .serialized)
@MainActor
struct UserFontSettingsTests {

    @Test("TXT builder uses selected reader font")
    func txtBuilderUsesSelectedReaderFont() async throws {
        let previousFont = GlobalSettings.shared.selectedReaderFontPostScript
        defer { GlobalSettings.shared.selectedReaderFontPostScript = previousFont }

        let selectedFont = try #require(UIFont(name: "Courier", size: 18))
        GlobalSettings.shared.selectedReaderFontPostScript = selectedFont.fontName
        let builder = TXTAttributedStringBuilder(
            chapters: [
                UnifiedChapter(
                    index: 0,
                    title: "第一章",
                    paragraphs: ["這是一段文字"],
                    sourceHref: nil
                )
            ]
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: ReaderRenderSettings(
                theme: "sepia",
                textColor: .black,
                backgroundColor: .white,
                fontSize: 18,
                lineHeightMultiple: 1.6,
                lineSpacing: 10,
                paragraphSpacing: 8,
                letterSpacing: 0,
                marginH: 24,
                marginV: 16,
                footerHeight: 24,
                contentInsets: .zero
            ),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )

        let bodyStart = result.attributedString.string.count > "第一章\n".count ? "第一章\n".count : 0
        let bodyFont = try #require(
            result.attributedString.attribute(.font, at: bodyStart, effectiveRange: nil) as? UIFont
        )
        #expect(bodyFont.fontName == selectedFont.fontName)
    }

    @Test("EPUB pipeline does not expose user-selected font")
    func epubPipelineDoesNotExposeUserSelectedFont() {
        #expect(BookPipelineKind.epub.allowsUserSelectedReaderFont == false)
        #expect(BookPipelineKind.txt.allowsUserSelectedReaderFont == true)
    }

    @Test("online books expose user-selected font while EPUB does not")
    func onlineBooksExposeUserSelectedFontWhileEPUBDoesNot() {
        var onlineBook = ReadingBook(title: "線上書", source: "https://example.com/book", contentFilename: "")
        onlineBook.isOnline = true

        let epubBook = ReadingBook(title: "EPUB", source: "local_epub", contentFilename: "book.epub")

        #expect(onlineBook.allowsUserSelectedReaderFont == true)
        #expect(epubBook.allowsUserSelectedReaderFont == false)
    }

    @Test("online HTML chapters use selected reader font as default")
    func onlineHTMLChaptersUseSelectedReaderFontAsDefault() async throws {
        let previousFont = GlobalSettings.shared.selectedReaderFontPostScript
        defer { GlobalSettings.shared.selectedReaderFontPostScript = previousFont }

        let selectedFont = try #require(UIFont(name: "Courier", size: 18))
        GlobalSettings.shared.selectedReaderFontPostScript = selectedFont.fontName
        let builder = OnlineProviderAttributedStringBuilder(
            provider: FakeOnlineBookProvider(
                payload: ChapterContentPayload(
                    index: 0,
                    title: "第一章",
                    content: "",
                    renderHTML: "<p>線上內容</p>",
                    sourceHref: nil
                )
            ),
            renderSize: CGSize(width: 320, height: 640)
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: defaultRenderSettings(fontSize: 18),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )

        let contentStart = try #require(result.attributedString.string.range(of: "線上內容"))
        let nsIndex = NSRange(contentStart, in: result.attributedString.string).location
        let bodyFont = try #require(
            result.attributedString.attribute(.font, at: nsIndex, effectiveRange: nil) as? UIFont
        )
        #expect(bodyFont.fontName == selectedFont.fontName)
    }

    @Test("online TXT fallback uses selected reader font")
    func onlineTXTFallbackUsesSelectedReaderFont() async throws {
        let previousFont = GlobalSettings.shared.selectedReaderFontPostScript
        defer { GlobalSettings.shared.selectedReaderFontPostScript = previousFont }

        let selectedFont = try #require(UIFont(name: "Courier", size: 18))
        GlobalSettings.shared.selectedReaderFontPostScript = selectedFont.fontName
        let builder = OnlineProviderAttributedStringBuilder(
            provider: FakeOnlineBookProvider(
                payload: ChapterContentPayload(
                    index: 0,
                    title: "第一章",
                    content: "這是一段線上文字",
                    renderHTML: nil,
                    sourceHref: nil
                )
            ),
            renderSize: CGSize(width: 320, height: 640)
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: defaultRenderSettings(fontSize: 18),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )

        let contentStart = try #require(result.attributedString.string.range(of: "這是一段線上文字"))
        let nsIndex = NSRange(contentStart, in: result.attributedString.string).location
        let bodyFont = try #require(
            result.attributedString.attribute(.font, at: nsIndex, effectiveRange: nil) as? UIFont
        )
        #expect(bodyFont.fontName == selectedFont.fontName)
    }

    private func defaultRenderSettings(fontSize: CGFloat) -> ReaderRenderSettings {
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

private struct FakeOnlineBookProvider: BookContentProvider {
    let payload: ChapterContentPayload

    var totalChapters: Int { 1 }

    func chapterTitle(at index: Int) -> String {
        index == payload.index ? payload.title : ""
    }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        guard index == payload.index else {
            throw BookContentProviderError.chapterIndexOutOfRange(index)
        }
        return payload
    }
}
