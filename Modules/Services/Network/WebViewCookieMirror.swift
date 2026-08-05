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

    /// Cookies for `host` after forcing a fresh jar read.
    ///
    /// For the Cloudflare path only: the challenge WebView has just written the
    /// clearance cookie and the retry must send exactly that value, so it cannot race
    /// the observer callback that would otherwise refresh the mirror.
    func refreshedCookies(for host: String) async -> [HTTPCookie] {
        await refresh()
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
        lock.lock()
        if isPrimed {
            lock.unlock()
            return
        }
        if let existing = primingTask {
            lock.unlock()
            await existing.value
            return
        }
        let task = Task { [weak self] in
            await self?.observer.install()
            await self?.refresh()
        }
        primingTask = task
        lock.unlock()
        await task.value
    }

    /// Re-reads the whole jar. Called once at prime time and thereafter only when
    /// WebKit signals that a cookie changed.
    fileprivate func refresh() async {
        let cookies = await Self.readJar()
        lock.lock()
        snapshot = cookies
        isPrimed = true
        primingTask = nil
        lock.unlock()
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

/// Bridges `WKHTTPCookieStoreObserver` (an `@objc` protocol that must be registered
/// and called on the main thread) back to the mirror.
private final class CookieStoreObserver: NSObject, WKHTTPCookieStoreObserver, @unchecked Sendable {
    private var isInstalled = false

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
