---
title: Browser 加載量測：一章只解析一次（共用 evaluation）＋第 0 章不重複建構
updated: 2026-10-06
tags: [browser-layout, performance]
---

# Browser 加載量測：一章只解析一次（共用 evaluation）＋第 0 章不重複建構

[09-30 基線與方案](loading-benchmark-2026-09-30.md) · [按需字型那一輪](loading-benchmark-2026-09-30-font-demand.md) · [本輪 before 120 筆](loading-benchmark-2026-10-06-baseline.json) · [本輪 after 120 筆](loading-benchmark-2026-10-06-shared-evaluation.json) · [中位數與來源校驗](loading-benchmark-2026-10-06-shared-evaluation-summary.json)

這是 09-30 文件「建議下一步」的第 2 項（scanner 與正式前端共用解析）和第 3 項的前半（第 0 章只讓選中的引擎建構）。畫面一個像素都沒變：能力判斷的結論、順序、text-indent 分類、字型需求，和排版輸出，都有逐一比對的測試證明與改前相同（見下）。

## 改了什麼

改前每開一章要把同一份 HTML／CSS 解析三次：`decideEngine` 的能力掃描一次（自己再對每條規則×每個元素配對一遍）、`fontScalePolicy(for:)` 為了讀 `<body style>` 再 parse 一次 DOM、`BrowserLayoutSession`／`HTMLLayoutDocument` 的前端第三次（再做一次 cascade）。

套件 YueduCoreText 0.6.2：
- `BrowserChapterDocument(input:)` 解析一次（HTML、CSS）；`evaluate(configuration:)` 用排版的配置 cascade 一次，同時給出能力判斷（`capabilities`）和排版要用的 style tree；`bodyInlineStyle` 讓宿主的字級政策不用再 parse。
- 能力判斷裡「規則有沒有配到元素」改讀 cascade 自己的配對紀錄，cascade 沒走到的元素（`<head>` 子樹、隱藏元素的後代）另外補配對，所以判斷範圍跟掃全部元素完全一樣。
- `HTMLLayoutDocument(evaluation:)`／`BrowserLayoutSession(evaluation:)` 從這棵 style tree 起步，不再跑前端；配置若動到 cascade 輸入（字級、字族、顏色、行距、間距、粗體、對齊）會拒絕（`accepts`／`rebound(to:)`），不會拿舊的 computed values 排新字級。
- `BrowserLayoutCapabilityScanner.scan(...)` 入口保留，變成共用路徑的薄包裝。

App：
- `decideEngine` 建一份 evaluation 就留著（`pendingEvaluations[spine]`），字型準備完後 `chapterEvaluation(for:)` 把它綁到帶 resolver 的排版配置上交給 session／viewport owner；分頁、橫排捲動、直排連續三條路都走這條。沒有可用的（字級改了之後重排）就當場重新 evaluate 一次——還是只解析一次。
- `CoreTextPageEngine.start(…, preloadingFirstChapter: false)`：browser 引擎開書時不再先用舊引擎建一份第 0 章再用 browser 建一份；第 0 章和別章一樣走 admission，回退時才由舊引擎建。`activatePagedLayout` 同樣改成走 admission。
- `CoreTextScrollEngine.waitForViewportIdle()`（只有測試用）現在也等「還在載入中的章」，不只等已插入章的排版交易；原本一個測試靠呼叫次序的運氣過。

## 套件內量測：每章解析＋cascade 到 box tree 之前的 CPU（Release，7 輪中位數，ms）

同一台機器、安靜狀態，輸入是 App dump 出來的五個原書章節（`FrontendStageProbeTests`，opt-in `YUEDU_FRONTEND_INPUT_DIR`）。

