import SwiftUI

// 大圖卡片 is a 分類卡 (maintainer, 2026-10-27: 「大圖卡片應該是分類或宣傳用的…可以拿來當分類卡」,
// 「我們肯定要根據分類作默認的圖片設計」): a card per list, its face designed from the list's name
// as Apple Books' More to Explore draws Romance — a drawing for the kind of book on a ground —
// with no covers. A name that says no kind gets a book on a ground the name picks, so a card
// looks the same every time it is drawn.

/// What a list's designed face draws: the symbol for the kind of book its name says, and the
/// ground (`DSColor.categoryArtPalette`) it stands on.
struct HomeCategoryFace: Equatable {
    let symbol: String
    let palette: Int

    init(name: String) {
        let lowered = name.lowercased()
        // Latin keywords are whole words ("war" is not in "software"); the others are found
        // anywhere in the name, which has no spaces to split on.
        let words = Set(lowered.split { !$0.isLetter && $0 != "-" && $0 != "'" }.map(String.init))
        let kind = Self.kinds.first { kind in
            kind.keywords.contains { keyword in
                keyword.allSatisfy(\.isASCII)
                    ? (keyword.contains(" ") ? lowered.contains(keyword) : words.contains(keyword))
                    : lowered.contains(keyword)
            }
        }
        if let kind {
            symbol = kind.symbol
            palette = kind.palette
        } else {
            symbol = "book.closed.fill"
            // A sum of the name's scalars: the same across launches, as `hashValue` is not.
            palette = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % DSColor.categoryArtPalette.count
        }
    }

    /// Kinds of book by the words their names use in the app's five languages, the more
    /// particular first (玄幻 before a bare 幻 would be). Palette: 0 rose, 1 coral, 2 plum,
    /// 3 indigo, 4 slate, 5 teal, 6 forest, 7 amber.
    private static let kinds: [(keywords: [String], symbol: String, palette: Int)] = [
        (["耽美", "百合", "ボーイズラブ", "boys' love"], "heart.circle.fill", 2),
        (["言情", "愛情", "爱情", "戀愛", "恋爱", "恋愛", "純愛", "纯爱", "romance", "ロマンス", "로맨스", "연애"], "heart.fill", 0),
        (["輕小說", "轻小说", "ライトノベル", "ラノベ", "light novel", "light novels", "라노벨"], "sparkles", 0),
        (["漫畫", "漫画", "comic", "comics", "manga", "マンガ", "まんが", "만화", "웹툰", "webtoon"],
         "bubble.left.and.bubble.right.fill", 1),
        (["科幻", "sci-fi", "science fiction", "星際", "星际", "末世", "ＳＦ", "공상과학"], "atom", 3),
        (["玄幻", "奇幻", "魔幻", "魔法", "異世界", "异世界", "fantasy", "ファンタジー", "판타지"], "wand.and.stars", 2),
        (["仙俠", "仙侠", "修真", "修仙", "洪荒", "神話", "神话", "mythology"], "mountain.2.fill", 5),
        (["武俠", "武侠", "功夫", "martial", "무협"], "figure.martial.arts", 1),
        (["懸疑", "悬疑", "推理", "偵探", "侦探", "探偵", "mystery", "mysteries", "detective", "crime", "ミステリ",
          "ミステリー", "미스터리", "추리"], "magnifyingglass", 4),
        (["恐怖", "驚悚", "惊悚", "靈異", "灵异", "怪談", "怪谈", "horror", "thriller", "thrillers", "ホラー", "호러", "공포"],
         "moon.stars.fill", 3),
        (["歷史", "历史", "歴史", "時代", "时代", "history", "historical", "역사"], "building.columns.fill", 7),
        (["軍事", "军事", "戰爭", "战争", "military", "war", "戦記", "전쟁"], "shield.fill", 4),
        (["遊戲", "游戏", "電競", "电竞", "網遊", "网游", "競技", "竞技", "game", "games", "gaming", "ゲーム", "게임"],
         "gamecontroller.fill", 5),
        (["體育", "体育", "運動", "运动", "sport", "sports", "スポーツ", "스포츠"], "figure.run", 6),
        (["校園", "校园", "青春", "學園", "学园", "学園", "school", "campus", "학원"], "graduationcap.fill", 4),
        (["都市", "現代", "现代", "現實", "现实", "職場", "职场", "urban", "contemporary", "현대"], "building.2.fill", 4),
        (["詩", "诗", "poetry", "poems", "poem", "시집"], "quote.opening", 3),
        (["兒童", "儿童", "童話", "童话", "童書", "童书", "絵本", "children", "kids", "juvenile", "동화"], "teddybear.fill", 7),
        (["美食", "料理", "グルメ", "cooking", "food", "요리"], "fork.knife", 7),
        (["旅行", "旅遊", "旅游", "遊記", "游记", "travel", "여행"], "airplane", 4),
        (["科學", "科学", "科普", "science", "과학"], "flask.fill", 5),
        (["哲學", "哲学", "思想", "philosophy", "철학"], "brain.head.profile", 2),
        (["經濟", "经济", "商業", "商业", "財經", "财经", "經管", "经管", "business", "economics", "ビジネス", "경제"],
         "chart.line.uptrend.xyaxis", 6),
        (["音樂", "音乐", "music", "음악"], "music.note", 0),
        (["藝術", "艺术", "設計", "设计", "art", "arts", "design", "アート", "예술"], "paintpalette.fill", 1),
        (["戲劇", "戏剧", "劇本", "剧本", "演劇", "drama", "plays", "희곡"], "theatermasks.fill", 1),
        (["冒險", "冒险", "探險", "探险", "adventure", "adventures", "모험"], "map.fill", 5),
        (["自然", "園藝", "园艺", "植物", "nature", "gardening", "자연"], "leaf.fill", 6),
        (["動物", "动物", "寵物", "宠物", "animals", "pets", "동물"], "pawprint.fill", 7),
        (["排行", "榜", "人氣", "人气", "人気", "熱門", "热门", "ranking", "rankings", "popular", "trending", "top", "ランキング",
          "인기"], "trophy.fill", 7),
        (["完結", "完结", "完本", "completed", "finished", "완결"], "checkmark.seal.fill", 6),
        (["新書", "新书", "最新", "新作", "新刊", "新着", "new", "신간"], "sparkles", 1),
        (["經典", "经典", "名著", "古典", "文學", "文学", "classic", "classics", "literature", "고전"], "scroll.fill", 7),
    ]
}

