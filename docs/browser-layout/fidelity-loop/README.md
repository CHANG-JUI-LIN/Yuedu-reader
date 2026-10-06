---
title: EPUB 渲染相似度量測
updated: 2026-10-07
tags: [yuedu, browser-layout, fidelity-loop, index]
---

# EPUB 渲染相似度量測

[BrowserLayout 目前狀態](../STATUS.md) · [歷史台帳](../PHASES.md)

把測試資料夾（`~/Desktop/Test document/EPUB Format`）裡的每一本 EPUB，用閱讀器和 WKWebView 各排一次，比兩邊有幾成像。目標是每本至少 80 分（[GOAL.md](GOAL.md)），分數怎麼算在 [ORACLE.md](ORACLE.md)。

2026-09-30 到 10-01 曾經讓 Codex 照這個分數一輪一輪自己修引擎（loop）。2026-10-07 起不跑 loop 了：Codex 的 skill、工作副本、佇列和執行紀錄都拆掉，量測留下來當 EPUB 測試，改了排版之後手動量、和基線比。

## 現在的分數

基線 `baseline-2026-09-30`：閱讀器是 `main eb960673` 加上當時還沒提交的改動（含按需字型），引擎是 YueduCoreText 0.6.1；語言環境固定為繁體中文。

| 書 | 分數 | 過關 | 最低的一章 | 走新引擎／回退舊引擎的章數 | 低於 60 的章 |
|---|---:|:---:|---:|---:|---|
| Georgia（EPUB 3 範例，表格） `georgia` | **58.3** | ✗ | 58.3 | 0／1 | 0 |
| 草枕（日文直排範例） `kusamakura` | **65.3** | ✗ | 45.1 | 13／2 | 0、14 |
| AI 術語詞典 第一冊 `ai-glossary` | **75.2** | ✗ | 4.0 | 0／16 | 0 |
| 紅樓夢脂評匯校本（繁體直排） `redchamber-vertical` | **76.6** | ✗ | 64.5 | 2／14 | — |
| Mahabharata（梵文詩行） `mahabharata` | **78.5** | ✗ | 74.3 | 16／0 | — |
| The Deal `the-deal` | **86.7** | ✓ | 50.3 | 3／13 | 50 |
| 全知讀者視角 01 `orv` | **86.7** | ✓ | 74.6 | 5／11 | — |
| 洪武大帝 `hongwu` | **88.3** | ✓ | 21.7 | 14／2 | 43 |
| 哈利波特全集 `harry-potter` | **88.9** | ✓ | 65.6 | 4／12 | — |
| 紅樓夢＋大觀紅樓 `redchamber` | **91.1** | ✓ | 81.3 | 18／0 | — |
| israelsailing（希伯來文，由右至左） `israelsailing` | **93.8** | ✓ | 44.8 | 12／0 | 1 |
| 詭秘之主 4 `guimi` | **94.5** | ✓ | 84.5 | 21／0 | — |
| 福爾摩斯探案全集（圖註本） `sherlock` | **96.4** | ✓ | 86.6 | 16／0 | — |
| 全能遊戲設計師 1 `game-designer` | **96.7** | ✓ | 74.3 | 18／1 | — |
| 全職高手 3 `quanzhi` | **96.8** | ✓ | 79.2 | 18／0 | — |
| Project Hail Mary `hail-mary` | **98.8** | ✓ | 85.7 | 17／0 | — |

11 / 16 本過關；量到 249 章，其中 177 章走新引擎（平均 91.8）、72 章回退舊引擎（平均 78.2）。

完整報告：[基線 2026-09-30](reports/baseline-2026-09-30.md)。並排圖（WebView 在左、閱讀器在右，最差的章節排最前面）在本機：`~/Library/Caches/YueduFidelity/runs/baseline-2026-09-30/index.html`。

讀這張表要知道的三件事：

- **沒過的五本卡在哪裡，見 [GAPS.md](GAPS.md)。**
- **回退舊引擎的章節分數偏低，有一部分是量法看不到。** 舊引擎把表格畫成一張圖，裡面的字量不到（georgia、洪武大帝第 43 章）。這些章節改走新引擎之後才量得準。
- **分數是穩定的。** 同一台模擬器把整份基線重量一次，走新引擎的 177 章每一章分數完全相同；走舊引擎的章節會小幅漂移（最多一章差 2.8），比較兩次量測時這些章節不算進去。換一台語言設定不同的模擬器重量同樣的章節，分數也一樣（抽 6 章驗證）。

