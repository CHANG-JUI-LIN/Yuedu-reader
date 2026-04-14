import Foundation

/// Caches parsed rule components for Legado JSOUP-default syntax.
final class SelectorCache {
    static let shared = SelectorCache()

    // MARK: - Parsed rule types

    /// Parsed result of a Legado JSOUP rule.
    struct ParsedJsoupRule: Hashable {
        let steps: [JsoupStep]
    }

    /// A single step in a parsed JSOUP rule chain.
    struct JsoupStep: Hashable {
        /// CSS selector equivalent (e.g. "class.book")
        let selector: String
        /// Optional index filtering (e.g. [0,2,-1])
        let indices: IndexFilter?
        /// Optional accessor (e.g. @text, @href)
        let accessor: String?
    }

    /// Describes how to filter elements by index.
    struct IndexFilter: Hashable {
        enum FilterType: Hashable {
            /// Select specific indices: [0, 2, -1]
            case select([Int])
            /// Exclude specific indices: [!0, 2]
            case exclude([Int])
            /// Range with step: [start:end:step]
            case range(start: Int, end: Int, step: Int)
        }
        let type: FilterType
    }

    // MARK: - Cache storage

    private let cache: LRUCache<String, ParsedJsoupRule>

    /// - Parameter capacity: Maximum cached parsed rules. Defaults to 32.
    init(capacity: Int = 32) {
        self.cache = LRUCache(capacity: capacity)
    }

    /// Get a previously parsed rule, or nil if not cached.
    func getParsed(_ rule: String) -> ParsedJsoupRule? {
        return cache.get(rule)
    }

    /// Store a parsed rule in the cache.
    func putParsed(_ rule: String, parsed: ParsedJsoupRule) {
        cache.put(rule, value: parsed)
    }

    /// Get cached parse result or invoke `parser` to create and cache it.
    func getOrParse(_ rule: String, parser: (String) -> ParsedJsoupRule) -> ParsedJsoupRule {
        return cache.getOrPut(rule) { parser(rule) }
    }

    /// Clear all cached parsed rules.
    func clear() {
        cache.clear()
    }
}
