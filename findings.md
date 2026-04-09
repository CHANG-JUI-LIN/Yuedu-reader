# Findings

## 2026-04-09
- `CoreTextPageEngine` 目前可同時支援兩種輸入：
  - `resourceProvider`（既有 EPUB/Online 路徑）
  - `attributedBuilder`（新策略路徑，先由 TXT 使用）
- TXT 的章節字串組裝責任已從引擎移到 `TXTAttributedStringBuilder`。
- `EPUBPageRenderer.loadTXT` 已改用 `CoreTextPageEngine(attributedBuilder:...)`，TXT 與 EPUB/Online 開始共用同一顆引擎主幹。
- `ReaderView` 已移除對 `TXTPageEngine` 的型別轉型依賴，維持對 `PageRenderingProvider` 抽象。
