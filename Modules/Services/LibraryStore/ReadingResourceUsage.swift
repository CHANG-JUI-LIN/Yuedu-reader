import Foundation

/// Reader ownership is tracked by presentation instance, so repeated appearance
/// callbacks and two windows cannot accidentally release each other's book.
@MainActor
final class ReadingResourceUsage {
    static let shared = ReadingResourceUsage()
    private var owners: [UUID: Set<UUID>] = [:]

    func retain(bookID: UUID, ownerID: UUID) {
        owners[bookID, default: []].insert(ownerID)
    }

    /// Only the last actual owner may tear down the shared reading session.
    @discardableResult
    func release(bookID: UUID, ownerID: UUID) -> Bool {
        guard owners[bookID]?.remove(ownerID) != nil else { return false }
        guard owners[bookID]?.isEmpty == true else { return false }
        owners.removeValue(forKey: bookID)
        return true
    }

    func isInUse(bookID: UUID) -> Bool { owners[bookID]?.isEmpty == false }
}
