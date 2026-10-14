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
    /// A result's cover address; for a shelf copy, its catalog cover's.
    let coverURL: String
    /// A shelf copy's cover as the shelf decides it (unified search 4b-1); nil for a result.
    var shelfCover: IOS17ShelfCover? = nil
    /// A library book's cover request: its connection's headers and session (unified search
    /// 4b-2); nil for a result.
    var remoteCover: IOS17RemoteCover? = nil
}

/// How a library book's cover is asked for: with its connection's headers and, for a
/// library that signs in, its own session, as `BookCoverImage` asks for it.
struct IOS17RemoteCover: Equatable {
    var headers: [String: String]
    var session: URLSession?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.headers == rhs.headers && lhs.session === rhs.session
    }
}

/// A shelf copy's cover for the UIKit row, taken from the shelf's own `BookshelfCoverPlan`:
/// its own artwork (saved or filled), else its catalog cover (`coverURL`), else 預設封面,
/// else the generated cover. Loaded through `CoverImagePipeline`, as the shelf's slots are.
struct IOS17ShelfCover: Equatable {
    var own: CoverImageSource?
    var usesCatalogCover: Bool
    var defaultCover: CoverImageSource?
}

/// A part of the search asked on submit (`LibrarySearchModel`), as values: its books, then its
/// status lines (searching, or each place that could not answer).
struct IOS17SearchAnswerSection: Equatable {
    var rows: [IOS17SearchResultTableRow]
    var notices: [String]

    var isEmpty: Bool { rows.isEmpty && notices.isEmpty }
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
    /// The shelf's copies (the 搜索 tab's root only), above the sources' results.
    var shelf: [IOS17SearchResultTableRow] = []
    let rows: [IOS17SearchResultTableRow]
    let showsLoadMore: Bool
    /// What the sources' part says while it has no row: searching, paused, or nothing found.
    var sourcesNotice: String? = nil
    /// The public libraries' section, under the sources' (the 搜索 tab's root only).
    var library: IOS17SearchLibrarySection? = nil
    /// 我的書庫: the saved OPDS and Calibre libraries (unified search 4b-2), under the shelf's.
    var remoteLibraries: IOS17SearchAnswerSection? = nil
    /// 書目資料庫: Open Library (4b-3), last.
    var bibliographic: IOS17SearchAnswerSection? = nil

    func requiresReload(comparedTo previous: Self?) -> Bool {
        self != previous
    }
}
