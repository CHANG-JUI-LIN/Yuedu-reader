---
title: 淘汰舊引擎：目標與計畫
updated: 2026-11-21
status: 進行中（範圍、發版方式、對照基準已由使用者於 2026-11-21 確認）
tags: [yuedu, browser-layout, legacy-retirement]
---

# 淘汰舊引擎：目標與計畫

[文件首頁](../../README.md) · [BrowserLayout 目前狀態](../STATUS.md) · [相似度量測](../fidelity-loop/README.md) · [已知差距](../fidelity-loop/GAPS.md)

「舊引擎」指用 `NSAttributedString` 排版的那一套（`HTMLAttributedStringBuilder`、`NodeAttributedStringRenderer`、`CoreTextPaginator`、`CoreTextPageEngine` 的排版部分）。「新引擎」指 YueduCoreText 套件裡的 BrowserLayout。

## 目標

依序達成，每一條都能用指令或搜尋檢查。

1. **EPUB 不再回退。** `~/Desktop/Test document/EPUB Format` 裡每一本 EPUB 量到的章節，回退舊引擎的章數是 0，而且每本書和 WebView 的相似度至少 80 分、沒有低於 60 分的章節。
   ```bash
   bash scripts/fidelity/measure.sh --sets dev,holdout --require-goal
   ```
   報告的「Legacy fallback」是 0 章才算。固定版面 EPUB 走 WebView，不在這條裡。
2. **其他可重排內容改走新引擎。** 線上章節、TXT、Markdown 不再建立舊引擎的排版物件。
3. **刪掉舊引擎。** `BrowserLayoutPageEngine` 不再需要 `CoreTextPageEngine` 當後盾；舊的排版檔案刪除，兩邊共用的宿主（`CoreTextPagedView`、`CoreTextCollectionScrollViewController` 等）留下並改名。

## 現況（2026-11-21）

基線 `phaseout-baseline-ios27-2026-11-21`：33 本、519 章，對照組是 iOS 27.2 的 WebKit（使用者 2026-11-21 決定以 27.2 為準），閱讀器是 main `3b51c6f8` 加當時未提交的改動，套件 0.19.0。[完整報告](../fidelity-loop/reports/phaseout-baseline-ios27-2026-11-21.md)

- 28／33 本過 80 分。走新引擎 426 章（平均 93.6），回退舊引擎 93 章（平均 73.3）。
- 沒過的 5 本：ナミヤ雑貨店の奇蹟 44.4、草枕 66.3、Thinking, Fast and Slow 75.1、紅樓夢脂評直排 75.4、Mahabharata 78.8。

| 回退原因 | 章數 | 書 |
|---|---:|---|
| `@media` | 48 | AI 術語詞典、Yesteryear、Thinking, Fast and Slow |
| 直排（有圖等） | 29 | ナミヤ雑貨店の奇蹟、草枕、紅樓夢脂評直排 |
| 表格 | 13 | Thinking, Fast and Slow、三國演義注評版、洪武大帝、全知讀者視角 |
| flex／grid | 11 | 全能遊戲設計師、全知讀者視角 |
| 複雜 SVG | 2 | 鬼吹燈 |
| `position` | 1 | 全能遊戲設計師 |

同一天也對 iOS 26.5 量了一次（`phaseout-baseline-2026-11-21`，[報告](../fidelity-loop/reports/phaseout-baseline-2026-11-21.md)）：同一份閱讀器只有 26／33 本過關，走新引擎的章節平均 89.1。差在「indent」和「line-break」兩項，是兩版 WebKit 自己排得不一樣（詭秘之主對 27.2 是 95.0、對 26.5 是 86.6）。兩個對照組的 run 不能互比。

ナミヤ雑貨店の奇蹟的 14 章全部回退。其中 4 章是只有一張圖的頁面，舊引擎直排時沒畫出圖（分數 0.3–11）；另有幾章在 WebView 是橫排、我們排成直排。這些都要在步驟 1-2 一起處理。

**量測要固定用自己的模擬器。** 預設挑到的那台和其他 session 共用，別人一啟動測試就會把量測中的 App 砍掉（今天第一次量測就是這樣中斷的）。量測用另建的「Fidelity 18 Pro Max」（iOS 27.2）：