## 怎麼量

`measure.sh` 會自己把語言環境固定成繁體中文。WebView 那一邊擷取一次後重複使用，每次只重新跑閱讀器這一邊。

```bash
# 量主工作目錄，只量幾本書的 dev 章節
bash scripts/fidelity/measure.sh --run 我的測試 --books guimi,quanzhi

# 量另一個工作目錄（例如某個分支的 worktree）；要用本機的 YueduCoreText 時，
# 給一個把閱讀器和套件配在一起的 workspace
YUEDU_WORKSPACE=<workspace> bash scripts/fidelity/measure.sh --tree <那個 Yuedu-reader> --run 我的測試-after --books kusamakura

# 驗收：全部的書，dev 和 holdout 都量
bash scripts/fidelity/measure.sh --sets dev,holdout --run 我的測試-verify

# 只重新評分已經擷取過的 run
python3 scripts/fidelity/fidelity.py score --run 我的測試 --verbose

# 兩次量測比較
python3 scripts/fidelity/fidelity.py compare --run 我的測試 --base baseline-2026-09-30

# 量法自己的測試（不需要 Xcode）
python3 scripts/fidelity/test_fidelity.py
```

- `compare` 只比兩次都量到的章節。兩次都走舊引擎的章節每次量會小幅漂移，所以不算進書的分數；改的是舊引擎本身時，要直接看兩次各自的 `report.md`。結束碼 0＝`PASS`，4＝`FAIL` 或 `NO PROGRESS`。
- 產物都在 `~/Library/Caches/YueduFidelity/runs/<run>/`：`report.md`、`report.json`、並排圖 `index.html`。說到分數一律附 run 編號，才查得到。
- 兩邊對同一台模擬器跑測試時，後開始的會重裝 App、把先開始的砍掉。和別的測試同時跑時，用 `YUEDU_DEST` 指定另一台。

## 改了排版要跑的測試

`-only-testing` 寫的是 struct／class 的名字，不是檔名：一個檔案裡常有好幾個測試型別（例如 `BrowserLayoutEngineTests.swift` 裡有 10 個，沒有一個叫 `BrowserLayoutEngineTests`），寫檔名會空跑。跑完核對 log 裡 `Test run with N tests in M suites` 的數字；0 個或比下面少都不算通過。

基本的一組，每次都跑（2026-10-01 在 main 上是 **84 tests in 15 suites**，全過；新增測試會讓數字變大，變小或有失敗就要查）：

```bash
bash scripts/xctest.sh -- \
  -only-testing:'yuedu appTests/BrowserLayoutFeatureTests' -only-testing:'yuedu appTests/CSSLengthResolverTests' \
  -only-testing:'yuedu appTests/ComputedStyleTests' -only-testing:'yuedu appTests/ComputedStyleTreeTests' \
  -only-testing:'yuedu appTests/BlockLayoutTests' -only-testing:'yuedu appTests/CoreTextLineBreakerTests' \
  -only-testing:'yuedu appTests/InlineLayoutTests' -only-testing:'yuedu appTests/PageFragmentationTests' \
  -only-testing:'yuedu appTests/BrowserLayoutDocumentTests' -only-testing:'yuedu appTests/DisplayListTests' \
  -only-testing:'yuedu appTests/BrowserLayoutPageEngineTests' -only-testing:'yuedu appTests/EPUBAutoRoutingTests' \
  -only-testing:'yuedu appTests/BrowserLayoutCapabilityScannerTests' \
  -only-testing:'yuedu appTests/BrowserAutoSupportedSubsetCorrectnessGateTests' \
  -only-testing:'yuedu appTests/BrowserLayoutDeterminismTests'
```

