# Yuedu Reader 閱讀器架構優化書

## 1. 現狀架構

### 翻頁管線資料流

```
┌─────────────────────────────────────────────────────────────────┐
│                        ReaderView.swift                         │
│  @State currentPage, externalTargetPosition, readerSessionCoord │
│  @StateObject epubRenderer, readerViewModel, ttsCoordinator     │
└────────┬──────────────────────────────────────────┬──────────────┘
         │ @Binding currentPage                      │ sessionCoordinator
         ▼                                          ▼
┌──────────────────────────────┐   ┌──────────────────────────────┐
│   CoreTextPageEngineView     │   │   ReaderSessionCoordinator   │
│   (UIViewControllerRep)      │   │   @ObservableObject          │
│   updateUIViewController()   │   │   FSM + TransitionQueue      │
│   是 SwiftUI 調和器 +         │   │   isPageTransitioning        │
│   也是轉場執行器               │   │   externalTargetPosition     │
└────────┬─────────────────────┘   └────────┬─────────────────────┘
         │ Coordinator                      │ send(action)
         ▼                                  ▼
┌──────────────────────────────┐   ┌──────────────────────────────┐
│   Coordinator (NSObject)     │   │   ReaderPageTransitionQueue   │
│   curlTransitionPhase        │   │   isTransitioning: Bool      │
│   suppressNextTransition     │   │   queuedPage: Int?           │
│   isTransitioning            │   │                               │
│   externalTargetPosition     │   │   沒有逾時自癒機制             │
│   pendingNavigation          │   └──────────────────────────────┘
│   currentCoreTextPosition    │
│   8+ setViewControllers 入口  │
│   4 套頁面位置事實             │
└──────────────────────────────┘
```

### 狀態擁有者清單

| 變數／入口 | 型別 | 位置 | 角色 |
|---|---|---|---|
| `ReaderView.currentPage` | `@State Int` | `ReaderView.swift:48` | SwiftUI 主綁定 |
| `Coordinator.currentPage` | `var Int` | `CoreTextPagedView.swift:240` | Coordinator 拷貝 |
| `externalTargetPosition` | `CoreTextReadingPosition?` | `CoreTextPagedView.swift` (`Coordinator`) + `ReaderSessionCoordinator.swift:48` | 定位指令 |
| `suppressNextTransition` | `Bool` | `CoreTextPagedView.swift:301` | 一次性抑制 |
| `pendingNavigation` | `PendingNavigation?` | `CoreTextPagedView.swift:303` | 排隊跳轉 |
| `curlTransitionPhase` | `CurlTransitionPhase` enum | `CoreTextPagedView.swift:308` | curl 相位 |
| `isPageTransitioning` | `ReaderPageTransitionQueue` | `ReaderPageTransitionQueue.swift:8` | FSM 轉場鎖 |
| `ReaderSessionState.currentLocation` | `CoreTextReadingPosition` | `ReaderSessionState` (navigator) | 持久化位置 |

### 四套互相糾正的「目前在哪頁」

1. **SwiftUI binding** `currentPage` — ReaderView.swift
2. **PVC 可見頁** `pvc.viewControllers?.first?.globalPageIndex` — PVC 實際渲染
3. **外部定位** `externalTargetPosition` — ReaderSessionCoordinator
4. **Coordinator 內部快照** `currentCoreTextPosition` + `syncStablePosition`

任何一方寫入過期值 → 觸發「糾正」轉場 → 回報又觸發反向糾正 → 乒乓震盪。

---

## 2. 症狀 → 根因

### 症狀 1：curl 翻頁來回震盪

**現象**：翻一頁後 PVC 自動彈回原頁，或連續來回跳。

**根因**：`updateUIViewController`（`CoreTextPagedView.swift:93-222`）是一個**雙向調和器**，同時處理 four sources 的差異。當 `externalTargetPosition` 未被一次性清除（`:160-168` 註解「curl animates then bounces back」已有記載），或 `suppressNextTransition` 過期後 `currentPage` 與 PVC 可見頁不一致，調和器發起糾正轉場 → PVC didFinishAnimating 回報 → binding 更新 → 再觸發另一方向糾正。來回反覆進入震盪。

**觸發序列**：
1. scroll→paged 切換：`externalTargetPosition` 設為 scroll 模式位置
2. `updateUIViewController` 看到差異 → `setViewControllers` 往 target 跳
3. PVC didFinishAnimating → `syncStablePosition` → 寫回 `currentPage`
4. 如果此時 target 已被清除但 `currentPage` 正值與 PVC 不一致 → 下一次 update 又跳回去

