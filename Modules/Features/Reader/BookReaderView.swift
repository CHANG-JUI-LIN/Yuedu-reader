import SwiftUI

// The single reader entry point prepares remote resources before choosing the
// existing format-specific reader. Shelf membership never determines readability.
struct BookReaderView: View {
    let bookId: UUID
    @EnvironmentObject var store: BookStore
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.readerNavigator) private var readerNavigator
    @Environment(\.dismiss) private var dismiss
    @State private var resourceOwnerID = UUID()
    @State private var remoteReady = false
    @State private var remoteError: String?
    @State private var retryGeneration = 0
    @State private var holdsCache = false
    @State private var resourceFailureAlert = RemoteReaderFailureAlertState()

    private var book: ReadingBook? { store.readingBook(id: bookId) }

    var body: some View {
        Group {
            if book?.remoteSource != nil && !remoteReady {
                RemoteReaderOpeningView(
                    error: remoteError,
                    onRetry: { retryGeneration += 1 },
                    onClose: closeReader
                )
            } else if isAudiobook {
                AudiobookReaderView(bookId: bookId)
            } else if shouldUseFixedPageReader {
                FixedPageReaderView(bookId: bookId)
            } else {
                ReaderView(bookId: bookId)
            }
        }
        .onReceive(dependencies.remoteLibrary.failurePublisher) { failure in
            resourceFailureAlert.receive(failure, bookID: bookId, isReady: remoteReady)
        }
        .alert(
            localized("遠端內容載入失敗"),
            isPresented: Binding(
                get: { resourceFailureAlert.failure != nil },
                set: { if !$0 { resourceFailureAlert.dismiss() } }
            ),
            presenting: resourceFailureAlert.failure
        ) { _ in
            Button(localized("關閉")) { closeReader() }
            Button(localized("取消"), role: .cancel) { resourceFailureAlert.dismiss() }
        } message: { failure in
            Text(failure.message)
        }
        .task(id: retryGeneration) {
            guard book?.remoteSource != nil else { return }
            if !holdsCache {
                RemoteLibraryCache.shared.retain(bookId)
                holdsCache = true
            }
            remoteError = nil
            do {
                _ = try await dependencies.remoteLibrary.prepare(bookID: bookId, store: store)
                try Task.checkCancellation()
                remoteReady = true
            } catch is CancellationError {
                // Navigation cancellation leaves the persisted reading position intact.
            } catch {
                remoteError = error.localizedDescription
            }
        }
        .onAppear {
            ReadingResourceUsage.shared.retain(bookID: bookId, ownerID: resourceOwnerID)
            if let book {
                CrashContext.setKey("current_book", "\(book.title) [\(book.id.uuidString.prefix(8))]")
                CrashContext.setKey("current_book_kind", "\(book.resolvedPipelineKind)")
                CrashContext.setKey("current_book_online", book.isOnline)
                CrashContext.breadcrumb("open reader: \(book.title) (\(book.resolvedPipelineKind))")
                if book.lastOpenedDate == nil, readerNavigator == nil {
                    store.updateLastOpened(bookId: bookId)
                }
            }
        }
        .onDisappear {
            let releasedLastReader = ReadingResourceUsage.shared.release(bookID: bookId, ownerID: resourceOwnerID)
            if holdsCache {
                RemoteLibraryCache.shared.release(bookId)
                if releasedLastReader { dependencies.remoteLibrary.release(bookID: bookId) }
                holdsCache = false
                remoteReady = false
            }
            CrashContext.breadcrumb("close reader")
        }
    }

    private func closeReader() {
        if let readerNavigator {
            readerNavigator.close()
        } else {
            // Pushed library readers and modal readers use their owning SwiftUI
            // presentation. Closing also cancels the view's preparation task.
            dismiss()
        }
    }

    private var shouldUseFixedPageReader: Bool {
        guard let kind = book?.resolvedPipelineKind else { return false }
        return kind == .manga || kind == .fixedPage
    }

    private var isAudiobook: Bool { book?.resolvedPipelineKind == .audio }
}

/// Preparation happens before the format reader installs its toolbar. These
/// actions stay visible even when the caller hides the navigation back button.
private struct RemoteReaderOpeningView: View {
    let error: String?
    var onRetry: () -> Void
    var onClose: () -> Void

    var body: some View {
        if let error {
            ContentUnavailableView {
                Label(localized("無法開啟書籍"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(localized("重試"), action: onRetry)
                Button(localized("關閉"), action: onClose)
            }
        } else {
            VStack(spacing: DSSpacing.lg) {
                ProgressView(localized("正在開啟書籍"))
                Button(localized("取消"), action: onClose)
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DSSpacing.lg)
        }
    }
}

#Preview("Remote reader loading") {
    RemoteReaderOpeningView(error: nil, onRetry: {}, onClose: {})
}

#Preview("Remote reader error") {
    RemoteReaderOpeningView(error: localized("認證失敗，請確認帳號和密碼"), onRetry: {}, onClose: {})
}
