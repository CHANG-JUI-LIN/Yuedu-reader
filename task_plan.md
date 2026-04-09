# Task Plan

## Goal
完成 UnifiedCoreTextEngine 路徑的核心整併：讓 TXT 與 EPUB/Online 共用 CoreText 引擎主幹，並以策略輸入分離內容組裝責任。

## Phases
- [x] Phase 1: 建立 AttributedStringBuilding 抽象與 TXT 策略（已完成）
- [x] Phase 2: CoreTextPageEngine 支援策略輸入（已完成）
- [x] Phase 3: TXT runtime 路徑切換到 CoreTextPageEngine（已完成）
- [x] Phase 4: ReaderView 移除 TXT 具體型別依賴（已完成）
- [x] Phase 5: 全量編譯驗證（已完成）
- [x] Phase 6: TXT Freeze Hotfix（背景解析 + 去重 parse，已完成）
- [x] Phase 7: TXT Lazy 索引/建構路徑（已完成）
- [x] Phase 8: Cover 跳章連環 reverse 動畫修補（已完成）
- [x] Phase 9: 翻頁樣式重建/`curl` 手勢/TXT 進度回捲修補（已完成）
- [x] Phase 10: Slide reverse dataSource 競態與 TXT ID 對齊修補（已完成）

## Errors Encountered
| Error | Attempts | Resolution |
|---|---:|---|
| None in this phase | 0 | N/A |

## Notes
- 目前 `TXTPageEngine` 仍保留為 legacy 類別（未在 runtime 路徑使用），後續可在下一輪移除。
- `ReaderView` 的 TXT 載入已改為 background queue 進行全文讀取與章節解析；主執行緒僅做 document/renderer 接線。
- `EPUBPageRenderer.loadTXT` 新增 `preparedChapters` 參數，搭配 `BookDocumentFactory.makeTXTDocument(book:chapters:)` 消除重複章節解析。
- 新增 `TXTChapterIndex` 與 `TXTLazyAttributedStringBuilder`，TXT 渲染改為「先索引、按章建字串」，不再預先物化 `UnifiedChapter.paragraphs` 全書資料。
- `CoreTextPageEngineView.updateUIViewController` 新增「僅相鄰頁可動畫」規則；非相鄰跳頁一律瞬切，避免 offset 重算導致的連環 reverse。
- `animateCoverTransition` 反向動畫加入 snapshot 缺失回退（瞬切），避免只出現陰影層的空動畫。
- `CoreTextPageEngineView.makeUIViewController` 初始頁改用 SwiftUI `currentPage`（非 `engine.currentPage`），修復切換翻頁樣式後跳回第一頁。
- `updateUIViewController` 的 reverse dataSource hack 加上 `pageTurnStyle != .curl` 保護，修復 `curl` 跳章後無法滑動。
- `applyInitialProgressIfNeeded` 加入引擎精準進度保護（`engine.currentPage > 0` 時不覆蓋），避免 TXT 進度被粗略百分比回捲。
- `updateUIViewController` 的 reverse hack 不再回填暫存 `savedDS`，改為動畫後在 slide 模式強制掛回 `context.coordinator`，避免快速連點造成 dataSource 永久掉線。
- `localEPUBBookIdentifier` 對 TXT 改回傳 `book.id.uuidString`，與 `loadTXT` 使用的進度 key 對齊，避免「存讀不同抽屜」導致每次開書回到章首附近。
