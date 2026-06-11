import Foundation

/// Persistent, domain-keyed cookie store for Legado book source JS bridge.
///
/// Cookies set by `cookie.set(url, value)` are written to both
/// `HTTPCookieStorage` (for native HTTP requests) and a JSON file on disk
/// (so they survive app restarts).  On first access the persisted cookies
/// are replayed into `HTTPCookieStorage`.
///
/// Usage:
/// ```swift
/// let value = CookieStore.shared.get(url: "https://example.com")
/// CookieStore.shared.set(url: "https://example.com", cookie: "session=abc")
/// CookieStore.shared.remove(url: "https://example.com")
/// ```
final class CookieStore {

    static let shared = CookieStore()

    // MARK: - Storage

    /// Domain → raw cookie string (persistent snapshot).
    private var store: [String: String] = [:]
    private let lock = NSLock()
    private let fileURL: URL

    // MARK: - Init

    private init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        fileURL = dir.appendingPathComponent("legado_cookies.json")
        load()
        replayIntoHTTPCookieStorage()
    }

    // MARK: - Public API

    /// Returns a `name=value; name2=value2` cookie string for the given URL.
    /// Queries `HTTPCookieStorage` first (picks up cookies set by HTTP responses),
    /// then falls back to the persistent store if the session storage is empty.
    func get(url: String) -> String {
        // HTTPCookieStorage (session / system managed)
        if let cookieURL = URL(string: url),
           let cookies = HTTPCookieStorage.shared.cookies(for: cookieURL),
           !cookies.isEmpty {
            return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        // Persistent fallback
        let domain = canonicalDomain(for: url)
        lock.lock()
        let persisted = store[domain] ?? ""
        lock.unlock()
        return persisted
    }

    /// Stores `cookie` for the host of `url`.
    /// Writes to both `HTTPCookieStorage` and the persistent file.
    func set(url: String, cookie: String) {
        guard !cookie.isEmpty, let cookieURL = URL(string: url) else { return }

        // Write to HTTPCookieStorage
        let parsed = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": cookie], for: cookieURL)
        if parsed.isEmpty {
            makeCookies(cookie, for: cookieURL).forEach {
                HTTPCookieStorage.shared.setCookie($0)
            }
        } else {
            parsed.forEach { HTTPCookieStorage.shared.setCookie($0) }
        }

        // Persist: merge with existing value for this domain
        let domain = canonicalDomain(for: url)
        lock.lock()
        store[domain] = merge(existing: store[domain], incoming: cookie)
        lock.unlock()
        save()
    }

    /// Returns the value of a single cookie named `key` for the host of `url`.
    /// Mirrors Legado's `cookie.getKey(tag, key)`. `url` may be a bare domain
    /// (e.g. `"fanqienovel.com"`) or a full URL; a missing scheme is treated as https.
    /// Returns the whole cookie string when `key` is empty, or "" when not found.
    func getKey(url: String, key: String) -> String {
        let cookieStr = get(url: Self.normalizedURLString(url))
        guard !key.isEmpty else { return cookieStr }
        for segment in cookieStr.components(separatedBy: ";") {
            let parts = segment.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, parts[0] == key { return parts[1] }
        }
        return ""
    }

    /// Normalize a cookie "tag" to a URL string: bare domains gain an https scheme
    /// so `URL(string:)` exposes a `host` for `HTTPCookieStorage` lookups.
    static func normalizedURLString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        return trimmed.contains("://") ? trimmed : "https://" + trimmed
    }

    /// Removes all cookies for the host of `url`.
    func remove(url: String) {
        if let cookieURL = URL(string: url),
           let cookies = HTTPCookieStorage.shared.cookies(for: cookieURL) {
            cookies.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        }
        let domain = canonicalDomain(for: url)
        lock.lock()
        store.removeValue(forKey: domain)
        lock.unlock()
        save()
    }

    /// Wipes all persisted cookies and clears HTTPCookieStorage.
    func clearAll() {
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        lock.lock()
        store.removeAll()
        lock.unlock()
        save()
    }

    // MARK: - Private: Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        store = decoded
    }

    private func save() {
        lock.lock()
        let snapshot = store
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Replay persisted cookies into HTTPCookieStorage on startup.
    private func replayIntoHTTPCookieStorage() {
        for (domain, cookieStr) in store {
            let baseURL = URL(string: "https://\(domain)") ?? URL(string: "https://example.com")!
            makeCookies(cookieStr, for: baseURL).forEach {
                HTTPCookieStorage.shared.setCookie($0)
            }
        }
    }

    // MARK: - Private: Helpers

    private func canonicalDomain(for urlString: String) -> String {
        URL(string: urlString)?.host ?? urlString
    }

    /// Parse a `name=value; name2=value2` string into HTTPCookie objects.
    private func makeCookies(_ raw: String, for url: URL) -> [HTTPCookie] {
        guard let host = url.host else { return [] }
        return raw.components(separatedBy: ";").compactMap { segment in
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return HTTPCookie(properties: [
                .name: parts[0].trimmingCharacters(in: .whitespaces),
                .value: parts[1].trimmingCharacters(in: .whitespaces),
                .domain: host,
                .path: "/"
            ])
        }
    }

    /// Merge incoming `name=value` pairs into an existing cookie string.
    /// Incoming values overwrite existing ones with the same name.
    private func merge(existing: String?, incoming: String) -> String {
        var dict: [String: String] = [:]
        // Parse existing
        for segment in (existing ?? "").components(separatedBy: ";") {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[0].isEmpty {
                dict[parts[0].trimmingCharacters(in: .whitespaces)] =
                    parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        // Overwrite with incoming
        for segment in incoming.components(separatedBy: ";") {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[0].isEmpty {
                dict[parts[0].trimmingCharacters(in: .whitespaces)] =
                    parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return dict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }
}
