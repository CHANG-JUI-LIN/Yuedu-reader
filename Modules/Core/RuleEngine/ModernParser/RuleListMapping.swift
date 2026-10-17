import Foundation

/// The rules of one list's items: a 來源配置's search or explore rule, or a module's list
/// (Phase 6c). One mapping for all of them, so a module reads a list the way a source does.
struct RuleListFields: Sendable {
    var name: String
    var author: String
    var bookUrl: String
    var coverUrl: String
    var intro: String
    var wordCount: String
    var lastChapter: String
    var kind: String
    /// A module's (6d); 來源配置 have no language rule.
    var language: String = ""
    // A module's (format 3.0); 來源配置 have none of these.
    var aliases: String = ""
    var tags: String = ""
    var publisher: String = ""
    var isbn: String = ""
    var series: String = ""
    var contentKind: String = ""
}

/// One list item as its rules read it.
struct RuleListItem: Codable, Equatable, Sendable {
    var name: String
    var author: String
    var bookUrl: String
    var coverUrl: String
    var intro: String
    var wordCount: String
    var lastChapter: String
    /// Every value of the kind rule, joined with `,` as Legado's `getStringList` result is.
    var kind: String
    var language: String = ""
    // A module's (format 3.0), nil without a rule. Optional, so a page cached before they
    // existed still decodes.
    var aliases: [String]? = nil
    var tags: [String]? = nil
    var publisher: String? = nil
    var isbn: String? = nil
    var series: String? = nil
    var contentKind: String? = nil
}

enum RuleListMapping {
    /// The items `listRule` selects in `content`, each read with `fields`; an item with no name
    /// is skipped. `engine` is left holding the last item.
    ///
    /// - Parameter earlyFilter: asked with the name and author before the other fields are
    ///   read (Legado's BookList idea): a strict matcher such as 換源 skips most of the work.
    /// - Parameter onMissingLink: when given, an item whose link rule finds no link in it is
    ///   left out and named here. Legado lists it as its page (`bookUrl = baseUrl`), which is
    ///   how a site's "no results" row (「没有找到包含：…」) became a book in 搜尋 (search 9a). An
    ///   empty link rule still means the page itself, as Legado has it.
    static func items(
        engine: ModernRuleEngine,
        content: Any,
        baseURL: String,
        listRule: String,
        fields: RuleListFields,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)? = nil,
        onMissingLink: ((_ name: String) -> Void)? = nil
    ) -> [RuleListItem] {
        guard !listRule.isEmpty else { return [] }
        engine.setContent(content, baseUrl: baseURL)
        var items: [RuleListItem] = []
        for element in engine.getElements(ruleStr: listRule) {
            engine.setContent(element, baseUrl: baseURL)
            let name = engine.getString(ruleStr: fields.name)
            guard !name.isEmpty else { continue }
            let author = engine.getString(ruleStr: fields.author)
            if let earlyFilter, !earlyFilter(name, author) { continue }
            let bookUrl: String
            if let onMissingLink, !fields.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bookUrl = engine.getOptionalURL(ruleStr: fields.bookUrl)
                guard !bookUrl.isEmpty else {
                    onMissingLink(name)
                    continue
                }
            } else {
                bookUrl = engine.getString(ruleStr: fields.bookUrl, isUrl: true)
            }
            items.append(RuleListItem(
                name: name,
                author: author,
                bookUrl: bookUrl,
                // A cover rule that matches nothing stays empty rather than falling back to
                // the page's URL (`getOptionalURL`).
                coverUrl: engine.getOptionalURL(ruleStr: fields.coverUrl),
                intro: engine.getString(ruleStr: fields.intro),
                wordCount: engine.getString(ruleStr: fields.wordCount),
                lastChapter: engine.getString(ruleStr: fields.lastChapter),
                // Android Legado parses `kind` with getStringList and joins the values. Besides
                // keeping several categories, this leaves the intermediate `result` a mutable
                // List for trailing JS such as `result.add(...)`.
                kind: engine.getStringList(ruleStr: fields.kind).joined(separator: ","),
                language: fields.language.isEmpty ? "" : engine.getString(ruleStr: fields.language),
                aliases: values(engine, fields.aliases),
                tags: values(engine, fields.tags),
                publisher: value(engine, fields.publisher),
                isbn: value(engine, fields.isbn),
                series: value(engine, fields.series),
                contentKind: value(engine, fields.contentKind)
            ))
        }
        return items
    }

    /// Nil without a rule; trimmed, empty values dropped.
    private static func values(_ engine: ModernRuleEngine, _ rule: String) -> [String]? {
        guard !rule.isEmpty else { return nil }
        return engine.getStringList(ruleStr: rule)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func value(_ engine: ModernRuleEngine, _ rule: String) -> String? {
        guard !rule.isEmpty else { return nil }
        return engine.getString(ruleStr: rule).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension OnlineBook {
    /// A 來源配置's list item. `tocUrl` is empty, as Legado's `SearchBook.tocUrl` is: the real
    /// table of contents comes from `ruleBookInfo.tocUrl` once the detail page is open.
    init(_ item: RuleListItem, source: BookSource) {
        self.init(name: item.name, author: item.author, intro: item.intro, coverUrl: item.coverUrl, bookUrl: item.bookUrl,
                  tocUrl: "", wordCount: item.wordCount, lastChapter: item.lastChapter, kind: item.kind,
                  sourceId: source.id, sourceName: source.bookSourceName)
    }
}
