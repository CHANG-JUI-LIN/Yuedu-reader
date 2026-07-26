import Foundation

/// Stable identity for the `OnlineBook` value created from a search result.
///
/// SwiftUI can rebuild a navigation destination several times while pushing it.
/// A fresh default `OnlineBook.id` on every rebuild changes the initial value of
/// the detail view's `@State currentBook`, which keeps iOS 17's AttributeGraph
/// dirty. Reuse the selected origin identity, or the aggregate search-book
/// identity when no origin exists.
enum SearchResultDetailIdentity {
    static func onlineBookID(
        searchBookID: UUID,
        originID: UUID?
    ) -> UUID {
        originID ?? searchBookID
    }
}
