import Foundation
import Combine

// MARK: - BookSourceDeepLinkHandler

// State machine driving the system-level book-source import sheet. The App
// entry point calls `handle(url:)` from `.onOpenURL`; when the URL is a valid
// book-source import deep link, the handler flips to `.confirming` and the App
// presents `BookSourceImportConfirmSheet` bound to this handler. The user then
// confirms, the handler downloads and imports via the same `BookSourceStore`
// path the in-app WebView importer uses, and reports the result.
//
// Same path as WebView import: `BookSourceStore.shared.importFromData`. There
// is no second cache/loader for this concern.
@MainActor
final class BookSourceDeepLinkHandler: ObservableObject {
    enum Phase: Equatable {
        case idle
        case confirming(sourceURL: URL)
        case importing
        case succeeded(count: Int)
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Entry point from `.onOpenURL`. Non-import URLs are silently dropped.
    /// A new import URL replaces a finished (succeeded/failed) phase, but is
    /// ignored while an import is already in flight so we never cancel a
    /// download the user already confirmed.
    func handle(url: URL) {
        if case .importing = phase { return }
        guard let sourceURL = BookSourceImportDeepLink.sourceURL(from: url) else {
            return
        }
        phase = .confirming(sourceURL: sourceURL)
    }

    /// Called by the confirm sheet's primary button. Downloads `sourceURL`
    /// and imports via `BookSourceStore`, mirroring the WebView importer.
    func confirm() {
        guard case .confirming(let sourceURL) = phase else { return }
        phase = .importing
        Task { await performImport(from: sourceURL) }
    }

    func cancel() {
        guard case .confirming = phase else { return }
        phase = .idle
    }

    /// Dismiss the result state and close the sheet.
    func finish() {
        phase = .idle
    }

    private func performImport(from sourceURL: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: sourceURL)
            guard !data.isEmpty else {
                phase = .failed(message: localized("無法讀取書源資料"))
                return
            }
            let ext = sourceURL.pathExtension.isEmpty ? "json" : sourceURL.pathExtension
            let count = try BookSourceStore.shared.importFromData(data, fileExtension: ext)
            phase = .succeeded(count: count)
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }
}