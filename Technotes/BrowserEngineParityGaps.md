# Browser layout engine — 與 legacy 的功能差距

**適用範圍**：橫排、可重排（reflowable）EPUB 的**分頁**模式。直排 `.verticalRL`、固定版面 `.prePaginated`、捲動模式本來就整條走 `CoreTextPageEngine` / `CoreTextScrollEngine`，不在此列。

**狀態（2026-09-08）**：依使用者回報，browserAuto 的翻頁與渲染仍有問題，EPUB 已全面撤回 legacy。`EPUBPageRenderer.load` 直接建立 `CoreTextPageEngine`；捲動與固定版面保留既有專用引擎。DEBUG／Release 的 `BrowserLayoutFeature.mode` 均固定為 `.legacy`，舊 `-browser-mode` 啟動參數不再切換引擎。Browser 實作與直接注入模式的測試保留，但不接入一般開書流程。以下記錄的是既有功能修補，不代表 browserAuto 已具備上線條件。

撤回路由回歸：`EPUBLegacyRoutingTests` 2、`BrowserLayoutFeatureTests` 1、`ReaderPresentationContractTests` 17、`ReaderRenderRefreshTests` 11，共 31/31 通過（2026-09-08，iOS 27 Simulator，序列執行）。結果：`/tmp/YueduEPUBLegacy-20260908-1.xcresult`；涵蓋 EPUB 解析／開書重開、legacy 章節文字與位置映射、捲動引擎啟動、翻頁契約及設定刷新。


---

## 已修（2026-09-07）

### 根因：`layouts` 是 **legacy paginator** 的字典

`BrowserLayoutPageEngine.layouts` 直接轉給 delegate，所以 browser 排的章節在裡面**永遠不存在**。reader 有 13 個地方拿 `engine.layouts[spine]` 當「這章排好了嗎／幾頁／章節文字」用，全部對 browser 章節得到「沒排版」。

修法：`StablePositionResolving` 新增三個查詢，預設實作讀 `layouts`（CoreText／TXT／固定版面照舊），`BrowserLayoutPageEngine` 覆寫成 per-chapter dispatch。

```swift
func chapterPagination(forSpine:charOffset:) -> ChapterPagination?   // nil = 沒排版
func chapterText(forSpine:) -> String?
func chapterAnchorOffsets(forSpine:) -> [String: Int]?
```

**以後判斷「這章排好了嗎」一律問 `chapterPagination`，不要再碰 `layouts`。**

一併修好的症狀：

| 症狀 | 位置 |
|---|---|
| 頁腳 `1/N` 空白 | `ReaderView+Footer.pageFooterInfo` |
| 「本章剩 N 頁」永遠 0 | `ReaderView+Toolbars.appleBooksPagesLeftText` |
| **閱讀進度完全不儲存**（`coreTextPositionIfLayoutReady` 恆 nil → `autoSaveProgress` 直接 return） | `ReaderView.coreTextPositionIfLayoutReady` |
| **聽書自動翻頁失效** | `ReaderView+SourceChange.followTTSPlaybackHighlight` |
| `preloadChapter` 排版成功仍回報 `.contentUnavailable` | `BrowserLayoutPageEngine.preloadChapter` |
| 目錄的 EPUB CFI 定位 | `ReaderView.tocCharOffset` |
| Media Overlay 朗讀高亮文字 | `ReaderView+SourceChange.currentMediaOverlayHighlightText` |
| 閱讀統計／剩餘時間／剩餘字數 | `contentMetrics` 走預設 nil |
| 聽書取不到章節文字（fallback 落到空的 `allPages`） | `narrationForTTSChapter` |
| 重新整理可以 commit 到還沒排版的章節 | `EPUBPageRenderer.hasPagedLayout` 的 browser 特例只問「選了哪個引擎」 |

### 本地章節設定刷新

- `invalidateLayout` 清除章節引擎選擇後，現在重新載入所有已路由的章節，包含 legacy 章節。之前只重載 browser 章節，會令 legacy 章節的頁碼與繪製查詢落到空的 browser 版面，造成粗體、氣泡等設定變更必須重開書才看得到。
- 回歸：`BrowserLayoutPageEngineTests.legacyChapterKeepsRoutingAcrossRelayout` 覆蓋重新排版後的路由、頁碼與章節版面可用性。

### 閱讀背景繪製

- `BrowserLayoutPageView.draw` 只 fill 一個純色，**從不畫閱讀背景圖**。現在跟 legacy 共用 `CoreTextPageView.drawPageBackground`（同一個 aspect-fill 幾何，所以跨引擎翻頁時圖不會跳）。
- 使用者選的背景圖**取代**書本自己的 `background-color` / `background-image`，跟 legacy 的 `readerBackgroundImage ?? pageBackgroundImage` 同一套優先序。靠 `DisplayListDrawer.draw(skipAuthoredBackgroundPaint:)` 實現；注入的畫布 fill 與 image 都帶 `isBackgroundPaint`。
- **換主題時 DisplayList 快取沒清**：快取只用 global page 當 key，文字顏色是排版時烘進去的，所以換夜間模式後目前這頁 ±2 頁還是舊顏色（黑字黑底）。`applyThemeChange` 現在會 `evictAllDisplayLists()`。
- `renderSnapshot`（捲頁背面、封面轉場）同樣補上背景圖。

