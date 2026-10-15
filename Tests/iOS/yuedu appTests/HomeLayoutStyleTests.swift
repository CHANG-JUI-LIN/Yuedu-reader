import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5d-3: the layouts (精簡閱讀卡片 since 5d-3c), what a stored layout draws, and 呈現方式's edit.
@Suite("Home layout style")
@MainActor
struct HomeLayoutStyleTests {
    @Test("each layout is written as its own value and read back as itself")
    func roundTrip() throws {
        for style in HomeLayoutStyle.allCases {
            for ranked in [false, true] {
                let layout = HomeSectionLayout(style: style, ranked: ranked)
                let section = HomeSection(layout: layout, binding: .related)
                let decoded = try JSONDecoder().decode(HomeSection.self, from: JSONEncoder().encode(section))
                #expect(decoded.layout == layout)
                #expect(decoded.layout.isKnown)
                #expect(decoded.layout.style == style)
                #expect(decoded.layout.showsRanks == (style == .list && ranked))
            }
        }
        #expect(HomeSectionLayout(style: .row) == .row)
    }

    @Test("a custom page's seven kinds draw as decision 14 maps them")
    func customPageKinds() {
        let expected: [CustomExploreComponent.Kind: (HomeLayoutStyle, Bool)] = [
            .featuredCards: (.row, false), .carousel: (.row, false), .grid: (.multiRow, false),
            .ranking: (.list, true), .pagedRanking: (.list, true), .multiCategoryRanking: (.list, true),
            .waterfall: (.coverGrid, false),
        ]
        #expect(Set(expected.keys) == Set(CustomExploreComponent.Kind.allCases))
        for (kind, (style, ranked)) in expected {
            let layout = HomeSectionLayout(kind)
            #expect(layout.style == style, "\(kind)")
            #expect(layout.showsRanks == ranked, "\(kind)")
        }
    }

    @Test("磚塊 and a later build's layout draw as a row")
    func othersDrawAsARow() {
        #expect(HomeSectionLayout.tiles.style == .row)
        let later = HomeSectionLayout(rawValue: "spotlight")
        #expect(later.style == .row)
        #expect(!later.isKnown)
    }

    @Test("at accessibility text sizes 多行橫向輪播 draws one row; the others draw as chosen")
    func accessibilitySizes() {
        #expect(HomeSectionLayout.multiRow.drawnStyle(accessibilityTextSize: true) == .row)
        #expect(HomeSectionLayout.multiRow.drawnStyle(accessibilityTextSize: false) == .multiRow)
        for style in HomeLayoutStyle.allCases where style != .multiRow {
            #expect(HomeSectionLayout(style: style).drawnStyle(accessibilityTextSize: true) == style)
        }
    }

    @Test("呈現方式 changes that one section's layout and nothing else")
    func setLayout() {
        let reading = HomeSection(layout: .readingCard, binding: .continueReading)
        let related = HomeSection(layout: .row, binding: .related)
        var page = HomePage(sections: [reading, related])
        page.setLayout(.rankedList, section: related.id)
        #expect(page.sections[1].layout == .rankedList)
        #expect(page.sections[0] == reading)
        #expect(page.sections[1].binding == .related)
    }

    @Test("a section of books is offered every layout but 專題集合; a section of lists only 專題集合")
    func choices() {
        for binding in [HomeSectionBinding.continueReading, .latest, .aiRecommendations] {
            #expect(HomeLayoutStyle.choices(for: binding) == HomeLayoutStyle.allCases.filter { $0 != .collection })
        }
        #expect(HomeLayoutStyle.choices(for: .gutenbergLists) == [.collection])
    }

    @Test("繼續閱讀 starts as 精簡閱讀卡片, 精選書單 as 專題集合; the other defaults as a row")
    func defaults() {
        for mode in ExploreMode.allCases {
            let page = HomePageDefaults.page(mode: mode, publicLibrariesAvailable: true)
            for section in page.sections {
                let expected: HomeSectionLayout = switch section.binding {
                case .continueReading: .compactReadingCard
                case .gutenbergLists: .collection
                default: .row
                }
                #expect(section.layout == expected)
            }
        }
    }
}
