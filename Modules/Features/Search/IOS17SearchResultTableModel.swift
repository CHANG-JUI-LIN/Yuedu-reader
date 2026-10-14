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

/// The 搜索 tab root's one list of works (unified search 4c-3), as values: its rows, what it
/// says besides them, and whether Gutenberg's search is offered.
struct IOS17SearchWorksSection: Equatable {
    var rows: [IOS17SearchResultTableRow]
    var status: UnifiedSearchStatus
    var offersGutenberg: Bool
    /// The query Gutenberg's row names.
    var query: String = ""
}

struct IOS17SearchResultTableContent: Equatable {
    /// The sources' results where the page is not the tab's root.
    let rows: [IOS17SearchResultTableRow]
    let showsLoadMore: Bool
    /// The tab root's works; set, it replaces `rows`.
    var works: IOS17SearchWorksSection? = nil

    func requiresReload(comparedTo previous: Self?) -> Bool {
        self != previous
    }
}
