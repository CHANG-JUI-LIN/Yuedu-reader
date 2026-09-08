# TXT 章節誤判與位置遷移修復

日期：2026-09-08。範圍：本機 TXT；不修改 EPUB、Lexbor、CoreText layout 或翻頁幾何。

## 根因與判定修正

大型檔案路徑選定「第 X 章」後，仍無條件加入「第 X 卷／篇／部」命中，
把正文中的功法分類和「第幾部分」誤當章節。一般字串路徑則沒有同樣的合併。
此外，512 KB 後鎖定候選格式會忽略後段才出現的主章節格式。

現在兩種輸入共用逐行掃描與候選選擇。字串以 UTF-16 adapter 保留 NSRange
座標，檔案保留 encoded byte range；不再提前凍結其他候選。
主格式仍保留短章、空章與以「篇」為主的書。次級卷／篇目前須緊接主章節
（中間只有空白）才提升為結構標題，不推測含介紹正文的次級卷。
被拒絕的候選留在原章正文，沒有刪文或書名、檔名特判。

## 既有資料遷移

- cache generation 5 → 6；新索引不能直接覆蓋舊索引。
- `TXTReaderPreparationService` 只準備與建構候選索引。
- `TXTReaderIndexMigrationService` 統一負責保存書籤、位置與新索引。
- 用原文 byte range 決定目的章，再驗證實際 renderer 文字與 UTF-16 偏移。
  沒有把 `charOffset` 加到 byte offset，也沒有全書搜尋相同句子猜位置。
- 書籤／畫線保留 UUID、種類、註記、節錄、日期與樣式；範圍端點分別遷移。
- 先完整計算目標，再寫入可恢復 journal。中途終止後重播絕對目標，
  不再次套用章號轉換。所有目標寫入成功後才清理 journal。
- 預覽／遷移失敗時不允許保存暫時章號；Markdown 共用 TXT renderer 的路徑
  在自己的索引準備完成後放行，不進 TXT 遷移。

### 安全限制

目前自動遷移要求可驗證的 v5 索引及相同檔案身分。若舊索引遺失或版本未知、
檔案已變更、文字轉換破壞原文對應，會保留原資料並停止發布新索引。
原生三語提示要求保留原始 TXT、匯出診斷，不清空位置或書籤。
本修復不是跨裝置位置版本協定，也不猜測遺失的歷史 renderer 設定。

## 真實檔案結果

`聚宝仙盆 (1).txt`：13,718,857 bytes，UTF-8。

- 修正前 1,981 項；修正後 1,967 項（前言 + 1,966 個章節）。
- 排除的 14 個次級命中均位於正文的功法／書籍／部分介紹。
- 「第一篇：人仙篇！」與「第二篇：地仙篇。」留在「第1005章 美人面」。
- 下一章直接為「第1006章 青玄仙人」。

實際 v5 範圍與 production renderer 的遷移驗證（index 從 0 開始）：

| 原位置 | 新位置 |
|---|---|
| `(1014, 1648)` | `(1005, 1648)` |
| `(1015, 0)` | `(1005, 1650)` |
| `(1016, 0)` | `(1005, 1659)` |

這三個位置現在屬於同一個完整章節，後兩個位置仍落在對應原文。

## 驗證

模擬器：iPhone 17 Pro Max，iOS 27.0；由 `scripts/sim.sh` 動態選取。
沿用既有 DerivedData、關閉平行測試。

最終 **33 tests / 8 suites 通過**：

- `TXTChapterBoundaryTests`
- `TXTFileReaderTests`
- `TXTLocationMigrationTests`
- `TXTReaderIndexMigrationTests`
- `TXTScrollJumpDiagnosticTests`
- `TXTInitialPreviewPlannerTests`
- `BookmarkStablePositionTests`
- `BookStoreMetadataWriteBudgetTests`

涵蓋 UTF-8／UTF-16、Big5／GB18030 既有測試、合法卷章、空章、篇格式、
512 KB 後才出現的主章節、真實 corpus、標註範圍、首次匯入、缺失／不符索引、
位置寫入失敗及清理 journal 前中斷的重開情境。

根因測試先出現 13 個 assertion failures；晚出現主章節測試先出現 2 個
assertion failures，再驗證修正。未重錄 golden。

最後測試輸出：`/tmp/yuedu-txt-final-check.log`。
三語字串檢查：3 files / 2,305 keys 通過；`git diff --check` 通過。
這是程式碼與模擬器自動化測試驗證，不冒稱真機操作或錯誤提示視覺驗收。