| 章節 | 改前：scan ＋ 前端到 box tree | 改後：document+evaluate ＋ 到 box tree | 差 |
|---|---:|---:|---:|
| 全職高手 正文 | 30.6 + 29.8 = 60.4 | 30.3 + 0.9 = 31.2 | −48% |
| 詭秘之主 短章 | 24.4 + 23.5 = 47.9 | 23.6 + 0.9 = 24.5 | −49% |
| Project Hail Mary | 29.4 + 30.3 = 59.7 | 28.0 + 5.8 = 33.8 | −43% |
| 全能遊戲設計師 回退章 | 38.7（只有 scan） | 39.6 | ±0（被拒的章本來就只付 scan） |
| 詭秘之主 長章 | 236.7 + 230.5 = 467.2 | 223.0 + 13.8 = 236.8 | −49% |

CSS 解析（`parseStylesheets`）本身 2–25 ms、每章一次之後還在；它是下一個可以單獨量的項目，本輪沒動。

## 引擎層量測：首屏就緒中位數（ms）

與 09-30 同一批書、章、設定、量法（`EPUBEngineLoadingBenchmarkTests`，Debug、iPhone 18 Pro Max／iOS 27.0 模擬器，每格 5 筆有效觀測）。before 是 App `25e9a121`＋遠端 0.6.1（獨立 worktree），after 是本輪改動＋本機套件；兩輪前後腳跑。純 Legacy 路徑是對照組：它沒改，這兩輪之間它也變了 −10%～+1%，那是機器狀態的漂移，看 Auto 時要扣掉。

| 案例 | 路徑 | Auto before | Auto after | Auto 差 | Legacy 對照差 | Auto/Legacy after（before） |
|---|---|---:|---:|---:|---:|---:|
| 全職高手 正文 | 翻頁 | 920.7 | 797.0 | −13.4% | +1.4% | 0.93×（1.09×） |
| 全職高手 正文 | 捲動 | 768.1 | 705.0 | −8.2% | −5.5% | 0.99×（1.02×） |
| 詭秘之主 短章 | 翻頁 | 578.3 | 495.0 | −14.4% | −10.2% | 1.05×（1.10×） |
| 詭秘之主 短章 | 捲動 | 488.0 | 431.7 | −11.5% | −6.0% | 1.02×（1.09×） |
| Project Hail Mary | 翻頁 | 316.3 | 175.6 | −44.5% | −8.2% | 1.13×（1.87×） |
| Project Hail Mary | 捲動 | 288.6 | 129.5 | −55.1% | −8.1% | 0.68×（1.38×） |
| 全能遊戲設計師 回退章 | 翻頁 | 1255.6 | 1059.7 | −15.6% | −8.9% | 1.37×（1.48×） |
| 全能遊戲設計師 回退章 | 捲動 | 1075.6 | 952.5 | −11.4% | −4.4% | 1.37×（1.48×） |
| 詭秘之主 長章 | 翻頁 | 6164.0 | 4788.4 | −22.3% | −8.7% | 0.97×（1.14×） |
| 詭秘之主 長章 | 捲動 | 5341.4 | 4066.8 | −23.9% | −7.9% | 0.91×（1.10×） |

短章的 Auto 首屏現在跟純 Legacy 持平（0.93–1.05×）；回退章還是 1.37×，因為它付完 admission 還要付 Legacy 的建構——那是 09-30 文件第 1 項已經縮到只剩判斷本身的成本，再往下要改回退的策略，不在本輪。

### 開書（第 0 章）

`openingFirstReadyMs`／`openingReturnMs`：翻頁模式 `start()` 到第 0 章首頁可用／`start()` 返回。

| 案例 | Auto before | Auto after | Legacy before | Legacy after |
|---|---:|---:|---:|---:|
| 全職高手 | 181.1 / 182.0 | 84.1 / 84.9 | 88.2 / 99.4 | 71.3 / 83.9 |
| 詭秘之主 | 190.5 / 191.2 | 85.7 / 86.5 | 88.3 / 99.0 | 76.8 / 82.6 |
| Project Hail Mary | 61.3 / 61.4 | 16.9 / 17.0 | 19.7 / 34.1 | 16.4 / 17.7 |
| 全能遊戲設計師 | 155.1 / 155.6 | 63.8 / 64.4 | 70.6 / 83.5 | 62.0 / 68.4 |
| 詭秘之主（長章那本） | 188.3 / 189.0 | 78.9 / 79.6 | 87.4 / 99.7 | 76.7 / 83.4 |

