import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// A reader's template redraws a source review card from what the card says. These tests pin
/// how the card is read, how the template is filled and sanitized, and how the filled card
/// grows to its content in the real WebView rasterizer.
@Suite("Review card templates")
struct ReviewCardTemplateTests {

    /// Verbatim 企点小说 本章说 card, trimmed to one comment (as in `ReviewCardSVGMetricsTests`).
    private let qidianChapterCard = """
    <?xml version="1.0" encoding="UTF-8"?>
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

    /// 起点 jsLib `ChapterCmtSvg`: no viewBox, a like pill beside each user, two comments.
    private let qidianTwoCommentCard = """
    <svg width="1080" height="700" xmlns="http://www.w3.org/2000/svg">\
    <rect width="1080" height="700" fill="rgba(255,255,255,0.25)" rx="35"/>\
    <text x="80" y="75" font-size="44" font-family="Arial" fill="#000">本章说</text>\
    <text x="1000" y="75" font-size="36" text-anchor="end" fill="#000">525条评论 ❯</text>\
    <rect x="880" y="150" width="120" height="64" rx="32" fill="rgba(200,200,200,0.35)"/>\
    <text x="940" y="195" font-size="40" fill="#000">10</text>\
    <text x="80" y="190" font-weight="bold" font-size="42" fill="#000">绝傲蜀风</text>\
    <text x="80" y="280" font-size="42" fill="#000">近现代背景、古董加点、漂亮妹妹</text>\
    <text x="80" y="420" font-weight="bold" font-size="42" fill="#000">刀锋大帝</text>\
    <text x="80" y="500" font-size="42" fill="#000">阅</text>\
    </svg>
    """

    /// 起点 qimo's 热评 pill: the comment shares the heading's row.
    private let hotCommentPill = """
    <svg width="1000" height="140" xmlns="http://www.w3.org/2000/svg">\
    <rect width="100%" height="100%" fill="rgba(255,255,255,0.5)" rx="70"/>\
    <text x="102" y="84" font-size="32">热评</text><text x="196" y="84" font-size="40">来抄书</text></svg>
    """

    /// 含遇見 jsLib `YuJianDrawAuthorSay`: the 作家說 tag, the author's name set larger than the
    /// note, the note wrapped at 25 characters, a 推薦 line and the author's sign-off.
    private let yuJianAuthorSay = """
    <svg width="1080" height="424" viewBox="0 0 1080 424" preserveAspectRatio="xMidYMid meet" xmlns="http://www.w3.org/2000/svg"><rect x="2" y="2" width="1076" height="420" fill="rgba(255,255,255,0.25)" rx="60" stroke="#888"/><path d="M 996 0 L 1080 0 L 1080 56 L 936 56 Z" fill="rgba(74,116,228,0.90)"/><text x="998" y="40" font-size="34" fill="#fff" font-weight="bold" text-anchor="middle" font-family="system-ui, sans-serif">作家說</text><text x="60" y="70" font-family="system-ui, sans-serif" font-size="44" fill="#000">熊狼狗</text><text x="60" y="150" font-family="system-ui, sans-serif" font-size="38" fill="#333">感謝大家一路以來的支持，今天兩更送上，明天繼續加更</text><text x="60" y="206" font-family="system-ui, sans-serif" font-size="38" fill="#333">，求月票求推薦票，我們明天見。</text><text x="60" y="282" font-family="system-ui, sans-serif" font-size="38" fill="#4A74E4" font-weight="bold">推薦：《星海》 作者：某某</text><text x="60" y="358" font-family="system-ui, sans-serif" font-size="38"><tspan fill="#000" font-weight="bold">熊狼狗：</tspan><tspan fill="#000">你不投我不投，作品何时能出头</tspan></text></svg>
    """

    /// 含遇見 jsLib `YuJianDrawChapterEnd`: two comments, each a bold name with its like pill.
    private let yuJianChapterSay = """
    <svg width="1080" height="559" viewBox="0 0 1080 559" preserveAspectRatio="xMidYMid meet" xmlns="http://www.w3.org/2000/svg"><rect x="2" y="2" width="1076" height="555" fill="rgba(255,255,255,0.25)" rx="59" stroke="#888" stroke-width="1"/><text x="60" y="75" font-size="44" font-family="system-ui, sans-serif" fill="#000">本章說</text><text x="1020" y="75" font-size="36" text-anchor="end" font-family="system-ui, sans-serif" fill="#000">7680條評論 ❯</text><rect x="859.9" y="122.5" width="160.1" height="56" rx="25" fill="rgba(200,200,200,0.35)"/><text x="60" y="160" font-weight="bold" font-size="42" font-family="system-ui, sans-serif" fill="#000">熊狼狗</text><g transform="translate(877.9,125.5) scale(2.5)" fill="#000"><path d="M8 2L17 10L8 17Z"/></g><text x="927.9" y="163.8" font-size="38" font-family="system-ui, sans-serif" fill="#000">382</text><text x="60" y="237" font-size="42" font-family="system-ui, sans-serif" fill="#000">這章看得我熱血沸騰，主角終於要出手了，等了好</text><text x="60" y="297" font-size="42" font-family="system-ui, sans-serif" fill="#000">久終於等到這一刻</text><rect x="859.9" y="372" width="160.1" height="56" rx="25" fill="rgba(200,200,200,0.35)"/><text x="60" y="409.5" font-weight="bold" font-size="42" font-family="system-ui, sans-serif" fill="#000">软泥小熊饼干怪</text><g transform="translate(877.9,375) scale(2.5)" fill="#000"><path d="M8 2L17 10L8 17Z"/></g><text x="927.9" y="413.3" font-size="38" font-family="system-ui, sans-serif" fill="#000">484</text><text x="60" y="486.5" font-size="42" font-family="system-ui, sans-serif" fill="#000">哈哈哈哈</text></svg>
    """

    /// The same card with every run bold, as 聚合段评's server draws its comment lines.
    private let allBoldChapterSay = """
    <svg width="1080" height="559" viewBox="0 0 1080 559" preserveAspectRatio="xMidYMid meet" xmlns="http://www.w3.org/2000/svg"><rect x="2" y="2" width="1076" height="555" fill="rgba(255,255,255,0.25)" rx="59" stroke="#888" stroke-width="1"/><text x="60" y="75" font-size="44" font-family="system-ui, sans-serif" fill="#000" font-weight="bold">本章說</text><text x="1020" y="75" font-size="36" text-anchor="end" font-family="system-ui, sans-serif" fill="#000" font-weight="bold">7680條評論 ❯</text><rect x="859.9" y="122.5" width="160.1" height="56" rx="25" fill="rgba(200,200,200,0.35)"/><text x="60" y="160" font-weight="bold" font-size="42" font-family="system-ui, sans-serif" fill="#000">熊狼狗</text><g transform="translate(877.9,125.5) scale(2.5)" fill="#000"><path d="M8 2L17 10L8 17Z"/></g><text x="927.9" y="163.8" font-size="38" font-family="system-ui, sans-serif" fill="#000" font-weight="bold">382</text><text x="60" y="237" font-size="42" font-family="system-ui, sans-serif" fill="#000" font-weight="bold">這章看得我熱血沸騰，主角終於要出手了，等了好</text><text x="60" y="297" font-size="42" font-family="system-ui, sans-serif" fill="#000" font-weight="bold">久終於等到這一刻</text><rect x="859.9" y="372" width="160.1" height="56" rx="25" fill="rgba(200,200,200,0.35)"/><text x="60" y="409.5" font-weight="bold" font-size="42" font-family="system-ui, sans-serif" fill="#000">软泥小熊饼干怪</text><g transform="translate(877.9,375) scale(2.5)" fill="#000"><path d="M8 2L17 10L8 17Z"/></g><text x="927.9" y="413.3" font-size="38" font-family="system-ui, sans-serif" fill="#000" font-weight="bold">484</text><text x="60" y="486.5" font-size="42" font-family="system-ui, sans-serif" fill="#000" font-weight="bold">哈哈哈哈</text></svg>
    """

    /// 聚合段评 jsLib `_dpHotCard`, the 章末卡: two comments, then its `查看全部 〉` link.
    private let juheChapterEndCard = """
    <?xml version='1.0' encoding='UTF-8'?><svg xmlns='http://www.w3.org/2000/svg' width='1800' height='1036' viewBox='0 0 1800 1036'><rect x='1' y='1' width='1798' height='1034' rx='30' fill='#F3F9F5' stroke='#C7DFCE' stroke-width='2'/><text x='56' y='160' font-size='104' fill='#4E7D5C' font-weight='bold' font-family='-apple-system, PingFang SC, Microsoft YaHei, sans-serif'>神评论</text><text x='406' y='160' font-size='78' fill='#8A9096' font-family='-apple-system, PingFang SC, Microsoft YaHei, sans-serif'>共 2381 条</text><text x='56' y='306' font-size='92' fill='#4E7D5C' font-weight='bold' font-family='-apple-system, PingFang SC, Microsoft YaHei, sans-serif'>猫猫不爱动</text><text x='1744' y='306' font-size='78' fill='#8A9096' text-anchor='end' font-family='-apple-system, PingFang SC, Microsoft YaHei, sans-serif'>👍 4138</text><text x='56' y='442' font-size='88' fill='#2F3437' font-family='-apple-system, PingFang SC, Microsoft YaHei, sans-serif'>倒反天罡哈哈哈</text><text x='56' y='588' font-size='92' fill='#4E7D5C' font-weight='bold' font-family='-apple-system, PingFang SC, Microsoft YaHei, sans-serif'>软泥小熊饼干怪</text><text x='1744' y='588' font-size='78' fill='#8A9096' text-anchor='end' font-family='-apple-system, PingFang SC, Microsoft YaHei, sans-serif'>👍 88</text><text x='56' y='724' font-size='88' fill='#2F3437' font-family='-apple-system, PingFang SC, Microsoft YaHei, sans-serif'>这章太好笑了</text><rect x='1177' y='816' width='567' height='164' rx='82' fill='#4E7D5C'/><text x='1460' y='927' font-size='78' fill='#FFFFFF' font-weight='bold' text-anchor='middle' font-family='-apple-system, PingFang SC, Microsoft YaHei, sans-serif'>查看全部 〉</text></svg>
    """

    /// 聚合段评 jsLib `_dpHotSegCard`, the 段卡: the like count beside the 神评论 capsule, the
    /// comment, then its writer signed underneath.
    private let juheParagraphCard = """
    <svg width="1800" height="444" viewBox="0 0 1800 444" xmlns="http://www.w3.org/2000/svg"><rect x="1" y="1" width="1798" height="442" rx="24" fill="#FFF9F2" stroke="#F0DCC4" stroke-width="2"/><rect x="56" y="38" width="300" height="100" rx="50" fill="#C0573F"/><text x="206" y="109" font-size="57" font-weight="bold" fill="#FFFFFF" text-anchor="middle" font-family="sans-serif">神评论</text><text x="1744" y="108" font-size="73" fill="#B0885A" text-anchor="end" font-family="sans-serif">👍 4138</text><text x="56" y="276" font-size="96" fill="#3A3A3A" font-family="sans-serif">倒反天罡哈哈哈</text><text x="56" y="394" font-size="66" fill="#9A8C7A" font-family="sans-serif">—— 猫猫不爱动</text></svg>
    """

    private let countBubble = """
    <svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 216 200'>
      <path fill='#802622' d='M20 20 H196 V150 H20 Z'/>
      <text x='108' y='110' font-size='96' fill='#FFFFFF' text-anchor='middle'>7</text>
    </svg>
    """

    private let appearance = ReviewCardTemplate.Appearance(
        pointSize: 18,
        fontFamilyCSS: "-apple-system, sans-serif",
        fontFaceCSS: "",
        textColorHex: "#333333",
        accentHex: "#D93A35",
        isNight: false
    )

    // MARK: - Reading the source card

    @Test("the 企点 本章说 card reads as its heading, count and one comment")
    func readsQidianChapterCard() throws {
        let card = try #require(ReviewCardContent.extract(from: qidianChapterCard))
        #expect(card.kind == .chapterSay)
        #expect(card.title == "本章说")
        #expect(card.count == "12条评论")
        #expect(card.number == "12")
        #expect(card.comments == [
            .init(user: "书友20250107212008897", likes: "57", content: "怎么主角栏里没有主角"),
        ])
    }

    @Test("a 起点 card with two comments reads both, each with its own like count")
    func readsTwoComments() throws {
        let card = try #require(ReviewCardContent.extract(from: qidianTwoCommentCard))
        #expect(card.number == "525")
        #expect(card.comments == [
            .init(user: "绝傲蜀风", likes: "10", content: "近现代背景、古董加点、漂亮妹妹"),
            .init(user: "刀锋大帝", likes: "", content: "阅"),
        ])
    }

    @Test("a 热评 pill is a 神評論 whose comment sits on the heading's row")
    func readsHotCommentPill() throws {
        let card = try #require(ReviewCardContent.extract(from: hotCommentPill))
        #expect(card.kind == .hotComment)
        #expect(card.title == "热评")
        #expect(card.comments == [.init(user: "", likes: "", content: "来抄书")])
    }

    @Test("起点's rebuilt dimensionless 神评论 names its kind and keeps its wrapped lines together")
    func readsRebuiltGodReview() throws {
        let reviewText = String(repeating: "評", count: 32)
        let svg = #"<svg><text y="15">\#(reviewText)</text></svg>"#
        let base64 = Data(svg.utf8).base64EncodedString()
        let raw = #"<p>段落<img src="data:image/svg+xml;base64,\#(base64),{"style":"FULL","type":"qd","click":"showCmt(123,456,7,999)"}"></p>"#
        let cleaned = ReaderHTMLUtilities.sanitizeOnlineChapterMarkup(
            raw,
            reviewContext: ReaderHTMLUtilities.LegadoReviewContext(sourceName: "起点中文", sourceURL: "https://baidu.com")
        )
        let match = try #require(cleaned.range(of: #"(?<=base64,)[^"]+"#, options: .regularExpression))
        let normalized = try #require(
            Data(base64Encoded: String(cleaned[match])).flatMap { String(data: $0, encoding: .utf8) }
        )
        let card = try #require(ReviewCardContent.extract(from: normalized))
        #expect(card.kind == .hotComment)
        #expect(card.title.isEmpty)
        #expect(card.comments == [.init(user: "", likes: "", content: reviewText)])
    }

    @Test("含遇見's 作家說 is one note: the author's name, then the note with its 推薦 and sign-off on lines of their own")
    func readsYuJianAuthorSay() throws {
        let card = try #require(ReviewCardContent.extract(from: yuJianAuthorSay))
        #expect(card.kind == .authorSay)
        #expect(card.title == "作家說")
        #expect(card.count.isEmpty)
        #expect(card.comments == [.init(
            user: "熊狼狗",
            likes: "",
            content: "感謝大家一路以來的支持，今天兩更送上，明天繼續加更，求月票求推薦票，我們明天見。\n推薦：《星海》 作者：某某\n熊狼狗：你不投我不投，作品何时能出头"
        )])
    }

    @Test("含遇見's 本章說 reads both comments, wrapped lines joined")
    func readsYuJianChapterSay() throws {
        let card = try #require(ReviewCardContent.extract(from: yuJianChapterSay))
        #expect(card.kind == .chapterSay)
        #expect(card.title == "本章說")
        #expect(card.count == "7680條評論")
        #expect(card.number == "7680")
        #expect(card.comments == [
            .init(user: "熊狼狗", likes: "382", content: "這章看得我熱血沸騰，主角終於要出手了，等了好久終於等到這一刻"),
            .init(user: "软泥小熊饼干怪", likes: "484", content: "哈哈哈哈"),
        ])
    }

    @Test("on a card whose comment lines are bold too, the like count tells a user row apart")
    func readsAllBoldChapterSay() throws {
        let card = try #require(ReviewCardContent.extract(from: allBoldChapterSay))
        #expect(card.comments == [
            .init(user: "熊狼狗", likes: "382", content: "這章看得我熱血沸騰，主角終於要出手了，等了好久終於等到這一刻"),
            .init(user: "软泥小熊饼干怪", likes: "484", content: "哈哈哈哈"),
        ])
    }

    @Test("聚合段评's 章末卡 reads its comments, and its 查看全部 link is not one")
    func readsJuheChapterEndCard() throws {
        let card = try #require(ReviewCardContent.extract(from: juheChapterEndCard))
        #expect(card.kind == .hotComment)
        #expect(card.count == "共 2381 条")
        #expect(card.comments == [
            .init(user: "猫猫不爱动", likes: "4138", content: "倒反天罡哈哈哈"),
            .init(user: "软泥小熊饼干怪", likes: "88", content: "这章太好笑了"),
        ])
    }

    @Test("聚合段评's 段卡: the like count beside the heading is the comment's, and the signature its user")
    func readsJuheParagraphCard() throws {
        let card = try #require(ReviewCardContent.extract(from: juheParagraphCard))
        #expect(card.kind == .hotComment)
        #expect(card.count.isEmpty && card.number.isEmpty)
        #expect(card.comments == [.init(user: "猫猫不爱动", likes: "4138", content: "倒反天罡哈哈哈")])
    }

    @Test("a 段評 count bubble is not a card")
    func countBubbleIsNotACard() {
        #expect(ReviewCardContent.extract(from: countBubble) == nil)
    }

    // MARK: - Filling

    @Test("a repeat block is drawn once per comment, up to its cap, and optional parts drop out")
    func fillsRepeatsAndOptionals() throws {
        let template = try ReviewCardTemplate(source: """
        <svg width="100%" height="40"><foreignObject width="100%" height="40">\
        <div xmlns="http://www.w3.org/1999/xhtml"><b>${title}</b><i data-yd-optional="num">${num}</i>\
        <p data-yd-repeat="1"><span data-yd-optional="likes">${likes}</span>${user}:${content}</p></div>\
        </foreignObject></svg>
        """)
        let card = try #require(ReviewCardContent.extract(from: qidianTwoCommentCard))
        let filled = template.filled(with: card, appearance: appearance, width: 360, colorHex: "#333333")
        #expect(filled.contains("<b>本章说</b><i>525</i>"))
        #expect(filled.contains("<p><span>10</span>绝傲蜀风:近现代背景、古董加点、漂亮妹妹</p>"))
        #expect(!filled.contains("刀锋大帝"))
        #expect(!filled.contains("data-yd-"))
    }

    @Test("the builtin 本章說 shows the card's first two comments, as 起點 does")
    func builtinChapterSayShowsTwoComments() throws {
        let template = try ReviewCardTemplate(source: ReviewCardTemplate.builtinSource(for: .chapterSay))
        var card = ReviewCardContent.sample(for: .chapterSay)
        card.comments = (1...5).map { ReviewCardContent.Comment(user: "書友\($0)", likes: "\($0)", content: "第\($0)則評論") }
        let filled = template.filled(with: card, appearance: appearance, width: 360, colorHex: "#333333")
        #expect(filled.contains("第1則評論") && filled.contains("第2則評論"))
        for index in 3...5 {
            #expect(!filled.contains("第\(index)則評論"))
        }
    }

    @Test("the builtin 作者說 names the author and keeps the note's own lines")
    func builtinAuthorSayShowsTheNote() throws {
        let template = try ReviewCardTemplate(source: ReviewCardTemplate.builtinSource(for: .authorSay))
        let card = try #require(ReviewCardContent.extract(from: yuJianAuthorSay))
        let filled = template.filled(with: card, appearance: appearance, width: 360, colorHex: "#333333")
        #expect(filled.contains(#"<span class="user">熊狼狗</span>"#))
        #expect(filled.contains("我們明天見。\n推薦：《星海》"))
        #expect(filled.contains("white-space: pre-line"))
    }

    @Test("the builtin 神評論 shows the comment without its like count")
    func builtinHotCommentHasNoLikes() throws {
        let template = try ReviewCardTemplate(source: ReviewCardTemplate.builtinSource(for: .hotComment))
        let card = try #require(ReviewCardContent.extract(from: juheParagraphCard))
        let filled = template.filled(with: card, appearance: appearance, width: 360, colorHex: "#333333")
        #expect(filled.contains("倒反天罡哈哈哈"))
        #expect(!filled.contains("4138"))
    }

    @Test("the builtin 神評論's tag takes the reading background's accent")
    @MainActor
    func builtinHotCommentTagFollowsTheBackground() throws {
        let template = try ReviewCardTemplate(source: ReviewCardTemplate.builtinSource(for: .hotComment))
        let reader = ReviewCardRaster.Reader(font: .systemFont(ofSize: 19), textColor: .black)
        var accents: Set<String> = []
        for theme in ReaderTheme.allCases {
            let themed = ReviewCardRaster.appearance(for: reader, theme: theme)
            let filled = template.filled(
                with: ReviewCardContent.sample(for: .hotComment), appearance: themed, width: 360, colorHex: "#333333"
            )
            #expect(filled.contains("background: \(themed.accentHex);"), "\(theme)")
            accents.insert(themed.accentHex)
        }
        // Red on 白色 and 黑色; 護眼綠 and 棕色 each their own.
        #expect(ReaderTheme.white.commentCardAccent == ReaderTheme.night.commentCardAccent)
        #expect(accents.count == 3)
    }

    @Test("comment text is escaped and never filled a second time")
    func escapesAndFillsOnce() throws {
        let template = try ReviewCardTemplate(source: """
        <svg height="10"><foreignObject width="100%" height="10"><p xmlns="http://www.w3.org/1999/xhtml">${content}</p></foreignObject></svg>
        """)
        let card = ReviewCardContent(
            kind: .hotComment, title: "神评", count: "", number: "",
            comments: [.init(user: "", likes: "", content: "<b>a&b</b> ${title}")]
        )
        let filled = template.filled(with: card, appearance: appearance, width: 360, colorHex: "#000")
        #expect(filled.contains("&lt;b&gt;a&amp;b&lt;/b&gt; ${title}"))
    }

    @Test("the root is sized to the column and dressed in the reader's text")
    func dressesRoot() throws {
        let template = try ReviewCardTemplate(source: #"<svg viewBox="0 0 10 10" height="24" class="mine"><rect width="100%" height="100%"/></svg>"#)
        var night = appearance
        night.isNight = true
        let filled = template.filled(
            with: ReviewCardContent.sample(for: .chapterSay), appearance: night, width: 393, colorHex: "#EEEEEE"
        )
        #expect(filled.contains(#"width="393""#))
        #expect(filled.contains(#"height="24""#))
        #expect(!filled.contains("viewBox"))
        #expect(filled.contains(#"class="mine yd-card yd-night""#))
        #expect(filled.contains("font-size:18px;font-family:-apple-system, sans-serif;color:#333333;"))
    }

    @Test("HTML inside a foreignObject is written with end tags; SVG elements may self-close")
    func writesHTMLWithEndTags() throws {
        let template = try ReviewCardTemplate(source: """
        <svg height="10"><rect width="1" height="1"/><foreignObject width="100%" height="10">\
        <div xmlns="http://www.w3.org/1999/xhtml"><span class="x"/><br/></div></foreignObject></svg>
        """)
        let filled = template.filled(
            with: ReviewCardContent.sample(for: .hotComment), appearance: appearance, width: 300, colorHex: "#000"
        )
        #expect(filled.contains(#"<rect height="1" width="1"/>"#))
        #expect(filled.contains(#"<span class="x"></span><br/>"#))
    }

    @Test("scripts, handlers and outside resources are removed")
    func sanitizes() throws {
        let template = try ReviewCardTemplate(source: """
        <svg height="10" onload="alert(1)"><script>alert(2)</script>\
        <style>@import url(https://e.com/a.css); .a { background: url(https://e.com/t.png) }</style>\
        <image href="https://e.com/p.png" width="1" height="1"/><image href="data:image/png;base64,AA==" width="1" height="1"/>\
        <a href="javascript:alert(3)"><text>x</text></a></svg>
        """)
        let filled = template.filled(
            with: ReviewCardContent.sample(for: .hotComment), appearance: appearance, width: 300, colorHex: "#000"
        )
        #expect(!filled.contains("alert"))
        #expect(!filled.contains("e.com"))
        #expect(filled.contains("data:image/png;base64,AA=="))
    }

    @Test("every built-in 玻璃 template reads and fills")
    func builtinTemplatesRead() throws {
        for kind in ReaderCommentCardKind.allCases {
            let template = try ReviewCardTemplate(source: ReviewCardTemplate.builtinSource(for: kind))
            let filled = template.filled(
                with: ReviewCardContent.sample(for: kind), appearance: appearance, width: 360, colorHex: "#333333"
            )
            #expect(!filled.contains("${"), "\(kind)")
            #expect(filled.contains(ReviewCardContent.sample(for: kind).comments[0].content), "\(kind)")
        }
    }

    @Test("a template that is not XML, or not an SVG, says why")
    func rejectsUnreadableTemplates() {
        #expect(throws: ReviewCardTemplate.Failure.self) { try ReviewCardTemplate(source: "<svg><div></svg>") }
        #expect(throws: ReviewCardTemplate.Failure.notSVG) { try ReviewCardTemplate(source: "<div/>") }
    }

    // MARK: - Choice

    @Test("a kind wears nothing until asked, then the built-in one unless its own template still exists")
    func wornTemplateFollowsChoice() {
        let mine = ReaderCommentCardCustomStyle(kind: .chapterSay, name: "Mine", svg: "<svg/>")
        let other = ReaderCommentCardCustomStyle(kind: .authorSay, name: "Other", svg: "<svg/>")
        let styles = [mine, other]
        typealias Library = ReaderCommentCardStyleLibrary
        #expect(Library.wornTemplate(for: .chapterSay, choice: .init(), styles: styles) == nil)
        #expect(Library.wornTemplate(for: .chapterSay, choice: .init(prefersSelectedStyle: true), styles: styles) == .builtin)
        #expect(Library.wornTemplate(
            for: .chapterSay, choice: .init(prefersSelectedStyle: true, selectedStyleID: mine.id), styles: styles
        ) == .custom(mine))
        #expect(Library.wornTemplate(
            for: .chapterSay, choice: .init(prefersSelectedStyle: true, selectedStyleID: other.id), styles: styles
        ) == .builtin)
        #expect(Library.wornTemplate(
            for: .chapterSay, choice: .init(prefersSelectedStyle: true, selectedStyleID: UUID()), styles: styles
        ) == .builtin)
    }

    @Test("a stored library keeps the templates it can read")
    func libraryDecodesLossily() throws {
        let style = ReaderCommentCardCustomStyle(kind: .hotComment, name: "A", svg: "<svg/>")
        var items = try JSONSerialization.jsonObject(with: JSONEncoder().encode([style])) as! [[String: Any]]
        items.append(["id": UUID().uuidString, "kind": "laterKind", "name": "B", "svg": "<svg/>"])
        let decoded = try ReaderCommentCardStyleLibrary.decode(JSONSerialization.data(withJSONObject: items))
        #expect(decoded == [style])
    }

    @Test("a package file carries a template with its colours")
    func packageRoundTrips() throws {
        let style = ReaderCommentCardCustomStyle(
            kind: .chapterSay, name: "Glass", svg: "<svg/>", dayColor: "#111111", nightColor: "#EEEEEE"
        )
        let data = try JSONEncoder().encode(ReaderCommentCardPackageFile(style: style))
        let package = try #require(ReaderCommentCardPackageFile.decode(data))
        let restored = package.makeStyle(id: style.id)
        #expect(restored == style)
        #expect(ReaderCommentCardPackageFile.decode(Data("<svg/>".utf8)) == nil)
    }

    // MARK: - Drawing

    @Test("a filled card grows to its content in the WebView rasterizer")
    @MainActor
    func filledCardGrowsWithItsComments() async throws {
        let template = try ReviewCardTemplate(source: ReviewCardTemplate.builtinSource(for: .chapterSay))
        var oneComment = try #require(ReviewCardContent.extract(from: qidianTwoCommentCard))
        oneComment.comments.removeLast()
        let twoComments = try #require(ReviewCardContent.extract(from: qidianTwoCommentCard))

        let short = try #require(await SVGWebViewRasterizer.shared.renderCard(
            svgString: template.filled(with: oneComment, appearance: appearance, width: 360, colorHex: "#333333"),
            width: 360,
            isNight: false
        ))
        let tall = try #require(await SVGWebViewRasterizer.shared.renderCard(
            svgString: template.filled(with: twoComments, appearance: appearance, width: 360, colorHex: "#333333"),
            width: 360,
            isNight: false
        ))
        #expect(short.size.width == 360)
        // Heading plus one comment at the card's fixed sizes: several lines, nowhere near the cap.
        #expect(short.size.height > 13 * 3)
        #expect(short.size.height < 400)
        // A second comment adds its user row and its line.
        #expect(tall.size.height > short.size.height + 18)
    }

    @Test("a comment's Latin run breaks at the card's edge, so its line is never left short")
    @MainActor
    func latinRunBreaksAtTheEdge() async throws {
        let template = try ReviewCardTemplate(source: ReviewCardTemplate.builtinSource(for: .chapterSay))
        func height(of content: String) async throws -> CGFloat {
            var card = ReviewCardContent.sample(for: .chapterSay)
            card.comments = [ReviewCardContent.Comment(user: "書友", likes: "1", content: content)]
            return try #require(await SVGWebViewRasterizer.shared.renderCard(
                svgString: template.filled(with: card, appearance: appearance, width: 360, colorHex: "#333333"),
                width: 360,
                isNight: false
            )).size.height
        }
        let oneLine = try await height(of: "哈哈")
        // Kept whole, a run wider than the card would stay on one line and run off its edge.
        let wideRun = try await height(of: String(repeating: "h", count: 80))
        #expect(wideRun > oneLine + 14)
    }

    @Test("a card's data-yd-glass panels come back with its image, for the system's glass")
    @MainActor
    func glassPanelsAreMeasured() async throws {
        let chapterTemplate = try ReviewCardTemplate(source: ReviewCardTemplate.builtinSource(for: .chapterSay))
        let chapter = try #require(await SVGWebViewRasterizer.shared.renderCard(
            svgString: chapterTemplate.filled(
                with: ReviewCardContent.sample(for: .chapterSay), appearance: appearance, width: 360, colorHex: "#333333"
            ),
            width: 360,
            isNight: false
        ) as? ReviewCardImage)
        let panel = try #require(chapter.glassPanels.first)
        #expect(chapter.glassPanels.count == 1)
        // The column's width, and as tall as the card less its margins.
        #expect(panel.rect.minX == 0 && panel.rect.maxX == 360)
        #expect(panel.rect.height > chapter.size.height / 2 && panel.rect.maxY <= chapter.size.height)
        #expect(panel.cornerRadius > 0)

        // 神評論 draws one pill per comment.
        let hotTemplate = try ReviewCardTemplate(source: ReviewCardTemplate.builtinSource(for: .hotComment))
        var twoPicks = ReviewCardContent.sample(for: .hotComment)
        twoPicks.comments.append(twoPicks.comments[0])
        let hot = try #require(await SVGWebViewRasterizer.shared.renderCard(
            svgString: hotTemplate.filled(with: twoPicks, appearance: appearance, width: 360, colorHex: "#333333"),
            width: 360,
            isNight: true
        ) as? ReviewCardImage)
        #expect(hot.glassPanels.count == 2)
        // The glass takes the look of the theme the card was filled for.
        #expect(!chapter.isNight && hot.isNight)
    }

    @Test("a reader font only this app registered is served to the WebView from its file")
    func importedFontIsServed() throws {
        let system = ReviewCardFonts.css(for: UIFont.systemFont(ofSize: 18))
        #expect(system.family == "-apple-system, sans-serif")
        #expect(system.fontFace.isEmpty)
        let songti = try #require(UIFont(name: "PingFangSC-Regular", size: 18))
        #expect(ReviewCardFonts.css(for: songti).fontFace.isEmpty)
    }
}
