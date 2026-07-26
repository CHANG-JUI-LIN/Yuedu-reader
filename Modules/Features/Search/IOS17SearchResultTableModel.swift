import Foundation

struct IOS17SearchResultTableRow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let author: String
    let intro: String
    let coverURL: String
    let sourceCount: Int
    let showsAudiobookBadge: Bool
}

struct IOS17SearchResultTableContent: Equatable {
    let rows: [IOS17SearchResultTableRow]
    let showsLoadMore: Bool

    func requiresReload(comparedTo previous: Self?) -> Bool {
        self != previous
    }
}
