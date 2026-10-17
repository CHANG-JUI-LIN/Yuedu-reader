import Foundation
import SwiftUI
import Testing
@testable import yuedu_app

/// 資源庫's cards (Phase 5 plan, 5h), laid out by the old 探索 root's 格狀 and 每列欄數.
struct ExploreEntryLabelTests {
    @Test("the grid keeps the chosen tiles to a row until the text grows too large for them")
    func gridDensityFollowsTextSize() {
        #expect(ExploreGridDensity.fitting(4, dynamicTypeSize: .large) == .four)
        #expect(ExploreGridDensity.fitting(3, dynamicTypeSize: .xSmall) == .three)
        #expect(ExploreGridDensity.fitting(4, dynamicTypeSize: .xLarge) == .three)
        #expect(ExploreGridDensity.fitting(2, dynamicTypeSize: .xLarge) == .two)
        #expect(ExploreGridDensity.fitting(4, dynamicTypeSize: .xxxLarge) == .two)
        // A value no menu offers, from an older or hand-edited preference.
        #expect(ExploreGridDensity.fitting(7, dynamicTypeSize: .large) == .default)
    }

    @Test("資源庫 reads the old 探索 root's 格狀 and 每列欄數, under the same keys")
    func layoutKeysAreTheOldOnes() {
        #expect(ExploreSettings.showsGridKey == "explore.showsGrid")
        #expect(ExploreSettings.gridColumnCountKey == "explore.gridColumnCount")
    }

    /// Maintainer's screenshot, 2026-10-17: in four columns 所有來源配置 (471) and 小說 (338)
    /// stood taller than the cards beside them, their counts broken one digit to a line.
    @Test("a count never makes its card taller than the cards beside it", arguments: [
        // A four-column card on a 375pt-wide iPhone, and on a 440pt-wide one.
        CGFloat(76.75), 93,
    ])
    @MainActor
    func countKeepsTheRowEven(width: CGFloat) {
        func height(_ corner: ExploreEntryLabel.Corner?) -> CGFloat {
            let label = ExploreEntryLabel(title: "小說", artwork: .neutral("folder.fill"),
                                          layout: .grid(.four), corner: corner)
            return UIHostingController(rootView: label.environment(\.dynamicTypeSize, .large))
                .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        let plain = height(nil)
        for count in [9, 471, 12_345] {
            #expect(height(.count(count)) == plain, "count \(count) at width \(width)")
        }
    }
}

struct LibrarySourceGroupsTests {
    private func source(_ name: String, group: String) -> BookSource {
        var source = BookSource(bookSourceUrl: "https://\(UUID().uuidString).example", bookSourceName: name)
        source.bookSourceGroup = group
        return source
    }

    @Test("資源庫 has a card per group, in name order, counting a source in each group it names")
    func groupsCountTheirSources() {
        let groups = LibrarySourceGroups.groups(of: [
            source("番茄", group: "男频, 精品"),
            source("起点", group: "男频"),
            source("晋江", group: "女频"),
            source("无分组", group: ""),
            // A group named twice counts the source once.
            source("重复", group: "精品,精品"),
        ])
        #expect(groups.map(\.name) == ["女频", "男频", "精品"])
        #expect(groups.map(\.count) == [1, 2, 2])
    }

    @Test("no groups when no source names one")
    func noGroups() {
        #expect(LibrarySourceGroups.groups(of: [source("无分组", group: " ")]).isEmpty)
    }
}
