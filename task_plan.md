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

## Errors Encountered
| Error | Attempts | Resolution |
|---|---:|---|
| None in this phase | 0 | N/A |

## Notes
- 目前 `TXTPageEngine` 仍保留為 legacy 類別（未在 runtime 路徑使用），後續可在下一輪移除。
- `ReaderView` 的 TXT 載入已改為 background queue 進行全文讀取與章節解析；主執行緒僅做 document/renderer 接線。
- `EPUBPageRenderer.loadTXT` 新增 `preparedChapters` 參數，搭配 `BookDocumentFactory.makeTXTDocument(book:chapters:)` 消除重複章節解析。
- 新增 `TXTChapterIndex` 與 `TXTLazyAttributedStringBuilder`，TXT 渲染改為「先索引、按章建字串」，不再預先物化 `UnifiedChapter.paragraphs` 全書資料。
