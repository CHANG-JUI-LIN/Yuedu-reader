import UIKit
import WebKit

/// 簡單 prefix logger：用 [SNAP] 標記所有截圖 WebView 的事件，方便在 Xcode console 過濾。
private func snapLog(_ msg: String) {
    print("[SNAP] \(msg)")
}

/// WKScriptMessageHandler weak proxy，避免 WKUserContentController 強持有 EPUBSnapshotWebView。
private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(target: WKScriptMessageHandler) { self.target = target }
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// 獨立截圖 WebView：放在隱藏 UIWindow 中，串行為每頁截圖。
/// 與閱讀 WebView 完全分離，消除 scroll/render 競爭。
/// 使用讀取 WebView 已計算好的 pageOffsets，不再等待自身的 paginationReady。
@MainActor
final class EPUBSnapshotWebView: NSObject {

    // MARK: - 公開狀態
    private(set) var isCapturing = false

    // MARK: - 私有狀態
    private let webView: WKWebView
    private let snapshotWindow: UIWindow
    private var currentCaptureTask: Task<Void, Never>?
    private var navigationContinuation: CheckedContinuation<Bool, Never>?

    // MARK: - 初始化

    init(schemeHandler: ReaderSchemeHandler) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setURLSchemeHandler(schemeHandler, forURLScheme: PublicationSession.scheme)

        let ucc = WKUserContentController()
        config.userContentController = ucc

        let size = UIScreen.main.bounds.size
        let wv = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        self.webView = wv

        // 隱藏 UIWindow：isHidden=false 讓 WebView 進渲染樹，alpha=0 對用戶不可見
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        window.windowLevel = UIWindow.Level.normal - 1
        window.frame = UIScreen.main.bounds
        window.isHidden = false
        window.alpha = 0
        self.snapshotWindow = window

        super.init()

        window.addSubview(wv)
        wv.frame = window.bounds
        wv.navigationDelegate = self

