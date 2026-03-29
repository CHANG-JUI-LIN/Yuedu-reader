import UIKit
import WebKit

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
@MainActor
final class EPUBSnapshotWebView: NSObject {

    // MARK: - 公開狀態
    private(set) var isCapturing = false

    // MARK: - 私有狀態
    private let webView: WKWebView
    private let snapshotWindow: UIWindow
    private var currentCaptureTask: Task<Void, Never>?
    private var paginationContinuation: CheckedContinuation<PaginationInfo?, Never>?
    private var paginationGeneration = 0

    struct PaginationInfo {
        let pageCount: Int
        let pageOffsets: [CGFloat]
    }

    // MARK: - 初始化

    init(schemeHandler: ReaderSchemeHandler) {
        // 1. 建立獨立 WKWebViewConfiguration（bridge name: snapshotBridge）
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setURLSchemeHandler(schemeHandler, forURLScheme: PublicationSession.scheme)

        let ucc = WKUserContentController()
        config.userContentController = ucc

        // 2. 建立 WKWebView（全螢幕尺寸，確保截圖分辨率正確）
        let size = UIScreen.main.bounds.size
        let wv = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        self.webView = wv

        // 3. 建立隱藏 UIWindow（必須 isHidden=false 才能進渲染樹，alpha=0 對用戶不可見）
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

        // 4. 把 WebView 加入 window
        window.addSubview(wv)
        wv.frame = window.bounds

        // 5. 註冊 JS message handler
        ucc.add(WeakScriptMessageProxy(target: self), name: "snapshotBridge")
        wv.navigationDelegate = self
    }

    deinit {
        snapshotWindow.isHidden = true
    }

    // MARK: - 公開方法

    /// 取消正在進行的截圖任務。
    func cancel() {
        currentCaptureTask?.cancel()
        currentCaptureTask = nil
        isCapturing = false
        paginationContinuation?.resume(returning: nil)
        paginationContinuation = nil
    }

    // MARK: - 主要截圖流程

    /// 載入章節 HTML 並串行截圖。
    func loadAndCapture(
        html: String,
        baseURL: URL,
        globalPageOffset: Int,
        onPageReady: @escaping (Int, UIImage) -> Void,
        onGateReady: @escaping () -> Void
    ) {
        cancel()

        isCapturing = true
        currentCaptureTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isCapturing = false }

            // 載入 HTML
            self.webView.stopLoading()
            self.webView.loadHTMLString(html, baseURL: baseURL)

            // 等待 paginationReady（最多 5 秒）
            guard let pagination = await self.waitForPagination() else {
                onGateReady()
                return
            }
            guard !Task.isCancelled else { return }

            let pageCount = max(pagination.pageCount, 1)
            let offsets = pagination.pageOffsets
            let gatePageCount = min(8, pageCount)
            var gateTriggered = false

            for localPage in 0..<pageCount {
                guard !Task.isCancelled else { return }

                // 滾到目標頁
                let targetOffset: CGFloat = offsets.indices.contains(localPage)
                    ? offsets[localPage]
                    : CGFloat(localPage) * self.webView.bounds.width
                self.webView.scrollView.setContentOffset(
                    CGPoint(x: targetOffset, y: 0), animated: false
                )

                // 等待渲染完成
                let hasImages = await self.pageHasImages()
                await self.waitForPageReady(hasImages: hasImages)
                guard !Task.isCancelled else { return }

                // 截圖
                if let image = await self.captureCurrentPage() {
                    onPageReady(globalPageOffset + localPage, image)
                }

                // 前 min(8, total) 頁截完後觸發 gate
                if !gateTriggered && (localPage + 1) >= gatePageCount {
                    gateTriggered = true
                    onGateReady()
                }
            }

            if !gateTriggered { onGateReady() }
        }
    }

    // MARK: - 私有輔助

    private func waitForPagination() async -> PaginationInfo? {
        paginationGeneration &+= 1
        let myGeneration = paginationGeneration
        return await withCheckedContinuation { continuation in
            paginationContinuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.paginationGeneration == myGeneration,
                      self.paginationContinuation != nil else { return }
                self.paginationContinuation?.resume(returning: nil)
                self.paginationContinuation = nil
            }
        }
    }

    private func waitForPageReady(hasImages: Bool) async {
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
            let item = DispatchWorkItem { finish() }
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
            webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { _ in finish() }
        }
    }

    private func captureCurrentPage() async -> UIImage? {
        await withCheckedContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: webView.bounds.size)
            config.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
            webView.takeSnapshot(with: config) { image, _ in
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
extension EPUBSnapshotWebView: WKNavigationDelegate {}

// MARK: - WKScriptMessageHandler
extension EPUBSnapshotWebView: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "snapshotBridge",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              type == "paginationReady",
              let payload = body["payload"] as? [String: Any] else { return }

        let pageCount = payload["pageCount"] as? Int ?? 0
        let offsets = (payload["pageOffsets"] as? [Double])?.map { CGFloat($0) } ?? []
        let info = PaginationInfo(pageCount: pageCount, pageOffsets: offsets)
        paginationContinuation?.resume(returning: info)
        paginationContinuation = nil
    }
}
