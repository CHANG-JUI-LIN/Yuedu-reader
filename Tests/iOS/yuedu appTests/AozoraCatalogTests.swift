import Foundation
import Testing
@testable import yuedu_app

@Suite("Aozora catalog")
struct AozoraCatalogTests {
    static var fixture: Data {
        get throws {
            try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/AozoraCatalog/works.json"))
        }
    }

    @Test func schemaAndUnknownFields() throws {
        var json = try #require(JSONSerialization.jsonObject(with: Self.fixture) as? [String: Any])
        json["future"] = "ignored"
        let catalog = try AozoraCatalog.decode(JSONSerialization.data(withJSONObject: json))
        #expect(catalog.works.count == 2)
        #expect(catalog.persons.count == 2)
        json["schemaVersion"] = 2
        #expect(throws: AozoraCatalogError.unsupportedSchema(2)) {
            try AozoraCatalog.decode(JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func groupingAndSorting() throws {
        var catalog = try AozoraCatalog.decode(Self.fixture)
        let sample = try #require(catalog.persons.first)
        let initials = ["わ", "ら", "や", "ま", "は", "な", "た", "さ", "か", "あ", "Ａ", "漢"]
        catalog.persons = initials.enumerated().map { i, reading in
            var person = sample
            person.id = String(i)
            person.sortYomi = reading
            return person
        }
        catalog.works = []
        let index = AozoraCatalogIndex(catalog: catalog)
        #expect(index.authorGroups.map(\.id) == ["あ", "か", "さ", "た", "な", "は", "ま", "や", "ら", "わ", "latin", "other"])
        let original = AozoraCatalogIndex(catalog: try AozoraCatalog.decode(Self.fixture))
        #expect(original.newWorks.map(\.id) == ["2", "1"])
        #expect(original.titleGroups.map(\.id) == ["あ", "か"])
        #expect(original.classificationGroups.map(\.id) == ["913", "911"])
        #expect(original.works(forPerson: "002").map(\.id) == ["1"])
        #expect(AozoraCatalogIndex.kanaGroup("ｶﾞ") == "か")
    }

    @Test func classificationOrder() throws {
        var catalog = try AozoraCatalog.decode(Self.fixture)
        let sample = try #require(catalog.works.first)
        catalog.works = ["NDC 100", "NDC 923", "NDC 918", "NDC 914", "NDC 911", "NDC 913"].enumerated().map { i, ndc in
            var work = sample; work.id = String(i); work.ndc = ndc; return work
        }
        #expect(AozoraCatalogIndex(catalog: catalog).classificationGroups.map(\.id) == ["913", "911", "914", "91x", "9xx", "other"])
    }

    @Test func searchRanksTitlePrefixThenTitleThenAuthor() throws {
        var catalog = try AozoraCatalog.decode(Self.fixture)
        var person = try #require(catalog.persons.first)
        person.name = "Alpha Writer"; person.yomi = "あるふぁ"
        catalog.persons = [person]
        let sample = try #require(catalog.works.first)
        catalog.works = ["Other", "The Alpha Book", "Alpha Book"].enumerated().map { i, title in
            var work = sample; work.id = String(i); work.title = title
            work.yomi = "ものがたり"; work.sortYomi = title
            work.credits = [.init(person: person.id, role: "著者")]
            return work
        }
        let index = AozoraCatalogIndex(catalog: catalog)
        #expect(index.search("ＡＬＰＨＡ").map(\.id) == ["2", "1", "0"])
        #expect(index.search("ｱﾙﾌｧ").count == 3)
        #expect(index.search("モノガタリ").count == 3)
        #expect(index.search("   ").isEmpty)
    }

    @Test func duplicateIDsFailBeforeIndexing() throws {
        var json = try #require(JSONSerialization.jsonObject(with: Self.fixture) as? [String: Any])
        let works = try #require(json["works"] as? [[String: Any]])
        json["works"] = works + works
        #expect(throws: AozoraCatalogError.self) { try AozoraCatalog.decode(JSONSerialization.data(withJSONObject: json)) }
    }
}
