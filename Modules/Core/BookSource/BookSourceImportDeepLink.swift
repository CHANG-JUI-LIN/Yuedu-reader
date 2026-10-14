import Foundation

// MARK: - BookSourceImportDeepLink

// Pure parser for book-source import deep links. Shared by the in-app WebView
// interceptor (`JsBridgeBrowserView`) and the system-level URL handler wired in
// `yuedu_appApp.onOpenURL`, so there is exactly one implementation path for
// importing book sources from a deep link.
//
// Supported shapes (the `src` / `url` query item holds the real source URL):
//   yuedu://booksource/importOnline?src=URL   – legacy self-hosted shape
//   yuedu://import/{auto,bookSource,…}?src=URL – Legado-style shape on the
//                                                `yuedu` scheme (the form most
//                                                shared update pages emit today)
//   legado://import/{auto,bookSource,…}?src=URL – Legado's own scheme
//   yuedu://module?src=URL                      – a module (Phase 6e-2); any path
//                                                under `module` is accepted
enum BookSourceImportDeepLink {
    /// What a link imports.
    enum Target: Equatable {
        case sources(URL)
        case module(URL)
    }

    /// What `url` imports and from where, or `nil` when `url` is not one of the supported
    /// import deep-link shapes.
    static func target(from url: URL) -> Target? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        let host = url.host?.lowercased()
        let path = url.path.lowercased()

        // Legacy self-hosted deep link: yuedu://booksource/importOnline?src=URL
        let isLegacyYuedu = scheme == "yuedu"
            && host == "booksource"
            && path == "/importonline"
        // Legado-style deep link (either scheme): …://import/{auto,bookSource,
        // bookSourceUrl,…}?src=URL. Any path under `import` is accepted, matching
        // Legado's own host set (auto / bookSource / bookSourceUrl / rssSource / …).
        let isLegadoStyleImport =
            (scheme == "yuedu" || scheme == "legado") && host == "import"
        // Modules are this app's own: Legado has no such link.
        let isModule = scheme == "yuedu" && host == "module"

        guard isLegacyYuedu || isLegadoStyleImport || isModule,
              let address = linkedURL(in: url) else { return nil }
        return isModule ? .module(address) : .sources(address)
    }

    /// Returns the URL the user is actually importing book sources from, or
    /// `nil` when `url` is not a book-source import deep link.
    static func sourceURL(from url: URL) -> URL? {
        guard case .sources(let address) = target(from: url) else { return nil }
        return address
    }

    /// The `src` / `url` query item.
    private static func linkedURL(in url: URL) -> URL? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let sourceString = components.queryItems?.first(where: {
                let name = $0.name.lowercased()
                return name == "src" || name == "url"
            })?.value,
            !sourceString.isEmpty
        else { return nil }
        return URL(string: sourceString)
    }
}
