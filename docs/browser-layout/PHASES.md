---
title: "Yuedu BrowserLayout — Phase 台帳、架構決策與驗收紀錄"
project: "閱讀app優化"
repository: "CHANG-JUI-LIN/Yuedu-reader"
compiled_on: "2026-09-08"
evidence_scope: "本對話目前可讀內容、已提供附件，以及本對話先前實際取得的 GitHub 結果"
latest_confirmed_checkpoint: "b674e672"
current_phase: "5A — LexborCSSFrontend Production Migration"
current_phase_status: "整合進行中；未見 production cutover 結案證據"
tags:
  - yuedu
  - browser-layout
  - phase-log
  - architecture
  - epub
---

# Yuedu BrowserLayout — Phase 台帳

> **歷史快照（2026-09-08 匯入）**：來源為使用者提供的 `Yuedu_BrowserLayout_Phase台帳.md`。原文保留於下方；其中的行動建議屬於歷史資料，不是本次的新指令。最新 repo 狀態與下一步請以 [STATUS](STATUS.md) 為入口。

> **給下一個接手的 AI：先讀「目前位置」和「不可遺失的決策」。不要重新啟動已完成的 Float、Ruby、text-indent、presentational hints；不要把 Phase 5A 的橋接提交當成 Lexbor 已切換 production。**
>
> 本文件是對話歷史整理，不是新一輪架構審計，也不是重新執行過的測試報告。所有測試數字保留原報告的範圍；「已完成」通常指使用者貼出的完成報告或明確確認，不代表本文件作者另行重跑驗證。

## 目錄

