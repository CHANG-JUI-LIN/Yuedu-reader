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
- cover 跳章回歸發現：offset/總頁重算觸發非相鄰頁更新時，若仍套用 reverse 動畫會造成連環回跳；必須將非相鄰頁更新視為「坐標瞬切」。
- cover backward 動畫若缺 snapshot，會只剩陰影層；需回退為瞬切以維持視覺完整性與頁位正確。
- 翻頁樣式切換重建問題：`makeUIViewController` 若採 `engine.currentPage` 作初始頁，在 binding 與引擎座標不同步時會回退到過時頁碼；改用 SwiftUI `currentPage` 可避免重建跳頁錯位。
- `curl` 模式手勢依賴 `dataSource`，reverse hack 僅適用 `.scroll`；在 `curl` 套用同 hack 會導致跳章後只能點擊、無法滑動。
- TXT 進度回捲根因是精準 CharOffset 恢復被粗糙 percentage 二次覆蓋；需在 `applyInitialProgressIfNeeded` 優先保護 `engine.currentPage > 0` 的精準狀態。
- slide 模式快速連點回上一頁時，若 reverse hack 依賴暫存 `savedDS`，可能捕獲到 `nil` 並永久回填 `nil`，導致 dataSource 失效；應直接回填 coordinator。
- TXT 進度遺失根因之一是 key 不一致：`loadTXT` 使用 `book.id.uuidString`，但 auto-save 使用 `coretext-<uuid>`；需統一為同一 key。
