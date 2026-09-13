---
title: BrowserLayout 目前狀態與下一步
updated: 2026-09-12
phase: 5A
status: 進行中，未結案
tags: [yuedu, browser-layout, status]
---

# BrowserLayout 目前狀態與下一步

[文件首頁](../README.md) · [歷史台帳](PHASES.md) · [5A 設計](../superpowers/specs/2026-09-04-lexbor-css-frontend-production-migration-design.md) · [5A 計畫](../superpowers/plans/2026-09-04-lexbor-css-frontend-production-migration.md)

## 現在的位置

2026-09-12：BrowserLayout 已抽取至 `YueduCoreText` 並發布 **0.3.0**；Reader 正常 project 已通過 GitHub 遠端套件接線驗證；翻頁與橫排捲動使用同一套件核心，App 保留 BrowserAuto 政策、legacy 與閱讀宿主。[抽取範圍](extraction/STATUS.md) · [0.3.0 發布驗證與 CI 已知問題](extraction/release-0.3.0.md)。以下 Phase 5A 記錄保留原有驗收範圍，本次沒有切換 Lexbor。

2026-09-12 後續（套件已發布 0.4.0）：Reader 已將 `writingMode` 接入套件能力掃描與排版設定；基礎 `vertical-rl` 的翻頁與捲動共用 BrowserAuto 決策，直排連續文件由右至左分成繪製視窗，交給既有 RTL collection 宿主。直排圖片、float 等套件仍不支援的內容保留按章 legacy fallback。正常 `Yuedu-Reader.xcodeproj` 最低依賴版本已更新為 0.4.0（限制於 0.4.x）；0.3.0 缺少 `documentPoint(forCharOffset:)`，不能用於此入口。[0.4.0 發布與正常 project 驗證](extraction/release-0.4.0.md)。下方歷史驗收範圍不回寫。

**Phase 5A 仍未結案。Task 5／6 已補齊本輪發現的差距；Task 7 長屬性映射已實作，完整驗收仍有阻擋。**

2026-09-08 實作與測試起點為 `b06801ded952625cb33c57274765327603476abb`，已帶回主工作目錄（整合起點 `3016d1d36f03062761b1eca96eacec5f95f74e87`）。本輪未 commit。使用者已選擇先完成可驗證的長屬性，shorthand 明確保留為切換阻擋。

[本輪實作與驗證報告](lexbor-migration/task5-7-longhand-report.md) · [機器可讀測試摘要](lexbor-migration/task5-7-verification.json)

| 項目 | 本次核對結果 | 證據 |
|---|---|---|
| 歷史橫排基線 | 曾結案；不能直接當作今日 HEAD 的測試結果 | [closure 報告](line-break-baseline/closure-2026-08-31.md)，`b674e672` |
| 產品 layout engine | 依使用者要求，正常 EPUB 橫排翻頁與捲動均啟用 BrowserAuto，接受的章節使用 Browser 排版 | [翻頁／捲動與原書驗證](reported-layout/2026-09-09-browser-scroll-inline.md) |
| BrowserLayout 的 CSS frontend | 現有文件建構入口預設 `LegacyCSSFrontend`（Current 相容前端），尚無 Lexbor production cutover 證據 | `BrowserLayoutDocument.swift`；勿將此名稱與 Legacy 排版器混淆 |
| Task 1–3：基線、vendoring、owner | 已有產物與提交，驗收仍依各自報告範圍 | [pre-integration.json](lexbor-migration/pre-integration.json)；`d13ef94f`、`f7e3d1f4`、`e8dd5ac5` |
| Task 4：DOM-neutral Current | 有實作及 parity 測試 | `afb051dd`；`CurrentCSSFrontendNeutralDOMParityTests` |
| Task 5：typed stylesheet ingestion | 已修正載入失敗仍列 active；合法空 sheet 保留，相關回歸通過 | `BrowserLayoutStylesheetIngestionTests`；本輪報告 |
| Task 6：DOM／cascade snapshot | 已補 winner／source、mixed order、完整 path、錯誤傳播與 owner 生命週期驗證；尚非完整差異 gate | `CLexborSmokeTests`、`LexborCSSFrontendSyntheticTests`、`LexborCSSFrontendLifetimeTests` |
| Task 7：ComputedStyle mapping | `LexborComputedStyleAdapter` 與 coverage tests 已實作；長屬性子集通過，shorthand／上游 parser／模型缺口會阻擋 layout | `LexborCSSFrontend` 已實作 `CSSFrontend`；本輪報告 |
| Task 8–13：共享 evaluation、切換、差異與 cutover | 未結案；完整 scanner 接線與正式切換尚未啟動 | `BrowserLayoutPageEngine.swift`；原 5A 計畫 |

