import Foundation
import WebKit

/// Thread-safe mirror of the WKWebView cookie jar.
///
/// Every outgoing book-source request needs the browser's cookies: a source the user
/// logged into through the in-app browser keeps its session in the WebView jar, not in
/// `HTTPCookieStorage`. `WebFetcher.buildRequest` used to obtain them by calling
/// `WKHTTPCookieStore.getAllCookies` **per request** — a main-thread WebKit IPC round
/// trip that returns the ENTIRE jar and is then filtered down to one host. A 100-source
/// search therefore queued 100+ main-thread hops ahead of its own network traffic,
/// competing with SwiftUI's list rendering the whole way.
///
/// The jar only changes when a WKWebView writes a cookie, and WebKit reports exactly
/// that via `WKHTTPCookieStoreObserver`. So this mirrors it: one fetch to prime, then
/// refreshes driven by the real change signal — no polling, no TTL. Reads are a plain
/// lock-protected array scan callable from any thread.
final class WebViewCookieMirror: @unchecked Sendable {
    static let shared = WebViewCookieMirror()

    private let lock = NSLock()
    private var snapshot: [HTTPCookie] = []
    private var isPrimed = false
    /// De-dupes the cold-launch stampede: 8 concurrent source searches must not each
    /// launch their own `getAllCookies`.
    private var primingTask: Task<Void, Never>?

    private let observer = CookieStoreObserver()

    private init() {}

    // MARK: - Reads

    /// Cookies whose domain matches `host`, priming the mirror on first use.
    func cookies(for host: String) async -> [HTTPCookie] {
        if let mirrored = mirroredCookies(for: host) { return mirrored }
        await primeIfNeeded()
        return mirroredCookies(for: host) ?? []
    }

    /// Mirror lookup. `nil` means "not primed yet" — distinct from "primed, and this
    /// host has no cookies", so a cold-launch caller knows to prime instead of
    /// silently sending no Cookie header (which turns an authenticated source into
    /// an HTTP 401).
    private func mirroredCookies(for host: String) -> [HTTPCookie]? {
        lock.lock()
        defer { lock.unlock() }
        guard isPrimed else { return nil }
        return snapshot.filter { $0.domain.contains(host) }
    }

    // MARK: - Priming / refresh

    /// Installs the change observer and takes the first snapshot. Safe to call more
    /// than once; only the first call does work.
    func start() {
        Task { await primeIfNeeded() }
    }

    private func primeIfNeeded() async {
        // Decide under the lock, await outside it. `NSLock.lock()` is `noasync`
        // precisely because holding it across a suspension is a deadlock waiting
        // to happen; `withLock` makes the critical section un-suspendable.
        let pending: Task<Void, Never>? = lock.withLock {
            if isPrimed { return nil }
            if let existing = primingTask { return existing }
            let task = Task { [weak self] in
                await self?.observer.install()
                await self?.refresh()
            }
            primingTask = task
            return task
        }
        await pending?.value
    }

    /// Re-reads the whole jar. Called once at prime time and thereafter only when
    /// WebKit signals that a cookie changed.
    fileprivate func refresh() async {
        let cookies = await Self.readJar()
        lock.withLock {
            snapshot = cookies
            isPrimed = true
            primingTask = nil
        }
    }

    @MainActor
    private static func readJar() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}

extension WebViewCookieMirror {
    /// legado-E `CookieStore.setWebCookie(url, cookie)`: each `name=value` of a cookie header
    /// goes into the in-app browser's jar for the URL's host, as Android's
    /// `CookieManager.setCookie(baseUrl, it)` does. Android also drops every session cookie
    /// of its WebView first; that is not copied, because here the browser jar also feeds the
    /// sources' own requests (this mirror), so it would sign other sources out.
    static func setBrowserCookies(url: String, cookie: String) {
        guard let host = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.host,
              !host.isEmpty else {
            AppLogger.parse("setWebCookie: no host", context: ["url": String(url.prefix(200))])
            return
        }
        let cookies: [HTTPCookie] = cookie.split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            let name = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !name.isEmpty else { return nil }
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            return HTTPCookie(properties: [
                .domain: host, .path: "/", .name: name, .value: value,
            ])
        }
        guard !cookies.isEmpty else { return }
        Task { @MainActor in
            let store = WKWebsiteDataStore.default().httpCookieStore
            for cookie in cookies { await store.setCookie(cookie) }
        }
    }
}

/// Bridges `WKHTTPCookieStoreObserver` (an `@objc` protocol that must be registered
/// and called on the main thread) back to the mirror.
private final class CookieStoreObserver: NSObject, WKHTTPCookieStoreObserver, @unchecked Sendable {
    private var isInstalled = false

    /// `WebViewCookieMirror.shared` creates this from whichever thread reads it first.
    nonisolated override init() {
        super.init()
    }

    @MainActor
    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        WKWebsiteDataStore.default().httpCookieStore.add(self)
    }

    // Deliberately does not touch the non-Sendable `cookieStore` parameter: the
    // refresh re-reads `WKWebsiteDataStore.default()` on the main actor instead.
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { await WebViewCookieMirror.shared.refresh() }
    }
}
