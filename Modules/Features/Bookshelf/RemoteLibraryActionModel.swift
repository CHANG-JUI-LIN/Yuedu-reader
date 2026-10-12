import SwiftUI
import Combine

/// Reading or shelving one remote library item, with its progress, its outcome and its
/// cancellation. 書籍詳情 and 作品詳情 (unified library 5f) both act through it, so a
/// library item is read one way wherever it is opened.
@MainActor
final class RemoteLibraryActionModel: ObservableObject {
    enum Action {
        case read, addToShelf

        var progressTitle: String {
            switch self {
            case .read: localized("正在開啟書籍")
            case .addToShelf: localized("加入書架")
            }
        }
    }

    @Published private(set) var action: Action?
    @Published private(set) var message: String?
    @Published private(set) var failed = false
    private var task: Task<Void, Never>?

    /// Starts `action` unless one is running. A read records the copy and hands it to
    /// `onRead` at once: the reader downloads and prepares it under its own 正在開啟書籍
    /// (`BookReaderView`), so the page never shows that wait itself.
    func begin(_ action: Action, item: RemoteLibraryItem, format: RemoteLibraryFormat,
               service: any RemoteLibraryServing, store: BookStore, onRead: @escaping (UUID) -> Void) {
        guard self.action == nil else { return }
        switch action {
        case .read:
            message = nil
            failed = false
            do {
                onRead(try service.readingCopy(item: item, format: format, store: store).id)
            } catch {
                failed = true
                message = error.localizedDescription
                UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
            }
        case .addToShelf:
            begin(action) {
                _ = try service.addToShelf(item: item, format: format, store: store)
                return localized("已加入書架")
            }
        }
    }

    /// Runs `work` as `action`; what it returns is the message to show and announce. 作品詳情
    /// reads a Gutenberg book's catalog entry inside it, so that wait shows as the action too.
    func begin(_ action: Action, work: @escaping @MainActor () async throws -> String?) {
        guard self.action == nil else { return }
        self.action = action
        message = nil
        failed = false
        task = Task { @MainActor in
            do {
                message = try await work()
            } catch {
                if Task.isCancelled {
                    message = localized("已取消")
                } else {
                    failed = true
                    message = error.localizedDescription
                }
            }
            self.action = nil
            if let message { UIAccessibility.post(notification: .announcement, argument: message) }
        }
    }

    func cancel() {
        task?.cancel()
        // Do not start another action until the cancelled service operation has
        // completed its cleanup and the task above clears the active operation.
        message = localized("正在取消")
    }

    /// The page is gone: whatever runs is cancelled, with nothing left to show.
    func cancelForDisappearance() {
        task?.cancel()
    }

    func clearMessage() {
        message = nil
    }
}
