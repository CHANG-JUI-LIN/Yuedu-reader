import Foundation
import SwiftSoup

/// Exact-match cache for parsed SwiftSoup documents, confined to one serial owner.
///
/// The rule engine hands every extraction the raw HTML STRING, and each
/// extractor called `SwiftSoup.parse` again — so a book-info parse with ten
/// CSS field rules rebuilt the same page DOM ten times, and every TOC page
/// built it once for `chapterList` and once more for `nextTocUrl`. This cache
/// makes repeated extractions over the same page string reuse one DOM.
///
/// Only "page-sized" content (≥ `minimumCacheableLength`) is cached: per-item
/// fragments (a chapter row's outerHtml) are small, cheap to parse, and would
/// otherwise flush the page entry out.
///
/// # Why per-thread, and never shared
///
/// SwiftSoup **mutates node state during reads**. `Attributes.getIgnoreCase` and
/// `hasKeyIgnoreCase` lazily populate `Attributes.lowercasedKeysCache`, and
/// `Element.select` fills `Element.selectorResultCache` /
/// `selectorResultCacheRoot`. Two threads merely *querying* the same `Document`
/// are therefore two threads writing the same stored properties.
///
/// This was a global singleton whose lock covered the entry list but not the
/// `Document` it handed out, on the reasoning that same-source parses are
/// serialized by `BookSourceSession` and different sources use different page
/// strings. Neither holds: the session handed out the bridge *without* the parse
/// lock by design, and even with every bridge call now on the source's host, a
/// JS-side `LegadoJsoupBridge.parse` runs on the engine's JS queue, a different
/// thread from an extractor on the host; and nothing prevents two flows from
/// parsing byte-identical HTML. It
/// produced shipped crashes: `EXC_BAD_ACCESS` in `Attributes.getIgnoreCaseSlice`,
/// `Attributes.updateLowercasedKeysCache` and `Element.storeSelectorResult`, with
/// a double `doDecrementSlow` above them — concurrent release of one object.
///
/// `current` is only for synchronous extractors: a rule set's field extractions
/// finish on the thread that parsed the page. A JS wrapper can retain its Document
/// after an evaluation returns, and a serial DispatchQueue can move between OS
/// threads. Each JSContext therefore owns a separate instance through its
/// LegadoJsoupBridge; it must never borrow a document from `current`.
///
/// Capacity is 1 because the access pattern is consecutive: N field rules against
/// the page currently being parsed. Holding more would multiply peak memory by the
/// number of live parsing threads for no hit-rate gain.
///
/// # Kept for the parse, not for the thread
///
/// A source's parses run on its host's serial queue, and GCD runs those queues on whichever
/// worker thread is free, so every worker that ever parsed a page kept that page until it
/// happened to parse another. The 書源檢查 keeps 32 sources parsing at once: a user with
/// 8,735 sources ran out of memory at 3.7 GB after about a hundred tables of contents
/// (Crashlytics 6dda6179). `ModernParserBridge` brackets each parse with `beginParse()`, and
/// the documents go when the outermost parse on the thread ends.
final class JsoupDocumentCache {

    private static let threadDictionaryKey = "com.yuedu.jsoupDocumentCache"
    private static let parseDepthKey = "com.yuedu.jsoupDocumentCache.parseDepth"

    /// One parse on one thread, from `beginParse()` to `end()`.
    struct ParseScope {
        fileprivate let thread: Thread

        /// Ends the parse; call it on the thread that began it (`defer` right after
        /// `beginParse()`). The outermost end forgets the thread's documents.
        func end() {
            assert(Thread.current === thread, "a parse scope ended on another thread than it began on")
            let storage = Thread.current.threadDictionary
            let depth = ((storage[JsoupDocumentCache.parseDepthKey] as? Int) ?? 1) - 1
            guard depth == 0 else {
                storage[JsoupDocumentCache.parseDepthKey] = depth
                return
            }
            storage.removeObject(forKey: JsoupDocumentCache.parseDepthKey)
            storage.removeObject(forKey: JsoupDocumentCache.threadDictionaryKey)
        }
    }

    /// Begins a parse on this thread. A parse inside another (`parseTOCPage` reading the
    /// chapters, then the next pages, of one page) shares the outer one's documents.
    static func beginParse() -> ParseScope {
        let storage = Thread.current.threadDictionary
        storage[parseDepthKey] = ((storage[parseDepthKey] as? Int) ?? 0) + 1
        return ParseScope(thread: .current)
    }

    /// The calling thread's cache. Never hand the returned instance — or any
    /// `Document`/`Element` obtained from it — to another thread.
    static var current: JsoupDocumentCache {
        let storage = Thread.current.threadDictionary
        if let existing = storage[threadDictionaryKey] as? JsoupDocumentCache {
            return existing
        }
        let created = JsoupDocumentCache()
        storage[threadDictionaryKey] = created
        return created
    }

    private struct Entry {
        let content: String
        let baseURL: String
        let document: Document
    }

    private var entry: Entry?
    private let minimumCacheableLength = 4096

    /// Keep this instance and all documents it returns within the same serial owner.
    init() {}

    /// Parse-or-reuse. `content` must already be in its final parse form
    /// (callers that truncate for SwiftSoup pass the truncated string).
    func document(for content: String, baseURL: String) throws -> Document {
        guard content.count >= minimumCacheableLength else {
            return try SwiftSoup.parse(content, baseURL)
        }

        if let entry, entry.baseURL == baseURL, entry.content == content {
            return entry.document
        }

        let document = try SwiftSoup.parse(content, baseURL)
        entry = Entry(content: content, baseURL: baseURL, document: document)
        return document
    }
}
