import Foundation

public enum ChapterLoadState: Equatable {
    case idle
    case loading
    case ready
    /// The fetch ended without a verdict — superseded by a higher-priority request for the
    /// same chapter, dropped on a source change, or abandoned by a shared in-flight task.
    ///
    /// Distinct from `.failed` because it used to collapse into it. Nothing was learned
    /// about the chapter: it was never asked for to completion. Reporting that as a failure
    /// painted 章節載入失敗 over content that fetched fine on the next try — which is why
    /// "刷新一下就好了" — and ended the listening session at a chapter boundary. Distinct
    /// from `.idle` too, because `.idle` reads as "never asked" and left the reader spinning
    /// with nothing driving a retry; `.cancelled` says a re-request is owed.
    case cancelled
    case failed(reason: String)
}
