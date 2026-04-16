# Cloudflare Bypass Design

**Date:** 2026-04-16  
**Status:** Approved for implementation

## Problem

The app has an existing `CloudflareChallengeView` + `CloudflareChallengePresenter` + `WebFetcher` hook, but the integration is incomplete. Four gaps cause silent failures:

1. After CF challenge passes, `WebFetcher` returns the challenge-page HTML instead of retrying the original URL with the new cookies.
2. `cf_clearance` cookie is harvested from WKWebView into `HTTPCookieStorage` only — the JS bridge's `CookieStore.shared` is never updated.
3. CF detection only covers HTTP 503. Cloudflare can also return 403/429, or return HTTP 200 with challenge HTML.
4. `LegadoJSBridge.performRequest` (used by JS-based book sources) detects CF and silently returns `""` — the user never sees a challenge UI, and the JS script thinks the request failed.
5. `WebViewFetcher` (used for chapter content) doesn't detect CF at all; it may return challenge HTML as chapter content.

## Design

### Scope

Fix the four gaps above. Do **not** add a backend proxy, TLS fingerprint spoofing, or auto-bypass without user interaction. All CF challenges are handled by `CloudflareChallengePresenter` (the existing full-screen interactive WebView).

---

### Fix 1 — WebFetcher: Real Retry After Challenge

**File:** `WebFetcher.swift`

Current behaviour on 503: call challenge handler → return challenge HTML.  
New behaviour: call challenge handler → harvest cookies → **retry** `session.data(for: request)` with new cookies → return actual content.

Also expand detection:
- Handle 403 in addition to 503.
- After receiving any HTML response (even 200), check for CF body markers using `LegadoJSBridge.isCloudflareChallenged(_:response:)`.

```
fetchHTML(url:) flow:
  1. Send URLSession request
  2. If status ∈ {403, 503}: trigger challenge
  3. If status == 200 but body contains CF markers: trigger challenge
  4. After challenge: harvest WebView cookies → push to HTTPCookieStorage
  5. Retry URLSession request once with new cookies
  6. Return actual HTML
```

---

### Fix 2 — Cookie Sync: cf_clearance → CookieStore

**File:** `CloudflareChallengePresenter.swift`

After `CloudflareChallengePresenter.present()` receives `onChallengePassed`:
1. Harvest all cookies from the WKWebView's `httpCookieStore` (async callback).
2. Push each to `HTTPCookieStorage.shared`.
3. Group by domain → push to `CookieStore.shared.set(url:cookie:)`.
4. Then resolve the continuation (return HTML to caller).

This ensures the JS bridge (`java.cookie(url)`) returns valid cookies immediately after challenge.

---

### Fix 3 — LegadoJSBridge: Present Challenge on CF Detection

**File:** `LegadoJSBridge.swift`

Current: `isCloudflareChallenged` → return `""`.  
New: Add a `cloudflareChallengeHandler: ((URL) -> String)?` property to `LegadoJSBridge`. When CF is detected:
1. If handler is set: call it (blocks the JS background queue via `DispatchSemaphore`, handler presents UI on main thread, waits for completion).
2. Handler harvests cookies, then performs a fresh URLSession GET to the same URL.
3. Returns the actual HTML content.
4. If no handler: keep existing behaviour (return `""`).

Wire the handler in `JSCoreEngine` after instantiating the bridge, pointing it to `CloudflareChallengePresenter`.

---

### Fix 4 — WebViewFetcher: Detect CF in Chapter Fetch

**File:** `WebViewFetcher.swift`

`pollForContent` already returns the outer HTML after JS polling. After getting the HTML:
- Run `LegadoJSBridge.isCloudflareChallenged(html, response: nil)` (using a 200-agnostic variant that checks body only).
- If true: throw `FetchError.cloudflareChallengeRequired(url)` instead of returning CF HTML.

Callers (`OnlineReadingPipeline`, `ChapterFetcher`, etc.) catch this error and call `CloudflareChallengePresenter.present()` then retry.

---

### CF Body Detection (200-status)

Add a separate detection function that only checks body content (not status code), for use when status == 200:

```swift
static func isCloudflareChallengedBody(_ body: String) -> Bool {
    let markers = ["cf-browser-verification", "cf_chl_prog", "Just a moment",
                   "checking your browser", "_cf_chl_", "cf-challenge",
                   "DDoS-Guard", "ddos-guard"]
    let lower = body.lowercased()
    return markers.contains(where: { lower.contains($0.lowercased()) })
}
```

The existing `isCloudflareChallenged(_:response:)` requires a non-200 status code — keep it for WebFetcher's status-code path; use the body-only variant for WebViewFetcher and the 200 case in WebFetcher.

---

### InteractiveWebView: Cookie Sync + Faster Polling

**File:** `CloudflareChallengeView.swift`

- Reduce timer interval from 2.0s → 0.5s.
- Add additional check: look for `cf_clearance` cookie in the WKWebView's `httpCookieStore` (a reliable signal that CF has cleared).
- Keep the existing HTML content check as fallback.

---

### File Change Summary

| File | Change |
|------|--------|
| `WebFetcher.swift` | Add 403 + 200-body CF detection; retry after challenge |
| `CloudflareChallengePresenter.swift` | Sync cookies to CookieStore + HTTPCookieStorage before resolving |
| `LegadoJSBridge.swift` | Add `cloudflareChallengeHandler`; call it on CF detection |
| `JSCoreEngine.swift` | Wire handler on bridge instantiation |
| `WebViewFetcher.swift` | Detect CF HTML in `pollForContent`, throw typed error |
| `CloudflareChallengeView.swift` | Faster polling (0.5s), add cf_clearance cookie check |
| Callers of `WebViewFetcher` | Catch `cloudflareChallengeRequired`, present challenge, retry |

---

## Error Flow

```
User taps chapter → OnlineReadingPipeline.fetchChapter()
  → WebViewFetcher.fetchHTML() [if JS rendering needed]
    → pollForContent() returns CF HTML
    → throws FetchError.cloudflareChallengeRequired(url)
  → OnlineReadingPipeline catches error
    → CloudflareChallengePresenter.present(url)
    → Cookies harvested + synced
    → Retry fetchChapter()
    → Return content ✓
```

```
JS book source executes java.ajax(url)
  → LegadoJSBridge.performRequest()
    → URLSession returns 503/CF body
    → Call cloudflareChallengeHandler (blocks JS queue)
      → Present UI on main thread
      → User passes challenge
      → Harvest cookies
      → URLSession retry with new cookies
    → Return HTML to JS ✓
```

## Non-Goals

- Backend proxy (FlareSolverr)
- TLS fingerprint spoofing
- Automatic Turnstile solving without user interaction
- Rate-limiting or IP rotation
