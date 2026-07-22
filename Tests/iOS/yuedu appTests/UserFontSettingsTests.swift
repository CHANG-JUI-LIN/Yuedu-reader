import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("User reader fonts", .serialized)
@MainActor
struct UserFontSettingsTests {

    @Test("font import reads real TrueType metadata")
    func fontImportReadsRealTrueTypeMetadata() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf")
        #expect(FileManager.default.fileExists(atPath: fixtureURL.path))

        let info = try UserFontStorageManager.shared.importFont(fileURL: fixtureURL)
        defer { UserFontStorageManager.shared.delete(info) }

        #expect(info.displayName == "Ahem")
        #expect(info.familyName == "Ahem")
        #expect(info.postScriptName == "Ahem")
        #expect(info.fileName.hasSuffix(".ttf"))
        #expect(UIFont(name: info.postScriptName, size: 18) != nil)
    }

    @Test("TXT builder uses selected reader font")
    func txtBuilderUsesSelectedReaderFont() async throws {
        let previousFont = GlobalSettings.shared.selectedReaderFontPostScript
        defer { GlobalSettings.shared.selectedReaderFontPostScript = previousFont }

        let selectedFont = try #require(UIFont(name: "Courier", size: 18))
        GlobalSettings.shared.selectedReaderFontPostScript = selectedFont.fontName
        let builder = NodeAttributedStringBuilder(
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
        #expect(BookPipelineKind.fixedPage.allowsUserSelectedReaderFont == false)
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
                    plainText: "",
                    body: .html("<p>線上內容</p>"),
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
                    plainText: "這是一段線上文字",
                    body: .plainText("這是一段線上文字"),
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

    @Test("regular-only custom font keeps its face and gains synthetic bold in TXT")
    func regularOnlyCustomFontGainsSyntheticBoldInTXT() async throws {
        let settingsStore = GlobalSettings.shared
        let previousFont = settingsStore.selectedReaderFontPostScript
        let previousBold = settingsStore.readerFontBold
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf")
        let imported = try UserFontStorageManager.shared.importFont(fileURL: fixtureURL)
        defer {
            settingsStore.selectedReaderFontPostScript = previousFont
            settingsStore.readerFontBold = previousBold
            UserFontStorageManager.shared.delete(imported)
        }

        settingsStore.selectedReaderFontPostScript = imported.postScriptName
        settingsStore.readerFontBold = false
        var renderSettings = defaultRenderSettings(fontSize: 18)
        renderSettings.isBold = true
        let builder = NodeAttributedStringBuilder(
            chapters: [
                UnifiedChapter(
                    index: 0,
                    title: "第一章",
                    paragraphs: ["這是一段粗體文字"],
                    sourceHref: nil
                )
            ]
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: renderSettings,
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        let contentRange = try #require(result.attributedString.string.range(of: "這是一段粗體文字"))
        let index = NSRange(contentRange, in: result.attributedString.string).location
        let font = try #require(
            result.attributedString.attribute(.font, at: index, effectiveRange: nil) as? UIFont
        )
        let strokeWidth = try #require(
            result.attributedString.attribute(.strokeWidth, at: index, effectiveRange: nil) as? NSNumber
        )

        #expect(font.fontName == imported.postScriptName)
        #expect(strokeWidth.doubleValue < 0)
    }

    @Test("regular-only custom font gains synthetic bold for online HTML strong text")
    func regularOnlyCustomFontGainsSyntheticBoldForOnlineHTML() async throws {
        let settingsStore = GlobalSettings.shared
        let previousFont = settingsStore.selectedReaderFontPostScript
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf")
        let imported = try UserFontStorageManager.shared.importFont(fileURL: fixtureURL)
        defer {
            settingsStore.selectedReaderFontPostScript = previousFont
            UserFontStorageManager.shared.delete(imported)
        }

        settingsStore.selectedReaderFontPostScript = imported.postScriptName
        let builder = OnlineProviderAttributedStringBuilder(
            provider: FakeOnlineBookProvider(
                payload: ChapterContentPayload(
                    index: 0,
                    title: "第一章",
                    plainText: "",
                    body: .html("<p><strong>線上粗體</strong></p>"),
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
        let contentRange = try #require(result.attributedString.string.range(of: "線上粗體"))
        let index = NSRange(contentRange, in: result.attributedString.string).location
        let font = try #require(
            result.attributedString.attribute(.font, at: index, effectiveRange: nil) as? UIFont
        )
        let strokeWidth = try #require(
            result.attributedString.attribute(.strokeWidth, at: index, effectiveRange: nil) as? NSNumber
        )

        #expect(font.fontName == imported.postScriptName)
        #expect(strokeWidth.doubleValue < 0)
    }

    @Test("native bold face does not receive synthetic stroke")
    func nativeBoldFaceDoesNotReceiveSyntheticStroke() {
        let font = UIFont.boldSystemFont(ofSize: 18)
        let attributes = UserReaderFontResolver.syntheticBoldAttributes(
            for: font,
            isBoldRequested: true
        )

        #expect(attributes[.strokeWidth] == nil)
    }

    @Test("global font import selects only the app interface font")
    func globalFontImportDoesNotChangeReaderSelection() throws {
        let settings = GlobalSettings.shared
        let savedFonts = settings.userFonts
        let savedGlobal = settings.selectedGlobalFontPostScript
        let savedReader = settings.selectedReaderFontPostScript
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf")
        var imported: UserFontInfo?
        defer {
            if let imported {
                UserFontStorageManager.shared.delete(imported)
            }
            settings.userFonts = savedFonts
            settings.selectedGlobalFontPostScript = savedGlobal
            settings.selectedReaderFontPostScript = savedReader
        }

        settings.selectedReaderFontPostScript = "Courier"
        imported = try settings.importGlobalFont(from: fixtureURL)

        #expect(settings.selectedGlobalFontPostScript == imported?.postScriptName)
        #expect(settings.selectedReaderFontPostScript == "Courier")
        #expect(settings.userFonts.contains { $0.postScriptName == imported?.postScriptName })
    }

    @Test("reader font import does not change the app interface font")
    func readerFontImportDoesNotChangeGlobalSelection() throws {
        let settings = GlobalSettings.shared
        let savedFonts = settings.userFonts
        let savedGlobal = settings.selectedGlobalFontPostScript
        let savedReader = settings.selectedReaderFontPostScript
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf")
        var imported: UserFontInfo?
        defer {
            if let imported {
                UserFontStorageManager.shared.delete(imported)
            }
            settings.userFonts = savedFonts
            settings.selectedGlobalFontPostScript = savedGlobal
            settings.selectedReaderFontPostScript = savedReader
        }

        settings.selectedGlobalFontPostScript = "ExistingGlobalFont"
        imported = try settings.importReaderFont(from: fixtureURL)

        #expect(settings.selectedReaderFontPostScript == imported?.postScriptName)
        #expect(settings.selectedGlobalFontPostScript == "ExistingGlobalFont")
        #expect(settings.userFonts.contains { $0.postScriptName == imported?.postScriptName })
    }

    @Test("deleting a shared font clears every selection that references it")
    func deletingSharedFontClearsGlobalAndReaderSelections() throws {
        let settings = GlobalSettings.shared
        let savedFonts = settings.userFonts
        let savedGlobal = settings.selectedGlobalFontPostScript
        let savedReader = settings.selectedReaderFontPostScript
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf")
        let imported = try UserFontStorageManager.shared.importFont(fileURL: fixtureURL)
        defer {
            UserFontStorageManager.shared.delete(imported)
            settings.userFonts = savedFonts
            settings.selectedGlobalFontPostScript = savedGlobal
            settings.selectedReaderFontPostScript = savedReader
        }

        settings.userFonts.removeAll { $0.postScriptName == imported.postScriptName }
        settings.userFonts.append(imported)
        settings.selectedGlobalFontPostScript = imported.postScriptName
        settings.selectedReaderFontPostScript = imported.postScriptName

        settings.deleteUserFont(imported)

        #expect(settings.selectedGlobalFontPostScript == nil)
        #expect(settings.selectedReaderFontPostScript == nil)
        #expect(!settings.userFonts.contains { $0.id == imported.id })
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
