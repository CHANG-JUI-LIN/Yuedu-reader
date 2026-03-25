# Reading Gate + 獨立截圖 WebView 設計文檔

**日期**：2026-03-25
**狀態**：已批准，待實施
**背景**：修復空白頁、重複頁內容、封面白屏問題

---

## 1. 問題根因

當前架構的致命缺陷：**截圖與閱讀共用同一個 WKWebView**。

截圖需要強制 scroll WebView 到目標頁位置，然後等待 render，再截圖，再還原。這一系列操作：

- 與用戶正在閱讀的 WebView 產生競爭（race condition）
- 加互斥鎖只是把競爭串行化，無法解決根本問題
- 35ms 固定 sleep / requestAnimationFrame 都無法可靠判斷 WebKit GPU 渲染是否完成
- 導致：空白頁（截圖未就緒）、重複頁（截到前一頁）、封面白屏（圖片未載入完）

---

## 2. 解決方案概覽

兩個互相配合的改動，缺一不可：

| 組件 | 職責 |
|------|------|
| **EPUBSnapshotWebView** | 獨立於閱讀的隱藏 WKWebView，專門生成截圖 |
| **ReadingGate** | 狀態機，控制何時允許用戶閱讀 |

### 與現有代碼的關係

項目中已存在 `EPUBSnapshotWorker.swift` 和 `EPUBSnapshotManager.swift`，是早期同概念的嘗試，但未完成。本次實施：
- **刪除** `EPUBSnapshotWorker.swift` 和 `EPUBSnapshotManager.swift`
- **新建** `EPUBSnapshotWebView.swift`（基於本規格，解決舊版的 UIWindow 和取消問題）

---

## 3. EPUBSnapshotWebView（獨立渲染 WebView）

### 設計原則

- 放在隱藏的 `UIWindow`（不可見，但在渲染樹中，確保 rAF 可靠觸發）
- 與閱讀 WebView **完全分離**，互不干擾，不需要互斥鎖
- 所有截圖工作**串行執行**（單個 Task，不並發），防止 scroll/render 競爭

### UIWindow 生命週期

- `EPUBSnapshotWebView` 初始化時建立 `UIWindow`
- `windowLevel = .normal - 1`（避免出現在 alert 等系統 UI 之上）
- 必須附加到 `UIWindowScene`（iOS 13+）：通過 `UIApplication.shared.connectedScenes` 取第一個 `UIWindowScene`（與 `LiveWebReader` 的 `ensureWebViewInHierarchy()` 使用相同模式）
- `frame = UIScreen.main.bounds`（確保 WebView 以正確解析度渲染）
- `isHidden = false`（UIWindow 必須 visible 才能進入渲染樹），`alpha = 0`（對用戶不可見）
- `deinit` 時 `window.isHidden = true`，再釋放

### JS Bridge

`EPUBSnapshotWebView` 使用獨立的 `WKUserContentController` 和獨立的 bridge name（`"snapshotBridge"`），避免與閱讀 WebView bridge 的消息路由衝突。

監聽與閱讀 WebView 相同的 `paginationReady` 消息（payload：`{ pageCount: Int, pageOffsets: [CGFloat] }`），timeout 設定為 **5 秒**（超時後視為章節無法分頁，跳過 gate）。

### HTML 載入

調用 `buildChapterHTML(chapterHTML:chapterBaseURL:bridgeName:useReadiumCSS:)` 時傳入 `bridgeName: "snapshotBridge"`，其他參數與閱讀 WebView 一致。必須使用相同的 `ReaderSchemeHandler` 實例（確保 `epub://` scheme 資源正常載入圖片和 CSS）。

### 取消契約（Cancellation Contract）

`EPUBSnapshotWebView` 持有一個 `currentCaptureTask: Task<Void, Never>?`。

每次調用 `loadAndCapture(chapter:onPageReady:onGateReady:)` 時：
1. 先取消 `currentCaptureTask`（若存在）
2. 建立新 Task，賦值給 `currentCaptureTask`
3. 新 Task 在每個截圖前檢查 `Task.isCancelled`

呼叫 `cancel()` 方法可隨時停止進行中的截圖任務（用於章節跳轉時清理舊任務）。

### 截圖流程（串行）

```
1. loadHTML（含 snapshotBridge）
2. 等 paginationReady 信號（最多 5 秒）→ 取得 pageCount, pageOffsets
3. 計算 gatePageCount = min(8, pageCount)
4. 對 localPage in 0..<pageCount，串行執行：
   a. Task.isCancelled → 退出
   b. scrollView.setContentOffset(x: pageOffsets[localPage])
   c. 偵測頁面是否含圖片（JS：document.images.length > 0）
   d. 等待 waitForPageReady(hasImages:)
   e. WKWebView.takeSnapshot(with: config) → UIImage
   f. 回調 onPageReady(localPage, image)
   g. 若 localPage + 1 == gatePageCount → 回調 onGateReady()
```

### waitForPageReady() 實現

```swift
private func waitForPageReady(_ webView: WKWebView, hasImages: Bool) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        // 使用 DispatchWorkItem 以便取消
        var workItem: DispatchWorkItem?
        var resumed = false

        let finish: () -> Void = {
            // 在 @MainActor 上執行，無並發問題
            guard !resumed else { return }
            resumed = true
            workItem?.cancel()       // 取消尚未觸發的超時
            continuation.resume()
        }

        // 超時保底（普通頁 80ms，圖片頁 600ms）
        let timeout = hasImages ? 0.6 : 0.08
        let item = DispatchWorkItem { finish() }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)

        // JS 路徑：等圖片 onload + 2個 rAF
        let js = hasImages ? """
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
        """ : "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))"

        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { _ in finish() }
    }
}
```

