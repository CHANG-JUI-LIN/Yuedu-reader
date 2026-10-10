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
// Same store path as every other importer, through `BookSourceImportCoordinator`:
// parse, review, then write the selected rows. There is no second cache/loader/decoder
// for this concern.
@MainActor
final class BookSourceDeepLinkHandler: ObservableObject {
    enum Phase: Equatable {
        case idle
        case confirming(sourceURL: URL)
        /// Downloading and parsing. Nothing is written in this phase.
        case importing
        /// The parsed pack is on screen in the confirmation list, awaiting the user's picks.
        /// The plan itself lives on `coordinator`; a phase has to stay `Equatable`.
        case reviewing
        case succeeded(count: Int)
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Holds the confirmation list and its import options. A deep link can arrive while
    /// 書源管理 is nowhere on screen, so this route owns its own coordinator rather than
    /// reaching for that screen's.
    let coordinator = BookSourceImportCoordinator()

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
        switch phase {
        case .confirming:
            phase = .idle
        case .reviewing:
            coordinator.cancel()
            phase = .idle
        default:
            return
        }
    }

    /// Writes the rows ticked in the confirmation list.
    func commitReview() {
        guard case .reviewing = phase else { return }
        do {
            phase = .succeeded(count: try coordinator.confirmImport())
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }

    /// Dismiss the result state and close the sheet.
    func finish() {
        phase = .idle
    }

    private func performImport(from sourceURL: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: sourceURL)
            guard !data.isEmpty else {
                phase = .failed(message: localized("無法讀取來源配置資料"))
                return
            }
            let ext = sourceURL.pathExtension.isEmpty ? "json" : sourceURL.pathExtension
            // Parse only. The user picks what to keep in the confirmation list, so a link
            // can no longer overwrite sources without showing what it contains.
            let sources = try BookSourceStore.shared.parseForImport(data: data, fileExtension: ext)
            coordinator.present(sources: sources)
            phase = .reviewing
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }
}