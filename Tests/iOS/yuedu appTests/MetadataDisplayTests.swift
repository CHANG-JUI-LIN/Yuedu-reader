import Foundation
import Testing
@testable import yuedu_app

/// 中繼資料語言偏好推薦 on the source's titles, authors and blurbs (maintainer, 2026-10-25). The
/// blurbs are cut from Bangumi's top-ranked novel and manga summaries (2026-10-25), the default
/// home's Chinese rankings: 简体, 繁體, Japanese, and a Chinese paragraph beside a Japanese one.
@Suite("Metadata display")
struct MetadataDisplayTests {
    private let traditional = MetadataDisplay(language: "zh-Hant")
    private let simplified = MetadataDisplay(language: "zh-Hans")

    @Test("titles and names in the chosen script; one with kana, Japanese, as it is")
    func titles() {
        #expect(traditional.text("灌篮高手 完全版") == "灌籃高手 完全版")
        #expect(traditional.text("田中芳树") == "田中芳樹")
        #expect(simplified.text("鋼之鍊金術師") == "钢之炼金术师")
        #expect(traditional.text("安達としまむら") == "安達としまむら")
        #expect(MetadataDisplay(language: "en").text("灌篮高手") == "灌篮高手")
        #expect(MetadataDisplay(language: "ja").text("灌篮高手") == "灌篮高手")
    }

