import Foundation

/// Whether a failing book source is one the reader can repair by turning on
/// 提供裝置識別碼, so the failure surfaces can offer it as a button.
///
/// `java.androidId()` answers by default (see `BookSource.presentsAndroidIdentity`
/// for why the default is ON and what the escape hatch is for), so this only ever
/// applies to a source the user deliberately turned OFF and then hit a backend that
/// refuses the request without a device id — 知秋番茄's `x-android-id`, 企点's
/// `&device=`. The switch lives in 書源編輯 → 基本, where a reader who just hit the
/// error will never look, so the failure surfaces offer it back.
///
/// Raising a JS exception instead of answering empty was tried and reverted: it is a
/// per-call-site decision (does *this* call sit inside a `try`?) that the bridge can
/// only ever answer per-source, so one guarded call anywhere would licence throwing
/// into a bare one — and a bare `java.androidId()` inside a `<js>` searchUrl aborts
/// the whole script. Do not reintroduce it.
///
/// Nothing here flips anything by itself — answering "yes" only earns the offer; the
/// user still taps.
enum AndroidIdentityRecovery {

    /// Whether 提供裝置識別碼 is worth offering for `source` right now.
    ///
    /// All three conditions must hold, and each rules out a different way the offer
    /// would be wrong:
    ///
    /// 1. the source has not opted in — otherwise there is nothing to turn on;
    /// 2. the source's own rules mention `androidId` — a source that never asks for
    ///    a device id cannot be fixed by handing it one;
    /// 3. the failure names a device identifier — this is what separates 知秋's
    ///    「缺少设备信息」 from 书山聚合, which calls `androidId()` too but only as a
    ///    platform probe, and is *broken* rather than fixed by answering it.
    ///
    /// `failureMessage` is whatever the failing surface is already showing (the
    /// reader's chapter failure reason); the source's last recorded API failure is
    /// consulted as well, because paths that fail before a chapter exists — 發現頁,
    /// 詳情頁 — have no message of their own.
    static func canRepair(_ source: BookSource, failureMessage: String? = nil) -> Bool {
        guard !source.presentsAndroidIdentity else { return false }
        let recorded = SourceAPIErrorLog.shared.last(for: source.bookSourceUrl)?.message
        let reported = [failureMessage, recorded].compactMap { $0 }
        guard reported.contains(where: namesDeviceIdentifier) else { return false }
        return requestsAndroidId(source)
    }

    /// Turns the opt-in on and persists it. Returns the updated source.
    ///
    /// Nothing else needs invalidating: `BookSourceStore.update` advances
    /// `lastUpdateTime` whenever the content actually changed, and
    /// `BookSourceSession`'s cache key carries that clock — so the next parse builds
    /// a fresh bridge, whose `androidId()` now answers. Callers are still
    /// responsible for discarding any cached *result* the refused request produced.
    @discardableResult
    static func enable(_ source: BookSource) -> BookSource {
        var updated = source
        updated.presentsAndroidIdentity = true
        BookSourceStore.shared.update(updated)
        // The recorded failure describes a request made under the old answer. Leaving
        // it would keep `canRepair` true — and the offer on screen — until the retry's
        // own reply overwrites it.
        SourceAPIErrorLog.shared.clear(for: source.bookSourceUrl)
        AppLogger.parse("⟐ android identity enabled from failure surface", context: [
            "source": source.bookSourceName,
            "url": source.bookSourceUrl,
        ])
        return updated
    }

    /// The book source a book is currently reading through, if it still exists.
    static func source(withId id: UUID?) -> BookSource? {
        guard let id else { return nil }
        return BookSourceStore.shared.sources.first { $0.id == id }
    }

    // MARK: - Does this source ask for a device id at all?

    /// `androidId` appears in the source's rules — either as the `java.androidId()`
    /// call or as the key the source caches it under (知秋番茄 does
    /// `source.put('androidId', …)`). The whole encoded source is searched because
    /// the call can live in any of a dozen rule fields, `jsLib`, or `header`.
    ///
    /// Only the boolean is cached — a source's JSON runs to hundreds of kilobytes,
    /// so keeping the text would cost megabytes for no gain.
    private static func requestsAndroidId(_ source: BookSource) -> Bool {
        let key = "\(source.bookSourceUrl)#\(source.lastUpdateTime)"
        if let cached = cacheLock.withLock({ requestsCache[key] }) { return cached }
        let encoded = (try? JSONEncoder().encode(source)) ?? Data()
        let answer = String(decoding: encoded, as: UTF8.self)
            .range(of: "androidid", options: .caseInsensitive) != nil
        cacheLock.withLock {
            // Bounded: one entry per (source, edit), and only sources the user is
            // actually parsing ever get asked about.
            if requestsCache.count >= 64 { requestsCache.removeAll() }
            requestsCache[key] = answer
        }
        return answer
    }

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var requestsCache: [String: Bool] = [:]

    // MARK: - Condition 3: is the failure about a device identifier?

    /// Phrases a source's backend uses when the device id it wanted arrived empty.
    ///
    /// Guards the real case reported on 2026-08-15: with the opt-in off, sources in
    /// 知秋's family answer 「缺少设备信息」 and the reader has no way to connect that
    /// sentence to a toggle three screens away. Matching the device *noun* alone is
    /// deliberate — 「设备信息错误」 and 「设备标识为空」 mean the same thing — and is
    /// specific enough only because conditions 1 and 2 already narrowed this to
    /// sources that ask for a device id and were given none. Delete this list if
    /// `androidId()` ever gains a way to answer "iOS, and here is my id", because
    /// then no source needs the toggle.
    private static let deviceIdentifierPhrases = [
        "设备信息", "設備信息", "装置信息", "裝置資訊",
        "设备标识", "設備標識", "装置识别", "裝置識別",
        "设备id", "設備id", "设备码", "設備碼", "装置码", "裝置碼",
        "androidid", "android_id", "android id",
        "deviceid", "device_id", "device id", "device info",
    ]

    private static func namesDeviceIdentifier(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return deviceIdentifierPhrases.contains { normalized.contains($0) }
    }
}