### VoiceOver 與朗讀高亮

- browser 頁面對 VoiceOver 是**空的 UIView**（CoreText 直接畫進 `draw(_:)`，沒有子視圖可聚焦），跟 2026-07 那個盲人使用者回報的 legacy bug 一模一樣。現在補上 `accessibilityLabel`（整頁文字）、hint、四個 custom action、`accessibilityActivate`、`accessibilityScroll`，與 `CoreTextPageView` 同一份契約。
- `CoreTextPagedView.Coordinator` 的 `installAccessibilityActions` 與 `applyPlaybackHighlight` 原本只認 `CoreTextPageViewController`，加上 browser 分支。
- 新增 TTS 句子高亮（獨立 `CAShapeLayer`，不重畫整頁文字）。頁面靠 `pageSourceText` / `pageSourceRange` 在**本頁**範圍內找朗讀句，所以同一句在章節後面重複出現不會標錯段。

### 行距

`BrowserLayoutConfig.lineHeight` 從 `settings.lineHeightMultiple` 填進去，然後**沒有任何人讀它** → 行距滑桿完全無效。現在在 `ComputedStyleTreeBuilder` 的 root style 種成繼承的 `lineHeightMultiplier`（不是絕對長度：那才是 CSS unitless `line-height` 的語意，標題放大時會跟著縮放，而作者 CSS 的 `line-height` 仍然在宣告它的元素上勝出）。

---

## 六項功能缺口已補齊（2026-09-07）

| 原缺口 | 實作與回歸 |
|---|---|
| 選字、複製、搜尋、翻譯 | `BrowserTextInteractionController` 共用 `TextSelectionInteractor`，使用實際 shaped glyph 幾何；`UIEditMenuInteraction` 提供複製、重點、筆記、書內搜尋、替換及系統翻譯。拖曳柄使用 base 字元位置，避免 ruby 標音帶偏；emoji 和 RTL 有回歸。搜尋沿既有 ReaderBookSearchView 並帶入選取文字。原生翻譯 API 需 iOS 17.4+；17.0–17.3 不顯示不可用的系統動作。 |
| 筆記、劃線及圓圈 | 共用 `InteractionOverlayView`／`NoteMarkerOverlayView`，以 `(spineIndex, UTF-16 range)` 繪製、命中、送既有儲存/編輯請求。引擎弱引用追蹤可見頁，資料變更即更新；跨頁筆記只在起點顯示圓圈。VoiceOver 加選字操作。 |
| 行間距、段間距、字距、粗體 | `BrowserLayoutConfig` 傳入實際 layout；共用 ReaderFontCascade / UserReaderFontResolver。修正 Latin bold 主字型仍解析出 Regular CJK 的情況，保留真實字級。 |
| 正則高亮 | 共用 RegexHighlightEngine，支援跨 inline tag、ruby base、原有裝飾，保留原始 UTF-16 座標。DisplayList 不再丟棄 shaped attributes；規則修改、停用、外觀變更會在刷新交易內 await 重新排版。 |
| 內嵌影片 | 同一 DOM/style tree 產生 media registry，沿 replaced fragment 幾何掛 AVPlayerViewController，使用既有 EPUBVideoPlaybackManager。支援回頁重掛、VoiceOver，等待資源不強持有已離頁 coordinator。 |
| ruby 發音 | 瀏覽器章節保留 authored ruby/SSML hints；系統和 HTTP TTS 送出讀音，callback 和進度仍用原文 UTF-16。處理 emoji、chunk 邊界及續播；修正第 0 章殘留 legacy layout 把朗讀導到錯誤來源。 |

已執行的直接回歸：
- `BrowserTextInteractionTests`：5/5。
- 排版／字型／正則／既有引擎七類：35 方法、37 次執行全部通過。
- 媒體／發音／System TTS：29/29；最後生命週期修改後 `BrowserMediaPronunciationParityTests` 13/13。

字型缺少原生斜體 face 時，沿用既有 oblique 合成；沒有增加另一條 loader/cache，也沒有為上述功能切回 legacy。翻譯的系統版本限制如上，並非已在 iOS 17.0–17.3 驗證可用。

線上書源的氣泡/耗能問題走 CoreText 線上管線，另以全預設/完整主題、氣泡開關和書評互動量測；不可用以上 EPUB 回歸推論它已解決。

---

## 相關

- `Technotes/ReaderPagingContract.md` — `positionAfter/Before` 目前對 browser engine 只是「時序上安全」，還沒有真實實作
- `docs/coretext/rendering-pipeline.md`