        // snapshotBridge 保留（HTML 可能仍有 postMessage 呼叫），用 weak proxy 避免 retain cycle
        ucc.add(WeakScriptMessageProxy(target: self), name: "snapshotBridge")
        snapLog("init – webView bounds: \(wv.bounds)")
    }

    deinit {
        snapshotWindow.isHidden = true
    }

    // MARK: - 公開方法

    /// 取消正在進行的截圖任務。
    func cancel() {
        if currentCaptureTask != nil {
            snapLog("cancel() – stopping active capture task")
        }
        currentCaptureTask?.cancel()
        currentCaptureTask = nil
        isCapturing = false
        navigationContinuation?.resume(returning: false)
        navigationContinuation = nil
    }

    // MARK: - 主要截圖流程

    /// 載入章節 HTML，使用讀取 WebView 已計算好的 pageOffsets 串行截圖。
    /// 不再等待自身的 paginationReady，改用 WKNavigationDelegate.didFinish + rAF。
    func loadAndCapture(
        html: String,
        baseURL: URL,
        pageOffsets: [CGFloat],
        pageCount: Int,
        globalPageOffset: Int,
        onPageReady: @escaping (Int, UIImage) -> Void,
        onGateReady: @escaping () -> Void,
        onDone: @escaping () -> Void = {}
    ) {
        cancel()
        snapLog("loadAndCapture – globalPageOffset=\(globalPageOffset) pageCount=\(pageCount) offsets=\(pageOffsets)")

        isCapturing = true
        currentCaptureTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isCapturing = false }

            // 載入 HTML，等待 didFinish（頁面 DOM + CSS 初始化完成）
            self.webView.stopLoading()
            self.webView.loadHTMLString(html, baseURL: baseURL)
            snapLog("loadAndCapture – loadHTMLString called, waiting for navigation…")

            let navOK = await self.waitForNavigation()
            snapLog("loadAndCapture – waitForNavigation result: \(navOK ? "✅ didFinish" : "❌ timeout/cancelled")")
            guard navOK else {
                if !Task.isCancelled { onGateReady(); onDone() }
                return
            }
            guard !Task.isCancelled else { return }

            // 等兩個 rAF 讓 CSS multi-column layout 完成計算
            snapLog("loadAndCapture – waiting two rAF frames…")
            await self.waitForTwoFrames()
            snapLog("loadAndCapture – two rAF frames done")
            guard !Task.isCancelled else { return }

            let safePageCount = max(pageCount, 1)
            let gatePageCount = min(8, safePageCount)
            var gateTriggered = false

            for localPage in 0..<safePageCount {
                guard !Task.isCancelled else { return }

                let targetOffset: CGFloat = pageOffsets.indices.contains(localPage)
                    ? pageOffsets[localPage]
                    : CGFloat(localPage) * self.webView.bounds.width
                snapLog("page \(localPage)/\(safePageCount-1) – scrolling to offset \(targetOffset)")
                self.webView.scrollView.setContentOffset(
                    CGPoint(x: targetOffset, y: 0), animated: false
                )

                let hasImages = await self.pageHasImages()
                snapLog("page \(localPage) – hasImages: \(hasImages)")
                await self.waitForPageReady(hasImages: hasImages, localPage: localPage)
                guard !Task.isCancelled else { return }

                if let image = await self.captureCurrentPage() {
                    snapLog("page \(localPage) – ✅ captured \(Int(image.size.width))×\(Int(image.size.height)) → globalPage \(globalPageOffset + localPage)")
                    onPageReady(globalPageOffset + localPage, image)
                } else {
                    snapLog("page \(localPage) – ❌ captureCurrentPage returned nil")
                }

                if !gateTriggered && (localPage + 1) >= gatePageCount {
                    gateTriggered = true
                    snapLog("gate OPEN after page \(localPage)")
                    onGateReady()
                }
            }

            if !gateTriggered {
                snapLog("gate OPEN (all pages < gatePageCount)")
                onGateReady()
            }
            snapLog("loadAndCapture – complete for globalPageOffset=\(globalPageOffset)")
            onDone()
        }
    }

    // MARK: - 私有輔助

    /// 等待 WKNavigationDelegate.didFinish，最多 10 秒超時
    private func waitForNavigation() async -> Bool {
        await withCheckedContinuation { continuation in
            navigationContinuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.navigationContinuation != nil else { return }
                snapLog("waitForNavigation – ⚠️ 10s TIMEOUT")
                self.navigationContinuation?.resume(returning: false)
                self.navigationContinuation = nil
            }
        }
    }

    /// 等兩個 rAF 讓 CSS layout 完成，100ms 超時保底。
    /// 關鍵：JS 失敗時不提前 resume，讓 timeout 保底，避免截到空頁。
    private func waitForTwoFrames() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var done = false
            let finish: () -> Void = {
                guard !done else { return }
                done = true
                continuation.resume()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: finish)
            webView.callAsyncJavaScript(
                "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))",
                arguments: [:], in: nil, in: .page
            ) { result in
                switch result {
                case .success:
                    snapLog("waitForTwoFrames – ✅ rAF OK")
                    finish()
                case .failure(let error):
                    // JS 失敗：不提前 resume，讓 100ms timeout 保底
                    snapLog("waitForTwoFrames – ⚠️ JS error: \(error.localizedDescription) → waiting for timeout fallback")
                }
            }
        }
    }

    private func waitForPageReady(hasImages: Bool, localPage: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var workItem: DispatchWorkItem?
            var resumed = false

            let finish: () -> Void = {
                guard !resumed else { return }
                resumed = true
                workItem?.cancel()
                continuation.resume()
            }

            let timeout: TimeInterval = hasImages ? 0.6 : 0.08
            let item = DispatchWorkItem {
                snapLog("waitForPageReady page \(localPage) – ⏱ timeout fired (\(timeout)s)")
                finish()
            }
            workItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)

            let js: String
            if hasImages {
                js = """
                await new Promise(resolve => {
                    const imgs = [...document.images];
                    if (imgs.every(i => i.complete)) { resolve(); return; }
                    let count = imgs.filter(i => !i.complete).length;
                    imgs.filter(i => !i.complete).forEach(i => {
                        i.addEventListener('load',  () => { if (--count === 0) resolve(); });
                        i.addEventListener('error', () => { if (--count === 0) resolve(); });
                    });
                });
                await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
                """
            } else {
                js = "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))"
            }
            webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success:
                    snapLog("waitForPageReady page \(localPage) – ✅ JS OK (hasImages=\(hasImages))")
                    finish()
                case .failure(let error):
                    // JS 失敗：不提前截圖，讓 timeout 保底。
                    // 這是重複頁/空白封面的根本原因：舊版 { _ in finish() } 在 JS 失敗時立即截圖。
                    snapLog("waitForPageReady page \(localPage) – ⚠️ JS FAILED: \(error.localizedDescription) → waiting for timeout (\(timeout)s)")
                }
            }
        }
    }

    private func captureCurrentPage() async -> UIImage? {
        await withCheckedContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: webView.bounds.size)
            config.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
            webView.takeSnapshot(with: config) { image, error in
                if let error {
                    snapLog("captureCurrentPage – ❌ takeSnapshot error: \(error.localizedDescription)")
                }
                continuation.resume(returning: image)
            }
        }
    }

    private func pageHasImages() async -> Bool {
        let result = try? await webView.evaluateJavaScript("document.images.length > 0")
        return (result as? Bool) ?? false
    }
}

// MARK: - WKNavigationDelegate
extension EPUBSnapshotWebView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        snapLog("WKNav – didFinish")
        navigationContinuation?.resume(returning: true)
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        snapLog("WKNav – didFail: \(error.localizedDescription)")
        navigationContinuation?.resume(returning: false)
        navigationContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        snapLog("WKNav – didFailProvisional: \(error.localizedDescription)")
        navigationContinuation?.resume(returning: false)
        navigationContinuation = nil
    }
}

// MARK: - WKScriptMessageHandler（保留以避免 HTML 的 postMessage 呼叫出現 console 錯誤）
extension EPUBSnapshotWebView: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // snapshotBridge 的訊息不再用於控制流程，靜默忽略
    }
}
