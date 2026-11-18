import Foundation
import SwiftUI
import Testing
@testable import yuedu_app

/// 評論列表 (2026-11-17): the comment list's style — its stylesheet dialect, how it decodes
/// from someone else's theme pack, and that a theme carries it.
@Suite("評論列表樣式", .serialized)
@MainActor
struct CommentListStyleTests {
    @Test("top-level declarations dress the card, a class its part, and @dark what changes at night")
    func stylesheetParts() throws {
        let sheet = CommentListCSS.parse("""
        /* a Cay pack's panel */
        background: rgba(255, 255, 255, 0.5);
        border-radius: 10px;
        glass: true;
        .user, .name { color: #c00; font-weight: bold; }
        .comment .text { font-size: 17px; line-height: 160%; letter-spacing: 0.1em; line-clamp: 4; }
        .quote { border-left: 4px solid #E0A33A; }
        .floor { display: none; }
        @dark { color: #EEE; .user { color: rgb(0 128 255 / 50%); } }
        """)
        let card = sheet.declarations(for: .card, isDark: false)
        #expect(card.background == CommentListCSS.Color(red: 1, green: 1, blue: 1, alpha: 0.5))
        #expect(card.cornerRadius == 10 && card.glass == true && card.color == nil)
        #expect(sheet.declarations(for: .card, isDark: true).color == CommentListCSS.Color(red: 238 / 255, green: 238 / 255,
                                                                                          blue: 238 / 255, alpha: 1))
        let name = sheet.declarations(for: .name, isDark: false)
        #expect(name.color == CommentListCSS.Color(red: 204 / 255, green: 0, blue: 0, alpha: 1) && name.fontWeight == 700)
        #expect(sheet.declarations(for: .name, isDark: true).color == CommentListCSS.Color(red: 0, green: 128 / 255, blue: 1, alpha: 0.5)
                && sheet.declarations(for: .name, isDark: true).fontWeight == 700, "night over day, part by part")
        let text = sheet.declarations(for: .text, isDark: false)
        #expect(text.fontSize == 17 && text.lineHeight == .multiple(1.6) && text.letterSpacing == .em(0.1) && text.lineClamp == 4,
                "`.comment .text` is the text: a selector names its last class")
        let quote = sheet.declarations(for: .quote, isDark: false)
        #expect(quote.barWidth == 4 && quote.barColor == CommentListCSS.color("#E0A33A"))
        #expect(sheet.declarations(for: .floor, isDark: false).isHidden == true)
        #expect(sheet.ignored.isEmpty)
    }

    @Test("what the list has no counterpart for is listed, never silently dropped")
    func stylesheetIgnored() {
        let sheet = CommentListCSS.parse("""
        transform: rotate(3deg);
        border-color: red;
        .user { content: "x"; color: notacolour; padding: 4px; }
        .label { font-size: 30px; }
        .sidebar { color: red; }
        """)
        #expect(sheet.ignored == ["transform: rotate(3deg)", "border-color: red", ".user content: \"x\"",
                                  ".user color: notacolour", ".user padding: 4px", ".label font-size: 30px", ".sidebar"],
                "a property the part does not draw is listed too")
        #expect(sheet.isEmpty)
    }

    @Test("someone else's stylesheet cannot recurse without end or run past its bound")
    func stylesheetBounded() {
        let nested = String(repeating: "@dark {", count: 50_000) + "color: red;"
        let sheet = CommentListCSS.parse(nested)
        #expect(sheet.base.isEmpty && sheet.light.isEmpty, "only the first @dark is read; one inside it is not a scheme")
        let long = String(repeating: " ", count: CommentListStyle.cssLimit) + ".user { color: red; }"
        #expect(CommentListCSS.parse(long).isEmpty, "past the bound is never read")
        #expect(CommentListCSS.points("9999px") == nil && CommentListCSS.lineHeight("40") == nil)
    }

    @Test("a setup from before 評論列表 has none; a value written differently costs that value alone")
    func decoding() throws {
        let old = #"{"followsSourceSVG":false,"presetMode":"builtin","scale":1,"textScale":0.4}"#
        let bubble = try JSONDecoder().decode(AppearanceThemeReadingSettings.CommentBubble.self, from: Data(old.utf8))
        #expect(bubble.list == nil)

        let odd = #"{"cardOpacity":"lots","cornerRadius":12,"hiddenParts":["quote","sparkles"],"css":".user{color:red}"}"#
        let style = try JSONDecoder().decode(CommentListStyle.self, from: Data(odd.utf8))
        #expect(style.cardOpacity == nil && style.cornerRadius == 12 && style.hiddenParts == [.quote]
                && style.css == ".user{color:red}")

        let wild = CommentListStyle(cardOpacity: 5, avatarSize: -3, inlineReplies: 99, hiddenParts: [],
                                    css: String(repeating: "a", count: CommentListStyle.cssLimit + 10)).sanitized
        #expect(wild.cardOpacity == 0.3 && wild.avatarSize == 20 && wild.inlineReplies == 10 && wild.hiddenParts == nil
                && wild.css?.count == CommentListStyle.cssLimit)

        let round = CommentListStyle(cornerRadius: 8, hiddenParts: [.voice, .avatar], css: "glass: true;")
        #expect(try JSONDecoder().decode(CommentListStyle.self, from: JSONEncoder().encode(round)) == round)
    }

    @Test("a slider wins over the stylesheet, the stylesheet over the App, and an unstyled list is the App's")
    func precedence() {
        let app = CommentListLook.app.resolved(isDark: false, fontScale: 1)
        #expect(app.cornerRadius == DSRadius.xl && app.avatarSize == DSLayout.commentAvatarSize && app.textLineSpacing == 0
                && app.inlineReplies == DSLayout.commentInlineReplies && app.hidden.isEmpty && app.textLineLimit == nil)

        let sheet = CommentListCSS.parse(".text { font-size: 20px; line-height: 1.5; } border-radius: 10px; .avatar { display: none; }")
        let styled = CommentListLook(style: CommentListStyle(), sheet: sheet).resolved(isDark: false, fontScale: 1)
        #expect(styled.cornerRadius == 10 && styled.textLineSpacing == 10 && styled.text.pointSize == 20 && !styled.shows(.avatar))

        let slid = CommentListLook(style: CommentListStyle(cornerRadius: 3, lineSpacing: 2, hiddenParts: [.likes]), sheet: sheet)
            .resolved(isDark: false, fontScale: 2)
        #expect(slid.cornerRadius == 3 && slid.textLineSpacing == 2 && slid.text.pointSize == 40,
                "a size grows with Dynamic Type")
        #expect(!slid.shows(.likes) && !slid.shows(.avatar))
    }

    @Test("an exported setup file carries the list's style, and importing it wears it")
    func exportedFileCarriesIt() throws {
        let settings = GlobalSettings.shared
        let stores = ReadingSettingsStoresSnapshot()
        let saved = settings.commentListStyle
        let records = settings.readingSettingSyncRecords
        defer {
            settings.commentListStyle = saved
            settings.readingSettingSyncRecords = records
            stores.restore()
        }

        let mine = CommentListStyle(cardOpacity: 0.1, hiddenParts: [.images], css: ".user { color: #c00; }")
        settings.commentListStyle = mine
        let bundle = try ReaderSettingsExportSnapshot.make().makeBundle()
        let payload = try ReaderStylePackagePayload.encode(bundle, kind: .readerSettings, assetIDs: [])
        let plan = try ReaderSettingsImportService.plan(from: payload)
        #expect(plan.fullReadingSettings?.commentBubble?.list == mine, "the file holds it")

        settings.commentListStyle = CommentListStyle()
        try ReaderSettingsImportService.apply(plan)
        #expect(settings.commentListStyle == mine, "importing the file wears it again")
        #expect(settings.commentListSheet.declarations(for: .name, isDark: false).color != nil)
    }

    @Test("a theme carries the list's style, and one from before it leaves the list as it was")
    func themeCarriesIt() throws {
        let settings = GlobalSettings.shared
        let stores = ReadingSettingsStoresSnapshot()
        let saved = settings.commentListStyle
        let records = settings.readingSettingSyncRecords
        defer {
            settings.commentListStyle = saved
            settings.readingSettingSyncRecords = records
            stores.restore()
        }
        settings.readingSettingSyncRecords = []

        let mine = CommentListStyle(cornerRadius: 6, css: ".user { color: #c00; }")
        settings.commentListStyle = mine
        #expect(settings.currentCommentBubbleSettings.list == mine)
        #expect(settings.commentListSheet.declarations(for: .name, isDark: false).color != nil, "the stylesheet is read when set")
        let noted = try #require(settings.readingSettingSyncRecords.first { $0.item == "commentBubble" })
        #expect(noted.values.commentBubble?.list == mine, "an edit is noted on the 段評氣泡 row")

        var arriving = AppearanceThemeReadingSettings()
        var bubble = settings.currentCommentBubbleSettings
        bubble.list = CommentListStyle(avatarSize: 500, css: "glass: true;")
        arriving.commentBubble = bubble
        settings.applyReadingSettingsSync([
            ReadingSettingSyncRecord(item: "commentBubble", values: arriving, editedAt: Date(timeIntervalSince1970: 1_900_000_000)),
        ])
        #expect(settings.commentListStyle == CommentListStyle(avatarSize: 60, css: "glass: true;"),
                "worn, its values bounded first")
        #expect(settings.commentListSheet.declarations(for: .card, isDark: false).glass == true)

        bubble.list = nil
        arriving.commentBubble = bubble
        settings.applyReadingSettingsSync([
            ReadingSettingSyncRecord(item: "commentBubble", values: arriving, editedAt: Date(timeIntervalSince1970: 1_900_000_100)),
        ])
        #expect(settings.commentListStyle.css == "glass: true;", "a setup without one changes nothing")
    }
}
