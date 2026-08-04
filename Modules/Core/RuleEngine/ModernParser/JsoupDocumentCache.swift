import Foundation
import SwiftSoup

/// Exact-match cache for parsed SwiftSoup documents, **confined to one thread**.
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
/// strings. Neither holds: `BookSourceSession.bridgeForAsyncOperations` hands out
/// the bridge *without* the parse lock by design (so a JS-side
/// `LegadoJsoupBridge.parse` on the JS queue races an extractor on a cooperative
/// thread), and nothing prevents two flows from parsing byte-identical HTML. It
/// produced shipped crashes: `EXC_BAD_ACCESS` in `Attributes.getIgnoreCaseSlice`,
/// `Attributes.updateLowercasedKeysCache` and `Element.storeSelectorResult`, with
/// a double `doDecrementSlow` above them — concurrent release of one object.
///
/// Thread confinement keeps every bit of the reuse this cache was built for — a
/// parse chain is synchronous, so a rule set's field extractions all run on the
/// thread that parsed the page — while making cross-thread sharing structurally
/// impossible rather than merely unlikely.
///
/// Capacity is 1 because the access pattern is consecutive: N field rules against
/// the page currently being parsed. Holding more would multiply peak memory by the
/// number of live parsing threads for no hit-rate gain.
final class JsoupDocumentCache {

    private static let threadDictionaryKey = "com.yuedu.jsoupDocumentCache"

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

    private init() {}

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