已在 `:160-168` 為 scroll→paged 單一入口補了一次性清除機制，但 theme 變更（`:118-129`）、spread 變更（`:110-116`）、chapter-ready 重設棧（`:693`）等共 **8+ 個 `setViewControllers` 寫入點**都有相同模式。

### 症狀 2：有動畫但畫面不刷新

**現象**：curl 翻頁動畫正常播完，但畫面停在舊內容。

**根因**：`curlTransitionPhase`（`CoreTextPagedView.swift:308`）是單層 enum（`.idle` / `.animating(deferredChapterReady:)`）。`willTransitionTo`（`:1123-1129`）**無條件覆寫**設為 begin，`didFinishAnimating`（`:1139-1141`）**無條件**清為 idle。

pageCurl 快速連續翻頁時 delegate 交錯（begin#2 先於 finish#1）→ 相位錯亂：
- `deferChapterReadyIfCurlIsAnimating`（`:358-368`）檢查相位時看到 `.animating(deferredChapterReady:false)` → 設定 deferred flag → finish#1 清成 idle → deferred flag 遺失
- chapter-ready 應該延遲時沒延遲（動畫中重設棧導致畫面錯亂），或延遲後標記遺失 → 永遠不重播（`:380-382`）

疊加：curl 模式下禁止替換快照頁（`:1159-1162` 註明會弄壞 curl 內部狀態）→ curl 落在 `SnapshotPageViewController` 時螢幕上是靜態截圖，全靠 deferred chapter-ready 換真頁；deferral 一漏 = 有動畫但畫面永遠不刷新。

### 症狀 3：翻頁卡死，換動畫才好

**現象**：翻到一半完全無法操作，改 PageTurnStyle（curl→slide）或殺 App 才恢復。

**根因**：`ReaderSessionCoordinator` 的 FSM + `ReaderPageTransitionQueue` 的 `isTransitioning` flag，只靠 completion / `didFinishAnimating` 觸發 `.pageTransitionSettled` 來解除。

UIPageViewController pageCurl 在以下序列下會**丟掉 delegate / completion**：
- 取消手勢 + 立刻再抓
- 動畫中 (`isTransitioning = true`) `setViewControllers`（`ProgrammaticPageTransitionPerformer.swift` 全篇在繞這些怪癖：1 元素棧 curl SIGABRT 降級、`_UIQueuingScrollView` NSInternalInconsistencyException 的 async 雙重 set、dataSource 摘除/恢復）
- 快照替換與 curl 內部狀態衝突（`:1159-1162`）

settle 一丟 → FSM 永久 `isTransitioning = true` → 後續翻頁請求全被 `requestTransition` 回傳 `.ignore` 或 `.defer` = 卡死。**換翻頁動畫** = 重建 PVC 與 Coordinator = `reset()` 旗標歸零。**無任何 watchdog 自癒機制**。

### 症狀 4：滑動模式掉幀

**現象**：複雜 EPUB 下滾動不流暢。

**根因**：`CoreTextChunkCell.swift` 的 `draw(_:)` 在**主執行緒同步**做：
- CTFrameDraw + `drawBlockRenderables`（CSS 盒繪製）+ inline annotations + `attachment.image.draw`
- 首繪可能觸發主執行緒圖片解碼
- `contentMode = .redraw`（`:12`）任何 bounds 變化全部重繪

複雜 EPUB 單格渲染 >8ms（120Hz 預算 8.3ms）即掉幀。排版（chunk slicing）已在背景（`CoreTextScrollEngine.swift:186,242` `Task.detached` + warmChunks 預熱半徑 6），但點陣化未背景化。

---

## 3. Readium 架構對照

本專案已使用 ReadiumShared / ReadiumStreamer（僅 EPUB 解析層），未使用其 Navigator 組件。

### Readium Navigator 核心設計

```
Publication (manifest + resources)
    │
    ▼
Navigator (單一導航擁有者)
    │  go(to: Locator, animated:)  — 唯一程式入口
    │  handleUserInteraction()     — 手勢作為 intent 上報
    │  ▸ events (didMoveToLocator) — 單向事件流出
    ▼
UIViewController / SwiftUI View (被動觀察者)
```

**關鍵差異**：

| Readium Navigator | 現有 Yuedu 翻頁管線 |
|---|---|
| 單一 `go(to:)` 入口 | 8+ `setViewControllers` 寫入點 + 多個 `currentPage` 直接賦值 |
| Navigator 是位置唯一擁有者 | 四套「目前在哪頁」互相糾正 |
| Locator 為正式化位置型別 | `CoreTextReadingPosition(spineIndex, charOffset)` 已同構但未正式化 |
| 事件單向流出（didMoveToLocator） | `onPageChanged` / `syncStablePosition` 雙向回寫 |
| 預載窗口由 Navigator 管理 | warmUp 分散在 engine / coordinator |
| WKWebView 渲染 | CoreText 自繪 |

