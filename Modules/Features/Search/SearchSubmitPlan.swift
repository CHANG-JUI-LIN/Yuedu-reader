import Foundation

/// What the keyboard's Search does with the sources once the parts that answer on submit
/// (the saved libraries and Gutenberg, the modules, Open Library) have been asked (unified
/// search 4b-2, 4b-3; search 9b).
enum SearchSubmitPlan: Equatable {
    /// Search the sources; with none, the search says so.
    case sources
    /// No source, and something else answers: no source is not an error here.
    case othersOnly
    /// The source library is still being read: a large library is not taken for none.
    case waitForSources

    static func decide(hasSources: Bool, sourcesLoaded: Bool, othersAnswer: Bool) -> SearchSubmitPlan {
        if hasSources { return .sources }
        guard othersAnswer else { return .sources }
        guard sourcesLoaded else { return .waitForSources }
        return .othersOnly
    }
}
