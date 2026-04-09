# Findings

## 2026-04-09
- `CoreTextPageEngine` 目前可同時支援兩種輸入：
  - `resourceProvider`（既有 EPUB/Online 路徑）
  - `attributedBuilder`（新策略路徑，先由 TXT 使用）
- TXT 的章節字串組裝責任已從引擎移到 `TXTAttributedStringBuilder`。
- `EPUBPageRenderer.loadTXT` 已改用 `CoreTextPageEngine(attributedBuilder:...)`，TXT 與 EPUB/Online 開始共用同一顆引擎主幹。
- `ReaderView` 已移除對 `TXTPageEngine` 的型別轉型依賴，維持對 `PageRenderingProvider` 抽象。
- TXT 開書的第一段重活（全文讀取 + 章節解析）已搬離主執行緒，先行降低大檔開書 freeze 風險。
- 透過 `preparedChapters` + `makeTXTDocument(book:chapters:)`，同一輪載入不再重複解析章節，避免額外 CPU 與記憶體峰值。
- 新增 `TXTChapterIndex` + `parseChapterIndexes(...)` 後，TXT 可先建立目錄索引，再於 `buildChapter` 按章載入內容。
- `TXTLazyAttributedStringBuilder` 已接入 renderer，TXT 主要路徑不再預先展開全書 `paragraphs` 陣列。
