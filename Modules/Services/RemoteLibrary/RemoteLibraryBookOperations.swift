import Foundation

/// Serializes resource mutations for one book, without blocking other books.
/// A waiting caller rechecks the completed output after acquiring its lease.
@MainActor
final class RemoteLibraryBookOperations {
    enum Kind: Equatable { case preparation, offlineDownload }

    struct Lease: Equatable {
        let id = UUID()
        let bookID: UUID
        let kind: Kind
    }

    private struct Waiter {
        let lease: Lease
        let continuation: CheckedContinuation<Void, Error>
    }

    private var active: [UUID: Lease] = [:]
    private var waiting: [UUID: [Waiter]] = [:]
    private var invalidated: [UUID: Error] = [:]

    func acquire(bookID: UUID, kind: Kind) async throws -> Lease {
        try Task.checkCancellation()
        let lease = Lease(bookID: bookID, kind: kind)
        if active[bookID] == nil {
            active[bookID] = lease
            return lease
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiting[bookID, default: []].append(Waiter(lease: lease, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiting(lease) }
        }
        // Cancellation can race the handoff. In that case this caller owns the
        // lease and must pass it on, even though it will never begin its work.
        do { try validate(lease) }
        catch { finish(lease); throw error }
        return lease
    }

    func validate(_ lease: Lease) throws {
        try Task.checkCancellation()
        guard active[lease.bookID] == lease else { throw CancellationError() }
        if let error = invalidated[lease.id] { throw error }
    }

    func finish(_ lease: Lease) {
        guard active[lease.bookID] == lease else { return }
        invalidated.removeValue(forKey: lease.id)
        active.removeValue(forKey: lease.bookID)
        if var queue = waiting.removeValue(forKey: lease.bookID), !queue.isEmpty {
            let next = queue.removeFirst()
            if !queue.isEmpty { waiting[lease.bookID] = queue }
            active[lease.bookID] = next.lease
            next.continuation.resume()
        }
    }

    func invalidate(bookID: UUID, kind: Kind? = nil, error: Error = CancellationError()) {
        if let lease = active[bookID], kind == nil || lease.kind == kind {
            // Keep ownership until cleanup finishes; a new operation must not
            // write into files that the invalidated operation is still using.
            invalidated[lease.id] = error
        }
        let queue = waiting.removeValue(forKey: bookID) ?? []
        for waiter in queue {
            if kind == nil || waiter.lease.kind == kind {
                waiter.continuation.resume(throwing: error)
            } else {
                waiting[bookID, default: []].append(waiter)
            }
        }
    }

    private func cancelWaiting(_ lease: Lease) {
        guard var queue = waiting[lease.bookID],
              let index = queue.firstIndex(where: { $0.lease == lease }) else { return }
        let waiter = queue.remove(at: index)
        waiting[lease.bookID] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(throwing: CancellationError())
    }
}
