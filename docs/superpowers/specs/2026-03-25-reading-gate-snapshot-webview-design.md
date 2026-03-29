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

---

## 3. EPUBSnapshotWebView（獨立渲染 WebView）

### 設計原則

- 放在隱藏的 `UIWindow`（不可見，但在渲染樹中）
- 與閱讀 WebView **完全分離**，互不干擾
- 專職截圖，不做任何閱讀用途
- 支持 `requestAnimationFrame`（因為在 UIWindow 中）

### 截圖流程

```
1. 載入章節 HTML（與閱讀 WebView 的相同 HTML）
2. 等待 JS isReady 信號（CSS multi-column 分頁完成）
3. 對每一頁：
   a. scrollView.setContentOffset(x: targetOffset, animated: false)
   b. 等待 waitForPageReady()：
      - 普通頁：等 2 個 rAF（約 33ms @ 60fps）
      - 含圖片頁：額外等 img.onload，最多超時 500ms
   c. WKWebView.takeSnapshot(with: config)
   d. 存入截圖緩存
```

### waitForPageReady() 實現

```swift
private func waitForPageReady(_ webView: WKWebView, hasImages: Bool) async {
    await withCheckedContinuation { continuation in
        var done = false
        let finish = { if !done { done = true; continuation.resume() } }

        // 超時保底（普通頁 80ms，圖片頁 600ms）
        let timeout = hasImages ? 0.6 : 0.08
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: finish)

        // 等圖片載入（如果有）
        if hasImages {
            webView.callAsyncJavaScript("""
                await new Promise(resolve => {
                    const imgs = [...document.images];
                    if (imgs.every(i => i.complete)) { resolve(); return; }
                    let count = imgs.filter(i => !i.complete).length;
                    imgs.filter(i => !i.complete).forEach(i => {
                        i.addEventListener('load', () => { if (--count === 0) resolve(); });
                        i.addEventListener('error', () => { if (--count === 0) resolve(); });
                    });
                });
                await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
            """, arguments: [:], in: nil, in: .page) { _ in finish() }
        } else {
            webView.callAsyncJavaScript(
                "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))",
                arguments: [:], in: nil, in: .page
            ) { _ in finish() }
        }
    }
}
```

### 與現有 WebView Pool 的關係

| WebView | 用途 | 可見性 |
|---------|------|--------|
| `webView`（主） | 當前章節閱讀 | 可見 |
| `webViewPool[.prev]` | 前一章節預載 | 隱藏 |
| `webViewPool[.next]` | 後一章節預載 | 隱藏 |
| `snapshotWebView`（新增） | 截圖生成 | 隱藏，在獨立 UIWindow |

截圖工作**完全由 snapshotWebView 承擔**，其他 WebView 只管閱讀，不再參與截圖。

---

## 4. ReadingGate（閱讀閘門）

### 狀態定義

```swift
enum ReadingGateState {
    case loading(progress: Int, total: Int)  // 顯示 spinner
    case open                                 // 允許閱讀
}
```

### 觸發時機

| 事件 | Gate 動作 |
|------|-----------|
| 開書 | → `.loading`，預渲染第 0 章前 8 頁 |
| 跳章（目錄/目錄跳轉） | → `.loading`，預渲染目標章前 8 頁 |
| 正常翻頁到下一章 | **不觸發 Gate**（已由背景預載完成） |

### UI 表現

- Gate `.loading`：閱讀器上方覆蓋半透明全屏 overlay，中央顯示 `ProgressView()`（系統 spinner）
- Gate `.open`：overlay 以 0.2s fade 消失
- **不顯示進度條、不顯示百分比**（與 iBooks 一致）

### 預渲染數量

- 初始預渲染：前 **8 頁**（約 0.5-0.7 秒完成）
- 背景繼續截圖：剩餘頁面（不影響閱讀）
- 跨章節翻頁：在用戶翻頁 **前 2 章**開始預渲染，Gate 通常不需要觸發

---

## 5. 數據流

```
用戶開書 / 跳章
    ↓
EPUBPageRenderer.navigateToChapter(N)
    ↓
ReadingGate → .loading
    ↓
EPUBSnapshotWebView.loadChapter(N)
    ↓
EPUBSnapshotWebView.capturePages(0..<8) [順序執行]
    ↓
每頁就緒 → PageSnapshotProvider.store(image, forPage: globalPage)
    ↓
8 頁全部就緒
    ↓
ReadingGate → .open（overlay fade out）
    ↓
背景繼續 EPUBSnapshotWebView.capturePages(8..<total)
```

---

## 6. 需要修改的文件

| 文件 | 變更類型 | 說明 |
|------|----------|------|
| `LiveWebReader.swift` | 重構 | 移除 snapshot 相關方法，改為調用 snapshotWebView；移除互斥鎖 |
| `EPUBPageRenderer.swift` | 新增 | 添加 `readingGate: ReadingGateState`（@Published），暴露給 SwiftUI |
| `ReaderView.swift` | 修改 | 監聽 `readingGate`，顯示/隱藏 spinner overlay |
| `SnapshotReaderView.swift` | 清理 | 移除之前的 workaround（currentPage != previousPage guard 可保留） |
| `PageSnapshotProvider.swift` | 小改 | 保留 DispatchQueue.main.async defer 修復（避免 SwiftUI publishing warning） |
| `EPUBSnapshotWebView.swift` | 新建 | 獨立截圖 WebView，含 waitForPageReady() |

---

## 7. 不在本次範圍內

- 磁盤 LRU 緩存（app 重啟後截圖持久化）
- CFI / DOM 位置映射
- 截圖分辨率自適應（Retina vs non-Retina）

---

## 8. 成功標準

- [ ] 開書後顯示 spinner，前 8 頁就緒後自動消失
- [ ] 跳章後顯示 spinner，前 8 頁就緒後自動消失
- [ ] 正常翻頁：永遠不出現空白頁
- [ ] 封面頁：不再白屏（img.onload 等待確保圖片渲染完成）
- [ ] 重複頁內容 bug：消失（獨立 WebView 無競爭）
- [ ] Gate 等待時間：< 1 秒（普通章節），< 1.5 秒（含圖片封面）