Auto 開書時間 −54%～−72%，現在和 Legacy 開書同級：第 0 章不再先建一份 Legacy。觀測裡 `legacyBuildCounts["0"]` 在 Auto 翻頁仍是 1，那是量測程式自己在開書計時結束後呼叫的 `legacy.preloadChapter(at: 0)`，不在任何計時窗內；沒改量測程式以保持可比。

`scannerProbeMs`（量測末尾獨立的暖 scan）：−25%～−46%，因為 scan 入口本身也從兩次 CSS 解析變一次。

## 等價證明

- 套件 `SharedEvaluationEquivalenceTests`（17 項）：把改前的 scanner 原碼複製成測試專用的 `ReferenceCapabilityScanner`，對五個 dump 章節×兩種書寫模式×兩種配置，以及專門打接縫的合成案例（只配到 `<head>` 的規則、只配到隱藏元素後代的規則、隱藏子樹裡的 inline style、dark media 與 `::first-letter` 規則、`!important` 與順序、authored order 下的 inline `@media`、沒有 body 的標記、直排宣告）逐一比對 `supported`／`unsupportedFeatures`（含順序）／`textIndentUsage`／`fontRequests`；再把「從 evaluation 排版」和「重新解析排版」的 display list（每個項目的 nodeID、range、rect、字號、文字）、`contentHeight`、`sourceText`、`anchorOffsets` 逐項比對。
- 套件全套 159＋11 項通過。
- App（本機套件 workspace）：29 個 browser-layout／閱讀器 suite 共 200 項通過；`BrowserLayoutLineBreakBaselineTests` 斷行黃金基線（`-testLanguage zh-Hant`）通過。發佈的 0.6.2 跟當時測的套件原始碼相同（之後只改了測試檔的 import 與文件）。
- `BrowserViewportHostTests.chapterArrivalDuringTrackingDoesNotSuspendViewportUntilDefaultMode` 改前就會隨機失敗，沒動它：測試自己的 `start(initialChapter: 2)` 跟捲動控制器的相鄰章載入同時跑，第 0、2 章誰先到是競態。第 2 章先到 3/3 都過；第 0 章先到 8 次失敗 6 次——失敗的那幾次在第 0 章插入後（它還在畫面外）多一次 viewport commit，之後捲進第 0 章的當下還沒有文字（照「文字晚到不掉幀」的取捨會晚一拍出現）。改前 4 跑 1 失敗，改後 7 跑 4 失敗；差別在這個測試裡第 0 章先到的比例（改前 2/4、改後 6/7），失敗機制本身改前就有。正常 project＋遠端 0.6.2 落地時重跑：30 個 suite 206 項，只有這一項失敗（第 0 章先到）。

## 可重跑

```bash
# 1. dump 五個章節的前端輸入（App 測試，寫到 TEST_RUNNER_YUEDU_FRONTEND_DUMP_DIR）
TEST_RUNNER_YUEDU_FRONTEND_DUMP_DIR=/path/to/dump scripts/xctest.sh -- -only-testing:'yuedu appTests/EPUBFrontendInputDumpTests'
# 2. 套件階段計時與等價測試
TEST_RUNNER_YUEDU_FRONTEND_INPUT_DIR=/path/to/dump xcodebuild test -scheme YueduCoreText-Package -configuration Release ENABLE_TESTABILITY=YES \
  -destination "$(scripts/sim.sh dest)" -only-testing:YueduCoreTextTests/FrontendStageProbeTests -only-testing:YueduCoreTextTests/SharedEvaluationEquivalenceTests
# 3. 引擎層 120 筆（before 在獨立 worktree 跑，after 用本機套件 workspace）
TEST_RUNNER_YUEDU_LOADING_BENCHMARK=1 TEST_RUNNER_YUEDU_LOADING_BENCHMARK_OUTPUT=loading-benchmark-<date>.json \
  scripts/xctest.sh -- -only-testing:'yuedu appTests/EPUBEngineLoadingBenchmarkTests'
```
