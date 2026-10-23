import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 氣泡設定's library writes: 匯入樣式 on every page, and what deleting a worn template does.
@MainActor
@Suite("Comment style import and library", .serialized)
struct ReaderCommentStyleImportTests {
    private static let cardSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="300" height="80"><text x="10" y="40">${title}</text></svg>
    """

    /// Runs `body` and puts back every setting these tests touch.
    private func withRestoredSettings(_ body: (GlobalSettings) throws -> Void) rethrows {
        let settings = GlobalSettings.shared
        let stores = ReadingSettingsStoresSnapshot()
        let old = (
            choices: settings.commentCardChoices,
            cards: settings.commentCardCustomStyles,
            bubbles: settings.commentBubbleCustomStyles,
            mode: settings.commentBubblePresetMode,
            selectedBubble: settings.commentBubbleSelectedCustomStyleID,
            follows: settings.commentBubbleFollowsSourceSVG,
            scale: settings.commentBubbleScale
        )
        defer {
            settings.commentCardCustomStyles = old.cards
            settings.commentCardChoices = old.choices
            settings.applyCommentBubbleSync(styles: old.bubbles)
            settings.applyCommentBubbleSync(selection: old.selectedBubble)
            settings.commentBubblePresetMode = old.mode
            settings.commentBubbleFollowsSourceSVG = old.follows
            settings.commentBubbleScale = old.scale
            stores.restore()
        }
        try body(settings)
    }

    @Test("each page's 匯入樣式 opens the picker for its own target")
    func routesNameTheirTargets() {
        #expect(ReaderStyleImportRoute.commentBubble.commentStyleTarget == .bubble)
        for kind in ReaderCommentCardKind.allCases {
            let route = ReaderStyleImportRoute.commentCard(kind)
            #expect(route.commentStyleTarget == .card(kind))
            #expect(route.contentTypes == ReaderCommentStyleImporter.contentTypes)
        }
        #expect(ReaderStyleImportRoute.dialogueBubble.commentStyleTarget == nil)
    }

    @Test("a card package lands in the kind it names and is worn there")
    func cardPackageLandsInItsKind() throws {
        try withRestoredSettings { settings in
            let exported = try CommentStyleJSONExport(card: ReaderCommentCardCustomStyle(
                kind: .hotComment,
                name: "熱評卡",
                svg: Self.cardSVG,
                dayColor: "#112233",
                nightColor: "#DDEEFF"
            ))
            let chapterChoice = settings.commentCardChoices[.chapterSay]

            // Imported from the 本章說 page.
            let message = try ReaderCommentStyleImporter.importCard(exported.data, fileName: "x", kind: .chapterSay)

            let imported = try #require(settings.commentCardStyles(of: .hotComment).first { $0.name == "熱評卡" })
            #expect(imported.dayColor == "#112233")
            #expect(imported.nightColor == "#DDEEFF")
            #expect(settings.wornCommentCardTemplate(for: .hotComment) == .custom(imported))
            #expect(settings.commentCardChoices[.chapterSay] == chapterChoice)
            #expect(message == ReaderCommentStyleImporter.appliedMessage(for: .hotComment))
        }
    }

    @Test("a bare SVG becomes a template of the page's kind, named after its file")
    func bareSVGTakesThePageKind() throws {
        try withRestoredSettings { settings in
            _ = try ReaderCommentStyleImporter.importCard(Data(Self.cardSVG.utf8), fileName: "我的作者說", kind: .authorSay)

            let imported = try #require(settings.commentCardStyles(of: .authorSay).first { $0.name == "我的作者說" })
            #expect(imported.dayColor == nil)
            #expect(settings.wornCommentCardTemplate(for: .authorSay) == .custom(imported))
        }
    }

    @Test("an unreadable template is refused and the library is left as it was")
    func unreadableTemplateIsRefused() {
        withRestoredSettings { settings in
            let before = settings.commentCardCustomStyles
            let choices = settings.commentCardChoices

            #expect(throws: ReaderCommentStyleImporter.Failure.self) {
                try ReaderCommentStyleImporter.importCard(Data("<div>no svg</div>".utf8), fileName: "bad", kind: .chapterSay)
            }
            #expect(settings.commentCardCustomStyles == before)
            #expect(settings.commentCardChoices == choices)
        }
    }

    @Test("deleting the worn template goes back to 玻璃 and keeps the preference")
    func deletingWornTemplateFallsBackToGlass() {
        withRestoredSettings { settings in
            let style = ReaderCommentCardCustomStyle(kind: .chapterSay, name: "刪除測試", svg: Self.cardSVG)
            settings.upsertCommentCardStyle(style)
            #expect(settings.commentCardChoices[.chapterSay].prefersSelectedStyle)

            settings.deleteCommentCardStyle(id: style.id)

            #expect(settings.commentCardChoices[.chapterSay].selectedStyleID == nil)
            #expect(settings.commentCardChoices[.chapterSay].prefersSelectedStyle)
            #expect(settings.wornCommentCardTemplate(for: .chapterSay) == .builtin)
            #expect(!settings.commentCardCustomStyles.contains { $0.id == style.id })
        }
    }

    @Test("turning 優先使用選取的樣式 off draws the source's card, and the snapshot follows")
    func preferenceOffWearsSourceCard() {
        withRestoredSettings { settings in
            settings.selectCommentCardStyle(id: nil, for: .hotComment)
            #expect(GlobalSettings.snapshot.wornCommentCardTemplate(for: .hotComment) == .builtin)

            settings.setCommentCardPrefersSelectedStyle(false, for: .hotComment)

            #expect(settings.wornCommentCardTemplate(for: .hotComment) == nil)
            #expect(GlobalSettings.snapshot.wornCommentCardTemplate(for: .hotComment) == nil)
        }
    }

    /// 企点小说's 本章说 card, trimmed to one comment (as in `ReviewCardTemplateTests`).
    private static let sourceChapterCard = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1000" height="322" viewBox="0 0 1000 322">
        <rect x="0" y="30" width="1000" height="262" rx="30" fill="rgba(244,249,245,0.55)"/>
        <rect x="44" y="62" width="164" height="56" rx="28" fill="#5E8A6A"/>
        <text x="126" y="101" font-size="34" fill="#FFFFFF" text-anchor="middle" font-weight="bold">本章说</text>
        <text x="956" y="102" font-size="34" fill="#5E8A6A" text-anchor="end" font-weight="bold">12条评论 〉</text>
        <rect x="44" y="130" width="912" height="2" fill="#e8e8e851"/>
        <text x="44" y="182" font-size="36" fill="#5E8A6A" font-weight="bold">书友20250107212008897</text>
        <text x="956" y="186" font-size="32" fill="#F06260" text-anchor="end" font-weight="bold">57</text>
        <text x="44" y="236" font-size="38" fill="#333333">怎么主角栏里没有主角</text>
    </svg>
    """

