import Foundation
import Testing
@testable import yuedu_app

/// 搜索's 青空文庫 matches (Phase 4 acceptance, 2026-10-14): the list was rebuilt on every
/// publication of every part and searched the whole catalog each time on the main actor,
/// 21–27 ms a time, twice between the keyboard's Search and the sources' first request. The
/// catalog is searched once per query, off the main actor.
@MainActor
struct PublicLibrarySearchModelTests {
    private static let index: AozoraCatalogIndex = {
        let person = AozoraPerson(id: "000148", name: "夏目 漱石", yomi: "なつめ そうせき", sortYomi: "なつめそうせき",
                                  born: "", died: "")
        func work(_ id: String, _ title: String, _ yomi: String) -> AozoraWork {
            AozoraWork(id: id, title: title, yomi: yomi, sortYomi: yomi, subtitle: "", kanaStyle: "", ndc: "",
                       published: "", updated: "", card: "", text: "", textUpdated: "",
                       credits: [.init(person: person.id, role: "著者")], source: "", sourcePublisher: "")
        }
        return AozoraCatalogIndex(catalog: AozoraCatalog(schemaVersion: 1, persons: [person], works: [
            work("000773", "こころ", "こころ"), work("000789", "吾輩は猫である", "わがはいはねこである"),
        ]))
    }()

    @Test("the catalog is searched off the main actor, and the answer names its query")
    func searchesOffTheMainActor() async {
        let threads = ThreadLog()
        let model = PublicLibrarySearchModel { index, query in
            threads.record(Thread.isMainThread)
            return index.search(query)
        }

        await model.search("こころ", in: Self.index)

        #expect(threads.values == [false])
        #expect(model.answer?.query == "こころ")
        #expect(model.answer?.works.map(\.id) == ["000773"])
    }

    @Test("an empty query or no catalog leaves no answer")
    func noQueryOrCatalogClears() async {
        let model = PublicLibrarySearchModel()
        await model.search("漱石", in: Self.index)
        #expect(model.answer?.works.count == 2, "both works, by their author")

        await model.search("", in: Self.index)
        #expect(model.answer == nil)
        await model.search("こころ", in: nil)
        #expect(model.answer == nil)
    }

    @Test("a search cancelled by the next query does not answer")
    func cancelledSearchDoesNotAnswer() async {
        let model = PublicLibrarySearchModel()
        let task = Task { await model.search("こころ", in: Self.index) }
        task.cancel()
        await task.value
        #expect(model.answer == nil)
    }
}

private final class ThreadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    func record(_ value: Bool) { lock.withLock { recorded.append(value) } }
    var values: [Bool] { lock.withLock { recorded } }
}
