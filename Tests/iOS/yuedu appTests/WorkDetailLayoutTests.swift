import Foundation
import Testing
@testable import yuedu_app

/// 作品詳情's order (maintainer, 2026-10-12): Hero (分類 and 系列 under the author) → 簡介 →
/// 目錄 → 作品關聯 → 作品資訊 at the end.
struct WorkDetailLayoutTests {
    private func index(ndcs: [String]) -> AozoraCatalogIndex {
        let person = AozoraPerson(id: "1", name: "山本 周五郎", yomi: "", sortYomi: "", born: "", died: "")
        let works = ndcs.enumerated().map { offset, ndc in
            AozoraWork(id: "\(offset + 1)", title: "作品\(offset + 1)", yomi: "", sortYomi: "\(offset)", subtitle: "", kanaStyle: "",
                       ndc: ndc, published: "", updated: "", card: "", text: "", textUpdated: "",
                       credits: [.init(person: "1", role: "著者")], source: "", sourcePublisher: "")
        }
        return AozoraCatalogIndex(catalog: AozoraCatalog(schemaVersion: 1, persons: [person], works: works))
    }

    /// The hero's 分類 are the index's own groups, so a link opens the same list 依分類 does.
    @Test("a 青空文庫 work's 分類 are its classification groups, in the index's order")
    func aozoraClassifications() throws {
        let index = index(ndcs: ["NDC 913 914", "NDC K913", "", "NDC 289"])
        let works = index.newWorks.sorted { $0.id < $1.id }
        #expect(index.classificationGroups(of: works[0]).map(\.id) == ["913", "914"])
        #expect(index.classificationGroups(of: works[1]).map(\.id) == ["913"])
        #expect(index.classificationGroups(of: works[2]).isEmpty, "「其他」 is no 分類 to link")
        #expect(index.classificationGroups(of: works[3]).isEmpty, "「其他」 is no 分類 to link")
        let novel = try #require(index.classificationGroups(of: works[0]).first)
        #expect(Set(novel.ids) == ["1", "2"])
    }
}
