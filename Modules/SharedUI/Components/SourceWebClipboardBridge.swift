import UIKit
import WebKit

/// Installs the clipboard contract expected by ordinary login pages and source-authored
/// browser pages. WKWebView may reject `navigator.clipboard.writeText` outside a secure
/// origin even when the call came from a real button tap, so the page delegates only the
/// final string write to UIKit; selection and button logic remain page-owned JavaScript.
final class SourceWebClipboardBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let messageName = "yueduClipboardWrite"

    static let bootstrapScript = #"""
    (function () {
      if (window.__yueduClipboardInstalled) return;
      window.__yueduClipboardInstalled = true;
      function nativeWrite(value) {
        return window.webkit.messageHandlers.yueduClipboardWrite
          .postMessage(String(value == null ? '' : value));
      }
      var clipboard = navigator.clipboard || {};
      try {
        Object.defineProperty(clipboard, 'writeText', {
          configurable: true,
          value: nativeWrite
        });
        Object.defineProperty(navigator, 'clipboard', {
          configurable: true,
          value: clipboard
        });
      } catch (_) {}
      var originalExecCommand = document.execCommand && document.execCommand.bind(document);
      document.execCommand = function (command) {
        if (String(command || '').toLowerCase() !== 'copy') {
          return originalExecCommand ? originalExecCommand.apply(document, arguments) : false;
        }
        var active = document.activeElement;
        var text = '';
        if (active && typeof active.value === 'string') {
          var start = Number(active.selectionStart);
          var end = Number(active.selectionEnd);
          text = Number.isFinite(start) && Number.isFinite(end) && end > start
            ? active.value.slice(start, end) : active.value;
        }
        if (!text && window.getSelection) text = String(window.getSelection() || '');
        nativeWrite(text);
        return true;
      };
      window.java = window.java || {};
      window.java.copyText = nativeWrite;
    })();
    """#

    func install(in controller: WKUserContentController) {
        controller.addScriptMessageHandler(
            self,
            contentWorld: .page,
            name: Self.messageName
        )
        controller.addUserScript(WKUserScript(
            source: Self.bootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
    }

    func remove(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(
            forName: Self.messageName,
            contentWorld: .page
        )
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard message.name == Self.messageName else {
            replyHandler(false, nil)
            return
        }
        let text = message.body as? String ?? String(describing: message.body)
        Task { @MainActor in
            UIPasteboard.general.string = text
            replyHandler(true, nil)
        }
    }
}
