import Testing
import UIKit
import WebKit
@testable import yuedu_app

/// #57: a rich intro collapsed to a fixed 88 points, cut through its second line wherever the
/// source's own CSS spaced lines apart from ours. It now ends on the last whole line.
@Suite("Rich intro collapse", .serialized)
@MainActor
struct BookIntroLayoutTests {
    @Test("an intro that fits shows whole")
    func fitsWhole() {
        let layout = BookIntroLayout(height: 60, lines: [0...30, 30...60])
        #expect(layout.collapsedHeight(limit: 88) == 60)
    }

    @Test("a limit through a line backs up to the line above it")
    func endsOnALine() {
        // A heading, then lines 30 points apart: 88 falls inside the third line.
        let layout = BookIntroLayout(height: 200, lines: [0...36, 46...76, 76...106, 106...136])
        #expect(layout.collapsedHeight(limit: 88) == 76)
    }

    @Test("a limit between lines, or through a picture, is kept")
    func keepsAClearLimit() {
        let between = BookIntroLayout(height: 200, lines: [0...40, 50...86, 92...130])
        #expect(between.collapsedHeight(limit: 88) == 88)
        // A cover above the text: cutting through it cuts no line.
        let picture = BookIntroLayout(height: 400, lines: [300...322])
        #expect(picture.collapsedHeight(limit: 88) == 88)
    }

    @Test("a first line taller than the limit is shown whole")
    func showsATallFirstLine() {
        let layout = BookIntroLayout(height: 300, lines: [10...120, 120...150])
        #expect(layout.collapsedHeight(limit: 88) == 120)
    }

    @Test("the intro's script reports lines a collapse can end on", .timeLimit(.minutes(1)))
    func scriptReportsLines() async throws {
        let receiver = LayoutReceiver()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(receiver, name: BookIntroWebView.Coordinator.heightMessage)
        configuration.userContentController.addUserScript(WKUserScript(
            source: BookIntroWebView.Coordinator.heightScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 88), configuration: configuration)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(webView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        // The shape of #57's intro: a heading in a larger size with a rule beside it, then text
        // on lines 30 points apart, with no margins of its own.
        let layout = try await receiver.layout(loading: """
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
            body { margin: 0; font-size: 15px; }
            h4 { margin: 0 0 10px; font-size: 20px; line-height: 36px; border-left: 4px solid red; }
            p { margin: 0; line-height: 30px; }
            </style></head><body><h4>作品简介</h4>
            <p>標籤：系統+穿越+爽文+癲+單女主+序列收容+克系+群像+輕鬆+日常+腦洞+無敵流+種田+經營+搞笑+熱血</p>
            </body></html>
            """, in: webView)

        #expect(layout.height > 88)
        #expect(!layout.lines.isEmpty)
        let cut = layout.collapsedHeight(limit: 88)
        #expect(cut > 0 && cut <= 88)
        #expect(!layout.lines.contains { $0.lowerBound < cut - 0.5 && $0.upperBound > cut + 0.5 }, "\(layout.lines) cut at \(cut)")
        #expect(layout.lines.contains { abs($0.upperBound - cut) < 0.5 }, "ends on a line: \(layout.lines) cut at \(cut)")
    }
}

@MainActor
private final class LayoutReceiver: NSObject, WKScriptMessageHandler {
    private var continuation: CheckedContinuation<BookIntroLayout, Error>?

    func layout(loading html: String, in webView: WKWebView) async throws -> BookIntroLayout {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let continuation else { return }
        self.continuation = nil
        guard let layout = BookIntroLayout(messageBody: message.body) else {
            continuation.resume(throwing: UnreadableLayout(body: String(describing: message.body)))
            return
        }
        continuation.resume(returning: layout)
    }

    struct UnreadableLayout: Error {
        let body: String
    }
}