/// A list's designed face: its ground, and its drawing large at the trailing side, where
/// Romance's heart is, turned a little. Decoration: VoiceOver reads the card's name, not this.
/// In a loading row, the skeleton's grey.
struct HomeCategoryArt: View {
    let name: String

    @Environment(\.redactionReasons) private var redactionReasons

    var body: some View {
        let face = HomeCategoryFace(name: name)
        let palette = DSColor.categoryArtPalette[face.palette]
        if redactionReasons.contains(.placeholder) {
            DSColor.neutralControlFill
        } else {
            palette.ground
                .overlay {
                    GeometryReader { proxy in
                        let side = proxy.size.height * DSLayout.homeCategoryArtGlyphShare
                        let center = DSLayout.homeCategoryArtCenter
                        Image(systemName: face.symbol)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(palette.art)
                            .frame(width: side, height: side)
                            .rotationEffect(.degrees(DSLayout.homeCategoryArtRotation))
                            .position(x: proxy.size.width * center.x, y: proxy.size.height * center.y)
                    }
                }
                .accessibilityHidden(true)
        }
    }
}

#if DEBUG
#Preview("分類卡的預設圖") {
    ScrollView {
        VStack(spacing: DSSpacing.lg) {
            ForEach(["玄幻", "言情", "懸疑推理", "科幻", "歷史", "Romance", "ミステリー", "本週精選"], id: \.self) { name in
                HomeCategoryArt(name: name)
                    .aspectRatio(DSLayout.homeBannerAspect, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        Text(name)
                            .font(DSFont.largeTitle.weight(.semibold))
                            .foregroundStyle(DSColor.textOnFixedFill)
                            .padding(.leading, DSSpacing.xxl)
                            .padding(.bottom, DSSpacing.xl)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous))
            }
        }
        .padding(DSSpacing.lg)
    }
}
#endif