```bash
YUEDU_DEST="id=7C0123B2-97C4-49CA-80A3-CF0FBFD8352D" bash scripts/fidelity/measure.sh --sets dev,holdout --run <名稱>
# 量本機套件（還沒發版的修改）時再加：
#   YUEDU_WORKSPACE="$HOME/.config/superpowers/worktrees/YueduEngine.xcworkspace"
```

每一步的前後比較要連著量（改之前一次、改之後一次），不要拿這份基線當「改之前」：同一個工作目錄有別的改動在進行。

抽樣量不到的回退原因（語料裡這次沒抽到，但掃描器會擋）：MathML、`script`／`iframe`／`audio` 等、`calc()`／`min()`／`max()`／`clamp()`、float 裡的 float、不支援的 ruby／`text-indent`／清單記號、排版逾時（5 秒）。

舊引擎現在還負責的東西（盤點 2026-11-21）：

| 項目 | 現況 |
|---|---|
| EPUB 回退章節 | 上表 |
| 整章翻譯 | 一開就整本書走舊引擎 |
| 線上章節 | 全部舊引擎；內容本來就是 HTML |
| TXT、Markdown | 全部舊引擎；沒有 HTML |
| 章節標題設計、對話氣泡 | 只有舊引擎有（TXT／線上用） |
| 取代規則、繁簡轉換 | 新引擎路徑上沒找到，要先確認 |
| 表格畫成圖、MathML、SVG 點陣化 | 只有舊引擎有 |

## 做法

每一步都照同一個流程，定義在 [fidelity-loop/README.md](../fidelity-loop/README.md)：

1. 先有一本只重現這個差距的測試書（`scripts/fidelity/fixtures/gaps/`），量出修之前的分數與回退原因。
2. 在套件裡照 CSS／HTML 的通用規則修，不為某本書、某個 class 寫特判。
3. 套件測試全過；App 用本機套件跑「改了排版要跑的測試」。
4. 測試書和 33 本全書各重量一次，和上一步的結果比：測試書接近 100、回退原因消失；其他書的章節變動在 0.3 以內，或能說明原因。
5. 套件發版，App 改用新版，更新 [GAPS.md](../fidelity-loop/GAPS.md) 和這份文件的進度表。

不做的事：不回頭修舊引擎；不新增回退；已錄製的基線要重錄時先停下來給人確認（[PHASES.md](../PHASES.md) D-09）。

## 階段

順序依基線的章數排，先做影響最多章的。

### 第一階段：EPUB 不再回退

| 步驟 | 內容 | 狀態 |
|---|---|---|
| 1-0 | 整頁背景圖照 CSS 的大小、位置、重複畫（原本一律當 `cover`） | **完成**：套件 0.20.0、App `f23f5f4b`。有整頁背景的十本書沒有一章退步，紅樓夢 92.0 → 95.9（run `phaseout-1-0-after`）。還沒做：量法自己畫整頁背景時只畫第一格（鎖定檔，要改得先問），所以測試書 S014 還量不準 |
| 1-1 | `@media` 照實際畫面求值（媒體類型、寬高、方向、配色、hover／pointer）；解析時保留條件、排版時才過濾 | 套件 0.21.0。AI 術語詞典 81.7 → 97.8、Thinking, Fast and Slow 75.2 → 89.3、Yesteryear 85.6 → 91.2，48 章全部改走新引擎（run `phaseout-1-1-1-2-after`） |
| 1-2 | 直排准入：`writing-mode` 依層疊結果判斷（日本出版社通用範本先寫橫排再用 class 覆蓋）；`em`／`rem`／`pt` 寬度；只包一張圖的 SVG 封面；`-webkit-text-combine-upright` 別名 | 套件 0.21.0。紅樓夢脂評直排 75.4 → 78.9（16 章全走新引擎）、ナミヤ 36.6 → 57.5（別名修正後剩下的 4 章也會走新引擎，還沒重量） |
| 1-3 | `<script>` 不再是回退理由（兩個引擎都不執行腳本；兩本新書每章掛一個空的 `main.js`，590 章全部回退） | 套件 0.21.0 |
| 1-4 | 表格：`border-collapse: collapse`、`inline-table`、沒有表格包著的 `table-cell`（匿名表格盒）、`colgroup`、巢狀表格、`rowspan` | 未開始，先寫設計。全書 64 章 |
| 1-5 | flex（EPUB 用到的子集：置中、對齊）與 `position: absolute` | 未開始，先寫設計。全書 18＋9 章，集中在全知讀者視角、全能遊戲設計師 |
| 1-6 | 有向量內容的 SVG（鬼吹燈 10 章）、`calc()`（1 章）、`audio`（1 章）、直排的 `min-width`（草枕封面 1 章）、MathML、`iframe` 等 | 未開始 |
| 1-7 | 排版失敗與逾時不再回退：修掉原因，或顯示錯誤頁 | 未開始 |
| 1-8 | 元素自己的背景圖。讀程式看起來新引擎不畫非根元素的 `background-image`，還沒用測試書確認 | 未開始 |

