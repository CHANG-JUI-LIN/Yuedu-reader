import SwiftUI

// MARK: - BookSourceImportReviewSheet

/// The book-source import confirmation list, assembled once. Every route that reviews an
/// import presents this: 書源管理's own importers, the `yuedu://import/…` deep link, and a
/// pack shared in from another app.
struct BookSourceImportReviewSheet: View {
    @ObservedObject var coordinator: BookSourceImportCoordinator
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        if let pending = coordinator.pending {
            SourceImportConfirmList(
                title: localized("匯入來源配置"),
                plan: pending.plan,
                existingClock: { coordinator.existingClock(for: $0) },
                showsComments: $coordinator.showsComments,
                confirmTitle: localized("匯入"),
                extraOptions: {
                    BookSourceImportOptionsSection(
                        options: $coordinator.options,
                        groupCandidates: BookSourceStore.shared.groupCounts().map {
                            BookSourceGroupCandidate(name: $0.name, count: $0.count)
                        }
                    )
                },
                onConfirm: onConfirm,
                onCancel: onCancel
            )
        }
    }
}

// MARK: - BookSourceImportReviewHost

/// A self-contained review sheet for callers that have no coordinator of their own — a pack
/// shared in from another app, or the in-page WebView importer, which presents from UIKit.
///
/// Owns the coordinator so the sheet's lifetime owns the pending plan; the routes above are
/// one-shot, unlike 書源管理, which keeps its coordinator across several importers.
struct BookSourceImportReviewHost: View {
    let sources: [BookSource]
    /// Called with the number of sources written once the user confirms.
    let onFinish: (Int) -> Void
    let onCancel: () -> Void

    @StateObject private var coordinator = BookSourceImportCoordinator()
    @State private var failureMessage: String?

    var body: some View {
        BookSourceImportReviewSheet(
            coordinator: coordinator,
            onConfirm: commit,
            onCancel: onCancel
        )
        .onAppear {
            // `present` here rather than in an initialiser: `@StateObject` is only valid once
            // the view is installed.
            if coordinator.pending == nil {
                coordinator.present(sources: sources)
            }
        }
        .alert(
            localized("操作失敗"),
            isPresented: Binding(
                get: { failureMessage != nil },
                set: { if !$0 { failureMessage = nil } }
            ),
            presenting: failureMessage
        ) { _ in
            Button(localized("確定"), role: .cancel) { failureMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private func commit() {
        do {
            onFinish(try coordinator.confirmImport())
        } catch {
            failureMessage = error.localizedDescription
        }
    }
}
