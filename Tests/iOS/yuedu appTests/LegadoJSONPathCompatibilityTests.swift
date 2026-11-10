import Foundation
import Testing
@testable import yuedu_app

@Suite("Legado JSONPath Compatibility", .serialized)
struct LegadoJSONPathCompatibilityTests {
    @Test("leading-dot filter searches nested JSON arrays")
    func leadingDotFilterSearchesNestedArrays() {
        let payload = #"""
        {
          "status": 200,
          "message": "ok",
          "data": {
            "sections": [
              {
                "items": [
                  {"displayName": "First", "id": "1"},
                  {"displayName": "Second", "id": "2"},
                  {"id": "metadata"}
                ]
              }
            ]
          }
        }
        """#
        let engine = ModernRuleEngine()
        engine.setContent(payload)

        let elements = engine.getElements(ruleStr: ".[?(@.displayName)]")

        #expect(elements.count == 2)
        engine.setContent(elements[0])
        #expect(engine.getString(ruleStr: "displayName") == "First")
        engine.setContent(elements[1])
        #expect(engine.getString(ruleStr: "displayName") == "Second")
    }

    @Test("leading-dot filter preserves first-nonempty schema fallback")
    func leadingDotFilterSchemaFallback() {
        let payload = #"""
        {
          "status": 200,
          "data": {
            "page": {
              "entries": [
                {"title": "Fallback One", "id": "1"},
                {"title": "Fallback Two", "id": "2"}
              ]
            }
          }
        }
        """#
        let engine = ModernRuleEngine()
        engine.setContent(payload)

        let elements = engine.getElements(
            ruleStr: ".[?(@.displayName)]||.[?(@.title)]"
        )

        #expect(elements.count == 2)
        engine.setContent(elements[0])
        #expect(engine.getString(ruleStr: "title") == "Fallback One")
    }

    /// jayway's `PredicatePathToken` keeps an object that passes, not only an array's elements:
    /// 晋江文学 (YCK1331) lists `$.*[?(@.novelName)]&&$.*[?(@.novelname)]` over the top-level
    /// array its 夹子 page answers.
    @Test("a filter on an object keeps the object when it passes")
    func filterOnObjectKeepsObject() {
        let list = #"[{"novelId":"1","novelName":"高塔之下"},{"novelId":"2"},{"novelId":"3","novelName":"乙"}]"#
        let engine = ModernRuleEngine()
        engine.setContent(list)
        let books = engine.getElements(ruleStr: "@JSon:$.*[?(@.novelName)]&&$.*[?(@.novelname)]")
        #expect(books.count == 2)
        engine.setContent(books[1])
        #expect(engine.getString(ruleStr: "$.novelId") == "3")

        let data = try! JSONSerialization.jsonObject(with: Data(#"{"data":{"id":7,"name":"x"}}"#.utf8))
        #expect(JSONPathEvaluator.query("$.data[?(@.id)]", on: data).count == 1)
        #expect(JSONPathEvaluator.query("$.data[?(@.missing)]", on: data).isEmpty)
    }

    /// jayway's scan before a filter walks depth first from the node itself: every object that
    /// passes, once, the root included.
    @Test("a recursive filter yields each passing object once, depth first")
    func recursiveFilterWalksDepthFirst() {
        let data = OrderedJSON.parse(#"""
        {"id":"root","a":[{"id":"a1","kids":[{"id":"a1x"}]},{"name":"none"}],"b":{"id":"b"}}
        """#)!
        let ids = JSONPathEvaluator.query("$..[?(@.id)]", on: data).compactMap {
            ($0 as? [String: Any])?["id"] as? String
        }
        #expect(ids == ["root", "a1", "a1x", "b"])
    }

    @Test("a leading-dot path is jayway's \"$.\" + path: a recursive search below the envelope")
    func leadingDotPathSearchesRecursively() {
        let payload = #"{"code":200,"data":{"id":"11","chapters":[{"title":"第1话","id":"a"},{"title":"第2话","id":"b"}]}}"#
        let engine = ModernRuleEngine()
        engine.setContent(payload)

        let elements = engine.getElements(ruleStr: ".chapters[*]")

        #expect(elements.count == 2)
        engine.setContent(elements[1])
        #expect(engine.getString(ruleStr: ".title") == "第2话")
    }
}
