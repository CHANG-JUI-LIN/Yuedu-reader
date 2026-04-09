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
