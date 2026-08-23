import Foundation

/// Everything an interactive cookie login needs, independent of what kind of source asked for it.
///
/// The WebView login was written for book sources and reached into `BookSource` for three values.
/// Voice sources need exactly the same three — 纳米AI TTS declares `loginUrl: "https://bot.n.cn/"`
/// and its own 使用说明 tells the user that whether the app can open that page from the TTS screen
/// "由 App 运行时决定", which until now meant no, leaving 手动填 Cookie as the only route. Naming the
/// three values makes one login screen serve both instead of a second copy of it.
struct SourceWebLogin: Identifiable, Equatable {
    /// Shown in the sheet title.
    let name: String
    /// The page to open.
    let url: URL
    /// Key the captured cookie is filed under in `LoginManager` — the same key the source's
    /// requests read their login header back with.
    let storageKey: String

    var id: String { storageKey }
}

extension SourceWebLogin {

    /// A book source's web login. `loginUrl` may be a plain URL or a `@js:` expression with the
    /// page URL inside it; an absent or unusable one falls back to the site itself, which is
    /// where a sign-in link normally lives.
    init?(bookSource source: BookSource) {
        guard let url = Self.pageURL(
            loginUrl: source.loginUrl,
            fallback: source.bookSourceUrl
        ) else { return nil }
        self.init(
            name: source.bookSourceName.isEmpty ? localized("書源登入") : source.bookSourceName,
            url: url,
            storageKey: source.bookSourceUrl
        )
    }

    /// A voice source's web login.
    ///
    /// Plain http(s) only, and no fallback: a voice source's `url` is a synthesis endpoint, not a
    /// site to browse, and a `@js:` `loginUrl` is a login *procedure* — `TTSSourceLoginView` runs
    /// it, so opening a URL scraped out of it would run the login twice by two different routes.
    /// Returning nil is what hides the entry for sources that have no web login.
    init?(ttsSource source: ImportedTTSSource) {
        guard let raw = source.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              !raw.hasPrefix("@"),
              !raw.hasPrefix("{"),
              !raw.hasPrefix("<"),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        self.init(name: source.name, url: url, storageKey: source.id)
    }

    /// Legado's `loginUrl` shapes, in the order the book-source login has always resolved them.
    private static func pageURL(loginUrl: String, fallback: String) -> URL? {
        let raw = loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Plain URL: `https://www.qidian.com/sign/`
        if !raw.isEmpty, !raw.hasPrefix("@"), !raw.hasPrefix("{"), let url = URL(string: raw) {
            return url
        }

        // 2. `@js:` expression — take the first http(s) URL written inside it.
        if raw.lowercased().hasPrefix("@js:") {
            let js = raw.dropFirst(4)
            if let range = js.range(of: #"https?://[^"'\s)>]+"#, options: .regularExpression),
               let url = URL(string: String(js[range])) {
                return url
            }
        }

        // 3. The site itself.
        return URL(string: fallback)
    }
}
