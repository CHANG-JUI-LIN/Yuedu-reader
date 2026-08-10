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
}
