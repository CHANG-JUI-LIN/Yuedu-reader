import Foundation

/// Resource prefetches can fail together. Show one alert at a time and report a
/// given failure only once for this reader presentation, including after Cancel.
struct RemoteReaderFailureAlertState {
    private(set) var failure: RemoteLibraryReadFailure?
    private var presentedFailures: Set<RemoteLibraryReadFailure> = []

    @discardableResult
    mutating func receive(_ failure: RemoteLibraryReadFailure, bookID: UUID, isReady: Bool) -> Bool {
        guard isReady, failure.bookID == bookID,
              self.failure == nil, !presentedFailures.contains(failure) else { return false }
        self.failure = failure
        presentedFailures.insert(failure)
        return true
    }

    mutating func dismiss() { failure = nil }
}
