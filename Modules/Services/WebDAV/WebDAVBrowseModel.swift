import Combine
import Foundation

/// One WebDAV folder's listing: the request, its result and its error, owned outside the
/// view as `OPDSBrowseModel` owns an OPDS feed's. `WebDAVDirectoryView` only draws it.
@MainActor
final class WebDAVBrowseModel: ObservableObject {
    let route: WebDAVDirectoryRoute
    @Published private(set) var entries: [WebDAVBrowseClient.Entry] = []
    /// Starts true, so the folder shows its spinner until the first listing answers.
    @Published private(set) var isLoading = true
    @Published private(set) var didLoad = false
    @Published private(set) var loadError: String?
    private var requestID = UUID()
    private let listOverride: ((URL) async throws -> [WebDAVBrowseClient.Entry])?

    /// - Parameter list: replaces the server request, for tests and previews.
    init(route: WebDAVDirectoryRoute, list: ((URL) async throws -> [WebDAVBrowseClient.Entry])? = nil) {
        self.route = route
        listOverride = list
    }

    func load() async {
        let id = UUID()
        requestID = id
        isLoading = true
        loadError = nil
        do {
            let result: [WebDAVBrowseClient.Entry]
            if let listOverride {
                result = try await listOverride(route.url)
            } else {
                let store = RemoteLibraryConnectionStore.shared
                guard let connection = store.connection(id: route.connectionID) else {
                    loadError = localized("書庫連線已移除，請重新加入伺服器。")
                    isLoading = false
                    return
                }
                result = try await store.webDAVClient(for: connection).list(route.url)
            }
            try Task.checkCancellation()
            // A later load (pull to refresh, a library change) owns the folder now.
            guard requestID == id else { return }
            entries = result
            didLoad = true
        } catch {
            // A cancelled load leaves the folder as it was, spinner included, for the next
            // load to settle.
            guard !Task.isCancelled, requestID == id else { return }
            AppLogger.network("WebDAV listing failed (\(route.url.host ?? ""))", error: error)
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
