import Foundation

/// Whether a freshly fetched table of contents may replace the one a book already has.
///
/// It exists because of a missing distinction: **a table of contents that came back empty
/// is a failed request, not a book with no chapters.** `BookSourceFetcher.fetchTOCPackage`
/// answers with an empty package rather than throwing when a source's rules match nothing —
/// a Cloudflare interstitial, a login wall, a WebView that resumed onto a challenge page, a
/// rule the site outgrew. The source-switch path already refused to commit that
/// (`BookStore.updateOnlineBookSource`); the automatic refresh did not, and that refresh runs
/// on every return to the foreground. Committing it emptied `onlineChapters`, and the
/// reconcile that followed read "every chapter disappeared" and deleted every cached file the
/// book had — which is how a backgrounded download came back as a book that had never been
/// downloaded.
enum OnlineTOCCommitPolicy {
    enum Decision: Equatable {
        case commit
        /// Nothing came back. Keep the chapters the book already has and try again later.
        /// A book that genuinely has no chapters is unreadable either way, so refusing costs
        /// nothing and a transient source failure costs everything.
        case rejectEmpty
    }

    static func decide(refreshedCount: Int) -> Decision {
        refreshedCount == 0 ? .rejectEmpty : .commit
    }
}

/// Whether a run of chapter failures has stopped being evidence about the chapters and
/// become evidence about the table of contents that supplied their URLs.
///
/// Chapters fail one at a time — a paywall, a rate limit, a parse the site outgrew. A stale
/// table of contents fails *all* of them, because every chapter is fetched from a URL that
/// list handed over. Only the count of distinct failing chapters separates the two; no single
/// failure carries the information.
///
/// The list outlives the book it describes: the TOC cache is keyed by `(sourceId, url)`, so it
/// belongs to the source, and deleting a book then re-adding it from 發現頁 gets the same
/// possibly-expired URLs back. That is why a book could fail on every chapter after 移除下載
/// and recover only on 換源 — a different source id is a different cache key.
enum StaleTOCSuspicion {
    enum Decision: Equatable {
        case keepWaiting
        /// Refetch the table of contents, then retry the failed chapters against it.
        case revalidateTableOfContents
    }

    static func decide(
        distinctFailedChapters: Int,
        alreadyRevalidated: Bool,
        threshold: Int = AppConfig.staleTOCSuspicionThreshold
    ) -> Decision {
        // Strictly one shot. A freshly fetched list that still fails is telling the truth, and
        // the failure overlay is the honest answer; retrying past it is the avalanche this
        // codebase keeps having to delete.
        guard !alreadyRevalidated else { return .keepWaiting }
        return distinctFailedChapters >= threshold
            ? .revalidateTableOfContents
            : .keepWaiting
    }
}

/// What a table-of-contents reconcile may do to cached chapter files whose ref no longer
/// matches. Marking is always performed — only deletion is conditional.
///
/// Deleting is reserved for the two actions where the user asked for it: 換源 (a confirmed
/// rebinding of the book to a different source) and 移除下載. Every table-of-contents
/// refresh — automatic or manual — preserves content, because a refresh is a question about
/// chapter *lists*, never a request to discard chapter *bytes*.
public enum OfflineContentDisposition: Equatable, Sendable {
    /// Remove the cached artifacts of every mismatched index.
    case deleteMismatched
    /// Leave every file alone. Callers still null `cachedFilename` and re-pend the index, so
    /// the chapter is refetched on demand; the bytes stay until the user removes the download
    /// or clears the cache. Orphaned files are the accepted cost of never losing a download
    /// to a source hiccup nobody was watching.
    case preserveContent
}
