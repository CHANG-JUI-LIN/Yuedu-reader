import Foundation

/// 搜索's 青空文庫 matches, searched once per query off the main actor. The list is rebuilt
/// on every publication of every part; it used to search the whole catalog each time, on the
/// main actor, 21–27 ms a time — twice between the keyboard's Search and the sources' first
/// request, which left 25–35 ms later (Phase 4 acceptance, 2026-10-14).
@Observable
@MainActor
final class PublicLibrarySearchModel {
    struct Answer {
        let query: String
        let works: [AozoraWork]
        /// The catalog the works were found in, which their routes read.
        let index: AozoraCatalogIndex
    }

    /// The last query's matches; nil when there is no query or no catalog.
    private(set) var answer: Answer?
    @ObservationIgnored private let searcher: @Sendable (AozoraCatalogIndex, String) -> [AozoraWork]

    init(searcher: @escaping @Sendable (AozoraCatalogIndex, String) -> [AozoraWork] = { $0.search($1) }) {
        self.searcher = searcher
    }

    func search(_ query: String, in index: AozoraCatalogIndex?) async {
        guard !query.isEmpty, let index else {
            if answer != nil { answer = nil }
            return
        }
        let started = SourcePerfTrace.now
        let searcher = searcher
        let works = await Task.detached(priority: .userInitiated) { searcher(index, query) }.value
        guard !Task.isCancelled else { return }
        answer = Answer(query: query, works: works, index: index)
        SourcePerfTrace.record("search.publicLibrary.aozora", "matches=\(works.count)", since: started, thresholdMs: 0)
    }
}