目前通用引擎位於相鄰 `YueduCoreText/Sources/YueduCoreText/`，Reader adapters 仍位於 `Modules/Core/ReaderCore/BrowserLayout/`；Lexbor 實驗實作位於測試 target 的 `ExperimentalFrontend/`。`EPUBPageRenderer.swift` 在上一層，測試在 `Tests/iOS/yuedu appTests/`，C bridge 在 `Packages/CLexbor/`。它們在 vault 外，因此保留可搜尋的檔名與 commit，不建立 vault 內的空白筆記。

## 本輪驗證與下一個工作單位

- [x] Task 5／6 初始回歸並定位失敗；補齊本輪 snapshot／ingestion 差距。
- [x] Task 7 可表示的長屬性映射與明確 gap；9 類 focused tests：76 個方法／106 次執行通過，無失敗或跳過。C package：19／19 通過。
- [x] 保存擴大回歸與未修改 HEAD 對照：紅樓夢斷行基線的 271 章差異逐字相同，沒有修改 golden。
- [x] 主工作目錄三類整合回歸：Lexbor synthetic、Current parity、真實 EPUB 圖片，16／16 通過，無跳過。
- [x] 2026-09-09 完成紅樓夢 458 章三方比較：187 章一致、30 章僅近期程式差異、241 章與歷史重跑差異重疊；[詳細歸因報告](line-break-baseline/attribution-2026-09-09.md)。
- [x] 找到並修正獨立的片段量寬錯誤：DOM 片段單獨 shaping 丟失字偶距，改用整行保留的 glyph run；新增 4 個測試方法／9 次執行通過。全書 458 章頁數與片段數不變，163 章 geometry fingerprint 改變，修正後對舊 golden 共 272 章不同。
- [x] 主目錄片段量寬修正的整合回歸：8 類／50 個方法通過，0 failed／0 skipped。首次建置遇到的 AutoReadController 重複宣告已由另一邊修改解除，本輪未改動自動閱讀程式碼。
- [x] 使用者截圖的指定章節路由診斷：紅樓夢畫冊（spine 4）在 Auto 選 Browser，但漏畫行內紫色背景，白字標題不可見；全能遊戲設計師第 2 章（spine 10）因定位／Flex 整章回退 Legacy。[診斷與實際圖片](reported-layout/2026-09-09.md)。此為啟用前診斷；正常 EPUB 翻頁入口現已啟用 BrowserAuto。
- [x] 確認翻頁／捲動尚未全面收斂；以捲動為視覺基準重現並修正橫排裝飾被翻頁重新置頂的分歧，另修正 EPUB 非同步建立引擎時漏綁頁眉頁腳。[畫面與驗證範圍](reported-layout/2026-09-09-paged-scroll.md)。
- [x] 第一回扉頁路由追查並啟用：修正前正常入口未執行 Auto；現已由正式入口啟用 BrowserAuto，接受此章並按 `15em` 排版。[原書路由與 CSS 證據](reported-layout/2026-09-09-title-page-routing.md)。
- [x] 正常 EPUB 橫排捲動已接 BrowserAuto，與翻頁共用章節決策及 Browser 排版；畫冊行內紫底／padding 與正文預設兩端對齊已修正。12 類、121 項相關回歸通過，0 failed／0 skipped；[原書畫面與驗證範圍](reported-layout/2026-09-09-browser-scroll-inline.md)。
- [ ] **下一步：定位／Flex 等 Auto 能力缺口及原書驗收。** 被能力判斷拒絕的章節仍使用 Legacy；直排捲動仍使用既有 RTL 宿主。不能將本輪橫排接線與行內修正稱為全部 CSS 或全部閱讀模式已收斂。
- [ ] 完成歷史重跑對 golden 的 241 章歸因。已完成 458 章字型／行距還原控制、glyph advance 與段落上下文檢查；片段量寬修正尚未解釋這批歷史差異。原 golden 保留。
- [ ] 解除 Lexbor 3.0.0 shorthand 展開缺口、合法 `clear: both` 被 parser 拒收及其他模型／語法限制，再依 Task 8–13 推進共用 evaluation 與差異驗證。

本輪長屬性測試通過不代表完整 Phase 5A 驗收通過；既有 golden gate 仍失敗，因此尚未結案。Lexbor CSS frontend 的 production 切換依原 Task 13 gate 獨立決定；這不等於 Browser 排版引擎的啟用開關。

## 後續候選

| 順序 | 候選 | 啟動條件 |
|---|---|---|
| 1 | 完成 5A Task 8–13：共用 evaluation、DEBUG 切換、差異驗證與 cutover 決策 | 前面的語義、cascade 與 mapping 驗收完成 |
| 2 | Table layout | 5A 結案後再確認範圍與優先序；尚未啟動 |
| 3 | Vertical layout | 與 Table 比較需求後決定；尚未啟動 |

不因歷史 gate 曾通過就重開整批 horizontal sweep；只有新實作的驗收範圍或具體回歸證據需要時才執行對應檢查。

## 更新規則

只在本頁維護目前狀態。每次更新保留日期、核對的 commit、證據連結、驗收範圍與下一步；詳細結果寫回既有報告目錄。歷史台帳與舊計畫中的勾選狀態不能取代實際證據。
