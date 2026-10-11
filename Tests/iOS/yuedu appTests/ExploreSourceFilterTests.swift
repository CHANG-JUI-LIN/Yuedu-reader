import Foundation
import Testing
@testable import yuedu_app

struct ExploreSourceFilterTests {
    @Test("a source search keeps the sources whose name or group holds the text, within the chosen group")
    func searchNarrowsSources() {
        func source(_ name: String, group: String) -> BookSource {
            var source = BookSource(bookSourceUrl: "https://\(UUID().uuidString).example", bookSourceName: name)
            source.bookSourceGroup = group
            return source
        }
        let fanqie = source("🍅番茄小说", group: "男频, 精品")
        let qidian = source("起点中文网", group: "男频")
        let jjwxc = source("JJWXC 晋江", group: "女频")
        let all = [fanqie, qidian, jjwxc]
        func names(_ group: String?, _ query: String) -> [String] {
            DiscoverViewModel.exploreSources(all, inGroup: group, matching: query).map(\.bookSourceName)
        }

        #expect(names(nil, "") == ["🍅番茄小说", "起点中文网", "JJWXC 晋江"])
        #expect(names(nil, "番茄") == ["🍅番茄小说"])
        // A group's name finds its sources, as Legado's `flowExplore(key)` does.
        #expect(names(nil, "精品") == ["🍅番茄小说"])
        #expect(names(nil, "jjwxc") == ["JJWXC 晋江"])
        #expect(names("男频", "") == ["🍅番茄小说", "起点中文网"])
        #expect(names("男频", "晋江").isEmpty)
    }
}