**全書普查（2026-11-21，不抽樣）：** 35 本、12,984 章逐章跑准入判斷（引擎是 0.21.0 的內容，但還沒含 1-3 與別名修正）。回退 679 章；扣掉 `<script>` 的 590 章和別名的 4 章，剩約 85 章：

| 還會回退的原因 | 章數 | 具體是什麼 |
|---|---:|---|
| 表格 | 64 | `border-collapse` 36、`display: inline-table` 19、沒有表格包著的 `table-cell` 10、`colgroup` 2（會重疊） |
| flex | 18 | `display: flex`＋`justify-content`／`align-items`；`inline-flex` 3 |
| 有向量內容的 SVG | 10 | 鬼吹燈 |
| `position: absolute` | 9 | 全能遊戲設計師 |
| 其他 | 3 | `calc()` 1、`audio` 1、直排 `min-width` 1 |

普查不經過 App：App 對「沒有宣告書寫方向的章節」用書的方向，普查用橫排；排版失敗、逾時、整章翻譯造成的回退普查也看不到。普查工具是一支暫時放進套件測試的程式（`CorpusCensusTests`），沒有進版本庫。

已走新引擎但低於 80 分、要另外查的：ナミヤ的封面與版權頁（WebView 是橫排、我們排成直排，26–53 分）、草枕 66.3、Mahabharata 78.8（行內 margin，GAPS S002）、紅樓夢脂評直排 78.9。ナミヤ有一章擷取花了 21.8 秒，要量是排版還是量測本身慢。

### 第二階段：新引擎補齊舊引擎才有的功能

整章翻譯、取代規則、繁簡轉換（先確認是否真的缺）、對話氣泡、章節標題設計。每一項做完，對應的「強制走舊引擎」條件就刪掉。

### 第三階段：線上章節改走新引擎

線上內容本來就是 HTML，`UniversalBookResourceAdapter` 已經存在。要補的是段評／本章說等只在線上路徑的附加內容，以及來源的 CSS 清理。

### 第四階段：TXT 與 Markdown 改走新引擎

把純文字與 Markdown 轉成 HTML 再交給新引擎。要確認大檔 TXT 的延遲載入在新引擎上的效能（先量再做）。

### 第五階段：刪除

EPUB 啟動時不再建立舊引擎；`BrowserLayoutPageEngine` 自己持有版面與位置資料；刪除舊排版檔案與只給它用的測試；共用宿主改名。閱讀位置：同一章換引擎後字元位移會變（例如清單記號），刪除前要有遷移。

## 進度

| 日期 | 做了什麼 | 量測 |
|---|---|---|
| 2026-11-21 | 量了 33 本的基線（iOS 27.2 與 26.5 各一次）；盤點舊引擎還負責什麼 | `phaseout-baseline-ios27-2026-11-21` |
| 2026-11-21 | 1-0 完成：套件 0.20.0、App `f23f5f4b` | `phaseout-1-0-after` |
| 2026-11-21 | 全書不抽樣普查（35 本、12,984 章）；1-1、1-2、1-3 完成：套件 0.21.0 | `phaseout-1-1-1-2-after` |
