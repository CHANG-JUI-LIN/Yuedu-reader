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
    /// Hitting it is logged with the page and the requests still in flight (kind, age, URL); the
    /// page is then read as it is. It stays as long as pages can hold a request open, which is
    /// not something a source controls.
    static let limitMs = 10_000

    /// How many of the requests still in flight at the limit the log names, oldest first.
    static let loggedRequests = 5

    private static let stateKey = "__yueduPageRequests"

    /// Counts the page's requests from before its first script runs. Installed on every
    /// configuration whose pages are read this way (`install(on:)`).
    private static let counterSource = """
        (function () {
          var KEY = '\(stateKey)';
          if (window[KEY]) return;
          // `inflight` names what `pending` counts, so a read held to the limit can say what by.
          var state = { pending: 0, idle: [], checking: false, inflight: {}, nextId: 1 };
          try { Object.defineProperty(window, KEY, { value: state }); } catch (e) { return; }
          function absolute(url) {
            try { return new URL(String(url), location.href).href; } catch (e) { return String(url); }
          }
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
          function begin(kind, url) {
            state.pending++;
            var id = state.nextId++;
            state.inflight[id] = { kind: kind, url: url, at: Date.now() };
            return id;
          }
          function end(id) {
            delete state.inflight[id];
            if (state.pending > 0) state.pending--;
            check();
          }
          state.whenIdle = function (waiter) { state.idle.push(waiter); check(); };
          // The URL an XHR was opened with, kept off the object so the page never sees it.
          var opened = typeof WeakMap === 'function' ? new WeakMap() : null;
          var open = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function (method, url) {
            if (opened) { try { opened.set(this, absolute(url)); } catch (e) {} }
            return open.apply(this, arguments);
          };
          // An XHR ends at `loadend`, which comes after its `readystatechange` and `load`
          // handlers: whatever the page does with the answer synchronously is done by then.
          var send = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.send = function () {
            var ended = false, id = begin('xhr', (opened && opened.get(this)) || '');
            function once() { if (!ended) { ended = true; end(id); } }
            this.addEventListener('loadend', once);
            try { return send.apply(this, arguments); } catch (e) { once(); throw e; }
          };
          function counted(call, kind, urlOf) {
            return function () {
              var url = '';
              try { url = urlOf(this, arguments); } catch (e) {}
              var id = begin(kind, url), promise;
              try { promise = call.apply(this, arguments); } catch (e) { end(id); throw e; }
              promise.then(function () { end(id); }, function () { end(id); });
              return promise;
            };
          }
          // `fetch` answers with the headers; the body the page then reads is counted on its own.
          if (typeof window.fetch === 'function') {
            window.fetch = counted(window.fetch, 'fetch', function (self, args) {
              var input = args[0];
              return absolute(input && typeof input === 'object' && 'url' in input ? input.url : input);
            });
          }
          if (window.Response) {
            ['text', 'json', 'arrayBuffer', 'blob', 'formData'].forEach(function (name) {
              var read = Response.prototype[name];
              if (typeof read === 'function') {
                Response.prototype[name] = counted(read, 'body', function (self) { return self.url; });
              }
            });
          }
        })();
        """

    /// Resolves once the page has nothing in flight, or at `limitMs` with the requests still in
    /// flight, oldest first. -1 when the counter is not on the page.
    private static let drainSource = """
        var state = window['\(stateKey)'];
        if (!state || typeof state.whenIdle !== 'function') return -1;
        var started = Date.now();
        function inflight() {
          var now = Date.now(), list = [];
          for (var id in state.inflight) list.push(state.inflight[id]);
          list.sort(function (a, b) { return a.at - b.at; });
          return list.slice(0, loggedRequests).map(function (r) {
            return r.kind + ' ' + (now - r.at) + 'ms ' + String(r.url || '?').slice(0, 200);
          });
        }
        return await new Promise(function (resolve) {
          var settled = false;
          function done(timedOut) {
            if (settled) return;
            settled = true;
            resolve({ waitedMs: Date.now() - started, timedOut: timedOut, pending: state.pending,
                      requests: timedOut ? inflight() : [] });
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
                drainSource, arguments: ["limitMs": limitMs, "loggedRequests": loggedRequests], contentWorld: .page
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
            let requests = (report["requests"] as? [String]) ?? []
            AppLogger.parse("Page still had requests in flight at the drain limit; read as it is", context: [
                "page": page, "pending": pending, "limitMs": limitMs,
                "requests": requests.isEmpty ? "-" : requests.joined(separator: " ; "),
            ], level: .warning)
        }
        SourcePerfTrace.record("webView.drain", "pending=\(pending) \(page)", since: started, thresholdMs: 50)
    }
}
