import Foundation

// Unified library 5d-3: the layouts the home draws (Phase 5 plan, decision 14, from the
// maintainer's layout notes): 大型閱讀卡片, 橫向單排書架, 多行橫向輪播, 固定封面網格 and
// 圖文資訊清單, the last with ranks as an option; 精簡閱讀卡片 since 5d-3c (decision 20). A stored layout may be anything a custom page
// or a later build wrote; the app decides what is drawn from it.
// The maintainer, 2026-10-25, after Apple Books' store and home: 色帶書架, 大型封面書架 and
// 一大四小 for books, ranks on 橫向單排書架 too, and 分類卡片 and 拼貼卡片 for lists
// (`Technotes/AppleBooksHomeLayouts-2026-10-25.md`).

/// One of the layouts.
enum HomeLayoutStyle: String, CaseIterable, Identifiable, Sendable {
    case readingCard
    case compactReadingCard
    case row
    case multiRow
    case coverGrid
    case list
    case featured
    case band
    case largeRow
    case heroGrid
    /// 專題集合: lists, not books; offered only for a section of lists (`choices(for:)`), as
    /// are the two after it.
    case collection
    case categoryCards
    case collageCards

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
        case .band: "色帶書架"
        case .largeRow: "大型封面書架"
        case .heroGrid: "一大四小"
        case .collection: "專題集合"
        case .categoryCards: "分類卡片"
        case .collageCards: "拼貼卡片"
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
        case .band: "rectangle.inset.filled"
        case .largeRow: "rectangle.split.2x1"
        case .heroGrid: "square.grid.2x2"
        case .collection: "square.stack"
        case .categoryCards: "rectangle.grid.1x2"
        case .collageCards: "rectangle.on.rectangle"
        }
    }

    /// A layout of lists, each card a list: 專題集合, 分類卡片 and 拼貼卡片.
    var drawsLists: Bool {
        switch self {
        case .collection, .categoryCards, .collageCards: true
        default: false
        }
    }

    /// The layouts that number their books when asked to (顯示排名).
    var canShowRanks: Bool {
        self == .list || self == .row
    }

    /// What 呈現方式 offers a section: the layouts of lists for a section of lists, every
    /// other layout for a section of books, and for a 來源配置's categories 分類卡片 too, a card
    /// per category (`HomeSection.drawsCategoryCards`). One place, for the long press, the form
    /// and 新增欄目.
    static func choices(for binding: HomeSectionBinding) -> [HomeLayoutStyle] {
        if case .sourceCategories = binding { return allCases.filter { !$0.drawsLists || $0 == .categoryCards } }
        return allCases.filter { $0.drawsLists == binding.listsCollections }
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
        case .band: return .band
        case .largeRow: return .largeRow
        case .heroGrid: return .heroGrid
        case .rankedRow: return .row
        case .categoryCards: return .categoryCards
        case .collageCards: return .collageCards
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
        case .band: self = .band
        case .largeRow: self = .largeRow
        case .heroGrid: self = .heroGrid
        case .collection: self = .collection
        case .categoryCards: self = .categoryCards
        case .collageCards: self = .collageCards
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
