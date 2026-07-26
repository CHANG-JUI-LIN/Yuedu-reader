import Foundation

/// A navigation value that retains the exact snapshot selected by the user.
///
/// Equality intentionally uses only the stable result id. Search publication
/// can replace its UI snapshots while a destination is open, but the route keeps
/// the selected snapshot out of that live update graph.
struct SearchResultRoute<Snapshot>: Hashable {
    let id: UUID
    let snapshot: Snapshot

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