### 不適用部分

Readium Navigator 基於 WKWebView 分頁渲染，與本專案 CoreText 自繪路線無法共用實作。這裡只借其**邊界劃分**與**狀態擁有權模型**，不借渲染實作。

### 本專案已同構的部分

`CoreTextReadingPosition(spineIndex, charOffset)` — 與 Readium `Locator` 概念對應（資源識別 + 偏移量），只需要正式化為 protocol 並賦予對應的相等 / 雜湊實作即可成為 Navigator 的核心型別。

---

## 4. 目標架構

### ReaderNavigator

```
@MainActor @Observable
class ReaderNavigator {
    // 單一事實來源
    private(set) var currentLocation: CoreTextReadingPosition
    private(set) var inFlightTransition: TransitionToken?
    private var pendingTarget: CoreTextReadingPosition?
    private var transitionCount = 0
    private var transitionStartTime: CFAbsoluteTime = 0

    // 意圖 API（外部呼叫的唯一路徑）
    func go(to: CoreTextReadingPosition, animated: Bool)
    func turnPage(_ direction: PageDirection)
    func handleGestureWillBegin()
    func handleGestureSettled(page: CoreTextReadingPosition)

    // 內部
    private func settle(by token: TransitionToken)
    private func watchdogTimedOut(_ token: TransitionToken)
}
```

### 轉場 token 生命週期

```
token = issueToken()      // 每次轉場一個新 token
transitionCount += 1      // 計數取代單層布林
transitionStartTime = now // watchdog 起算

settle(token):            // completion / delegate 正常路徑
    guard token == currentToken else { return } // 過期 token 忽略
    transitionCount = max(0, transitionCount - 1)
    guard transitionCount == 0 else { return }  // 巢狀轉場中，不提早 settle
    publishLocation()
    pendingTarget = nil

watchdog(token):          // 逾時 ~2.5s 強制 settle
    if now - transitionStartTime > 2.5 {
        transitionCount = 0
        settle(token)
        AppLogger.render("⟐ pageTurn watchdog token=\(token.id)")
    }
```

**核心改善**：
- token 配對 → 交錯序列（begin#2 在 finish#1 之前）不再錯亂
- watchdog → completion 被吞時 2.5 秒自癒
- 計數取代布林 → 巢狀轉場不再遺失相位標記
- `curlTransitionPhase` 整個被 `transitionCount` + `hasDeferredChapterReady` 取代

### updateUIViewController 降級為純執行器

```
// 目標寫法（非本階段實作，是路線圖階段 2 目標）
func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
    // 不再讀取 currentPage / externalTargetPosition
    // 不再主動發起糾正轉場
    // 只負責將 Navigator 的 currentLocation → PVC 位置
    context.executor.render(navigator.currentLocation, on: pvc)
}
```

### 滑動管線目標

```
背景序列：
  layout 文字 (Task.detached) → 已實作 ✓
  UIGraphicsImageRenderer 離屏點陣化 → 新 add
  attachment.image.byPreparingForDisplay() → 預解碼
  CALayer.contents = cgImage → 去掉 .redraw

參考：SVGWebViewRasterizer 現有的並行池模式
```

---

## 5. 遷移路線圖

### 階段 0：止血（當前可做，小 diff）

**目標**：消除症狀 2/3 的死鎖態，不需大重構。

1. **curl 相位計數化**（`CoreTextPagedView.swift`）：
   - `curlTransitionPhase` 單層 enum → `activeCurlTransitionCount: Int` + `hasDeferredChapterReady: Bool`
   - `willTransitionTo` / `beginCurlTransitionIfNeeded` → count += 1
   - `didFinishAnimating` / programmatic completion → count = max(0, count-1)，歸零時重播 deferred
   - 交錯序列下 deferred 標記不再遺失

2. **轉場 settle watchdog**（`ReaderSessionCoordinator.swift` + `ReaderPageTransitionQueue.swift`）：
   - 轉場開始記錄時間戳
   - 逾時 ~2.5s 強制 settle + 重設 transitioning flag
   - `AppLogger.render("⟐ pageTurn watchdog")` 診斷

3. **`[CurlTrace]`/`[FlipTrace]` print → AppLogger.render**（`CoreTextPagedView.swift`）

4. **externalTargetPosition 殘留入口清理**（theme/spread 變更分支一次性化）

