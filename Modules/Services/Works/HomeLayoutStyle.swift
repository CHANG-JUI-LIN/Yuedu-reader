import Foundation

// Unified library 5d-3: the layouts the home draws (Phase 5 plan, decision 14, from the
// maintainer's layout notes): 大型閱讀卡片, 橫向單排書架, 多行橫向輪播, 固定封面網格 and
// 圖文資訊清單, the last with ranks as an option; 精簡閱讀卡片 since 5d-3c (decision 20). A stored layout may be anything a custom page
// or a later build wrote; the app decides what is drawn from it.
// The maintainer, 2026-10-25, after Apple Books' store and home: 色帶書架, 大型封面書架 and
// 一大四小 for books, ranks on 橫向單排書架 too, and 分類卡片 and 拼貼卡片 for lists
// (`Technotes/AppleBooksHomeLayouts-2026-10-25.md`). 2026-10-27: 色帶書架 became the home's
// 頂部輪播圖, not a layout to choose, and 大圖卡片 joined the layouts of lists.

/// One of the layouts.
enum HomeLayoutStyle: String, CaseIterable, Identifiable, Sendable {
    case readingCard
    case compactReadingCard
    case row
    case multiRow
    case coverGrid
    case list
    case featured
    case largeRow
    case heroGrid
    /// 專題集合: lists, not books, a card each (`HomeSection.listCards`), as are the three after it.
    case collection
    case categoryCards
    case collageCards
    case bannerCards

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .readingCard: "大型閱讀卡片"
        case .compactReadingCard: "精簡閱讀卡片"
        case .row: "橫向單排書架"
        case .multiRow: "多行橫向輪播"
        case .coverGrid: "固定封面網格"
        case .list: "圖文資訊清單"
        case .featured: "精選"
        case .largeRow: "大型封面書架"
        case .heroGrid: "一大四小"
        case .collection: "專題集合"
        case .categoryCards: "分類卡片"
        case .collageCards: "拼貼卡片"
        case .bannerCards: "大圖卡片"
        }
    }

    var symbol: String {
        switch self {
        case .readingCard: "rectangle.portrait.on.rectangle.portrait"
        case .compactReadingCard: "rectangle.leadingthird.inset.filled"
        case .row: "rectangle.split.3x1"
        case .multiRow: "rectangle.grid.3x2"
        case .coverGrid: "square.grid.3x3"
        case .list: "list.bullet.rectangle"
        case .featured: "rectangle.on.rectangle.angled"
        case .largeRow: "rectangle.split.2x1"
        case .heroGrid: "square.grid.2x2"
        case .collection: "square.stack"
        case .categoryCards: "rectangle.grid.1x2"
        case .collageCards: "rectangle.on.rectangle"
        case .bannerCards: "rectangle.inset.filled"
        }
    }

    /// A layout of lists, each card a list: 專題集合, 分類卡片, 拼貼卡片 and 大圖卡片.
    var drawsLists: Bool {
        switch self {
        case .collection, .categoryCards, .collageCards, .bannerCards: true
        default: false
        }
    }

    /// The layouts that number their books when asked to (顯示排名).
    var canShowRanks: Bool {
        self == .list || self == .row
    }

    /// What 呈現方式 offers a section: every layout (maintainer, 2026-10-27: every source in every
    /// layout), a layout of lists drawing a card per list (`HomeSection.listCards`); only the
    /// layouts of lists for what is lists alone (`HomeSectionBinding.drawsOnlyLists`). One place,
    /// for the long press, the form and 新增欄目.
    static func choices(for binding: HomeSectionBinding) -> [HomeLayoutStyle] {
        binding.drawsOnlyLists ? allCases.filter(\.drawsLists) : allCases
    }
}

extension HomeSectionLayout {
    /// The layout the reader sees chosen. A custom page's seven kinds map as decision 14 says
    /// (5d-4 migrates them with the same mapping). 磚塊 and a later build's layout are drawn as
    /// a row, the layout every section can take, and kept as they are.
    var style: HomeLayoutStyle {
        switch self {
        case .readingCard: return .readingCard
        case .compactReadingCard: return .compactReadingCard
        case .multiRow: return .multiRow
        case .coverGrid: return .coverGrid
        case .list, .rankedList: return .list
        case .featured: return .featured
        case .collection: return .collection
        // The page's first band is its 頂部輪播圖, drawn by the home itself; another is drawn
        // as the row of large covers it was closest to.
        case .band, .largeRow: return .largeRow
        case .heroGrid: return .heroGrid
        case .rankedRow: return .row
        case .categoryCards: return .categoryCards
        case .collageCards: return .collageCards
        case .bannerCards: return .bannerCards
        default: break
        }
        switch componentKind {
        case .grid: return .multiRow
        case .waterfall: return .coverGrid
        case .ranking, .pagedRanking, .multiCategoryRanking: return .list
        case .featuredCards, .carousel, nil: return .row
        }
    }

    /// Whether 圖文資訊清單 or 橫向單排書架 numbers its books.
    var showsRanks: Bool {
        switch self {
        case .rankedList, .rankedRow: return true
        default:
            switch componentKind {
            case .ranking, .pagedRanking, .multiCategoryRanking: return true
            default: return false
            }
        }
    }

    /// What 呈現方式 writes. Ranks are kept only by a layout that can show them.
    init(style: HomeLayoutStyle, ranked: Bool = false) {
        switch style {
        case .readingCard: self = .readingCard
        case .compactReadingCard: self = .compactReadingCard
        case .row: self = ranked ? .rankedRow : .row
        case .multiRow: self = .multiRow
        case .coverGrid: self = .coverGrid
        case .list: self = ranked ? .rankedList : .list
        case .featured: self = .featured
        case .largeRow: self = .largeRow
        case .heroGrid: self = .heroGrid
        case .collection: self = .collection
        case .categoryCards: self = .categoryCards
        case .collageCards: self = .collageCards
        case .bannerCards: self = .bannerCards
        }
    }

    /// What the home draws: the chosen layout, except that two rows of covers do not fit a
    /// phone at accessibility text sizes, so 多行橫向輪播 draws one (decision 14: the app
    /// decides what is drawn). 一大四小 draws covers alone, which no text size changes.
    func drawnStyle(accessibilityTextSize: Bool) -> HomeLayoutStyle {
        if accessibilityTextSize, style == .multiRow { return .row }
        return style
    }
}