---

## 4. ReadingGate（閱讀閘門）

### 狀態定義

```swift
enum ReadingGateState: Equatable {
    case loading   // 顯示 spinner，禁止翻頁
    case open      // 允許閱讀
}
```

### 觸發時機

| 事件 | Gate 動作 |
|------|-----------|
| 開書 | → `.loading`，預渲染第 0 章 |
| 目錄跳章（`jumpToChapter` 調用路徑） | → `.loading`，預渲染目標章 |
| 正常翻頁到下一章（`loadChapterForPage` 路徑，且 WebView pool 已預載） | **不觸發**（pool 已有截圖） |
| 正常翻頁到下一章（pool 未就緒，退化為 `loadChapter`） | → `.loading` |

**判斷準則**：Gate 觸發當且僅當目標章節的截圖緩存中頁 0 的截圖不存在。

### Gate 開啟條件

- `min(8, chapterPageCount)` 頁截圖全部就緒後 Gate → `.open`
- `chapterPageCount` 由 `paginationReady` 信號提供
- 若 `paginationReady` 超時（5 秒）：Gate 強制 → `.open`（fallback，避免卡死）

### UI 表現

- Gate `.loading`：閱讀器上蓋全屏透明 overlay，中央顯示 `ProgressView()`（系統 spinner），無進度條、無文字
- Gate `.open`：overlay 以 0.2s easeOut fade 消失
- 閱讀 WebView 在 overlay 之後，Gate 開啟前不響應翻頁手勢（`isUserInteractionEnabled = false` 或 SwiftUI `disabled(gate != .open)`）

---

## 5. PageSnapshotProvider 整合

### 新增 push 介面

在 `PageSnapshotProvider` 新增：
```swift
func store(image: UIImage, forGlobalPage page: Int)
```

此方法由 `EPUBSnapshotWebView` 的 `onPageReady` 回調調用，直接寫入 `snapshotImages[page]` 並觸發 `version &+= 1`。

Gate 預渲染階段繞過 `processQueueIfNeeded()` 的距離限制（stale-drop logic）：`store()` 直接寫入，不經過 priority queue。`processQueueIfNeeded()` 的 `maxDistance` 限制僅影響按需請求（用戶閱讀時的懶加載），不影響 gate 預渲染。

### 保留現有修復

`PageSnapshotProvider` 的 `DispatchQueue.main.async { self.version &+= 1 }` 修復保留（防止 SwiftUI publishing warning）。

---

## 6. 數據流

```
用戶開書 / 跳章
    ↓
EPUBPageRenderer.navigateToChapter(N)
    ↓
snapshotWebView.cancel()              ← 取消可能進行中的舊章節截圖任務
ReadingGate → .loading
    ↓
snapshotWebView.loadAndCapture(
    chapter: N,
    onPageReady: { page, image in snapshotProvider.store(image, forPage: globalPage) },
    onGateReady: { ReadingGate → .open }
)
    ↓
[串行截圖每頁，前 min(8,total) 頁就緒後觸發 onGateReady]
    ↓
overlay fade out，用戶可以翻頁
    ↓
背景繼續截圖剩餘頁面（同一 Task，串行繼續）
```

---

## 7. 需要修改的文件

| 文件 | 變更類型 | 說明 |
|------|----------|------|
| `EPUBSnapshotWebView.swift` | **新建** | 獨立截圖 WebView，含 waitForPageReady()、取消契約、UIWindow 管理 |
| `EPUBPageRenderer.swift` | **修改** | 新增 `readingGate: ReadingGateState`（@Published）；持有 `EPUBSnapshotWebView` 實例；新增 `navigateToChapter()` |
| `LiveWebReader.swift` | **重構** | 移除 `snapshotImage()`、`waitForWebViewRender()`、互斥鎖（`snapshotLockByWebView` 等）；`snapshotImages` 字典可能移至 `PageSnapshotProvider` |
| `PageSnapshotProvider.swift` | **小改** | 新增 `store(image:forGlobalPage:)` |
| `ReaderView.swift` | **修改** | 監聽 `readingGate`，`.loading` 時顯示 overlay，`.open` 時 fade out；Gate `.loading` 時 disable 翻頁手勢 |
| `SnapshotReaderView.swift` | **清理** | 移除舊的 workaround（保留 `currentPage != previousPage` guard） |
| `EPUBSnapshotWorker.swift` | **刪除** | 被 EPUBSnapshotWebView 取代 |
| `EPUBSnapshotManager.swift` | **刪除** | 被 EPUBSnapshotWebView 取代 |

---

## 8. 不在本次範圍內

- 磁盤 LRU 緩存（app 重啟後截圖持久化）
- CFI / DOM 位置映射
- 截圖分辨率自適應（Retina vs non-Retina）
- XCTest 自動化性能測試（人工測試即可）

---

## 9. 成功標準

- [ ] 開書後顯示 spinner，`min(8, total)` 頁就緒後自動消失
- [ ] 跳章後顯示 spinner，`min(8, total)` 頁就緒後自動消失
- [ ] 正常翻頁：永遠不出現空白頁
- [ ] 封面頁：不再白屏（`img.onload` 等待確保圖片渲染完成）
- [ ] 重複頁內容 bug：消失（獨立 WebView 串行截圖，無競爭）
- [ ] 快速跳章：舊章節截圖任務正確取消，不污染新章節緩存
- [ ] 章節頁數 < 8 頁時：Gate 正確開啟，不崩潰
- [ ] Gate 等待時間：< 1 秒（普通章節）、< 1.5 秒（含圖片封面）（人工計時）
