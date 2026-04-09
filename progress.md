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
