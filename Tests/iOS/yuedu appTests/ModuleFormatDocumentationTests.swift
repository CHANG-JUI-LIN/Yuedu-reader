import Foundation
import Testing
@testable import yuedu_app

/// Module ecosystem M7: `docs/modules/README.md` names every field of the module format, every
/// value a fixed-set field takes, and every field of a repository index. A field added to the
/// format without a line in the document fails here.
@Suite("Module format documentation")
struct ModuleFormatDocumentationTests {
    private static let document = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/modules/README.md")

    /// A module with every optional part present, so the walk reaches every nested type.
    private static let everything = """
    {"id":"doc.all","title":"t","description":"d","author":"a","site":"https://example.com","version":"1.0",
     "requiredVersion":"3.0","hosts":["example.com"],"rateLimit":"1/1000",
     "modules":[{"id":"e","title":"t","description":"d","cacheDuration":60,
       "params":[{"name":"p","title":"t","type":"enumeration","description":"d","value":"v",
                  "enumOptions":[{"title":"t","value":"v"}]}],
       "request":{"url":"https://example.com/{{p}}","method":"POST","body":"b","headers":{"h":"v"},"charset":"utf-8",
                  "bodyEncoding":"json"},
       "list":{"items":"i","title":"t","author":"a","cover":"c","intro":"i","url":"u","kind":"k","language":"l",
               "aliases":"a","tags":"t","publisher":"p","isbn":"i","series":"s","contentKind":"c"},
       "contentKind":"comic","excludeTags":["x"]}],
     "search":{"request":{"url":"https://example.com/s"},"list":{"items":"i","title":"t","url":"u"},
               "detail":{"request":{"url":"{{url}}.json"},"intro":"i","tags":"t"}},
     "lookup":{"request":{"url":"https://example.com/{{isbn}}"},"list":{"items":"i","title":"t","isbn":"i"},
               "isbnPrefixes":["9784"]},
     "reading":{"headers":{"h":"v"},"charset":"utf-8",
                "toc":{"items":"i","title":"t","url":"u","nextPage":"n","singleChapter":"s"},
                "content":{"text":"t","title":"t","nextPage":"n"}},
     "attribution":{"text":"t","url":"https://example.com"},
     "localizations":{"en":{"title":"t","description":"d","entries":{"e":{"title":"t","description":"d"}}}}}
    """

    /// Every stored property's name, at every depth of the format's own types.
    private static func fieldNames(of value: Any) -> Set<String> {
        var names = Set<String>()
        func walk(_ value: Any) {
            let mirror = Mirror(reflecting: value)
            switch mirror.displayStyle {
            case .optional, .collection:
                mirror.children.forEach { walk($0.value) }
            case .dictionary:
                // A dictionary's entries are (key, value) pairs; only the value is the format's.
                mirror.children.forEach { child in
                    Mirror(reflecting: child.value).children.dropFirst().forEach { walk($0.value) }
                }
            case .struct:
                guard String(reflecting: type(of: value)).contains("RuleModule") else { return }
                for child in mirror.children {
                    if let label = child.label { names.insert(label) }
                    walk(child.value)
                }
            default:
                return
            }
        }
        walk(value)
        return names
    }

    private func documented() throws -> String {
        try String(contentsOf: Self.document, encoding: .utf8)
    }

    @Test("every field of a module is in the document")
    func moduleFields() throws {
        let module = try RuleModuleValidator.validate(Data(Self.everything.utf8), appVersion: "3.0")
        let names = Self.fieldNames(of: module)
        #expect(names.contains("singleChapter") && names.contains("enumOptions") && names.contains("entries")
                && names.contains("detail"),
                "the walk reaches the nested types: \(names.sorted())")
        let document = try documented()
        let missing = names.filter { !document.contains("`\($0)`") }.sorted()
        #expect(missing.isEmpty, "not in docs/modules/README.md: \(missing)")
    }

    @Test("every value of a fixed-set field is in the document")
    func values() throws {
        let document = try documented()
        let values = RuleModule.ParamType.allCases.map(\.rawValue) + RuleModule.BodyEncoding.allCases.map(\.rawValue)
            + [ContentKind.text, .comic].map(\.rawValue) // the validator's own list
        let missing = values.filter { !document.contains("`\($0)`") }
        #expect(missing.isEmpty, "not in docs/modules/README.md: \(missing)")
    }

    @Test("every field of a repository index is in the document")
    func repositoryFields() throws {
        let index = try RuleModuleRepositoryIndex.parse(Data(#"""
            {"name":"n","modules":[{"id":"a","title":"t","description":"d","author":"a","version":"1.0","url":"a.json"}]}
            """#.utf8), from: URL(string: "https://example.com/index.json")!)
        let document = try documented()
        var names = Set(Mirror(reflecting: index).children.compactMap(\.label))
        names.formUnion(Mirror(reflecting: index.modules[0]).children.compactMap(\.label).map { "modules[].\($0)" })
        let missing = names.filter { !document.contains("`\($0)`") }.sorted()
        #expect(missing.isEmpty, "not in docs/modules/README.md: \(missing)")
    }
}