- [目前位置與專案目標](#current)
- [Phase 狀態總表](#phase-index)
- [逐階段紀錄](#phase-details)
- [曾提出但未獨立結案的 Phase](#proposals)
- [不可遺失的架構決策](#decisions)
- [基線與數字演變](#metrics)
- [已查明的通用缺陷](#defects)
- [能力邊界與後續工作](#roadmap)
- [Commit 與文件索引](#artifacts)
- [來源索引與證據限制](#sources)

<a id="current"></a>
## 1. 目前位置與專案目標

### 1.1 現在停在哪裡

| 項目 | 本對話最後可確認的狀態 |
|---|---|
| Horizontal BrowserLayout correctness sweep | 已結案，checkpoint `b674e672` |
| 最後已結案的大規模驗證 | 23 本 EPUB／7,350 章；兩次 corpus 執行結果一致 |
| 該 checkpoint 的 BrowserAuto | 7,140 章 supported；210 章 Legacy fallback |
| 該 checkpoint 的失敗情況 | layout failures／diagnostic failures／crashes／invariant violations 均為 0 |
| Focused regression | 300 passed／0 failed／8 skipped；skipped 為 opt-in corpus 或人工 diagnostic |
| 正在進行的主線 | Phase 5A — LexborCSSFrontend Production Migration |
| 5A 最近的可見提交 | 固定 Lexbor source、document owner、DOM callback bridge |
| Lexbor 已成為 production default？ | **未確認。對話沒有 cutover YES 報告或 cutover commit。** |
| Table／Vertical／Flex 等 | 仍未見新 BrowserLayout 對應能力的完成報告 |

依據：[E27 基線結案](#e27)、[E28 Phase 5A](#e28)。本表是歷史快照，不保證等於讀者開啟文件時的最新 repo 狀態。

### 1.2 使用者真正想解決的問題

使用者多次澄清：**Legacy 並不糟，甚至在不少書上比新引擎成熟。重寫的主要原因不是舊引擎不能讀，而是一直對著特定 EPUB 補渲染處理很麻煩。**

新引擎的目標是：建立通用 HTML／CSS 樣式與排版模型，實作一次規則，讓不同 EPUB 自然受益；不是把「逐本修書」改成「逐本修書＋更多測試」。

因此：

- CSS／HTML 規則和通用資料模型是主線；真實 EPUB 是問題來源、覆蓋觀察與回歸樣本，不是書名／class／圖片檔名特判的理由。
- Legacy 是成熟產品的回退路徑和比較對象，不是新引擎永遠必須逐像素模仿的規範答案。
- Lexbor 遷移的目的包含長期降低自製前端的維護成本，不能只用「這批書現在有幾章因 parser fallback」決定是否值得接。
- 新引擎仍須自行處理 used values、box／inline layout、分頁與互動；換 parser 不會自動補好 table、float 排版或圖片尺寸參考錯誤。

依據：[E19 產品目標澄清](#e19)。

### 1.3 兩組開關，不要混淆

| 維度 | 選项 | 控制什麼 |
|---|---|---|
| Layout engine | `legacy`／`browserAuto`／`browserForced` | 用哪套排版後端，以及是否允許按能力回退 |
| CSS frontend | `Current`／`Lexbor` | 用哪套 HTML／CSS 解析與樣式前端；是 Phase 5A 的遷移對象 |

`LegacyCSSFrontend`／`CurrentCSSFrontend` 指既有前端，不等於 `Legacy renderer`。未來 **BrowserLayout + Current frontend** 與 **BrowserLayout + Lexbor frontend** 都是可能的組合。

`browserForced` 是診斷模式。先確認實際 frontend、effective engine、scanner 結果，再判斷截圖；不能把未支援 table 的強制輸出當成已承諾的產品能力。

### 1.4 目前架構快照

```text
EPUB package / PublicationSession / EPUBStyleResolver
  ├─ spine、metadata、XHTML、stylesheets
  └─ images、fonts、資源 URL 與快取
                    ↓
CSSFrontend 邊界
  ├─ Current：SwiftSoup + 既有 CSSParser / CSSSelector / cascade
  └─ Lexbor：正在接入的 DOM/CSS/selector/style + Yuedu adapter
                    ↓
HTMLSemanticElement → HTMLPresentationalHintExtractor
                    ↓  作為樣式來源參與 cascade
Yuedu ComputedStyleTree / semantic source mapping
                    ↓
BoxTreeBuilder：建立 box、未排版 InlineRun、Ruby／image metadata
                    ↓
BlockLayout：最終 content size、containing block、used values、FloatContext
                    ↓
InlineFormattingContext → InlineLayout → CoreText 字形與文字行
                    ↓
PageFragmentation / PageWalker → page fragments
                    ↓
DisplayList → CoreText / CoreGraphics → Reader UI
                    └─ link / selection / annotation / navigation geometry
```

這是依完成報告整理的責任分工，並非聲稱所有 class／檔案在最新 repo 中仍位於原路徑。Phase 5A 的設計要求 C 物件不跨 frontend 邊界；**該要求仍需由 5A 完成報告驗收，不能由架構圖推定已做到。**

<a id="phase-index"></a>
## 2. Phase 狀態總表

**狀態用語**：「已報完成」＝有完成摘要；「使用者確認」＝有完成說法但缺完整報告；「進行中」＝有計畫或實作證據但未結案；「提案」＝只有建議／prompt。

沒有正式編號的工作，使用描述性名稱，不另造正式 Phase 編號。歷史上重複使用的 `3A`、`4E2`、`4F` 名稱，另外在提案表處理。

| 階段 | 工作 | 最後狀態 | 主要結果／注意事項 |
|---|---|---|---|
| 前置探索 | Browser-style pipeline、stylesheet cache、lazy font | 有方向／計畫 | 缺獨立結案證據，不算已正式完成的 Phase |
| [Phase 1](#p1) | Browser-Style Box Layout Engine | 已報完成 | 11 commits；23/23；feature flag 關閉 |
| [Phase 1.5](#p15) | 順序、source mapping、圖片、white-space、paint | 已報完成 | 16 commits；56/56 |
| [Phase 2A](#p2a) | Reader DEBUG 接入、scanner、整章 fallback、A/B | 已報完成，部分早期結論後被修正 | 19 commits；76/76；12 本 corpus |
| [Phase 2B](#p2b) | 增量分頁、記憶體、互動最小閉環 | 已報完成 | 25 commits；36/36 核心；發現漏載 head CSS |
| [紅樓夢真實回歸](#redchamber-regression) | root margin、body、cascade、production trace | 分批修復 | 內部測試通過後，真機仍暴露問題 |
| [Phase 2C](#p2c) | Production Rendering Correctness | 初次宣稱完成後驗收失敗，後續補正 | 座標、背景、border、大圖與模式語義 |
| [畫冊與導航修復](#gallery-navigation) | inline image、flowShift、forced terminal page | 分批完成紀錄 | 多輪根因更新，不能只採最早解釋 |
| [Phase 3A](#p3a) | Link / Annotation Interaction | 使用者確認完成＋對話內提交證據 | 圖片連結、anchor、noteref、pressed feedback |
| [Phase 4A](#p4a) | CSS Frontend Boundary Audit + Lexbor PoC | 已報完成 | 選 C：先保留 Current、建立 frontend 邊界；PoC 數字待正式驗證 |
| [Phase 4B](#p4b) | CSS Float Layout | 使用者確認完成，後續報告佐證 subset | 非完整 CSS float；auto width 等仍有限制 |
| [Phase 4C](#p4c) | EPUB Layout Capability Census | 已報完成 | 23 本／7,350 章；推薦 horizontal Ruby |
| [Phase 4D](#p4d) | Horizontal Ruby Inline Layout | 已報完成 | 152/152；4 本／75 章／613 組 |
| [Phase 4E Audit](#p4e-audit) | text-indent 現況與方案選擇 | 已決策 | 採方案 2 的責任分工修正版 |
| [Phase 4E0](#p4e0) | Inline formatting ownership refactor | 已報完成 | parity 通過；保留 width 相容值，之後再清理 |
| [Phase 4E1](#p4e1) | CSS text-indent | 已報完成 | 4,849 章 geometry 改變；2,469 章 unaffected parity |
| [DEBUG 真機 A/B](#visual-acceptance) | 同章、同設定切換 engine | 操作流程已提供；實際觀察有差異 | Legacy 原本已有 indent，新引擎不必故意不同 |
| [共享大圖根因診斷](#presentational-diagnostic) | `<img width="15%">` | 已定位 | 不是 selector 問題，是 presentational hint 未進 style |
| [Phase 4F0](#p4f0) | HTML Presentational Hints Normalization | 已報完成 | 2,019 章變化；5,290 章 unaffected exact parity |
| [Float 百分比圖片修正](#float-sizing) | 50% 容器內 85% 圖片 | 已報完成 | final containing block 解析；不改 exclusion 演算法 |
| [Used-Value Timing Audit](#used-values) | 最終尺寸／font 後才求 used values | 已報完成 | 147/147；完整 corpus 當輪未跑 |
| [跨頁裝飾＋缺字](#decoration-glyph) | 大框跨頁與中文問號方框 | 使用者表示已完成 | 缺獨立根因／測試結案摘要 |
| [Supported-Subset Correctness Gate](#supported-gate) | root 左右留白、table admission | 已報完成，曾有基線紅字 | root-x 修正；table scanner 沒漏判 |
| [Baseline Difference Attribution](#attribution) | 433 個 golden 差異歸因 | 已報完成 | root-x X-only；NEW／UNKNOWN 均為 0 |
| [Horizontal Baseline Closure](#closure) | 更新有依據的 golden、全 corpus、checkpoint | 已結案 | `b674e672`；7,140 supported／210 fallback |
| [Phase 5A](#p5a) | LexborCSSFrontend Production Migration | **進行中；cutover 未確認** | 已見 baseline、vendoring、owner、bridge 提交 |

只有提案、名稱被取代或沒有獨立執行證據的 `4E2`／`4F`／`4F1` 等，見[第 4 節](#proposals)，不要補成完成狀態。

<a id="phase-details"></a>
## 3. 逐階段紀錄

<a id="p1"></a>
### Phase 1 — Browser-Style Box Layout Engine

**狀態：已報完成。來源：[E02](#e02)。**

**目標**：在獨立 worktree 建立 browser-style EPUB 重排骨架，不改現有 CoreText production 管線。

- 分支：`feature/browser-layout-engine`；worktree：`../Yuedu-browser-layout`；基於 `aefbf82`。
- 11 個 commits；新增 `BrowserLayout/` 12 檔與一個測試檔。
- 五層管線：`ComputedStyleTree → LayoutBoxTree → FragmentTree → PageFragments → DisplayList`。
- 新引擎複用既有 `CSSParser`／`CSSSelector`，不是重新寫一整套 parser。
- block layout 包括寬度、percentage、auto margin、padding／border、margin collapsing。
- inline layout 使用 CoreText typesetter 斷行與度量；初期分頁以絕對 Y 推算頁。
- 23/23 tests；`BrowserLayoutFeature.isEnabled = false`；未接 ReaderView。

**當時限制**：`br`／white-space、圖片 atomic box、anonymous block 順序、rem、跨頁 fill、orphans／widows、calc 等未完整。

**不能沿用到今日的早期結論**：`floor(documentY/pageHeight)` 加單個片段位移，後來不足以處理畫冊推頁；最後增加了 continuation／flow displacement 等模型。

<a id="p15"></a>
### Phase 1.5 — 基礎語義、圖片與 Source Mapping

**狀態：已報完成。來源：[E03](#e03)。**

- 16 commits；56/56 tests。
- `BoxTreeBuilder` 保留 inline／block 交錯順序，不再跨 block 合併 anonymous inline group。
- fragment 保存 `sourceRange`、`nodeID`、`linkTarget`、`writingMode`；建立 anchor offset。
- root font size 用於 rem；補 `<br>` 和 normal／nowrap／pre／pre-wrap／pre-line。
- inline atomic image 使用 `CTRunDelegate`；加入 intrinsic、指定尺寸、比例、max-width 與移頁處理。
- cluster-safe 斷行，覆蓋 ZWJ emoji、combining marks 等。
- `DisplayListRenderer`、幾何斷言與兩張 golden PNG。

**當輪量測**：40 段 benchmark，legacy 約 23.5 ms、browser 約 11.7 ms，記憶體增量約 656 KB。這只是該 benchmark，不是所有 EPUB 的速度承諾。

**當時 golden 問題**：缺檔可自動錄製；Phase 2A 已改為缺檔預設失敗，錄製需顯式啟用並人工確認。

<a id="p2a"></a>
### Phase 2A — DEBUG Reader 接入與整章回退

**狀態：已報完成；早期 corpus 解讀後來被修正。來源：[E04](#e04)。**

- 19 commits；76/76 BrowserLayout tests；12 本 corpus A/B。
- `legacy`／`browserAuto`／`browserForced` 三種模式；**當時** Release 編譯鎖 `.legacy`。
- scanner 拒絕未支援的 vertical、ruby、float、table、flex/grid、position、MathML、SVG 等。
- `BrowserLayoutPageEngine` 接 `PageRenderingProvider`，resource adapter 複用 session／style resolver。
- 章節級 engine 決策與 fallback；generation token 防止過期結果發布。
- source offset ↔ page ↔ rect、anchor、link hit-testing、改字號恢復位置。
- A/B 記錄首三頁、page count、文字 parity、首頁延遲、完整布局、RSS、fallback reason。

**後來被推翻／補充的部分**：

1. 某些 browser 章節其實沒載到 XHTML `<head>` 的 linked CSS；當時高接受率不能代表真實 CSS 覆蓋。
2. 兩個 legacy tests 原稱 flaky，Phase 2B 發現其實是確定性失敗，方法級 filter 曾空跑。
3. 「Release 鎖 legacy」是當時狀態；後續對話內 repo 查閱顯示已另有 browserAuto 啟用提交，不能當永久現況。

<a id="p2b"></a>
### Phase 2B — 增量布局、生命週期與資料路徑修正

**狀態：已報完成。來源：[E05](#e05)。**

- 25 commits；36/36 核心 tests。
- `PageWalker` 改為可暫停／續跑的顯式 stack；batch 與 incremental 共用 walker。
- `BrowserLayoutSession` 提供 `layoutNextPage()`／`layout(untilSourceOffset:)`／`finish()`。
- 首頁完成即發布，剩餘頁續跑；`pageSourceRanges` 不再只在 init 算一次。
- MemoryTracker 按型別記錄；DisplayList 使用 ±2 頁窗口與 eviction／重建。
- 選取、標註、TTS 最小 contract；當時 range rect 還有比例切分策略，不等於完整字形級選字已完善。

**重要根因**：`EPUBBrowserLayoutResourceAdapter` 漏 `<head><link rel="stylesheet">`。補載 CSS 後 page difference 歸零，但 scanner 拒絕率上升；這是更誠實的能力判定，不是新增退化。

**測試可信度修正**：方法級 filter 得到 `totalTestCount: 0`，不能算通過；legacy 的 longTable／chatBubble 失敗可在 base worktree 重現，交付 repro 和 issue，而非偷偷改 legacy。

**已報限制**：MemoryLifecycle 某 class 組合在本機模擬器會 hang；不應將核心 36/36 擴寫成所有測試都毫無環境問題。

<a id="redchamber-regression"></a>
### 紅樓夢真實回歸與 Production Trace

**狀態：分批修復；內部測試通過不等於當時真機已過。來源：[E06](#e06)、[E07](#e07)。**

**第一批提交**：

- `9c5cdb9`：先加真實 EPUB regression，修前出現關鍵失敗。
- `d619bdc`：root margin collapse、DOM-aware scanner、body background-image。
- `2b5664a`：font-size／line-height 解析順序，處理 cascade 字典順序造成的飄動。

章節以 `<title>`／標題文字定位「第一回」與人名，不綁 spine index。當輪 RedChamber 8/8、Browser 63/63、Legacy EPUBRenderingTests 57/57；缺真書時 7 個真實測試明確 skip，synthetic 仍執行。

**另一批 production 回歸**：`fcf94af` 修 rgba parsing 及 fixture 誤認 body fill，報 Production 5/5、Browser 69/69、Legacy 57/57；亦檢驗 fixed font policy。

**真機觀察的轉折**：使用者後來發現先前部分截圖可能仍走舊引擎。之後改成真機 log、effective engine 和實際 paint path 驗證。

保留的教訓：同一組 fixture 算得自洽、測試顯示綠色，不足以證明實際安裝的 build、engine、字體、viewport 與被比較畫面相同。

<a id="p2c"></a>
### Phase 2C — Production Rendering Correctness

**狀態：初次完成後真機驗收失敗，後續修復逐步吸收。來源：[E08](#e08)、[E09](#e09)。**

原始範圍是座標契約、root/body canvas、背景／完整 box paint、大型圖片 atomic 分頁、fallback 與 overlay 語義。使用者明確表示 2C 已跑完，但最新真機仍有章名偏右、畫冊重疊與不可信的座標 log。

因此本台帳不把「2C 完成」等同於所有該範圍問題當場消失。後續修正包括：

- 標題／圖片使用錯誤的 inline containing width。
- inline 圖片高度未正確撐開 line box 和父 block。
- 圖片被移頁後，後續 caption／sibling 未同步移動。
- forced mode 不 fallback 後產出零頁，造成 placeholder 重試。
- body background、rgba、border、SVG 圖片包裝與 NBSP-only 內容的處理。

這些工作後來才在 broader horizontal baseline 中取得較完整的結案依據。

<a id="gallery-navigation"></a>
### 畫冊殘片、Forced Mode 與 Flow Displacement 修復鏈

**狀態：有多次提交／診斷紀錄，最早根因説明不是最終結論。來源：[E09](#e09)、[E10](#e10)。**

| 提交／紀錄 | 解決內容 | 後續限制／修正 |
|---|---|---|
| `1c75103` | 修 inline 大圖被 line-height clamp 等；報 synthetic 三圖無重疊 | 真機仍有殘片；`minY<0` 搬頁頂曾是疑點；不可視為完整修復 |
| `c78261b` | gallery flow height、巢狀水平置中、forced mode diagnostics | forced 零頁仍導致 main-thread 重試風暴 |
| `29192ec` | forced 章節 terminal diagnostic page、layout state、in-flight dedupe | 不再用空 pages 同時代表 loading／failure／unsupported |
| `abf5fe4` | 取消圖片 75/25 ascent/descent 人工切分；統一 `flowShift` | 圖片位移／縮放必須推動後續 text／fill／image，不再局部 clamp |
| `5a69465` | 單 raster image 的 SVG wrapper、NBSP-only 背景頁 | 不代表完整 SVG 能力已實作 |

**當時 log 可重現的症狀**：627.2pt 圖片的相鄰 y 只增加約 60pt，或跨頁後多圖同為 page-local y=82；這些是 flow／fragmentation 問題的現象，不是新的 CSS 圖庫標準。

**保留的政策**：區分 flow start、unforced break、forced break；斷頁邊距不能靠「頁空就吞 margin」泛化。實際實作／驗收以後續通用規則和 baseline 為準。

<a id="p3a"></a>
### Phase 3A — Link / Annotation Interaction

**狀態：使用者明確確認已完成；對話內曾讀到相應提交。來源：[E11](#e11)。**

主線：`DOM <a href> → link semantic → fragment geometry → interaction region → hit-test／pressed feedback → resolver／navigation／footnote`。

涵蓋的工作包括文字與圖片連結、跨 run／跨行區域、同章／跨 spine anchor、noteref、backlink、外部 URL，以及不參與 layout 的 pressed highlight。

對話內 repo 查閱的 `a9afd634` 提交摘要記載：

- 修 `<a><img></a>` 能畫但點不到；部分 block image 的 node/link identity 丟失。
- 修無自身文字的 image anchor 無法精確返回正文。
- 加入 `LinkInteraction.swift` 與共用 resolver。
- 註解呈現統一為 tap owner 提供 anchor rect 的原生 popover；早期「沿用既有 popup」是設計方向，不代表最後 UI 仍是舊 bottom sheet。
- 該歷史提交也記載 browserAuto 啟用；不是本文件重新確認目前 store build 的設定。

**名稱注意**：早期也曾把 `Phase 3` 用作 Float 計畫、把 `3A/3B` 用於 logical geometry／vertical 規劃。不能因此推定 vertical 已完成。

<a id="p4a"></a>
### Phase 4A — CSS Frontend Boundary Audit + Lexbor PoC

**狀態：已報完成；正式整合效能與 cutover 尚未由此階段證明。來源：[E12](#e12)。**

**工作**：盤點 Current frontend，建立隔離 Lexbor C build／harness，評估 parser、selector、style 與 Swift adapter 邊界。

**報告結論 C**：暫保留既有前端，先建立 `CSSFrontend`／`LegacyCSSFrontend`，後續再評估遷移。附件末段記錄建立 `CSSFrontend.swift`、修改 `BrowserLayoutDocument` 並跑相關 tests。

**重要邊界**：

```text
float:left → 解析／cascade → style.cssFloat=.left        前端
float 放在哪、旁邊剩多少文字寬、怎麼跨頁                  layout
```

**證據限制需保留**：

- 附件提供 C harness、命令歷程與報告，但不能由此斷言完整 iOS production adapter 已完成。
- 「體積增加 480–850 KB」「快 3.5–6 倍」「完全 thread-safe」「無記憶體碎片風險」是早期報告的主張；對話後續已要求正式 build／archive／真機量測，不繼承成已驗證事實。
- `clear:both` 被報告為 Lexbor omission，仍需固定版本與最小 repro 才能作正式 upstream 結論。
- `CSSFrontend` protocol 存在，不自動證明所有 DOM 相依已解除；Phase 5A 另要求 neutral snapshots、source identity 和 C lifetime 驗證。

附件定位：`已貼上文字 (1)(8).txt`，主要 audit 約第 455–625 行，最終摘要約第 688–736 行。

<a id="p4b"></a>
### Phase 4B — CSS Float Layout

**狀態：使用者確認「做完了」，本對話未貼完整獨立結案摘要；後續診斷與回歸佐證有正式 subset。來源：[E13](#e13)、[E22](#e22)。**

**原定範圍**：horizontal left／right float、矩形 margin-box exclusion、clear、逐行可用 interval、圖片與基本 box、分頁與 scanner 精確放行。

後續確定存在：`FloatContext`、definite-width non-replaced float、圖片／caption 與 inline 內容、逐行文字繞排。`float + width:auto`、某些 fragmentation 組合仍 fallback；不得將本階段寫成完整 CSS float 已畢業。

**後續修正**：圖片被拿 global renderWidth 算 percentage，先在 float 子樹修正，後由 Used-Value Timing Audit 推廣到普通圖片／block。

**測試證據**：原始 phase 沒有可核對的完整 passed count；後續 Float suites 出现在 Ruby、indent、used-value、baseline closure 的 focused gates，勿倒填一個 phase4B 數字。

附件 `EPUB排版引擎探討.txt` 保存的是當時的 Float prompt／建議，不是 Float 執行結果。

<a id="p4c"></a>
### Phase 4C — EPUB Layout Capability Census

**狀態：已報完成。報告日期：2026-08-22。來源：[E14](#e14)。**

**範圍**：23 本／7,350 linear chapters，含 IDPF 4 本、真實 EPUB 8 本、repo samples 6 本、generated fixtures 5 本。

方法包含 production resource adapter、DOM、selector matching、cascade、DOM semantics 與 OPF metadata。當 production selector 不支援時，有 test-only SwiftSoup selector 輔助統計；該次 unsupported occurrence 的 `frontend` bucket 是 0。

**主要發現**：

| 能力／缺口 | 當時統計 | 決策意義 |
|---|---|---|
| Ruby | 5 本／88 章／5,216 組 | horizontal 4 本／75 章／613 組，先做這個 subset |
| text-indent | 至少 6 本／4,755 章；大量 `2em` | scanner 沒拒絕的 silent geometry gap，獨立 correctness phase |
| Table | 4 本／43 章（含 CSS table display） | semantic table 和 inline-table 不同 subset |
| 未支援 Float | 2 本／25 章，310 個 auto-width boxes | 需要 shrink-to-fit 等，不代表基本 float 沒做 |
| Vertical | 2 本／108 章 | publication routing 與 CSS scanner 統計不同 |
| @media | 1 本／16 章 | 全為 dark-mode 分支；frontend／scanner 精度議題 |
| Flex／Position／calc | 18／9／1 章 | 可能同章重疊，不能用單項 count 當可獨立解鎖量 |

當時 11 本、247 個不重複 chapter fallback。原因 count 可以重疊。

**限制**：Kusamakura 15 章使用 test-only ZIP fallback 處理 Unicode href ingestion；不代表 production 該資源路徑已修好。`frontend=0` 是特定 census 觀察，不是 HTML semantics、presentational hints 或 parser 全面正確的認證。

產物：`phase4c-layout-capability-census.json`、Kusamakura shard、census test harness、`merge_phase4c_census.py`。

<a id="p4d"></a>
### Phase 4D — Horizontal Ruby Inline Layout

**狀態：已報完成。來源：[E15](#e15)。**

- `RubyInlineUnit` 保存 base／annotation pieces、source／style／link／node；`RubyBox` 保存量測結果。
- base／annotation 分開 CoreText line，advance 取容納兩者的寬度；實作的 subset 使用上方 annotation 與置中。
- atomic placeholder 進 parent inline line；不在 unit 內斷行。
- annotation 參與 ascent、line-height、pagination，產生自己的 fragment／display item。
- annotation 用 `.wholeRange` 指回 base range；`rt` 不併入正文 source text，`rp` 不顯示。
- scanner 與 layout 共用 computed-style predicate。

**已支持 subset**：horizontal、單 direct `rt`、一般 inline descendants、center／over／separate。vertical、nested、rb／rtc、多 `rt`、block／replaced descendants、其他 position／align／merge 繼續回退。

**驗證**：focused 152/152；真實 horizontal 4 本／75 章／613 組；corpus test 1 passed／0 failed／0 skipped。

這些數字不是 5,216 組全部啟用；4,603 組 vertical Ruby 仍屬後續工作。

<a id="p4e-audit"></a>
### Phase 4E Audit — text-indent 與 Inline Ownership 決策

**狀態：完成 audit，採方案 2 的責任分工修正版。來源：[E16](#e16)。**

**原缺口**：CSSParser 留住 declaration，但 `ComputedStyle` 無 textIndent；`ComputedStylePropertyApplier` 忽略它，還沒進 layout 已丟失。

**產品 contract**：author CSS 覆寫 reader default，非 additive。EPUB shipping default 是 0，無首行縮排 UI；TXT／網路小說另有 2em default。

原方案：

1. 只對受影響 box 做 post-width reflow。
2. 全面調整 inline layout 的呼叫時機。
3. 直接依賴 NSParagraphStyle firstLineHeadIndent。

使用者不希望 feature-specific 重排不斷累積，選 2 的方向；最後確立為：**BlockLayout 先提供最終寬度與 context，InlineLayout 繼續獨占 shaping／斷行，不把 CoreText 工作塞進 BlockLayout。**

因此拆成 E0 純 ownership parity，再 E1 加 indent。這是本專案的改造決策，不代表所有一般瀏覽器的重新排版都屬於錯誤架構。

<a id="p4e0"></a>
### Phase 4E0 — Inline Formatting Context Ownership Refactor

**狀態：已報完成；當時尚未 commit。來源：[E17](#e17)。**

- BoxTreeBuilder 只建 `BlockBox`／未排版 `InlineRun`，不 shaping。
- BlockLayout 先定 box model、used width、child position 與 FloatContext，再建立 IFC 並呼叫 InlineLayout。
- shaping、CTLine、Ruby、inline image、float interval 仍由 InlineLayout 負責。
- 保留 `establishedInlineSize` 相容層，刻意不在純 refactor 順手改 historical width geometry。
- 處理過期 FloatContext 不應影響後續 block。

**驗證**：synthetic fingerprints＋oracle 9/9；完整 corpus 7,162 supported／188 fallback；immutable POST comparison 1/1；相關 focused 曾為 136/136；Ruby 75 章／613 組。

PRE SHA-256：

```text
ff979f6283a17b4ddbef9ec58b28f46571484d4d9d181eff342668350f5602a3
```

font process 變異有嚴格 test-only same-process differential，要求 row identity／source／scanner 等條件，不能把它理解成忽略 geometry 差異。

**後續狀態**：Used-Value Timing Audit 已讓最終 content width 統一進 IFC；歷史相容參數後來仍存在，但報告稱不再參與 geometry。

<a id="p4e1"></a>
### Phase 4E1 — CSS text-indent

**狀態：已報完成。來源：[E18](#e18)。**

- `.length(CSSLength)`／`.unsupported` typed model；0、px／em／rem／percentage 與正值。
- negative、hanging、each-line、modern functions、未知 multi-token 暫 gate。
- inherited，child 0 可覆寫；`ownsFirstFormattedLine` 管 anonymous／nested block。
- 最終 inline size 後解析 percentage；`float available interval → first-line constraint → line breaker`。
- 沒有 PageWalker text-indent 分支，沒有 paint 位移、全段 padding 模擬或專用 post-width reflow。
- EPUB default 0；沒有新增 UI。

**原輪量測**：

| 項目 | 數量 |
|---|---:|
| Corpus | 23 本／7,350 章 |
| Browser supported／fallback | 7,136／214 |
| 命中 supported text-indent | 4,855 |
| 可歸因 text-indent | 4,851 |
| Geometry 實際改變 | 4,849 |
| Unsupported syntax | 26 |
| 另有既有 float fragmentation fallback | 4 |
| Unaffected parity | 2,469：2,450 exact＋19 same-process oracle |

Fresh gate 59/59；focused 121/121；Ruby 75 章／613 組；舊 PRE 未重錄。這幾組測試範圍可能重疊，不能相加。

<a id="visual-acceptance"></a>
### DEBUG A/B 真機驗收與開發方向修正

**狀態：已有切換入口與候選章；使用者觀察不等同全面視覺通過。來源：[E18b](#e18b)、[E19](#e19)。**

候選：普通 `2em`、float＋indent、ruby＋indent、無 indent control。操作以相同 viewport／font／字號／行距／邊距，切換 Legacy／BrowserForced，盡量保持 `(spineIndex, charOffset)`。

使用者回饋：A／B 幾乎沒差，C Ruby 有差；整體仍覺得 Legacy 較少錯位。之後更明確澄清不想用逐本書對照作為開發主線。

**保留的解讀**：Legacy 本來已有 indent，所以補上後相近不代表沒作用。引擎間差異要區分合法排版差、已支持規則的錯誤、forced 未支持內容；不將所有差異判為 Browser bug，也不因測試多就聲稱 Browser 已全面勝過 Legacy。

<a id="presentational-diagnostic"></a>
### 共享大圖診斷 — 圖片尺寸提示未進樣式

**狀態：根因已定位，成為 Phase 4F0 的依據。來源：[E20](#e20)。**

精確例子：metadata《詭秘之主》，spine 5，`OEBPS/Text/tlh001.xhtml`；檔名中的「4」不是正式書名。

```html
<div class="pp">
  <img alt="pp" class="pp" src="../Images/gm3.png" width="15%"/>
</div>
```

- 2 份 stylesheet、159 rules；img 無 matched author rule，父 div 規則正常。
- width 要求來自 HTML attribute，不是 CSS selector 被漏掉。
- Legacy width=nil、Browser width=auto，兩者都看不到 15%。
- intrinsic 800×800；418pt containing width 下兩者原出 418×418。
- 若正確保留 15%，結果應約 62.7×62.7，置中由父 text-align 決定。

**已推翻的早期猜測**：不能把「新舊都同樣錯」直接寫成 parser／selector bug；此例是共同的 presentational attribute → style 缺口。

<a id="p4f0"></a>
### Phase 4F0 — HTML Presentational Hints Normalization

**狀態：已報完成。使用者完成訊息時間：2026-08-27。來源：[E21](#e21)。**

架構：`SwiftSoup Element → HTMLSemanticElement → HTMLPresentationalHintExtractor → typed hints → 正常 cascade → Legacy／Browser style → 原 layout`。

本輪只實作 img width／height。body／table／align 等掃描未命中，列 deferred，不假裝已全支援。

**Census**：23 本／7,350 章。img width：4 本／2,060 章／4,313 elements；img height：3 本／479 章／1,038 elements。`height="auto"` 不產生 dimension hint，不轉成 0。

**合約**：hints 不能在 cascade 後強蓋 CSS；author width:40%、inline width:30%、important 都可按既定優先順序覆寫。Legacy 的 absolute width／auto override 會清除殘留 raw percentage。

**驗證**：13 synthetic＋1 production＝14/14；相關 image suites passed；gm3 兩後端均約 62.7×62.7。

完整 corpus：2,060 章含相關 attribute，2,019 章 geometry change；5,290 章無相關 attribute，5,290/5,290 identical。PRE／unrelated golden 未重錄。

一章因 image hint 縮小而解除原 float-fragmentation failure，是精確允許的 transition，不是 scanner 任意放寬。

<a id="float-sizing"></a>
### Float Geometry Diagnostic 與 Percentage Image 修正

**狀態：已報完成；後續由全域 used-value audit 接續。來源：[E22](#e22)。**

章節：metadata《詭秘之主》，spine 68，`非凡物品 封印物品`，`OEBPS/Text/ffwp001.xhtml`。

**先釐清能力**：BrowserAuto supported=true，無 rejection；不是未做 table／position／flex。右圖左文繞排本來就是正確設計。

```html
<div class="ctright">
  <img width="85%" height="auto" src="../Images/ffwp001.png"/>
</div>
```

父層 `float:right; width:50%; margin:1em .2em; text-align:center`。

```text
body content width             409.640
float content width = 50%       204.820
image width = 85% of float      174.097

修前誤用：85% × global 418 = 355.300
```

**首錯層**：BoxTreeBuilder 太早求 image used size；final float width 出現時沒有更新。Exclusion 和 line breaking 使用錯尺寸，是下游後果。

當輪改在 BlockLayout final width 後、IFC 前解析 float 內 replaced image，未修改 renderer／scanner／parser。Synthetic 驗 400 → body392 → float196 → image166.6；浮動底下恢復全寬。

**同一章其他元素診斷**：藍色 heading、橘色 heading、資訊框均為普通 supported block；`double` border paint 缺口是另一件事，不能拿來解釋文字消失。

**歷史限制**：當輪非 float 圖片仍保持 E0 compatibility；下一節才統一推廣。

<a id="used-values"></a>
### Used-Value Resolution Timing Audit

**狀態：已報完成。來源：[E23](#e23)。**

此工作沒有新的正式數字編號；不要把它冒充另一個已執行的 4F1。

**完成修正**：

- IFC／text-indent 統一 final `box.contentSize.width`。
- BoxTreeBuilder 只留 image intrinsic metadata；inline／block／float 圖片於 BlockLayout 用最終 containing block 求 used size。
- percentage height 不再拿 inline width 當參考；無 definite containing height 時按 auto 行為處理。
- max-width clamp 後重算 auto margins。
- line-height 在完整 cascade 確定 font-size 後解析；unitless line-height 在子元素依子 font-size 計算。
- em／rem border width、radius 不再用 hard-coded 17／400。
- `inlineContainingSize` compatibility parameter 仍在，但報告稱不參與 geometry。

**明確未完成**：一般 block 的 percentage／em／rem height definite block-size model；min-width／min-height／max-height；percentage radius；explicit background-size lengths；部分 background paint correctness。

**驗證**：16 synthetic；fresh focused 147/147，0 failed／skipped；unaffected oracle exact parity。只更新直接命中新規則的 assertions／一個 prose fingerprint，未重錄 unrelated golden。

**當輪未做**：完整 7,350 章 sweep 仍受 marker gate 控制，報告明確沒有宣稱已跑；後來 closure 才補全。

<a id="decoration-glyph"></a>
### Fragmented Block Decoration + Missing Glyph Correctness

**狀態：使用者後續表示「我做完了」，但未貼獨立完整 root-cause／測試結案報告。來源：[E24](#e24)。**

兩個被要求一起查清的問題：

1. 「制作细则」長 bordered block 跨頁時，Browser 裝飾穿過 page content 底部；Legacy 確認有第二頁 continuation，不能誤認第一頁就是文件結尾。
2. Character Introduction 區塊 Browser 出現中文問號方框，Legacy 可正常顯示。

原任務要求分別 trace：box fragment／display list／clip，以及 source Unicode／font selection／registration／shaping／paint；synthetic reproduction 後作 generic fix。

**不可擅自寫死的根因**：對話只曾懷疑 font fallback 和跨頁 decoration，不足以確定具體修復就是哪個 API／哪行程式。後續基線 gate 提及 font／border regressions，也不能補造這兩項的獨立細節。

後續工作已進入左右留白與 baseline closure；本項保留「完成確認＋待補歷史報告」狀態，不重開新功能任務。

<a id="supported-gate"></a>
### BrowserAuto Supported-Subset Correctness Gate

**狀態：generic root-x 修復完成；當輪全書 golden 尚紅。來源：[E25](#e25)。**

**Case 1：普通正文左右不等**

```text
viewport                            440 × 956
reader insets                       L24 / R24
page content                        x24, width392
UA body margins                     L8 / R8
body content width                  376

修前實際 fragment                   x24...400 → 留白24 / 40
修後實際 fragment                   x32...408 → 留白32 / 32
```

首錯層不是 Reader 漏 inset；BlockLayout 已扣 body margins，但 PageWalker root origin 未加左 margin／border／padding。

```text
rootContentOriginX = margins.left + borders.left + padding.left
```

reader inset 仍由 canvas 統一加入；只動 horizontal contract。作者 L10／R30 仍保留不對稱結果 34／54，沒有硬把所有 CSS 置中。

**Case 2／3：《壹▪洪武大帝》**

| 章節 | Spine | 真實結構 | Auto 結果 |
|---|---:|---|---|
| 扉頁 | 1 | table.vol-t，兩 cell | table fallback |
| 制作说明 | 2 | table.scbg9，16 rows／32 cells | table＋unknown-block-display fallback |
| 目錄 | 8 | table.scbg10，37 rows／111 cells | table＋unknown-block-display fallback |
| 第一章 童年 | 9 | table.scbg2，15 rows／45 cells | table＋unknown-block-display fallback |

「我們從一份檔案開始」是正文內容，不是 chapter title。四章是 reflowable，沒有診斷到此前猜測的 absolute／flex／vertical 等主因。**Scanner 沒漏判，不修這些 forced table 畫面。**

**當輪 gates**：4/4、29/29、6/6、2/2、4/4、11/11 各指定 class 通過；`BrowserLayoutLineBreakBaselineTests` 仍紅。page／line-count 差異不能單由 x-only hunk 解釋，因此未 commit、未更新 golden，進入 attribution。

<a id="attribution"></a>
### Line-Break Baseline Difference Attribution

**狀態：已報完成。報告日期：2026-08-31。來源：[E26](#e26)。**

對 **《紅樓夢》基線範圍** 的 root-x before／after，比較結果：

| 指標 | Before | After |
|---|---:|---:|
| Page count | 3,820 | 3,820 |
| Logical lines | 116,714 | 116,714 |
| Text fragments | 137,294 | 137,294 |
| Source／page ranges | 相同 | 相同 |
| Line width／break／fragment Y | 相同 | 相同 |

63,912 fragment rows 只改 x／documentRect.x；296 章受 root origin 影響，295 章 +3.66pt、cover +8pt。AFTER／repeat NDJSON SHA-256 相同。

**433 golden failures 的分類**：32 EXPECTED_X_ONLY、279 PREEXISTING_LINE_BREAK_DIFF、122 PREEXISTING_PAGE_DIFF；FONT_PROCESS_VARIANCE／NEW_REGRESSION／UNKNOWN 均 0。

**欄位定義修正**：golden 的 `lines` 實際是 text-fragment count，不是 logical line count。不可再混稱。

**最終可更新 provenance groups**：

| 分組 | 章數 |
|---|---:|
| Root X only | 32 |
| Final IFC width | 243 |
| Final IFC width＋line-height | 115 |
| Presentational hints＋final width | 43 |
| 合計 | 433 |

`ffeaf95` 搭配 typed zero-indent 重跑，458/458 與舊 golden byte-identical；逐項切回 provisional width／hint on-off，用於隔離真正來源。這是 attribution 實驗，不是新的 production fallback。

**資料保留**：報告／TSV 留存；約 278 MB 的五份臨時 capture 和臨時 worktree 已刪除。報告稱可重新生成，但原始刪除檔不能直接恢復；本文件不提供不存在的下載連結。

<a id="closure"></a>
### Horizontal BrowserLayout Correctness Baseline Closure

**狀態：已結案。報告檔名日期 2026-08-31；使用者回報在 2026-09-04 對話。來源：[E27](#e27)。**

**Checkpoint**：`b674e672 browser-layout: close horizontal correctness baseline`。

- 依 provenance 更新 433 rows；其餘 25 unchanged。
- CoreText advance normalization 另驗 18 既有 rows，沒有擴大更新範圍。
- Line-break baseline：0 failed／unknown／unexplained diff。
- Focused：300 passed／0 failed／8 skipped，skip 原因為 opt-in corpus／人工 diagnostic。
- 完整 23 本／7,350 章：7,140 supported，210 Legacy fallback。
- layout failures、diagnostic failures、crashes、invariant violations 全 0。
- 完整 corpus 兩次 geometry digest 和結構結果相同，nondeterministic rows=0。
- 無 production 書名／class／src／spine 特判；`git diff --check` 通過。

**退出決策 A**：停止這輪 horizontal correctness sweep。後續不再為了無限制找更多肉眼差異而重開相同工作；新的明確 generic regression 仍可另行修復。

**證據範圍**：這是該 23 本 corpus 與已宣稱 supported subset 的基線，不是所有 EPUB 或全部 CSS 已正確的證明。Spot-check 清單已建立；單凭清單存在不能寫成每個真機項目都已人工簽核。

<a id="p5a"></a>
### Phase 5A — LexborCSSFrontend Production Migration

**狀態：進行中；本對話未見 cutover 結案。來源：[E28](#e28)。**

**目的**：保留已結案的 BrowserLayout 後半段，將自製 HTML／CSS 前端逐步換成 Lexbor＋Yuedu adapter，降低 parser／selector／樣式前端的長期維護負擔。

**固定比較基線**：`b674e672`。另有 `d13ef94f` 的 pre-Lexbor baseline capture 提交。

**已出現在本對話的 repo 證據**：

| 日期（提交紀錄） | Commit | 內容 |
|---|---|---|
| 2026-09-04 | `a4715bc1` | Lexbor frontend migration 計畫 |
| 2026-09-04 | `d13ef94f` | pre-Lexbor baseline |
| 2026-09-04 | `f7e3d1f4` | deterministic v3.0.0 amalgamation vendoring |
| 2026-09-04 | `e8dd5ac5` | opaque Lexbor document owner |
| 2026-09-07 | `987ea443` | Lexbor DOM callback bridge |

上述是本對話先前工具讀到的紀錄，不是本次重新掃描 GitHub，也不保證沒有之後的新提交。

**已定案的設計方向**：

- 固定 Lexbor `v3.0.0`，upstream commit `2ae88a1c6b5261830eff73ee12bb3cdf805f3cfe`。
- 官方 `single.pl` 生成 `html css selectors style` 與必要依賴的 deterministic amalgamation。
- `Packages/CLexbor/` 保存 source、license／NOTICE、manifest、hash、手動 regeneration script；build 不下載、不使用 Homebrew runtime、不依賴 Lexbor Layout。
- 保留 production EPUB resource loader；`CSSFrontendInput` 保存 stylesheet identity／order／media／alternate 等。
- opaque document owner、callback snapshot、Swift value model；C handle 不外洩到 layout。
- Phase 4F0 的 HTML semantics 由共用 extractor 處理，不另寫一套圖片 hint parser。
- 所有現有 ComputedStyle fields 和 unsupported capability facts 必須可表示或明確分類；不得因 Lexbor 能 parse 就放行未知 layout。
- scanner 和 layout 應消費同次 frontend evaluation 的結果，而非各跑一套互相不同的 parser。
- Current／Lexbor frontend 可比對；保留 Current rollback。

**切換條件（仍待完成證據）**：synthetic differential、23 本 style differential、相同語義下 geometry parity、standards corrections provenance、scanner、lifetime／memory／cancel、正式效能、Debug／Release／archive、determinism。

**不能提前勾選**：document owner／callback bridge 只表示基礎整合；不代表所有 styles 已映射、不代表同章節完整可讀、更不代表 production default 已切 Lexbor。

**目前交接點**：讀既有 5A spec／plan，確認未完成 gate，繼續同一個 Phase。不要再開一個內容相同的新 Lexbor Phase。

<a id="proposals"></a>
## 4. 曾提出但未獨立結案的 Phase／分支

這些名稱確實在對話出現，但不能列成「都做完了」。保留它們是為了避免下一個 AI 再次拿舊 prompt 當現在的下一步。

| 歷史名稱 | 當時用途 | 台帳處理 |
|---|---|---|
| Browser-style cache／lazy font 優化 | stylesheet URL cache、lazy font、negative cache、background matching | 前置方向；缺獨立完成摘要 |
| Phase 3 — CSS Float | 紅樓夢 scanner 當時認為大量章節有 float | 實際 Float 主線後來以 Phase 4B 記錄 |
| Phase 3A／3B logical geometry／vertical | 早期 code comments 和提議 | 不等於 vertical 能力完成；3A 亦被用為 Link phase |
| Phase 4B — Layout Capabilities & Modular CSS Frontend | 4A 報告曾把 protocol、layout、CLexbor 引入混成下一階段 | 未獨立結案；不取代後來明確的 4B Float |
| Phase 4E — text-indent（原方案） | feature-specific post-width reflow 或全面 inline ownership 调整 | 實際拆為 E0 ownership＋E1 indent |
| Phase 4E2 — Horizontal Visual Correctness / Geometry Audit | 真機 A/B 發現差異後提出 | 未見完整獨立報告；後來轉為具體診斷與通用規則修正 |
| Phase 4E2 — Legacy / Browser Rendering Delta Audit | 分 Browser better／same defect／worse | 同上；不是已執行完的 corpus 工具 |
| Phase 4E2 — Visual / Geometry Differential Harness | 用大面積幾何差異找 candidate | 只有提案；使用者後來拒絕以逐書人工比較當主線 |
| Phase 4F — Horizontal CSS Layout Conformance Matrix | 按規範盤 containing block／BFC／IFC 等 | 未見獨立完成矩陣；不可標全部核心 CSS 已 audit 完 |
| Phase 4F — CSS Frontend / Style Pipeline End-to-End Audit + Lexbor Differential | 檢查資源／CSS／style 上游 | 提案；presentational hint 問題先被實際診斷並以 F0 修復 |
| Phase 4F — Lexbor CSS Frontend Migration | 使用者再次澄清長期目標後提出 | 後續正式遷移任務收斂到 Phase 5A |
| Phase 4F1 — Production-grade LexborCSSFrontend + Differential Cutover Gate | F0 後提出正式整合方案 | 沒有獨立完成／cutover 報告；追踪 5A，不重複計數 |
| Phase 4F／4G／4H 的 Vertical／Table／shrink-to-fit 排程 | 助手曾多次建議排序 | 都是歷史候選順序，不是使用者已批准的永久排程 |

**整理原則**：採原名稱＋目的辨識，不為了表格漂亮而自行重編歷史。新的正式編號應沿 repo 已核准 plan，而不是沿聊天中每一次臨時提案。

<a id="decisions"></a>
## 5. 不可遺失的架構決策

以下 `D-xx` 是本台帳的整理索引，不宣稱 repo 已有同名 ADR。

### D-01｜為通用規則重寫，不是因 Legacy 很爛

使用者不否認 Legacy 的成熟度。新引擎價值在於更可組合的 HTML／CSS／box／fragment 模型。不要再把「對著 20 本書抓差異」當長期主計畫，也不要因為新引擎暫時不如 Legacy，就否認重写的原始目的。依據：[E19](#e19)。

### D-02｜Parser、Style、Used Values、Layout 是不同責任

Lexbor 可以接手的範圍必須按實际版本／API／adapter 驗證；不是看到 README 的 CSS 支援就把完整 computed-style／layout 都外包。CSS 有 `85%`、最終 reference 是誰、排到哪一頁，是不同問題。依據：[E12](#e12)、[E20](#e20)、[E22](#e22)、[E28](#e28)。

### D-03｜Lexbor 決策曾改變；現在不要重新回到起點

| 階段 | 當時決策 | 原因／後續 |
|---|---|---|
| 初期談論 | 先當 reference，暫不換 | 當時新引擎尚未穩定 |
| 4A | C：protocol 先行，暫保留 Current | PoC 和邊界盤點 |
| 4C 後 | 先 Ruby／indent | 該 corpus 主要未支援項是 layout |
| 使用者澄清目標後 | 接 Lexbor 的長期方向成立 | 避免持续維護自製 CSS frontend，而非只增加這批書的接受數 |
| F0／used-value 修正期間 | 遷移提案存在，但先完成已確認的通用缺陷 | 不能因此寫成 Lexbor 永久取消 |
| `b674e672` closure 後 | 正式進 5A | 已有穩定後端 baseline 可隔離前端變化 |
| 最後 repo 紀錄 | source／owner／bridge 進行中 | 未確認 production cutover |

### D-04｜HTML Presentational Hints 是共用語義，不是書籍修補

`img width/height` 經 extractor 變 typed hints 進 cascade；不在 renderer 最後硬蓋尺寸。Future Lexbor DOM adapter 應複用它。依據：[E21](#e21)。

### D-05｜Inline Layout 的責任與呼叫時機

BoxTreeBuilder 保存未排版內容；BlockLayout 得到本次 layout 的 final content constraints；InlineLayout 負責 shaping／line construction／Ruby／image／float interval／first-line constraint。不把每個 feature 塞進 PageWalker 或 paint offset。依據：[E16](#e16)、[E17](#e17)、[E23](#e23)。

### D-06｜先保 parity，之後可有證據地修正舊 geometry

E0 留 `establishedInlineSize` 是當時純 ownership refactor 的隔離措施，不是永久標準。之後 final-width correctness 有依據地改變 line break／page count，應建立 provenance 更新基線，而非為保老 golden 永遠沿用錯 width。依據：[E17](#e17)、[E23](#e23)、[E26](#e26)。

### D-07｜Reader 留白與作者 margin 分層

Reader base insets 可以對稱；作者 CSS 仍可不對稱。真正發現的 root-x bug 在 PageWalker，而不是 Reader 少傳設定；不能加一條「所有頁左右強制相等」把作者設計消掉。依據：[E25](#e25)。

### D-08｜BrowserAuto 的能力承諾與 Forced 診斷分開

Auto 只放行已實作的 subset，不支持的章節整章 fallback；Forced 仍需穩定 terminal state，不能以零頁導致無限 ensure。supported 並非正確性的自動證明，仍可能有通用實作 bug。依據：[E10](#e10)、[E22](#e22)、[E25](#e25)。

### D-09｜Baseline 不是自動接受新輸出的工具

先有根因和正確性證據，再更新受影響 rows。沒有直接受到規則影響的樣本應維持原 geometry；有 legitimate style／width 改變的行不能硬要求舊分頁。`exit 0`、空跑、filtered subset、raw screenshot 一律不能混稱「全套驗收通過」。依據：[E05](#e05)、[E26](#e26)、[E27](#e27)。

### D-10｜兩個 Source Range 粒度要區分

Ruby annotation 會映射回 base 的整段 range，文字 fragment 也不必等於 logical line。因此「所有 display items 的 source range 絕不重複」不能當跨所有 item 類型的盲目斷言。現有報告應按 logical text、annotation mapping、fragment、page 各自定義驗收。依據：[E15](#e15)、[E26](#e26)。

### D-11｜對稱、置中、相同尺寸不能從截圖臆測

這段對話中多個最早猜測後來被 trace 修正。以 code／DOM／computed style／最早錯誤層為證據；截圖作為現象定位，不把「看起來像 table／像 parser 壞了」寫成已確認根因。依據：[E20](#e20)、[E22](#e22)、[E25](#e25)。

### D-12｜不要混入另一個 repo 或另一個 worktree 的未知狀態

早期新引擎在 `Yuedu-reader` worktree；使用者亦提到部分 CoreText 拆到另一 repo。當前對話不足以完整重建所有跨倉庫 ownership。5A 可見路徑是閱讀器 repo 內的 `Packages/CLexbor/` 與 BrowserLayout；後續修改前應以實際 checkout／package references 確認，不依聊天猜所在倉庫。

<a id="metrics"></a>
## 6. 基線與數字演變

### 6.1 Corpus admission 歷史

下表只對相同報告範圍保留數字；模型、能力與規則隨時間變化，不能用接受率升降單獨判斷品質。

| 階段 | Corpus | Browser supported | Unique fallback | 備註 |
|---|---|---:|---:|---|
| Phase 2A | 12 本小型 A/B | 原報告逐書統計 | 原報告逐書統計 | 後來發現漏 head CSS，不能拿當成熟能力覆蓋 |
| Phase 4C | 23／7,350 | 未在本文換算 | 247 | scanner／feature census 分口徑；理由重疊 |
| Phase 4E0 | 23／7,350 | 7,162 | 188 | ownership parity |
| Phase 4E1 | 23／7,350 | 7,136 | 214 | 26 章 unsupported text-indent 被明確 gate |
| Horizontal closure | 23／7,350 | 7,140 | 210 | `b674e672`，本對話最後已結案基準 |

這不代表 BrowserLayout 對全世界 EPUB 有某個固定支援百分比。

### 6.2 Closure 的 fallback reason 分布

| Reason | Count |
|---|---:|
| metadata vertical writing | 108 |
| vertical writing | 107 |
| unknown block display | 45 |
| unsupported text-indent | 26 |
| unsupported float | 25 |
| table | 25 |
| flex/grid | 18 |
| media queries | 16 |
| positioned layout | 9 |
| calc/min/max/clamp | 1 |
| MathML | 1 |
| scripted interactive | 1 |

**不要加總成獨立章數。**metadata 和 CSS vertical、table 和 unknown display 等可命中同一章；unique fallback 為 210。

### 6.3 重要基準物件

| 基準 | 用途 | 保留規則 |
|---|---|---|
| Phase 4E0 PRE JSON | ownership 重構前後比較 | 原 SHA 不改；不是每個後續 correctness 都必須維持 geometry |
| `redchamber.tsv` | 紅樓夢 line／fragment／page 基線 | 舊 `lines` 欄實為 text-fragment count |
| attribution 2026-08-31 | 433 舊 failures 的規則歸因 | 記錄分組，不把 page change 歸給 root-x |
| `b674e672` | 已結案 horizontal correctness | Phase 5A 後端比較基準 |
| `d13ef94f` | pre-Lexbor baseline capture | 用於遷移前端比較；不是新 layout 能力 |

### 6.4 真機 Spot-check 清單（Closure 建立）

Spine 全從 0 開始。清單是「待／供抽查的代表點」，不自動表示每個已由使用者人工驗收。

| 書 | Spine | 章節 |
|---|---:|---|
| 全能游戏设计师 | 16 | 第8章 这就是你刷分的理由吗 |
| 全知读者视角01 | 1 | 制作说明 |
| 全职高手 | 56 | 轮回战队 |
| 诡秘之主 | 8 | 塔罗会 戴里克·伯格 XIX The Sun.太阳 |
| 诡秘之主 | 64 | 诡秘百科 非凡途径 |
| 诡秘之主 | 136 | 第37章 俱乐部 |
| 壹▪洪武大帝 | 24 | 第十六章 建国 |
| 红楼梦（人民文学版本） | 138 | 第六十三回 寿怡红群芳开夜宴 死金丹独艳理亲丧 |
| Centered Percent Image | 0 | Centered Image |

<a id="defects"></a>
## 7. 已查明的通用缺陷與被修正的猜測

| 現象 | 早期猜測／容易誤判 | 後來的實際結論 | 對應工作 |
|---|---|---|---|
| 「第一頁看起來正常」，CSS 支援率很高 | Browser 已能處理大部分樣式 | head linked CSS 漏載；讀到真 CSS 後應回退更多章 | 2B |
| 大圖疊成很多卷軸頂端 | 單純 clip／單圖太大 | inline line metrics、父 flow height、錯 ascent/descent、移頁後 flowShift 等多層缺口 | 畫冊修復鏈 |
| Forced 模式點圖／開章卡住 | 圖片解碼或隨機 hang | 零頁 terminal 狀態缺口，placeholder ensure 重試風暴 | `29192ec` |
| 「愚者」等標題消失／出框 | 一定是 table／position 或單純 font | 當時多項仍須分開 trace；A/B/D 後續指向 final inline width 等；不能一概指定根因 | used-value 等 |
| 紅色裝飾圖新舊都巨大 | parser／selector 一定沒 match | `width="15%"` attribute 沒 normalize 進 style | 4F0 |
| 右圖左文很難看 | 繞排本身不應存在 | 原設計就是右 float；85% 誤相對 global width 而非 50% float container | Float size fix |
| 每章 content 左移、左右留白不同 | Reader 沒給對稱 inset | Reader inset 正確；root width 扣了 margin、PageWalker origin 卻漏加 | root-x |
| 明朝扉頁／目錄／timeline 散掉 | 普通 box／absolute 混乱 | 真實 table；Auto 已正確 fallback，Forced 不代表承諾能力 | supported-subset gate |
| baseline 433 處失敗 | root-x 又把換行改壞 | root-x 只改 X；其餘來自先前 final width、line-height、hint correctness | attribution |
| golden `lines` 改變 | 一定 logical line count 改變 | 欄位實際是 text-fragment count，需另量 logical lines | attribution |
| test succeeded | 全套通過 | 方法 filter 曾 0 tests；後來以 actual count／xcresult 判定 | 2B、後續 gates |
| 兩個 legacy tests 曾稱 flaky | 隨機 shared-state | 對照後是確定性既有失敗，先前單跑為空跑 | 2B |
| 中文問號方框 | 一定缺 fallback | 當時提出 font path 調查；此對話未提供最終獨立根因報告 | 裝飾＋缺字工作 |

本表的書名只用作回歸來源定位；不是 production 分支條件。

<a id="roadmap"></a>
## 8. 能力邊界與後續工作

### 8.1 已有完成依據的核心能力

Horizontal block／inline、現有 box model subset、final-width used-value 修正、基本圖片與 HTML width／height hints、basic Float subset、horizontal Ruby subset、text-indent subset、source／link／annotation 互動、增量分頁、root origin、回歸基線。

以上均有 subset 與歷史限制；不是全部 CSS2／CSS Text／CSS Fragmentation 的完整 conformance 宣告。

### 8.2 尚未確認完成或明確 deferred

| 類別 | 最後已知限制／待做 |
|---|---|
| Lexbor | 正式 ComputedStyle adapter 覆蓋、差異歸因、正式建置／lifetime／perf／cutover gates 待結案 |
| Table | semantic table、CSS table display／inline-table；新 BrowserLayout 尚未見完成 |
| Vertical | publication routing 仍 fallback；不是只把橫排座標旋轉就算完成的已交付項目 |
| Float | width:auto／shrink-to-fit、部分 fragmentation／更複雜組合 |
| Ruby | vertical、nested、rb／rtc、多 pairing、under／inter-character、其他 align／merge |
| text-indent | negative、hanging、each-line、modern function 等未支持 subset |
| Block sizing | audit 列出的 definite block-size、部分 min/max-size 模型未完整 |
| Paint | double border、percentage radius、explicit background-size／部分 background placement 未有獨立完成紀錄 |
| Flex／Grid／Position | 未見對應新 layout completion |
| Media／calc | conditional evaluation、modern value 模型仍有限制；Lexbor 能讀不等於引擎能執行 |
| MathML／互動／SVG | 無完整新能力完成報告；SVG 單圖 wrapper 支援不等於完整 SVG |
| Presentational hints | img align、table／body 等暫未實作 |
| 資源／字體 | Kusamakura test-only ingestion fallback、早期 process-generated font identity 的處理需按最新 production 證據判定 |

### 8.3 下一步的唯一已啟動主線

**繼續 Phase 5A；不要重開 horizontal sweep，也不要同時啟動 Table／Vertical。**

5A 結案後再選下一個 layout capability。對話最後一次建議把 Table 作大功能候選、Vertical 接後面；這是候選順序，**使用者尚未在本段對話確認啟動，也沒有正式下一 Phase 編號**。

### 8.4 尚欠的歷史證據，而非新功能任務

- Phase 4B 的完整獨立完成報告／commit。
- Fragmented decoration＋missing glyph 的精確根因／修復提交／獨立驗證摘要。
- 4A PoC 所稱效能／體積／完整 cascade 能力的正式證據；不得直接繼承成 production guarantee。
- 5A 的完整差異、cutover YES／NO、正式 default 和切換 commit。
- 最後 spot-check 清單哪些已由使用者簽核；清單本身不是人工完成紀錄。

歷史報告提到「當時未 commit」的項目，後來可能已納入 checkpoint，但本對話沒有逐項 commit 對映，不能自行補 hash。

<a id="artifacts"></a>
## 9. Commit 與文件索引

### 9.1 重要 Commit

僅列本對話出現過的提交，不是 repo 完整 commit history。

| Commit | 用途／階段 | 證據來源 |
|---|---|---|
| `aefbf82` | Phase 1 worktree base | E02 |
| `9c5cdb9` | 紅樓夢 regression tests | E06 |
| `d619bdc` | root margin／DOM-aware scanner／background | E06 |
| `2b5664a` | cascade font-size／line-height | E06 |
| `fcf94af` | rgba／production regression | E07 |
| `1c75103` | 第一輪 inline gallery 修復 | E09 |
| `c78261b` | gallery／center／forced diagnostics | E09、E10 |
| `29192ec` | forced terminal page／livelock | E10 |
| `abf5fe4` | image metrics／flowShift／margin rule | E10 |
| `5a69465` | SVG image wrapper／NBSP | E10 |
| `02cfd82e` | float 有效值 gate／line-break net（歷史） | E10、E11 |
| `227e294d` | declaration source order 修正 | E10 |
| `7501c164` | BrowserLayout feature merge（歷史） | E11 |
| `a9afd634` | Link／annotation 與 browserAuto 啟用紀錄 | E11 |
| `ffeaf95` | baseline attribution 對照點 | E26 |
| `b674e672` | horizontal correctness baseline closure | E27 |
| `a4715bc1` | 5A 計畫 | E28 |
| `d13ef94f` | pre-Lexbor baseline capture | E28 |
| `f7e3d1f4` | Lexbor v3.0.0 deterministic amalgamation | E28 |
| `e8dd5ac5` | opaque Lexbor document owner | E28 |
| `987ea443` | Lexbor DOM callback bridge | E28 |

### 9.2 已提及的報告／測試產物路徑

路徑以 repo 相對文字列出。這些檔案是對話所引用的產物，**不代表本次產出的單一 Markdown 已附带它們，也沒有逐一驗證現在仍存在**。因此本索引用 code path 而非製造不可用的本機下載連結。

| 路徑／群組 | 用途 |
|---|---|
| `docs/browser-layout/phase1.5-report/` | snapshot、fragment dump、metrics、source text |
| `docs/browser-layout/phase2a-report.md` | 12 本 A/B |
| `docs/browser-layout/phase2b-legacy-flaky-issue.md` | legacy 確定性失敗／空跑澄清 |
| `docs/browser-layout/phase4c-layout-capability-census.json` | capability census |
| `docs/browser-layout/phase4c-census-parts/kusamakura.json` | ingestion fallback shard |
| `scripts/merge_phase4c_census.py` | shard 合併 |
| `docs/browser-layout/phase4e0-inline-context-pre.json` | immutable PRE |
| `docs/browser-layout/phase4f0-html-presentational-hints-census.json` | img hint 統計 |
| `docs/browser-layout/used-value-resolution-timing-audit.md` | used-value timing／reference 矩陣 |
| `docs/browser-layout/line-break-baseline/redchamber.tsv` | 458-row golden |
| `docs/browser-layout/line-break-baseline/attribution-2026-08-31.md` | 差異根因歸因 |
| `docs/browser-layout/line-break-baseline/attribution-2026-08-31.tsv` | 逐 spine 分類 |
| `docs/browser-layout/line-break-baseline/closure-2026-08-31.md` | checkpoint 結案 |
| `docs/superpowers/specs/2026-09-04-lexbor-css-frontend-production-migration-design.md` | 5A 設計 |
| `docs/superpowers/plans/2026-09-04-lexbor-css-frontend-production-migration.md` | 5A 執行計畫 |
| `Packages/CLexbor/` | 正式 vendoring／bridge package |

早期 `docs/superpowers/plans/2026-08-04-browser-layout-engine.md` 被報告為 `.gitignore` 內的 local plan。4A 的 `implementation_plan.md`／`walkthrough.md` 在 agent 私有 scratch 目錄。不能把這些當成 repo 已可靠保存的正式文件。

### 9.3 建議放置本台帳的位置

可放入既有 repo 的 `docs/browser-layout/PHASES.md`，或直接在 Obsidian 打開本檔案。這只是檔案放置建議；本次沒有修改使用者 repo、建立 vault、寫入 Slack 或同步 GitHub。

後續每個 Phase 的狀態應引用對應 spec、plan、實作／驗證 commit 和實際測試範圍；不要只把聊天裡的「完成」複製成所有 gate 全綠。

<a id="sources"></a>
## 10. 來源索引與證據限制

### 10.1 使用方式

本檔案離線可讀，因此使用 `E01–E29` 對话來源索引，不保留只能在原聊天介面解析的 `filecite`／`memcite` token。

- **使用者完成報告**：使用者貼上的 agent 報告，是本整理的主要依据；不等於本次重新執行。
- **使用者明確確認**：可記為完成確認，但不補造缺少的根因／test count。
- **先前 GitHub 工具結果**：本對話已實際取得的歷史提交／檔案；不代表本次重查最新 repo。
- **助手提案或推測**：只作規劃歷史，不當成已完成或已確認技術結論。

由於部分原對話內容在目前上下文中略去，本台帳只整理可見報告、已讀附件與既有工具證據；未見者明確標記，不聲稱重建了所有本機 commit 或所有歷史訊息。

<a id="e01"></a>
### E01｜專案起點與現有引擎

使用者問「這個引擎不就是在用 AI 重新寫一個瀏覽器內核嗎」，並貼出 stylesheet URL cache、lazy font、background matching、分頁／display list cache 的方向。之後多次澄清 Legacy 原本已有良好產品表現。

<a id="e02"></a>
### E02｜Phase 1 完成摘要

來源訊息標題：`Browser-Style Box Layout Engine — Phase 1 結果摘要`。關鍵值：11 commits，`aefbf82`，23/23，worktree `../Yuedu-browser-layout`，feature disabled。

<a id="e03"></a>
### E03｜Phase 1.5 完成摘要

來源標題：`Phase 1.5 完成總結`。關鍵值：16 commits，56/56，source mapping／white-space／images／snapshots，40 段 benchmark。

<a id="e04"></a>
### E04｜Phase 2A 完成摘要

來源標題：`Phase 2A 完成總結`。關鍵值：19 commits，76/76，12 本 A/B，三模式、scanner、整章 fallback。

<a id="e05"></a>
### E05｜Phase 2B 完成摘要

來源標題：`Phase 2B 完成總結`。關鍵值：25 commits，36/36 核心，resumable walker、CSS head link 缺失、method filter 0-test 澄清。

<a id="e06"></a>
### E06｜紅樓夢真實 EPUB 回歸

來源標題：`紅樓夢真實 EPUB 回歸測試 — 完成報告`。提交 `9c5cdb9`／`d619bdc`／`2b5664a`，8/8、63/63、57/57。

<a id="e07"></a>
### E07｜Production 渲染回歸及真機引擎身份

來源標題：`Production 渲染回歸 — 完成報告`，提交 `fcf94af`；以及使用者後續「之前可能是沒用到新版引擎」的確認。早期「一定是 screenshot scale」等說法未在本台帳採為根因。

<a id="e08"></a>
### E08｜Phase 2C 提案與驗收失敗

來源：助手的 `Phase 2C — Production Rendering Correctness` prompt；使用者「他就是跑完 Phase 2C 了，然後我把這份 log 發給他了，他要修改」。

<a id="e09"></a>
### E09｜畫冊、座標與 forced 真機 logs

來源：使用者 `1c75103` 修復摘要與後續仍有殘頁的確認；附件 `已貼上文字 (1)(2).txt`（3e20373）、`(1)(3).txt`（3bf8b90）、`(1)(4).txt`（1c75103）、`(1)(5).txt`（重試循環）、`(1)(6).txt`（c78261b）。本次只將其作歷史佐證，不重新判讀每一條 log。

<a id="e10"></a>
### E10｜對話內已取得的早期修復 Commit

先前 GitHub fetch／search 的提交內容包括：`c78261b`、`29192ec`、`abf5fe4`、`5a69465`、`02cfd82e`、`227e294d`。來源是本對話工具輸出，不是助手僅憑印象給出的程式細節。

<a id="e11"></a>
### E11｜Link 已完成與歷史主分支狀態

使用者明確說「我新引擎 link 早做完了其實」；對話內 GitHub 結果另有 `a9afd634`（link／annotation、browserAuto）與 `7501c164`（feature merge）。

<a id="e12"></a>
### E12｜Phase 4A 原始附件

本對話附件：`已貼上文字 (1)(8).txt`，736 行。主要結論約 455–625 行；最後完成摘要約 688–736 行。包含 scratch C harness、PoC claims、C 決策、protocol 建立與測試命令紀錄。

<a id="e13"></a>
### E13｜Phase 4B Float

使用者在 Phase 4B prompt 後回覆「做完了然後呢？」。附件 `EPUB排版引擎探討.txt`（439 行）是當時的助手 prompt，不是完成報告；後續 E22／E23 等提供已存在 FloatContext 與 supported subset 的佐證。

<a id="e14"></a>
### E14｜Phase 4C Census 原始附件

本對話附件：`貼上的 Markdown (1).md`，108 行，日期 2026-08-22。結論第 5–11 行；corpus／方法第 13–35 行；ranking 第 37–58 行；layer 分類第 60–71 行；Ruby subset 第 73–102 行；產物第 103–108 行。

<a id="e15"></a>
### E15｜Phase 4D 完成摘要

來源：使用者「Phase 4D — Horizontal Ruby Inline Layout 已完成並通過驗證」。含 model、atomic break、wholeRange mapping、subset、152/152 與 75 章／613 組。

<a id="e16"></a>
### E16｜text-indent Audit 與方案選擇

來源：使用者貼 A–E 現況、推薦方案 1／2／3，並表示「我想選2」；接著「我的直覺告訴我1就是在走老路」。採用修正版 2 的責任分工方向。

<a id="e17"></a>
### E17｜Phase 4E0 完成摘要

來源：使用者「Phase 4E0 parity gate 已通過，尚未開始 text-indent」。含 ownership、establishedInlineSize、9/9、7,162／188、PRE hash 與 test-only oracle。

<a id="e18"></a>
### E18｜Phase 4E1 完成摘要

來源：使用者「Phase 4E1 — CSS text-indent 已完成」。含 12 項交付、4,849 changed、2,469 unaffected、59/59 與 121/121。

<a id="e18b"></a>
### E18b｜DEBUG A/B 驗收入口與觀察

來源：使用者貼四個 case、Legacy／BrowserForced 切換操作，並說「只有 C 看出差別，A/B 沒看出來，Legacy 比較不會錯位」。這是使用者觀察，不是實際 CSS 根因診斷。

<a id="e19"></a>
### E19｜使用者對新引擎願望的明確澄清

關鍵原話：

> 「本身舊引擎就不糟啊，只是要一直針對性優化很麻煩……我不想對著書本人工或測試抓渲染錯誤……這才是我對新引擎的願望。」

以及「Lexbor 不就是想著來補 CSS 的嗎」。它們改變了前面僅按當前 corpus fallback 收益延後 Lexbor 的規劃依據。

<a id="e20"></a>
### E20｜紅色水晶球精確根因

來源：使用者定位 spine 5／`tlh001.xhtml`／`gm3.png`，列 DOM、159 rules、0 img matching CSS、width attribute 未轉換、兩後端 418×418，結論為 HTML presentational normalization 缺口。

<a id="e21"></a>
### E21｜Phase 4F0 完成摘要

來源：使用者「Phase 4F0 — HTML Presentational Hints Normalization 已完成並通過驗證」。含 4,313 width elements、2,019 changed chapters、5,290/5,290 unaffected，以及 14/14 tests。

<a id="e22"></a>
### E22｜封印物章節 scanner 與 float 精確診斷

來源：使用者「BrowserAuto 對整章 supported=true」完整報告；metadata 書名澄清、spine68／ffwp001.xhtml、A–D DOM、50% float 內 85% image 及 generic used-size 修復。

<a id="e23"></a>
### E23｜Used-Value Timing Audit 完成摘要

來源：使用者「Phase — Used-Value Resolution Timing Audit 已完成，並修正通用 timing/reference 缺陷」。含 final content width、image metadata、line-height、em/rem、147/147，並明說完整 corpus 未跑。

<a id="e24"></a>
### E24｜跨頁裝飾／缺字任務與完成確認

來源：使用者要求兩項一併查清；助手提供 `Fragmented Block Decoration + Missing Glyph Correctness` prompt。使用者後續「話說我做完了，然後現在 browser 左右邊距有問題」。未見獨立完成細節，故不補造確定根因。

<a id="e25"></a>
### E25｜Supported-Subset Correctness Gate 完成摘要

來源：使用者「只修改一個 generic supported-subset geometry defect」報告。root-x 詳細數值、明朝四章 table scanner、指定 class counts，以及全書 golden 紅字狀態。

<a id="e26"></a>
### E26｜Attribution 2026-08-31

來源：使用者「root-x fix 是乾淨的 X-only correctness fix」。含 3820／116714／137294、63912 rows、433 failures 分組、`ffeaf95` 對照、刪除臨時 capture。

<a id="e27"></a>
### E27｜Horizontal Baseline Closure 完成摘要

來源：使用者「已滿足全部 checkpoint criteria」。433 rows、300/0/8、7140／210、全 corpus deterministic、checkpoint `b674e672`、spot-check 清單。

<a id="e28"></a>
### E28｜Phase 5A 與最後可見 repo 證據

來源：closure 後的正式 5A prompt，以及本對話最後一輪 GitHub 查閱。

- spec：`docs/superpowers/specs/2026-09-04-lexbor-css-frontend-production-migration-design.md`
- plan：`docs/superpowers/plans/2026-09-04-lexbor-css-frontend-production-migration.md`
- 文檔查閱 ref：`43481b6c5c108733d71331bb1f914df6802c31b2`
- 提交結果：`a4715bc1`、`d13ef94f`、`f7e3d1f4`、`e8dd5ac5`、`987ea443`
- 本對話沒有正式 cutover YES／default 已換的最後報告。

<a id="e29"></a>
### E29｜Phase 文件管理需求

使用者問 Obsidian／Slack 是否適合維護每個 Phase，之後要求將這段對話整理成 Markdown。本文以 repo 文件為可保存的台帳；沒有另建一套與 repo 不一致的已完成狀態。

---

## 維護備註

本文件首先是歷史台帳。後续更新時，新增實際完成報告、驗證 commit 和 cutover 決策；保留曾失敗或被推翻的結論及其後續修正，不刪成一條虛假的「每個 Phase 一次就全綠」歷史。

**下一個應接續更新的條目：Phase 5A。**
