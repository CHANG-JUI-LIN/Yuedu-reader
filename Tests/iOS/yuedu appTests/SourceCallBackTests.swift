import Foundation
import Testing
@testable import yuedu_app

/// legado-E / MD3 `SourceCallBack` (requested 2026-10-10 for 📚书山聚合): a source with
/// `eventListener` gets its `ruleContent.callBackJs` run on book and UI events, with `event`,
/// `book`, `chapter` and `result` bound, and its answer decides whether a tap is handled.
@Suite("Source callBackJs", .serialized)
@MainActor
struct SourceCallBackTests {

    /// Echoes what it was given, and answers per event the way a real source branches.
    private static let script = """
        var seen = JSON.stringify({ e: event, b: book.name, a: book.author, c: chapter.title, r: String(result) });
        if (event == 'clickAuthor') { false }
        else if (event == 'clickBookLabel') { throw new Error('boom') }
        else if (event == 'startRead') { undefined }
        else { seen }
        """

    private static func source(listening: Bool = true) -> BookSource {
        var source = BookSource()
        source.bookSourceName = "callback-fixture"
        source.bookSourceUrl = "https://callback-\(UUID().uuidString).example"
        source.eventListener = listening
        source.ruleContent.callBackJs = script
        return source
    }

    private static let book = ReaderHTMLUtilities.LegadoSourceActionContext.BookSnapshot(
        durChapterIndex: 2, durChapterTitle: "第3章", order: 0, type: 0, imageStyle: "",
        name: "沒錢修什麼仙", author: "熊狼狗", coverURL: "", bookURL: "https://b/1", tocURL: "https://b/1/toc",
        abstract: ""
    )

    private static func run(_ event: SourceCallBackEvent, result: String?, source: BookSource) async -> SourceCallBackOutcome {
        await SourceCallBackService.tap(
            event, source: source, book: book, runtimeVariables: [:],
            chapter: .init(index: 2, title: "第3章", order: 2, url: "https://b/1/3", isVip: false),
            result: result
        )
    }

    @Test("the script sees event, book, chapter and result, and a returned value takes the tap")
    func bindingsAndHandled() async throws {
        let source = Self.source()
        let outcome = await Self.run(.clickBookName, result: "沒錢修什麼仙", source: source)
        #expect(outcome.handled)
        #expect(!SourceCallBackService.shouldFallBack(outcome))
        let seen = try #require(outcome.value.flatMap { $0.data(using: .utf8) })
        let object = try #require(JSONSerialization.jsonObject(with: seen) as? [String: String])
        #expect(object["e"] == "clickBookName")
        #expect(object["b"] == "沒錢修什麼仙")
        #expect(object["a"] == "熊狼狗")
        #expect(object["c"] == "第3章")
        #expect(object["r"] == "沒錢修什麼仙")
    }

    @Test("false or nothing falls back to the app's action; a throw neither handles nor falls back")
    func legadoTruthiness() async {
        let source = Self.source()
        let declined = await Self.run(.clickAuthor, result: "熊狼狗", source: source)
        #expect(!declined.handled)
        #expect(SourceCallBackService.shouldFallBack(declined))

        let threw = await Self.run(.clickBookLabel, result: "仙俠", source: source)
        #expect(threw.failed)
        #expect(!SourceCallBackService.shouldFallBack(threw))

        // legado's Rhino unwraps `undefined` to null → "null" → not true: a script that says
        // nothing leaves the tap to the app.
        let silent = await Self.run(.startRead, result: nil, source: source)
        #expect(!silent.handled)
        #expect(SourceCallBackService.shouldFallBack(silent))
    }

    @Test("a source that does not listen runs nothing and leaves the tap to the app")
    func notListening() async {
        let outcome = await Self.run(.clickBookName, result: "x", source: Self.source(listening: false))
        #expect(!outcome.handled && !outcome.failed && outcome.value == nil)
        #expect(SourceCallBackService.shouldFallBack(outcome))
    }

    @Test("legado isTrue")
    func isTrue() {
        for falsy in ["false", "FALSE", "no", "not", "0", "0.0", " false "] {
            #expect(!LegadoReviewActionRunner.legadoIsTrue(falsy, nilIsTrue: true), "\(falsy)")
        }
        for truthy in ["true", "1", "yes", "anything"] {
            #expect(LegadoReviewActionRunner.legadoIsTrue(truthy, nilIsTrue: false))
        }
        #expect(LegadoReviewActionRunner.legadoIsTrue(nil, nilIsTrue: true))
        #expect(!LegadoReviewActionRunner.legadoIsTrue("null", nilIsTrue: false))
        #expect(!LegadoReviewActionRunner.legadoIsTrue("", nilIsTrue: false))
    }

    @Test("the fields survive import and export, and a source without them encodes as before")
    func modelRoundTrip() throws {
        let json = #"""
            {"bookSourceName":"s","bookSourceUrl":"https://s","eventListener":true,"customButton":true,
             "ruleContent":{"content":"@css:p","callBackJs":"event=='startRead'"}}
            """#
        let decoded = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        #expect(decoded.eventListener == true)
        #expect(decoded.customButton == true)
        #expect(decoded.ruleContent.callBackJs == "event=='startRead'")
        let reencoded = try JSONDecoder().decode(BookSource.self, from: JSONEncoder().encode(decoded))
        #expect(reencoded.ruleContent.callBackJs == "event=='startRead'")

        let plain = try JSONDecoder().decode(
            BookSource.self, from: Data(#"{"bookSourceName":"p","bookSourceUrl":"https://p","ruleContent":{"content":"@css:p"}}"#.utf8)
        )
        let encoded = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!encoded.contains("eventListener"))
        #expect(!encoded.contains("customButton"))
        #expect(!encoded.contains("callBackJs"))
    }
}
