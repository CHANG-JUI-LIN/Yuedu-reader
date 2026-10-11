import Foundation

enum SearchResultNavigationMode: Equatable {
    case selectedItem
    case valueRoute

    static var current: Self {
        mode(
            forIOSMajorVersion:
                ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }

    static func mode(forIOSMajorVersion majorVersion: Int) -> Self {
        majorVersion >= 18 ? .valueRoute : .selectedItem
    }
}

struct IOS17SearchResultTableRow: Identifiable, Equatable {
    let id: UUID
    /// What the row says — the same value the SwiftUI row draws from.
    let content: SearchBookListRowContent
    let coverURL: String
}

/// The 公有書庫 part of the same search (unified library 5d-1b), as values like the result
/// rows: Gutenberg's search to submit, then 青空文庫's matches.
struct IOS17SearchLibrarySection: Equatable {
    struct Work: Identifiable, Equatable {
        let id: String
        let title: String
        let author: String
    }

    let query: String
    let works: [Work]
}

struct IOS17SearchResultTableContent: Equatable {
    let rows: [IOS17SearchResultTableRow]
    let showsLoadMore: Bool
    /// What the sources' part says while it has no row: searching, paused, or nothing found.
    var sourcesNotice: String? = nil
    /// The public libraries' section, under the sources' (the 搜索 tab's root only).
    var library: IOS17SearchLibrarySection? = nil

    func requiresReload(comparedTo previous: Self?) -> Bool {
        self != previous
    }
}
