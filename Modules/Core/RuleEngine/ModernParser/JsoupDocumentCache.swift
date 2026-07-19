import Foundation
import SwiftSoup

/// Exact-match cache for parsed SwiftSoup documents.
///
/// The rule engine hands every extraction the raw HTML STRING, and each
/// extractor called `SwiftSoup.parse` again — so a book-info parse with ten
/// CSS field rules rebuilt the same page DOM ten times, and every TOC page
/// built it once for `chapterList` and once more for `nextTocUrl`. This cache
/// makes repeated extractions over the same page string reuse one DOM.
///
/// Only "page-sized" content (≥ `minimumCacheableLength`) is cached: per-item
/// fragments (a chapter row's outerHtml) are small, cheap to parse, and would
/// otherwise flush the page entries out of the tiny MRU list.
///
/// Concurrency: lookups are exact string matches under a lock. Same-source
/// parses are already serialized by `BookSourceSession`; distinct sources use
/// distinct page strings, so concurrent traversal of one Document is not a
/// pattern this cache introduces.
final class JsoupDocumentCache {
    static let shared = JsoupDocumentCache()

    private struct Entry {
        let content: String
        let baseURL: String
        let document: Document
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity = 4
    private let minimumCacheableLength = 4096

    /// Parse-or-reuse. `content` must already be in its final parse form
    /// (callers that truncate for SwiftSoup pass the truncated string).
    func document(for content: String, baseURL: String) throws -> Document {
        guard content.count >= minimumCacheableLength else {
            return try SwiftSoup.parse(content, baseURL)
        }

        lock.lock()
        if let index = entries.firstIndex(where: {
            $0.baseURL == baseURL && $0.content == content
        }) {
            let entry = entries.remove(at: index)
            entries.insert(entry, at: 0)
            lock.unlock()
            return entry.document
        }
        lock.unlock()

        let document = try SwiftSoup.parse(content, baseURL)

        lock.lock()
        entries.insert(Entry(content: content, baseURL: baseURL, document: document), at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
        lock.unlock()
        return document
    }
}
