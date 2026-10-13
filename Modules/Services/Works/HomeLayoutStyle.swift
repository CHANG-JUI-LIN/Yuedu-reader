import Foundation

// Unified library 5d-3: the layouts the home draws (Phase 5 plan, decision 14, from the
// maintainer's layout notes): 大型閱讀卡片, 橫向單排書架, 多行橫向輪播, 固定封面網格 and
// 圖文資訊清單, the last with ranks as an option; 精簡閱讀卡片 since 5d-3c (decision 20). A stored layout may be anything a custom page
// or a later build wrote; the app decides what is drawn from it.

/// One of the layouts.
enum HomeLayoutStyle: String, CaseIterable, Identifiable, Sendable {
    case readingCard
    case compactReadingCard
    case row
    case multiRow
    case coverGrid
    case list
    case featured

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
        }
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
        default: break
        }
        switch componentKind {
        case .grid: return .multiRow
        case .waterfall: return .coverGrid
        case .ranking, .pagedRanking, .multiCategoryRanking: return .list
        case .featuredCards, .carousel, nil: return .row
        }
    }

    /// Whether 圖文資訊清單 numbers its books.
    var showsRanks: Bool {
        switch self {
        case .rankedList: return true
        default:
            switch componentKind {
            case .ranking, .pagedRanking, .multiCategoryRanking: return true
            default: return false
            }
        }
    }

    /// What 呈現方式 writes.
    init(style: HomeLayoutStyle, ranked: Bool = false) {
        switch style {
        case .readingCard: self = .readingCard
        case .compactReadingCard: self = .compactReadingCard
        case .row: self = .row
        case .multiRow: self = .multiRow
        case .coverGrid: self = .coverGrid
        case .list: self = ranked ? .rankedList : .list
        case .featured: self = .featured
        }
    }

    /// What the home draws: the chosen layout, except that two rows of covers do not fit a
    /// phone at accessibility text sizes, so 多行橫向輪播 draws one (decision 14: the app
    /// decides what is drawn).
    func drawnStyle(accessibilityTextSize: Bool) -> HomeLayoutStyle {
        if accessibilityTextSize, style == .multiRow { return .row }
        return style
    }
}