    @Test("a Chinese blurb in the chosen script; one in another language as sent")
    func chineseBlurbs() {
        #expect(traditional.blurb("在国中时期创下五十次失恋纪录的著名坏学生─樱木花道，进入了县立湘北高中。")
                    == .text("在國中時期創下五十次失戀紀錄的著名壞學生─櫻木花道，進入了縣立湘北高中。"))
        #expect(simplified.blurb("故事世界中有七顆名為龍珠的物件。") == .text("故事世界中有七颗名为龙珠的物件。"))
        let english = "Harry Potter is a series of seven fantasy novels."
        #expect(traditional.blurb(english) == .text(english))
        #expect(MetadataDisplay(language: "en").blurb("ここは汚れなき理想郷のはずだった。") == .text("ここは汚れなき理想郷のはずだった。"))
        #expect(traditional.blurb(nil) == nil)
        #expect(traditional.blurb("") == nil)
    }

    @Test("Chinese that quotes a Japanese title stays whole")
    func quotedJapanese() {
        let quoted = "《惊爆危机》，又名《全金属狂潮》，原名フルメタル・パニック!（Full Metal Panic!，通称フルメタ或FMP!），是日本作家贺东招二于1998年开始创作的轻小说。"
        #expect(traditional.blurb(quoted) == .text(quoted.converted(to: .toTraditional)))
        let hiragana = "<<付丧堂骨董店>> (<<“不思议”取り扱います 付丧堂骨董店>>) : 是由电击文库发行的日本轻小说.作者是御堂彰彦,插画家是タケシマサトシ。"
        #expect(JapaneseSentences.removing(from: hiragana) == hiragana)
        let particle = "《奇诺之旅》，时雨泽惠一的作品之一。2000年3月に『电撃hp』Vol.6上刊载。由MEDIAWORKS电击文库出版。"
        #expect(JapaneseSentences.removing(from: particle) == particle)
    }

    @Test("a Chinese paragraph beside a Japanese one: the Chinese, the rule between them gone")
    func bilingual() {
        let chineseFirst = """
        “我的人生，差不多都是哥哥呢。”
        这是一个描绘“兄控与妹控”兄妹“一生”的故事。
        她六岁，我十岁。
        ---------------------------------------------
        シスコン＆ブラコン兄妹の“一生”を描く、兄妹ラブコメ

        「わたしのじんせーは、にーさんでほとんどだもん」
        """
        #expect(JapaneseSentences.removing(from: chineseFirst) == """
        “我的人生，差不多都是哥哥呢。”
        这是一个描绘“兄控与妹控”兄妹“一生”的故事。
        她六岁，我十岁。
        """)
        // Bangumi's list rows read the summary as one line (`OPDSClient.plainMetadata`).
        let oneLine = chineseFirst.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
        #expect(JapaneseSentences.removing(from: oneLine)
                    == "“我的人生，差不多都是哥哥呢。” 这是一个描绘“兄控与妹控”兄妹“一生”的故事。 她六岁，我十岁。")

        let japaneseFirst = "誰かと同じになりたい女の子たちのおはなしです。ガールズラブ作品です。\n这是想要和某人「相同」的女孩子们的故事。"
        #expect(traditional.blurb(japaneseFirst) == .text("這是想要和某人「相同」的女孩子們的故事。"))

        // A credit too short to tell goes with the Japanese before it.
        let credit = "然而假象看上去有多美，揭开假象之后看到的现实就有多可怕……\n\nここは汚れなき理想郷のはずだった。\n1000年後の日本。伝説。消える子供たち。\n\n第29回日本SF大賞受賞"
        #expect(JapaneseSentences.removing(from: credit) == "然而假象看上去有多美，揭开假象之后看到的现实就有多可怕……")

        let manga = "在文明崩坏的末日世界中，千都与优梨两人乘坐半履带车Kettenkrad在废墟徘徊、寻找食物。\n\n電撃コミック大賞金賞作家が描く、ガールズラブストーリー。"
        #expect(JapaneseSentences.removing(from: manga) == "在文明崩坏的末日世界中，千都与优梨两人乘坐半履带车Kettenkrad在废墟徘徊、寻找食物。")
    }

    @Test("all Japanese: that there is no blurb in the chosen script")
    func japaneseOnly() {
        let japanese = [
            "中学3年間で50人もの女性にフラれた高校1年の不良少年・桜木花道は背の高さと身体能力からバスケットボール部に誘われる。",
            // Katakana and kanji with hardly any hiragana.
            "クリシェ＝アルベリネア＝クリシュタンド――アルベラン王国将軍。\n当時追い詰められたアルベランを持ち直させた。",
            "ドラゴン、ゴブリン、イエティ、ネッシー、ガネーシャ、宇宙人……そんな世界中の「人ならざる者」をかくまう島。",
            "・月刊コミックブレイド連載当時のカラーページを完全再現\n・各巻300ページオーバーの大ボリューム",
            // A Latin title and a Chinese-looking list among Japanese.
            "『DDD（Decoration Disorder Disconnection）』\n\n奈須きのこによる伝奇小説。",
            "古典部員が高校を卒業するまで、シリーズが続く予定。\n\n　　*刊行顺序：\n　　　　氷菓\n　　　　愚者のエンドロール",
        ]
        for blurb in japanese {
            #expect(traditional.blurb(blurb) == .unavailable(localized("沒有繁體中文簡介")), "\(blurb)")
        }
        #expect(simplified.blurb(japanese[0]) == .unavailable(localized("沒有簡體中文簡介")))
    }

    @MainActor
    @Test("a card reads the chosen script; its route keeps what the source sent")
    func card() throws {
        let key = SourceItemKey(instance: SourceInstanceKey(type: .module, id: "bangumi"), item: "1")
        let record = SourceRecord(key: key, title: "灌篮高手", authors: ["井上雄彦"], language: nil, contentKind: .comic,
                                  identifiers: [], copyID: nil, acquisitions: [])
        let summary = WorkSummary(title: "灌篮高手", authors: ["井上雄彦"], cover: nil,
                                  blurb: "中学3年間で50人もの女性にフラれた高校1年の不良少年。", language: nil,
                                  contentKind: .comic, category: "运动")
        let card = try #require(HomeCardContent(.item(record, summary, .bibliographic), status: { _ in nil },
                                                shelfBooks: [:], display: traditional))
        #expect(card.title == "灌籃高手")
        #expect(card.accessibilityLabel == "灌籃高手")
        #expect(card.blurb == localized("沒有繁體中文簡介"))
        #expect(card.category == "運動")
        #expect(card.route?.summary.title == "灌篮高手")
    }
}
