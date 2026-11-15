import Combine
import Foundation

/// One reader's review of a work, as a module's site gave it. Every part but the text is there
/// only when the site has it: 作品詳情 draws no stars for a review without a rating.
struct WorkReview: Codable, Hashable, Sendable {
    /// The review's own headline.
    var title: String?
    /// Plain text, one line per paragraph, bounded (`WorkReview.textLimit`).
    var text: String
    var author: String?
    var date: Date?
    /// The writer's rating of the work, in stars out of `WorkRating.stars`.
    var rating: Double?
    /// How many readers marked it helpful.
    var likes: Int?

    /// Source-controlled text is bounded before it reaches SwiftUI's layout
    /// (`Technotes/iOS17SearchWatchdogPostmortem.md`, guardrail 4).
    static let textLimit = 2_000
    static let titleLimit = 120
    static let authorLimit = 60
}

/// A work's rating as a whole.
struct WorkRating: Codable, Hashable, Sendable {
    /// What every rating is shown out of.
    static let stars = 5

    /// The average, in stars out of `stars`.
    var score: Double
    /// How many ratings it is the average of.
    var count: Int?
    /// How many ratings each star has, the highest star first; `stars` values, or absent.
    var distribution: [Int]?
}

/// What one module's readers wrote about a work.
struct WorkReviewSet: Hashable, Sendable {
    /// The module they came from, and its name as 作品詳情 credits it.
    var moduleID: String
    var moduleTitle: String
    var reviews: [WorkReview]
    var rating: WorkRating?

    var isEmpty: Bool { reviews.isEmpty && rating == nil }
}

/// The work 作品詳情 shows, as a module is asked about it.
struct WorkReviewQuery: Hashable, Sendable {
    var title: String
    var authors: [String]
    /// ISBN-13s of the versions this device knows, sorted.
    var isbns: [String]
    var contentKind: ContentKind
    /// The page's own record, when a module listed it: that module is asked about it as it is.
    var record: SourceItemKey?

    init(title: String, authors: [String], isbns: [String] = [], contentKind: ContentKind, record: SourceItemKey? = nil) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authors = WorkMatchKey.knownAuthors(authors)
        self.isbns = Array(Set(isbns)).sorted()
        self.contentKind = contentKind
        self.record = record
    }
}

/// 作品詳情's 讀者評論: the first module that has reviews of the work, in the order 資料來源
/// lists the modules. A module is asked only while it is checked there and in use (停用 takes it
/// out of the library), so the reader's one list decides what leaves the device: asking sends
/// the work's ISBN or title to the module's site.
@MainActor
enum WorkReviews {
    typealias Ask = @MainActor (RuleModule, WorkReviewQuery) async throws -> WorkReviewSet?

    static func load(_ query: WorkReviewQuery, library: RuleModuleLibrary = .shared,
                     order: MetadataFillOrderStore = .shared,
                     ask: Ask = { module, query in
                         try await ModuleReviewProvider(provider: ModuleProvider(module: module)).reviews(for: query)
                     }) async -> WorkReviewSet? {
        guard !query.title.isEmpty else { return nil }
        await library.loadIfNeeded()
        let modules = Self.modules(in: library, order: order)
        guard !modules.isEmpty else { return nil }
        let started = SourcePerfTrace.now
        for module in modules {
            guard !Task.isCancelled else { return nil }
            do {
                if let found = try await ask(module, query), !found.isEmpty {
                    SourcePerfTrace.record("works.detail.reviews",
                                           "module=\(module.id) reviews=\(found.reviews.count) rating=\(found.rating != nil)",
                                           since: started, thresholdMs: 0)
                    return found
                }
            } catch is CancellationError {
                return nil
            } catch {
                // The site's own failure (this one answers 502 now and then): the next module is
                // asked, and the section stays out. Nothing is retried here.
                AppLogger.network("⟐ work reviews: module failed", error: SourceFailure.loggable(error),
                                  context: ["module": module.id])
            }
        }
        SourcePerfTrace.record("works.detail.reviews", "modules=\(modules.count) reviews=0", since: started, thresholdMs: 0)
        return nil
    }

    /// The modules with reviews that 資料來源 has checked, in its order; with `having`, the ones
    /// with something else a work is asked about the same way (本章說, `ChapterComments`).
    static func modules(in library: RuleModuleLibrary, order: MetadataFillOrderStore,
                        having has: (RuleModule) -> Bool = { $0.reviews != nil }) -> [RuleModule] {
        let filling = library.fillingModules
        return order.order(modules: filling.map(\.id)).entries.filter(\.isEnabled).compactMap { entry in
            guard case .module(let id) = entry.place else { return nil }
            return filling.first { $0.id == id && has($0) }
        }
    }
}

/// One 作品詳情's 讀者評論, loaded once per work shown. Nothing is published until reviews are
/// read: no header over a spinner that could then vanish and move the page.
@MainActor
final class WorkReviewsModel: ObservableObject {
    @Published private(set) var reviews: WorkReviewSet?
    private var loaded: WorkReviewQuery?
    private let read: @MainActor (WorkReviewQuery) async -> WorkReviewSet?

    init(read: @escaping @MainActor (WorkReviewQuery) async -> WorkReviewSet? = { await WorkReviews.load($0) }) {
        self.read = read
    }

    /// Loads the section for `query`; nil hides it. The same query is not asked again when the
    /// page reappears.
    func load(_ query: WorkReviewQuery?) async {
        guard query != loaded || query == nil else { return }
        guard let query else {
            loaded = nil
            reviews = nil
            return
        }
        reviews = nil
        let found = await read(query)
        guard !Task.isCancelled else { return }
        reviews = found
        loaded = query
    }
}