    @Test("the reader redraws a source card from the worn template, and draws the source's once it is off")
    func wornTemplateReachesTheReader() throws {
        try withRestoredSettings { settings in
            for kind in ReaderCommentCardKind.allCases {
                settings.setCommentCardPrefersSelectedStyle(false, for: kind)
            }
            let reader = ReviewCardRaster.Reader(font: .systemFont(ofSize: 18), textColor: .black)
            @MainActor func redrawn() -> String? {
                ReviewCardRaster.templatedSVG(Self.sourceChapterCard, columnWidth: 360, reader: reader, path: "test")
            }
            #expect(redrawn() == nil)

            // Another kind's template leaves this card the source's.
            settings.selectCommentCardStyle(id: nil, for: .hotComment)
            #expect(redrawn() == nil)

            settings.selectCommentCardStyle(id: nil, for: .chapterSay)
            let svg = try #require(redrawn())
            #expect(svg.contains("yd-card"))
            #expect(svg.contains("怎么主角栏里没有主角"))
            #expect(svg.contains("书友20250107212008897"))

            settings.setCommentCardPrefersSelectedStyle(false, for: .chapterSay)
            #expect(redrawn() == nil)
        }
    }

    @Test("a bubble.json import keeps its colours and size and is worn")
    func bubblePackageKeepsColoursAndSize() throws {
        try withRestoredSettings { settings in
            let json = """
            {
              "name": "匯入測試氣泡",
              "dayNormalColor": "#808080",
              "dayEmphasisColor": "#FF0000",
              "nightNormalColor": "#909090",
              "nightEmphasisColor": "#FF4444",
              "sizeScale": 1.25,
              "svgTemplate": "<svg viewBox=\\"0 0 40 24\\"><rect x=\\"1\\" y=\\"1\\" width=\\"38\\" height=\\"22\\" fill=\\"none\\" stroke=\\"${color}\\"/><text x=\\"20\\" y=\\"17\\" fill=\\"${color}\\">${num}</text></svg>"
            }
            """

            _ = try ReaderCommentStyleImporter.importBubble(Data(json.utf8), fileName: "ignored")

            let worn = try #require(settings.commentBubbleSelectedCustomStyle)
            #expect(settings.commentBubblePresetMode == .custom)
            #expect(worn.name == "匯入測試氣泡")
            #expect(worn.nightEmphasisColor == "#FF4444")
            #expect(settings.commentBubbleScale == 1.25)
            #expect(!settings.commentBubbleFollowsSourceSVG)

            // What 匯出當前樣式 writes for it reads back as the same style.
            #expect(worn.needsPackageToExport)
            let exported = try CommentStyleJSONExport(bubble: worn)
            let reread = try #require(ReaderCommentBubbleCustomStyle.fromBubblePackage(exported.data))
            #expect(reread.svg == worn.svg)
            #expect(reread.dayEmphasisColor == worn.dayEmphasisColor)
            #expect(reread.sizeScale == worn.sizeScale)
        }
    }
}
