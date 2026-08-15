import Foundation

/// What to do when a book source wants a device id this device cannot give it.
///
/// Two answers live here, one automatic and one offered:
///
/// - **`handlesMissingAndroidId`** — the source wrote its own recovery around the
///   call, so `LegadoJSBridge.androidId()` raises instead of answering empty and
///   the source's `deviceID()` branch takes over. Nothing to ask the user.
/// - **`canRepair`** — the source calls bare and its API refused the request, so
///   the failure surfaces offer 以 Android 身分回報 as a button.
///
/// `java.androidId()` hands back an empty string unless the source opted in via
/// `BookSource.presentsAndroidIdentity`, and that default is deliberate: most
/// sources call it to ask *which platform they are on* — 书山聚合's `deviceType()`
/// reads any non-empty answer as proof of Android — so answering everyone broke
/// its `X-Device-Type` header and every chapter with it. The minority that use the
/// value as a real device key (知秋番茄's `x-android-id`) therefore get nothing, and
/// their backend refuses the request. There is no third answer *in the return
/// value*: the API is named `androidId`, so "I am iOS, and here is my id" cannot be
/// expressed in it — which is why the sources that wrote a `catch` get told the
/// truth out-of-band, as an exception.
///
/// The toggle that resolves the rest per source lives in 書源編輯 → 基本, where a
/// reader who just hit the error will never look, so the failure surfaces offer it.
/// Nothing here flips it by itself — answering "yes" only earns the offer; the user
/// still taps.
enum AndroidIdentityRecovery {

    /// Whether 以 Android 身分回報 is worth offering for `source` right now.
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

    // MARK: - What the source's own JS says it wants

    /// Whether the source wrote its own recovery for a device id it cannot get.
    ///
    /// 晴天起点 (`🔅企点小说`) does exactly this in its request wrapper:
    ///
    /// ```js
    /// let device = '';
    /// try { device = java.androidId(); }
    /// catch { try { device = java.deviceID(); } catch {} }
    /// ```
    ///
    /// A source that writes this is telling us two things: it wants *a device id*,
    /// not proof of Android (`deviceID()` answers on Android too, so falling back to
    /// it settles nothing about the platform), and it can absorb a thrown error at
    /// that call site. `LegadoJSBridge.androidId()` therefore raises a JS exception
    /// for these sources instead of the empty string — see the note there for why
    /// empty is still the answer for everyone else.
    static func handlesMissingAndroidId(_ source: BookSource) -> Bool {
        shape(of: source).handlesMissing
    }

    /// `androidId` appears in the source's rules — either as the `java.androidId()`
    /// call or as the key the source caches it under (知秋番茄 does
    /// `source.put('androidId', …)`). The whole encoded source is searched because
    /// the call can live in any of a dozen rule fields, `jsLib`, or `header`.
    private static func requestsAndroidId(_ source: BookSource) -> Bool {
        shape(of: source).requestsId
    }

    private struct Shape {
        let requestsId: Bool
        let handlesMissing: Bool
    }

    /// Both answers come from one pass over the encoded source, and only the two
    /// booleans are kept — a source's JSON runs to hundreds of kilobytes, so caching
    /// the text itself would cost megabytes for no gain.
    private static func shape(of source: BookSource) -> Shape {
        let key = "\(source.bookSourceUrl)#\(source.lastUpdateTime)"
        if let cached = cacheLock.withLock({ shapeCache[key] }) { return cached }
        let encoded = (try? JSONEncoder().encode(source)) ?? Data()
        let text = String(decoding: encoded, as: UTF8.self)
        let shape = Shape(
            requestsId: text.range(of: "androidid", options: .caseInsensitive) != nil,
            handlesMissing: fallsBackToDeviceID(in: text)
        )
        cacheLock.withLock {
            // Bounded: one entry per (source, edit), and only sources the user is
            // actually parsing ever get asked about.
            if shapeCache.count >= 64 { shapeCache.removeAll() }
            shapeCache[key] = shape
        }
        return shape
    }

    /// A `catch` that reaches for `deviceID`, close behind an `androidId` call.
    ///
    /// The window is deliberately short: the two have to be part of the same
    /// recovery, not merely both present somewhere in a 250KB source. 晴天起点's
    /// span is under 100 characters even with the JSON escaping.
    private static func fallsBackToDeviceID(in text: String) -> Bool {
        let window = 400
        var searchFrom = text.startIndex
        while let call = text.range(
            of: "androidId", options: .caseInsensitive, range: searchFrom..<text.endIndex
        ) {
            let end = text.index(call.upperBound, offsetBy: window, limitedBy: text.endIndex)
                ?? text.endIndex
            if let rescue = text.range(of: "catch", range: call.upperBound..<end),
               text.range(of: "deviceID", options: .caseInsensitive,
                          range: rescue.upperBound..<end) != nil {
                return true
            }
            searchFrom = call.upperBound
        }
        return false
    }

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var shapeCache: [String: Shape] = [:]

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