| 改到什麼 | 再加跑 |
|---|---|
| 斷行、行內排版 | `BrowserLayoutLineBreakerClusterTests`、`BrowserLayoutJustificationTests`、`BrowserLayoutInlineRunGeometryTests`、`BrowserLayoutInlineFormattingContextParityTests`、`BrowserLayoutWhiteSpaceTests` |
| 字型、字級、行高 | `BrowserLayoutFontFallbackTests`、`BrowserReaderTypographyTests`、`BrowserFontDemandTests`、`BrowserLayoutUsedValueResolutionTests` |
| 邊距、縮排、float | `BrowserLayoutTextIndentTests`、`BrowserLayoutFloatLayoutTests`、`BrowserLayoutFloatStyleTests`、`BrowserLayoutLogicalGeometryTests` |
| 圖片 | `BrowserLayoutImageTests`、`BrowserLayoutProductionCorrectnessTests` |
| 背景、邊框、裝飾 | `BrowserLayoutInlineDecorationTests`、`BrowserLayoutFragmentedDecorationTests`、`BrowserScrollPageBackgroundTests` |
| 注音 | `BrowserLayoutRubySubsetTests`、`BrowserLayoutRubyUnitTests`、`BrowserLayoutRubyMeasurementTests`、`BrowserLayoutRubyFragmentTests`、`BrowserLayoutRubyInteractionTests`、`BrowserLayoutRubyCorpusTests` |
| 直排 | `CoreTextWritingModeTests`、`BrowserVerticalReaderRouteTests` |
| 捲動與 viewport | `BrowserScrollDocumentTests`、`BrowserViewportSessionTests`、`BrowserViewportRegressionTests` |
| 連結、選字 | `BrowserLayoutLinkInteractionTests`、`BrowserLayoutSelectionContractTests`、`BrowserTextInteractionTests` |

`BrowserLayoutSnapshotTests` 比的是已錄製的結果。它因為一個正確的修正而失敗時，不要直接重錄：先有根因與正確性證據，由人確認（[PHASES.md](../PHASES.md) D-09）。

`BrowserLayoutRedChamberRegressionTests` 不比錄製的結果，是對整本《紅樓夢》做的結構檢查（章節定位、樣式表、封面頁幾何、背景圖），失敗就照一般回歸處理。2026-10-01 在 main 上是 12 tests 全過。

### 斷行基線

`BrowserLayoutLineBreakBaselineTests` 比對整本《紅樓夢》458 章的斷行指紋（`docs/browser-layout/line-break-baseline/redchamber.tsv`）。基線是用繁體中文錄的，而程序語言會改變斷行（英文下有 196 章不同），所以跑它一定要加 `-testLanguage zh-Hant -testRegion TW`；沒加會立刻失敗，訊息會說要加什麼。整本書跑一次約 3 分鐘：

```bash
bash scripts/xctest.sh -t 1500 -- \
  -only-testing:'yuedu appTests/BrowserLayoutLineBreakBaselineTests' -testLanguage zh-Hant -testRegion TW
```

它失敗時（2026-10-01 使用者決定；依據 PHASES.md D-09：先有原因，只更新受影響的列）：

- **改動不是要改斷行**（碰不到行內排版、字型、字級、行高、縮排、內容寬度）：這是回歸，要修掉。
- **改動本來就是要改斷行**：在同一個 commit 重錄，指令是上面那行前面加 `TEST_RUNNER_YUEDU_LINEBREAK_REGEN=1`，重錄後再跑一次要通過，檔頭仍然寫著 `zh-Hant`。紀錄寫出變了幾章和全部的 spine 編號（`git diff` 這個檔案就看得到），並抽 3 章說明章裡哪一段 CSS／HTML 用到了這次改的規則（解壓 EPUB 後的檔名＋那段樣式或標籤）。

## 這幾頁各是什麼

| 頁面 | 內容 |
|---|---|
| [GOAL.md](GOAL.md) | 目標與完成條件（鎖住） |
| [ORACLE.md](ORACLE.md) | 分數怎麼算、它看不到什麼、怎麼改量法（鎖住） |
| [GAPS.md](GAPS.md) | 量出來還沒修的差距，以及量法的雜訊 |
| `reports/` | 只有數字的量測報告 |

## loop 留下的東西

- **S001 最後一次的候選改動沒有合入**，收在本機 git 的 `refs/archive/fidelity-S001-attempt3`（閱讀器和 YueduCoreText 兩個 repo 各一個，不會上傳）。它讓 ai-glossary 從 75.2 到 97.7，但第 15 章的有序清單編號不見了；細節在 [GAPS.md](GAPS.md)。要接著做時，在對應的 repo 裡：
  ```bash
  git diff refs/archive/fidelity-S001-attempt3^ refs/archive/fidelity-S001-attempt3 | git apply
  ```
- 量法的鎖（`scripts/fidelity/oracle.lock`）還在，改法見 [ORACLE.md](ORACLE.md)「改量法」。