**風險**：低。沒有行為變更，只加逾時保護與計數器。

**驗證**：連續快速 curl 翻頁 50 次、curl 中途取消再抓、TOC 跳章。

### 階段 1：抽出 ReaderNavigator

**目標**：收斂「目前在哪頁」的四個擁有者為單一事實來源。

**改動**：
- 新檔 `Modules/Core/ReaderCore/ReaderNavigator.swift`（@Observable @MainActor）
- 持有 `currentLocation`、`inFlightTransition`、pending 目標
- 意圖 API：`go(to:)`、`turnPage(_:)`、`handleGestureWillBegin()`、`handleGestureSettled(page:)`
- 收編 `currentPage` binding 寫回、`externalTargetPosition`、`suppressNextTransition`、`pendingNavigation`
- `updateUIViewController` 保持行為，讀取來源換成 Navigator
- TTS 跟讀翻頁、位置恢復路徑改走 `go(to:)`

**風險**：中。diff 較大，需完整手動迴歸。

**驗證清單**：
- 連續快速 curl 翻頁 50 次
- curl 拖到一半取消再立刻抓
- 快速翻到未載入章節（快照/佔位頁）等 chapter-ready
- TTS 跟讀自動翻頁
- TOC 跳章
- scroll↔paged 來回切換
- slide / cover / none 各模式回歸
- `CoreTextWritingModeTests`

### 階段 2：updateUIViewController 降級 + 寫入點收斂

**目標**：8+ 個 `setViewControllers` 寫入點降到 2 個（初始設定 + Navigator 驅動）。

**改動**：
- `updateUIViewController` 不再讀 `currentPage` / `externalTargetPosition`，只聽 Navigator 事件
- Coordinator 移除 `suppressNextTransition` / `pendingNavigation` / `externalTargetPosition`
- 所有 setViewControllers 寫入點收到 `Coordinator.setPage(_:)` 單一方法

**風險**：中高。需確保不引入回歸。

### 階段 3：滑動預點陣化 + 圖片預解碼

**目標**：消滅主執行緒點陣化掉幀。

**改動**：
- `CoreTextChunkCell` 的 `draw(_:)` → 背景 `UIGraphicsImageRenderer` 產 CGImage
- `CALayer.contents = cgImage`
- `contentMode = .redraw` 改為 `.bottom`（只對內容變化重繪）
- `attachment.image.byPreparingForDisplay()` 預解碼
- 參考 `SVGWebViewRasterizer` 並行池模式

**風險**：中。記憶體用量上升（快取點陣圖），需 LRU 淘汰。

---

## 6. 附錄

### 閱讀器死代碼清單（已清理）

以下檔案已在 2026-07-03 重構中刪除（對應 cleanup commit `4f41e19`）：

| 檔案 | 行數 | 原因 |
|---|---|---|
| `VideoPlayerView.swift` | ~100 | EPUB 影片已改 inline 方案 |
| `FontSettingsView.swift` | ~200 | 字體設定已整合至 ReaderSettingsView |
| `ReaderPageProvider.swift` | 204 | 協議唯一使用者是死的 adapter |
| `CoreTextScrollProgressThrottle.swift` | ~40 | 僅測試引用 |
| `BookshelfSearchFilter.swift` | ~40 | 僅測試引用 |
| `LoginUiBuilder.swift` | ~60 | 生產登入已改走 LoginUIField.parse |
| `CoreTextChapterEndPlaceholderTests.swift` | 126 | 只測死掉的 LegacyCoreTextPageProvider |
| `BookshelfSearchTests.swift` | ~30 | 只測死掉的 BookshelfSearchFilter |

### 層級歸位（同 commit `5f8338e`）

| 原來位置 | 新位置 |
|---|---|
| `Core/ReaderCore/AutoReadController.swift` | `Features/Reader/` |
| `Core/ReaderCore/CoreText/FootnotePopover.swift` | `Features/Reader/` |
| `Core/ReaderCore/ReaderPagingAdapter.swift` | → `Features/Reader/ReaderCoverPageMotion.swift`（改名） |
| `ReaderPageTypes.swift` 中 3 個 PreferenceKey | 抽出 `Features/Reader/ReaderPreferenceKeys.swift` |

### print()→AppLogger（同 commit `fbb58f2`）

轉換 52 處裸 `print()` 為 `AppLogger.render/parse/cache`。

### ReaderView.swift 拆分（同 commit `749cb7d`）

3,922 行 → 主檔 1,745 行 + 9 個新檔（`ReaderFootnotePopup.swift`、`ReaderDownloadOptionsView.swift`、7 個 `ReaderView+*.swift` extension）。
