import Foundation

/// An absolute http(s) URL with a host — the only kind `SFSafariViewController`
/// accepts. Its initializer throws `NSInvalidArgumentException` for any other scheme
/// (Crashlytics c43ca927, 2.0.7), so `SafariView` takes this type instead of `URL`:
/// a link that has not been through `RSSLinkRoute` cannot reach it.
struct InAppWebURL: Hashable, Identifiable, Sendable {
    let url: URL

    var id: String { url.absoluteString }

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        // "HTTPS://…" is a web URL too; hand Safari the canonical lowercase scheme
        // rather than rely on its scheme check being case-insensitive.
        if url.scheme == scheme {
            self.url = url
        } else {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
            components.scheme = scheme
            guard let lowered = components.url else { return nil }
            self.url = lowered
        }
    }
}

/// Where a link from feed or source data opens. Article links, homepages, and links
/// tapped inside an article all pass through `route(_:relativeTo:)`, so relative-path
/// resolution and scheme handling live in one place.
enum RSSLinkRoute: Hashable, Sendable {
    /// http(s): the in-app Safari sheet.
    case inApp(InAppWebURL)
    /// Any other scheme an app may own — `mailto:`, `tel:`, `itms-apps:`, and our own
    /// `legado://` / `yuedu://`, which come back through the app's `.onOpenURL`.
    case system(URL)
    /// Nothing can open it: script/inline/local schemes, a relative path with no web
    /// base, or text that is not a URL. Callers hide the action (maintainer, 2026-10-20).
    case unopenable

    /// The URL to open or share, or `nil` when the link is unopenable.
    var url: URL? {
        switch self {
        case .inApp(let webURL): return webURL.url
        case .system(let url): return url
        case .unopenable: return nil
        }
    }

    /// Schemes that run or embed content instead of naming a destination.
    private static let unopenableSchemes: Set<String> = [
        "javascript", "vbscript", "data", "about", "blob", "file"
    ]

    /// Routes a stored link string. A relative link resolves against `base` — feeds
    /// write `/2026/10/post.html`, and articles stored before their parser resolved such
    /// links keep the relative text, so this covers persisted data too.
    static func route(_ raw: String, relativeTo base: URL?) -> RSSLinkRoute {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unopenable }
        let cleaned = RSSSource.strippingLegadoURLOptions(trimmed)

        if let absolute = URL(string: cleaned), absolute.scheme != nil {
            return route(absolute)
        }
        guard let base, InAppWebURL(base) != nil,
              let resolved = URL(string: cleaned, relativeTo: base)?.absoluteURL else {
            return .unopenable
        }
        return route(resolved)
    }

    /// A `.system` link no installed app accepted — logged so a device report shows
    /// which scheme a feed or source handed us.
    static func logUnhandled(_ url: URL) {
        AppLogger.info("RSS link has no app to open it", context: ["scheme": url.scheme ?? ""], level: .warning)
    }

    /// Routes an already absolute URL (e.g. one a web view resolved).
    static func route(_ url: URL) -> RSSLinkRoute {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return .unopenable }
        if scheme == "http" || scheme == "https" {
            return InAppWebURL(url).map(RSSLinkRoute.inApp) ?? .unopenable
        }
        return unopenableSchemes.contains(scheme) ? .unopenable : .system(url)
    }
}

extension RSSSource {
    /// Base for this source's relative article links: the site homepage when known,
    /// otherwise the feed's own URL — the same bases the feed parsers resolve against.
    var articleLinkBaseURL: URL? {
        if let homepageURL, let url = URL(string: homepageURL), InAppWebURL(url) != nil {
            return url
        }
        return RSSRequestFactory.requestURL(for: self)
    }

    /// Where 開啟首頁 goes; `nil` when the source has no homepage.
    var homepageLinkRoute: RSSLinkRoute? {
        guard let homepageURL,
              !homepageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return RSSLinkRoute.route(homepageURL, relativeTo: RSSRequestFactory.requestURL(for: self))
    }
}
