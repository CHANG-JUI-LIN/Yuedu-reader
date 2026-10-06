---
title: BrowserLayout 目前狀態與下一步
updated: 2026-10-07
phase: 5A
status: 進行中，未結案
tags: [yuedu, browser-layout, status]
---

# BrowserLayout 目前狀態與下一步

[文件首頁](../README.md) · [歷史台帳](PHASES.md) · [5A 設計](../superpowers/specs/2026-09-04-lexbor-css-frontend-production-migration-design.md) · [5A 計畫](../superpowers/plans/2026-09-04-lexbor-css-frontend-production-migration.md)

## 2026-10-07：不跑 loop 了，相似度量測留下來手動跑

使用者決定不再讓 Codex 照相似度分數自己修引擎。拆掉的：Codex 的四個 fidelity skill、loop 的工作副本與 `loop/fidelity` 分支、操作手冊、執行紀錄、S001 三次嘗試的報告與量測，以及 `fidelity.py gate`。留下的：量法（`scripts/fidelity/`、`RenderFidelityOracleTests.swift`）、16 本書與 WebView 對照組、基線分數。原本的佇列整理成 [已知差距](fidelity-loop/GAPS.md)；怎麼量、改了排版要跑哪些測試在 [fidelity-loop/](fidelity-loop/README.md)。S001 沒合入的候選收在本機 git 的 `refs/archive/fidelity-S001-attempt3`。量法的鎖已照「改量法」只做第 2、3 步重錄（`SCORER_VERSION` 不變，基線照舊可比）。

## 2026-10-01：和 WebView 的相似度有了量法與基線，loop 已備好交給 Codex

目標：測試資料夾（`~/Desktop/Test document/EPUB Format`）裡每一本 EPUB，閱讀器的渲染和 WKWebView 至少 80 分相似。量法、基線、佇列與給 Codex 的操作手冊都在 [fidelity-loop/](fidelity-loop/README.md)。

**基線（`baseline-2026-09-30`，16 本、249 章）：11 本過關，5 本沒過**——georgia 58.3、草枕 65.3、AI 術語詞典 75.2、紅樓夢脂評直排 76.6、Mahabharata 78.5。走新引擎的 177 章平均 91.8，回退舊引擎的 72 章平均 78.2；差距主要在回退的章節。[完整報告](fidelity-loop/reports/baseline-2026-09-30.md) · [已知差距](fidelity-loop/GAPS.md)（原本的佇列，10-07 改名）。

量法是 Claude 寫的，loop 不准改（`scripts/fidelity/oracle.lock`）：兩邊用同一個捲動版面（390×800、繁體中文語言環境），以「同一個字」對齊後比每段的換行、位置、字級與整頁畫面。51 個量法自測；每條擷取路徑（新引擎橫直排、舊引擎橫直排、由右至左）都把量到的方塊疊回截圖核對過。整份基線在同一台模擬器重量一次，走新引擎的 177 章每一章分數完全相同，舊引擎的章節最多漂移 2.8 分；換一台語言設定不同的模擬器重量同樣的章節，分數也一樣（抽 6 章驗證；量測固定用繁體中文）。

這個目標把表格、flex／grid、直排圖片、`@media` 這些原本排在載入效能後面的能力往前拉。兩條主線會改到同一批檔案（能力掃描、CSS 前端），loop 的手冊規定合併時在這些檔案遇到衝突一律停下來等人；每合入五個切片要重跑一次按需字型的載入量測，慢超過 15% 就停。還沒有任何引擎修改，也還沒建立 loop 的工作副本。

## 2026-09-30：按需字型與 0.6.1 正式套件整合已完成

Browser ingestion 已只收集 CSS／字型描述；能力掃描沿用其 computed-style tree 產生字型需求，選中 Browser 後才準備對應 face。能力回退章不再先讀取 Browser 字型。分頁、捲動、讀者字型與粗體切換、ruby／首字及來源／版面均已做相關回歸。

本機 App＋原始套件 checkout 的 **59 項回歸全部通過**，同批原書重測 120 筆／100 筆有效資料、來源校驗一致。Auto 分頁／捲動中位數降低：詭秘短章 **57.8%／57.6%**、遊戲設計師回退章 **35.0%／33.9%**、全職短章 **17.2%／14.4%**。長章約 7–8%，英文無內嵌字型章大致不變。Auto 仍慢於同輪 Legacy，第一輪提議的各重字型案例至少降低 30% 未全部達到。

**[YueduCoreText 0.6.1](https://github.com/CHANG-JUI-LIN/YueduCoreText/releases/tag/0.6.1) 已正式發布，普通 `.xcodeproj` 的要求與 Xcode 產生的 pin 均已更新為 0.6.1／`d7e16bd`。** 正常 project 使用遠端套件重跑上述六類 59 項回歸，全部通過；套件公開 API 2 項及發布 metadata 9 項也通過。其餘 27 個 pin 不變。量測仍保留發布前本機 workspace 的歷史來源校驗。[正式發布與 project 驗證](extraction/release-0.6.1.md)。

下一個單位先拆量 scanner 的 declaration matching／style tree 與 Current frontend，再縮小安全規則的多餘 selector matching、重用解析結果；共享整份 DOM／cascade 準備產物前需固定字型與 used values 的邊界。Lexbor cutover 與歷史 gate 狀態保留。

[第一輪改動、前後數字與驗收限制](loading-benchmark-2026-09-30-font-demand.md) · [本輪原始觀測](loading-benchmark-2026-09-30-font-demand.json) · [統計與來源校驗](loading-benchmark-2026-09-30-font-demand-summary.json)

## 2026-09-30：優化前的 Auto／Legacy 基線與優先序

以下舊段落保留 9/12 當時的 Phase 5A 快照。優化前量測時正常 `.xcodeproj` 使用遠端 **YueduCoreText 0.6.0 / `8cd1bf6`**，含 viewport 背景排版；Lexbor production cutover 仍沒有完成證據。9/23 的幾何基準處理另見 [0.5.0 之後的重錄與歸因](yueducoretext-0.5.0-baselines-2026-09-23.md)。

本輪依使用者回報直接比較原書的 Auto 與純 Legacy：四本 EPUB、五個章節、翻頁與捲動，共 120 筆觀測，扣除暖機後使用 100 筆。正常 project、iPhone 18 Pro Max / iOS 27.0 Simulator、Debug；最小量測測試 `TEST SUCCEEDED`，效能相關源碼前後校驗一致。五個案例的 Auto 首屏中位數均較慢，約為 Legacy 的 **1.17–2.59 倍**；這是引擎內容就緒時間。

已定位的優先工作：

1. **先縮小字型資源準備範圍。** Browser ingestion 在 capability 判斷之前註冊所有待用字型；純 Legacy 只按章節實際需求載入。回退章節也先支付 Browser 字型準備成本。
2. **再共用 scanner／Current 前端 evaluation。** CSS input cache 沒有省掉兩次 DOM／CSS／cascade；英文及長章仍有明顯掃描成本。
3. **之後拆分 metadata startup 與章節排版。** 第 0 章先建 Legacy，再建 Browser；本次第 0 章都很短，尚未證明等待剩餘分頁是主要載入瓶頸。

[完整數據、量測邊界及下一步驗收方案](loading-benchmark-2026-09-30.md) · [原始觀測](loading-benchmark-2026-09-30.json) · [統計與來源校驗](loading-benchmark-2026-09-30-summary.json)。本輪新增量測與文件，沒有啟動上述優化或變更產品路由。歷史能力擴充與 Lexbor gate 保留，載入效能工作建議優先處理。

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
