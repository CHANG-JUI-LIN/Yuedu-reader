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
}

/// A shelf copy's cover for the UIKit row, taken from the shelf's own `BookshelfCoverPlan`:
/// its own artwork (saved or filled), else its catalog cover (`coverURL`), else 預設封面,
/// else the generated cover. Loaded through `CoverImagePipeline`, as the shelf's slots are.
struct IOS17ShelfCover: Equatable {
    var own: CoverImageSource?
    var usesCatalogCover: Bool
    var defaultCover: CoverImageSource?
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

    func requiresReload(comparedTo previous: Self?) -> Bool {
        self != previous
    }
}
