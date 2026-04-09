# Progress Log

## 2026-04-09 Session
- 新增 `AttributedStringBuilding.swift`。
- 新增 `TXTAttributedStringBuilder.swift`。
- 重構 `CoreTextPageEngine.swift`：
  - 新增 `attributedBuilder` 輸入初始化。
  - 新增章節抽象 helper（count/title/href/index）。
  - `preloadChapterInternal` 新增 builder 分支。
  - `start/scanChapterByteSizes/warmUpNext/rebuildPageOffsets/resolveInternalLink` 改為吃統一章節抽象。
- 修改 `EPUBPageRenderer.loadTXT` 改走 `CoreTextPageEngine(attributedBuilder:)`。
- 修改 `ReaderView` 移除 `TXTPageEngine` 型別依賴分支。
- 執行 `xcodebuild` 全量編譯：`BUILD SUCCEEDED`。

## 2026-04-09 Session (TXT Freeze Hotfix)
- 修改 `ReaderView.loadContent()` 的 TXT 分支：改為 background queue 讀取全文與章節解析，避免主執行緒同步重活。
- 修改 `EPUBPageRenderer.loadTXT(...)`：新增 `preparedChapters` 參數，允許外部注入預解析章節。
- 修改 `TXTBookDocument` / `BookDocumentFactory`：新增 `makeTXTDocument(book:chapters:)` 路徑，直接吃預解析章節。
- 目標達成：同一輪 TXT 開書流程中移除 Reader/Renderer 的重複 `parseUnifiedChapters`。
- 執行 `xcodebuild` 全量編譯：`BUILD SUCCEEDED`。

## 2026-04-09 Session (TXT Lazy Index Path)
- `TXTChapterParser` 新增 `TXTChapterIndex` 與 `parseChapterIndexes(...)`，可只建立章節目錄與內容範圍（NSRange）。
- 新增 `TXTLazyAttributedStringBuilder`（`AttributedStringBuilding`）：`buildChapter` 時才取章節範圍內容並切段落。
- `EPUBPageRenderer` 新增 `loadTXT(attributedBuilder:...)`，TXT 可直接以 lazy builder 啟動引擎。
- `TXTBookDocument` 新增 `chapterIndexes + text` 初始化路徑，TOC 可由索引生成，內容改為按章載入。
- `ReaderView` TXT 分支改接 `parseChapterIndexes + TXTLazyAttributedStringBuilder`，完成 lazy 路徑接線。
- 執行 `xcodebuild` 全量編譯：`BUILD SUCCEEDED`。

## 2026-04-09 Session (Cover Jump Animation Fix)
- 修正 `CoreTextPageEngineView.updateUIViewController(...)`：只有相鄰頁（差 1 頁）才允許動畫，非相鄰跳頁強制 `animated: false`。
- 修正 suppress transition 分支：改為消耗 flag 後立即瞬切到目標頁並同步 stable position，避免初始/重算狀態殘留。
- 修正 `animateCoverTransition` backward 分支：若目標 snapshot 缺失，直接瞬切並同步位置，避免陰影層空動畫。
- 執行 `xcodebuild` 全量編譯：`BUILD SUCCEEDED`。

## 2026-04-09 Session (Page Style/Curl/Progress Fix)
- 修正 `CoreTextPageEngineView.makeUIViewController` 初始頁來源：由 `engine.currentPage` 改為 SwiftUI binding `currentPage`，修復切換翻頁樣式後跳回第一頁。
- 修正 `updateUIViewController` reverse dataSource hack：加上 `pageTurnStyle != .curl` 條件，保留 `curl` 模式手勢 dataSource 連線。
- 修正 `applyInitialProgressIfNeeded`：若引擎已透過 CharOffsetStore 精準恢復到非零頁，直接採用該頁並中止 percentage 覆蓋。
- 修正 `TXTPageEngine.totalProgress(...)`：加入章節內字元比例，避免僅以章節序號估算造成粗糙進度。
- 執行 `xcodebuild` 全量編譯：`BUILD SUCCEEDED`。

## 2026-04-09 Session (Slide DS Race + TXT ID Alignment)
- 修正 `updateUIViewController` 的 reverse 動畫 dataSource 回復策略：移除 `savedDS` 回填，改為動畫完成後在 `.slide` 模式強制 `uiViewController.dataSource = context.coordinator`。
- 修正 `localEPUBBookIdentifier`：TXT 分支改回傳 `currentBook.id.uuidString`，與 `loadTXT` / `CharOffsetStore` key 保持一致。
- 影響：解決 slide 模式快速左點後上一頁永久失效，與 TXT 每次開書進度丟失回捲。
- 執行 `xcodebuild` 全量編譯：`BUILD SUCCEEDED`。
