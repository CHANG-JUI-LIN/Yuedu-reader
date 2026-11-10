import Foundation
import WebKit

/// Holds the read of a source's WebView page until the requests the page itself has in flight
/// are answered: its XHRs, its `fetch` calls and the response bodies it reads.
///
/// Legado reads such a page once, a fixed time after it loads — `onPageFinished` plus
/// `100 + delayTime` ms with `delayTime` 900 when the source gives no script (legado-E
/// `BackstageWebView.kt:90`, `:218`), `1000 + delayTime` in MD3 (`:209`) — and reads it again
/// only when the script answered `null`, which `document.documentElement.outerHTML` never does.
/// That one second still comes first here (`AppConfig.webViewJSRenderWait`,
/// `LegadoHeadlessWebView.effectiveDelayMs`); this waits after it, on the page's own requests,
/// which are an actual signal rather than more time.
///
/// Deliberate divergence from Legado (maintainer decision, 2026-11-10): a page that fills its
/// text from requests answered after that second was read empty. 17k's chapter page (YCK
/// 1330#54) clears `#Context` and rebuilds it from three chained requests (`/ckv3/…/chapter`,
/// `…/otherInfo`, `mod/decode.js`); measured from here, 2 loads in 8 rebuilt it 0.3–1.5 s past
/// the read. Legado blocks network images, which brings its `load` event sooner still.
@MainActor
enum PageRequestDrain {
    /// The longest a read waits for the page's requests. It guards against a page that is never
    /// without a request in flight — a long-poll or streaming connection held open by a chat or
    /// ad script — which would otherwise hold every read of it until the source's 60 s deadline.
    /// Hitting it is logged with the page and its pending count; the page is then read as it is.
    /// It stays as long as pages can hold a request open, which is not something a source controls.
    static let limitMs = 10_000

    private static let stateKey = "__yueduPageRequests"

    /// Counts the page's requests from before its first script runs. Installed on every
    /// configuration whose pages are read this way (`install(on:)`).
    private static let counterSource = """
        (function () {
          var KEY = '\(stateKey)';
          if (window[KEY]) return;
          var state = { pending: 0, idle: [], checking: false };
          try { Object.defineProperty(window, KEY, { value: state }); } catch (e) { return; }
          // A check runs as a task of its own, after every microtask the last answer queued:
          // a page's continuation reads the body (one more request) or fills the page there.
          // A message is a task WebKit does not throttle in a page nobody sees, as it does timers.
          var channel = new MessageChannel();
          channel.port1.onmessage = function () {
            state.checking = false;
            if (state.pending !== 0) return;
            var waiters = state.idle.splice(0);
            for (var i = 0; i < waiters.length; i++) { try { waiters[i](); } catch (e) {} }
          };
          function check() {
            if (state.pending === 0 && state.idle.length && !state.checking) {
              state.checking = true;
              channel.port2.postMessage(0);
            }
          }
          function begin() { state.pending++; }
          function end() { if (state.pending > 0) state.pending--; check(); }
          state.whenIdle = function (waiter) { state.idle.push(waiter); check(); };
          // An XHR ends at `loadend`, which comes after its `readystatechange` and `load`
          // handlers: whatever the page does with the answer synchronously is done by then.
          var send = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.send = function () {
            var ended = false;
            function once() { if (!ended) { ended = true; end(); } }
            begin();
            this.addEventListener('loadend', once);
            try { return send.apply(this, arguments); } catch (e) { once(); throw e; }
          };
          function counted(call) {
            return function () {
              begin();
              var promise;
              try { promise = call.apply(this, arguments); } catch (e) { end(); throw e; }
              promise.then(end, end);
              return promise;
            };
          }
          // `fetch` answers with the headers; the body the page then reads is counted on its own.
          if (typeof window.fetch === 'function') window.fetch = counted(window.fetch);
          if (window.Response) {
            ['text', 'json', 'arrayBuffer', 'blob', 'formData'].forEach(function (name) {
              var read = Response.prototype[name];
              if (typeof read === 'function') Response.prototype[name] = counted(read);
            });
          }
        })();
        """

    /// Resolves once the page has nothing in flight, or at `limitMs`. -1 when the counter is
    /// not on the page.
    private static let drainSource = """
        var state = window['\(stateKey)'];
        if (!state || typeof state.whenIdle !== 'function') return -1;
        var started = Date.now();
        return await new Promise(function (resolve) {
          var settled = false;
          function done(timedOut) {
            if (settled) return;
            settled = true;
            resolve({ waitedMs: Date.now() - started, timedOut: timedOut, pending: state.pending });
          }
          setTimeout(function () { done(true); }, limitMs);
          state.whenIdle(function () { done(false); });
        });
        """

    /// Counts the requests of the main frame's pages; the read is of the main frame's document.
    static func install(on controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(
            source: counterSource, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
    }

    /// Waits for the page `webView` shows to have no request in flight. Never throws: a page
    /// that cannot be asked is read as it is, and why is logged.
    static func wait(in webView: WKWebView) async {
        let started = ProcessInfo.processInfo.systemUptime
        let page = String((webView.url?.absoluteString ?? "-").prefix(160))
        let answer: Any?
        do {
            answer = try await webView.callAsyncJavaScript(
                drainSource, arguments: ["limitMs": limitMs], contentWorld: .page
            )
        } catch {
            AppLogger.parse("Page request drain could not ask the page", error: error, context: [
                "page": page,
            ], level: .warning)
            return
        }
        guard let report = answer as? [String: Any] else {
            AppLogger.parse("Page request counter missing from the page", context: [
                "page": page, "answer": String(describing: answer),
            ], level: .warning)
            return
        }
        let pending = report["pending"] as? Int ?? -1
        if report["timedOut"] as? Bool == true {
            AppLogger.parse("Page still had requests in flight at the drain limit; read as it is", context: [
                "page": page, "pending": pending, "limitMs": limitMs,
            ], level: .warning)
        }
        SourcePerfTrace.record("webView.drain", "pending=\(pending) \(page)", since: started, thresholdMs: 50)
    }
}
