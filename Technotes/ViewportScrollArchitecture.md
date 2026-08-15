# 把 TextKit 2 的 viewport layout 架構移植到 CoreText 捲動引擎

分析階段文件。**不改動程式碼**，目的是決定架構後再動手。

排版引擎仍然是 CoreText：`CTFramesetter` / `CTFrame` / `CTLine`、EPUB CSS、圖片與 attachment、float、直排、註解與選取全部保留。要移植的只是 TextKit 2 的**排版時機與幾何管理策略**。

> **不要誤解**：`NSTextViewportLayoutController` 只能驅動 `NSTextLayoutManager`，不能驅動 CoreText。本文所有「移植」都是指自己寫一個同構的控制器，不是複用 Apple 的類別。

## 標註約定

| 標記 | 意思 |
|---|---|
| **【文件】** | Apple 官方文件明確寫出 |
| **【推斷】** | 從公開 API 形狀、命名、sample 行為推導，Apple 未明述 |
| **【我們的選擇】** | 本專案自行決定，與 TextKit 2 無關 |

---

## 1. TextKit 2 viewport 架構實際怎麼運作

### 1.1 內容與排版分離

**【文件】** `NSTextLayoutManager` 是「TextKit 物件網路的中心，透過一組 `NSTextContainer` 維護排版幾何，並把 `NSTextContentManager` 提供的 `NSTextElement` 排版成 `NSTextLayoutFragment`」。

關鍵在於**內容單元（element）與排版單元（fragment）是兩層**。內容層知道「文件裡有哪些段落、各自多長」，不需要排版就能列舉；排版層才做斷行。

### 1.2 viewport 的定義

**【文件】** `NSTextViewportLayoutController`：「viewport 定義框架排版 text fragment 的作用區域 —— **典型情況是使用者可見區域再加上一段額外的 over-scroll 區域**。」`viewportBounds` 的說明是「view 的可見範圍，**加上 overdraw 區域**」。

**【文件】** viewport 是「翻轉座標系中沿 y 軸擴展的矩形區域」。

### 1.3 排版迴圈

**【文件】** 委派協定 `NSTextViewportLayoutControllerDelegate` 的四個方法：

| 方法 | 必要性 | Apple 的說明 |
|---|---|---|
| `viewportBounds(for:)` | 必要 | 回傳目前 viewport＝可見範圍＋overdraw |
| `textViewportLayoutControllerWillLayout(_:)` | 選用 | 排版流程**開始前**呼叫 |
| `configureRenderingSurfaceFor(textLayoutFragment:)` | 必要 | 控制器**把某個 fragment 排進 UI 時**呼叫 |
| `textViewportLayoutControllerDidLayout(_:)` | 選用 | 排版流程**結束時**呼叫 |

**【推斷】** 由這個形狀可以確定職責切分：**控制器決定「哪些 fragment 要排、排在哪」，委派只負責「給我 viewport」與「把這個 fragment 貼到畫面上」**。委派不決定排版範圍，也不自己算幾何。`willLayout` / `didLayout` 成對出現，是給委派做「開始貼圖前清空舊 surface、結束後收尾」用的 —— Apple sample 就是在這兩個回呼裡管理 layer 的增刪。

**【文件】** `layoutViewport()`：「在 viewport 內執行排版。」

### 1.4 fragment 的狀態機（估算 vs 實算的核心）

**【文件】** `NSTextLayoutFragment.state` 型別為 `NSTextLayoutFragment.State`，列舉值為：

- `.none`
- `.estimatedUsageBounds`
- `.calculatedUsageBounds`
- `.layoutAvailable`

**【推斷】** 這四個值就是整個 lazy layout 的骨架，語意由命名與 API 形狀可以確定地推出：

1. `.none` — 還沒有任何排版資訊。
2. `.estimatedUsageBounds` — `layoutFragmentFrame` 有值，但是**估算**的。可以拿來算捲動幾何，不能拿來畫。
3. `.calculatedUsageBounds` — 幾何已經**實算**，尺寸確定。
4. `.layoutAvailable` — 連 line fragment 等完整排版細節都在了，可以繪製。

Apple 未明述各狀態間的轉換時機與估算演算法本身。

**【文件】** `layoutFragmentFrame` 是「框架用來在目標排版座標系中鋪排此 fragment 的矩形」；`renderingSurfaceBounds` 是「繪製內容所需區域的界」。**兩者分開**——鋪排用的格子與實際著墨範圍不同（例如陰影、超出行高的字符會讓後者更大）。

### 1.5 只排 viewport 附近，其餘估算

**【文件】** `enumerateTextLayoutFragments(from:options:using:)` 的 `NSTextLayoutFragment.EnumerationOptions` 包含：

- `.estimatesSize` — 「估算 fragment 的尺寸而不做完整排版」
- `.ensuresLayout` — 「確保被列舉的 fragment 完成完整排版」
- `.ensuresExtraLineFragment`

**這一組選項就是非連續排版的公開介面**：同一個列舉 API，要嘛便宜地走過去拿估算幾何，要嘛強制排版。

**【文件】** `ensureLayout(for:)` 有兩個多載：吃 `NSTextRange`（把某段文字排好），以及吃 `CGRect`（「排版以填滿你指定的界」）。**吃 CGRect 的那個多載是 viewport 驅動排版的直接證據**——「把這塊矩形填滿」正是捲動時要的語意。

**【文件】** `usageBoundsForTextContainer`：「text container 的使用界 —— 已排版內容實際佔據的區域。」

**【推斷】** 這就是非連續排版下的 content size 來源：它是**估算與實算混合**的總和，會隨著排版推進而修正。這也是為什麼 TextKit 2 的捲動條在長文件裡會隨捲動微調。

### 1.6 viewport 位移與錨點補償

**【文件】**

- `adjustViewport(byVerticalOffset:)` — 「若有需要，依指定位移調整 viewport 矩形。」
- `relocateViewport(to:) -> CGFloat` — 「把 viewport 重新定位到你指定的位置。」參數是 `NSTextLocation`（文件中的**文字位置**，不是像素）。

**【推斷】** 這兩個是估算轉實算時避免畫面跳動的機制，理由是簽章形狀：

- `relocateViewport` **吃文字位置、回傳 CGFloat**。回傳值只可能是「重新定位後，該文字位置落在新座標系中的 y（或需要施加的位移差）」。這就是**錨點補償**：跳轉時先宣告「我要錨在這個字」，再由控制器算出捲動位置，而不是先算像素再祈禱它還對。
- `adjustViewport(byVerticalOffset:)` 則是反向：已知像素位移，讓 viewport 跟上。

Apple 未明述估算誤差累積如何被吸收，也未明述 fragment 何時被丟棄（下一節）。

### 1.7 fragment 何時 materialize / discard

**【文件】** `invalidateLayout()` —「使與此 fragment 關聯的排版資訊失效」；`NSTextLayoutManager.invalidateLayout(for: NSTextRange)` 同理。`layoutQueue` 是「框架派送排版操作的佇列」。

**【推斷】** materialize 的時機是明確的：fragment 進入 viewport（含 overdraw）時被 `layoutViewport()` 排到 → 狀態推進到 `.layoutAvailable` → `configureRenderingSurfaceFor` 被呼叫。

**discard 的時機 Apple 沒有公開**。`layoutQueue` 的存在說明排版可以非同步，但沒有任何 API 說「離開 viewport 多遠會被丟棄」。**我們不能假設 TextKit 2 一定會丟棄**——它可能只是不再持有 rendering surface，而排版結果仍在快取。這一點必須自己決定策略。

---

## 2. 與目前 `CoreTextScrollEngine` 的逐項對比

| 面向 | TextKit 2 | 我們現在 | 差距性質 |
|---|---|---|---|
| 內容／排版分層 | element ↔ fragment 兩層 | **一層**：`NSAttributedString` 直接切成 `CoreTextChunk` | 缺「便宜可列舉的內容單元」 |
| 排版範圍 | viewport＋overdraw | **整章**（`slice()` 從頭跑到尾） | 核心差距 |
| 幾何估算 | `.estimatedUsageBounds` | **沒有估算概念**，高度一律實算 | 核心差距 |
| 幾何實算 | `.calculatedUsageBounds` / `.layoutAvailable` | `CTFrame` 建立即完整 | 我們只有「全有」 |
| content size | `usageBoundsForTextContainer`，會修正 | `UICollectionViewFlowLayout` 由**每個 item 的精確高度**加總 | **這是逼出 eager 的結構性原因** |
| 排版觸發者 | viewport controller | `loadChapter` → 章節載入即全排 | 觸發時機錯位 |
| 錨點補償 | `relocateViewport(to:)`（文字位置） | prepend 時用 **cell frame 差值**還原 `contentOffset` | 我們有等價機制，但綁在 cell 上 |
| 記憶體回收 | `invalidateLayout()`，策略未公開 | `evictFrame()` ＋ `warmChunks(radius:)` | **我們這塊反而比較明確** |
| 繪製表面 | `configureRenderingSurfaceFor` | `UICollectionViewCell` reuse | 等價 |
| 非同步 | `layoutQueue` | `Task.detached(priority:.userInitiated)` | 等價 |

**結論**：我們已經有 TextKit 2 的**後半段**（materialize / evict / reuse / 非同步），缺的是**前半段**（便宜的內容描述 → 估算幾何 → viewport 驅動排版）。

---

## 3. 目前最大的效能瓶頸

### 3.0 實測基準（2026-08-14，真機）

階段 0 量到的數字。**這一節推翻了本文原先的優先序判斷**，見 §3.3。

**slice 對章長：完美線性，正如預測。** 同一本書 1588→9313 字（5.9×）：

| chars | slice | perKChar |
|---|---|---|
| 1588 | 4.9ms | 3.09 |
| 3477 | 10.4ms | 3.00 |
| 4820 | 15.0ms | 3.11 |
| 8862 | 24.7ms | 2.78 |
| 9313 | 29.2ms | 3.13 |

重 CSS 書（紅樓夢類）為 5.06–8.26 ms/kchar。

**slice 內部組成**（§3.1 的推斷全部證實，除了一項）：

| | 重 CSS 書 | 輕量書 |
|---|---|---|
| `SuggestFrameSize` | **58%** | **43%** |
| `CreateFrame` | 26% | 20% |
| attachment 抽取 | 5% | 23% |
| framesetter 建立 | 8% | 12% |
| **renderable 抽取** | **0.6%** | **1%** |

`SuggestFrameSize` 是最大單一項，每 chunk 約 1.9 次（§3.1 預測 1～4，符合）。
**但 renderable 抽取幾乎免費**——§3.1 把它列為三大成本之一是錯的，之後不必為它花力氣。

**決定性的數字：slice 不是瓶頸。**

| | document | slice | slice 佔 loadChapter |
|---|---|---|---|
| 重 CSS 書 14334 字 | **5307.6ms** | 105.7ms | **2.0%** |
| 重 CSS 書 14039 字 | 3932.5ms | 97.0ms | 2.4% |
| 輕量書 9313 字 | 140.1ms | 29.2ms | 17% |
| 輕量書 3106 字 | 227.0ms | 9.3ms | 3.9% |

每一筆樣本，document 都是 slice 的 **5～50 倍**。**階段 1–5 全部做完、slice 砍到 0，重 CSS
書的章節載入是 5414ms → 5308ms（快 2%）。**

### 3.1 直接原因：`slice()` 是整章 eager layout

`CoreTextChunkSlicer.slice()` 的主迴圈 `while offset < totalLen` 走完整章。每一圈實際成本：

| 步驟 | 呼叫 | 次數 |
|---|---|---|
| 量測 | `CTFramesetterSuggestFrameSizeWithConstraints` | 1，`fitRange==0` 時 +1，段落邊界回退時 +1，float 切分時 +1 → **最多 4** |
| 建 frame | `CTFramesetterCreateFrame`（`makeHorizontalFrame`） | 1，float 切分 +1，`visibleStringRange` 修正 +1 → **最多 3** |
| 抽取 | `extractBlockRenderables` ＋ attachment extraction | 每 chunk 各一次，逐行走訪 |

`SuggestFrameSizeWithConstraints` **本身就會做斷行**——它不是便宜的估算 API，是完整量測。所以一章的成本大致是「整章斷行 1～4 次 ＋ 整章建 frame 1～3 次 ＋ 整章逐行抽取」。

### 3.2 根本原因：`UICollectionViewFlowLayout` 要求精確高度

```
collectionView(_:layout:sizeForItemAt:) -> CGSize   // 回傳 chunk.height
```

flow layout 必須拿到**每個 item 的精確尺寸**才能算出 `contentSize` 與各 cell 的位置。所以「插入一章」在架構上就等於「這章每個 chunk 的高度都必須已知」——**eager 不是實作偷懶，是被 layout 物件的契約逼出來的**。

> 這一點決定了整個 migration 的形狀：**不先解決「捲動幾何可以接受估算值」，任何 lazy layout 的努力都會被 `sizeForItemAt` 打回原形。**

### 3.3 次要瓶頸

1. **`insertLoadingPlaceholder` 在 main actor 上同步呼叫 `slice()`**（`CoreTextScrollEngine.swift:483`）。佔位字串很短所以目前不痛，但這是一條同步排版路徑，架構上該收掉。
2. **frame 已經是 lazy 的，量測不是**。`evictFrame()` / `materializeFrameIfNeeded()` 已經讓 `CTFrame` 可丟可重建，但 `chunk.height` 是在 slice 時定死的 —— 也就是說**我們已經有一半的懶惰機制，卡在幾何這一關**。
3. ~~每章一次的 `chapterDocumentStore.document(for:)` …屬於另一個題目。~~
   **【2026-08-14 實測更正】這不是次要瓶頸，是主要瓶頸，差 5～50 倍（§3.0）。**
   `chapterDocumentStore.document(for:)` 產生整章 `NSAttributedString` 的成本主導了整個
   `loadChapter`；lazy layout 確實不會改善它，但那意味著**本文的成功判準無法只靠 viewport
   重構達成**，不意味著它可以晚點再說。

   而且它跑在主執行緒：[`ChapterDocument.swift:86`](../Modules/Core/ReaderCore/CoreText/ChapterDocument.swift)
   是 `Task { @MainActor [builder] in }`，而 `EPUBAttributedStringBuilder` 標了 `@MainActor`。
   那 5.3 秒不只是慢，是卡住 UI。（但 wall time 含 `await` 掛起，不全是 CPU——這正是要拆
   子階段的原因。）

---

## 4. 建議的新架構

```
Chapter
  └─ ChapterOutline                    ← 便宜：只切段落邊界，不做斷行
       └─ [FragmentDescriptor]         ← charRange + estimatedHeight + isEstimated
            ↓  進入 viewport + overscan
       ReaderViewportController         ← 決定排哪些、何時排
            ↓
       CoreTextChunk（現有型別）        ← 實算：SuggestFrameSize + CTFrame + renderables
            ↓
       actualHeight ≠ estimatedHeight
            ↓
       AnchorCompensator                ← 修正 contentOffset，畫面不跳
            ↓
       遠離 viewport → discard CTFrame（保留 descriptor 與 actualHeight）
```

### 4.1 估算怎麼來（**【我們的選擇】**）

CoreText **沒有**比 `SuggestFrameSizeWithConstraints` 更便宜又準確的高度 API。所以估算必須是非 CoreText 的啟發式：

```
estimatedHeight ≈ ceil(charCount / charsPerLine) * lineHeight + paragraphSpacing
charsPerLine ≈ contentWidth / averageGlyphAdvance
```

`averageGlyphAdvance` 由字型與字級一次量出（中文字幾乎等寬，誤差小；西文誤差大）。圖片／表格等 attachment 的高度**不估算**——它們的尺寸在 attributed string 裡已經是已知的固定值，直接取用即可，這是我們比 TextKit 2 有利的地方。

**估算只需要「不會離譜」，不需要準**——它的唯一用途是讓捲動條與 `contentOffset` 有個起點，實算一到就會被修正。

### 4.2 一個 fragment 的狀態（對應 TextKit 2 的四態）

| 我們 | 對應 TextKit 2 | 持有什麼 |
|---|---|---|
| `.described` | `.none` | charRange |
| `.estimated` | `.estimatedUsageBounds` | ＋ estimatedHeight |
| `.measured` | `.calculatedUsageBounds` | ＋ actualHeight（實算過，frame 已丟） |
| `.laidOut` | `.layoutAvailable` | ＋ CTFrame ＋ renderables ＋ attachments |

`.measured` 這一態是我們**必須**有而 TextKit 2 可以模糊處理的：一旦某個 fragment 的真實高度被算過，即使 CTFrame 被丟棄，**高度也永遠不該再退回估算值**——否則使用者往回捲會看到已經穩定的內容再跳一次。

### 4.3 捲動幾何的歸屬（關鍵決策）

必須讓「接受估算高度」成為可能。兩條路：

| 方案 | 做法 | 代價 |
|---|---|---|
| **A. 自訂 `UICollectionViewLayout`** | 自己算 `layoutAttributes`，維護 `contentSize`，高度變更時 `invalidateLayout(with:)` ＋ 在 `targetContentOffset(forProposedContentOffset:)` 做錨點補償 | 要自己寫 layout；但保留 cell reuse、prefetch、既有互動與無障礙 |
| **B. 換成 `UIScrollView` ＋ 自繪 tile** | 完全照 TextKit 2：viewport controller 直接管理 layer | 捲動、reuse、選取、VoiceOver、註解 popover 全部重寫 |

**建議 A。** 理由：`CoreTextCollectionScrollViewController` 這 1213 行裡絕大部分是**與排版無關**的資產——位置還原、章節預載、選取、TTS 高亮、註解 popover、VoiceOver、背景圖、RTL 直排。方案 B 會把這些全部推倒重來，而它們正是這個閱讀器最貴的部分。TextKit 2 用 `UIScrollView` 是因為它從零開始；我們不是。

---

## 5. 建議新增／修改的型別

### 新增

| 型別 | 位置 | 職責 |
|---|---|---|
| `ChapterOutline` | `Core/ReaderCore/CoreText/` | 一章的段落切分結果：`[FragmentDescriptor]`。**只掃 `\n` 與 attachment，不碰 CoreText** |
| `FragmentDescriptor` | 同上 | `charRange` ＋ `state` ＋ `estimatedHeight` ＋ `actualHeight?` |
| `FragmentGeometryStore` | 同上 | 章 → descriptor 陣列；高度查詢與更新的單一入口；`totalHeight` |
| `ReaderViewportController` | 同上 | 由 viewport 矩形算出「該排哪些 descriptor」，觸發實算，回報高度變更 |
| `AnchorCompensator` | `Features/Reader/` | 高度變更 → `contentOffset` 修正。錨點用 **charOffset**（不是 index path），對應 `relocateViewport(to:)` 的文字位置語意 |
| `EstimatedHeightModel` | 同上 | 字型／字級 → `charsPerLine`、`lineHeight`；估算高度的唯一來源 |
| `ReaderScrollLayout: UICollectionViewLayout` | `Features/Reader/` | 吃 `FragmentGeometryStore` 的高度（估算或實算皆可），支援高度變更的 in-place 失效 |

### 修改

| 型別 | 修改 |
|---|---|
| `CoreTextChunkSlicer` | 拆成兩半：`outline()`（便宜、切段落）與**現有的實算邏輯**（改成「排單一 descriptor」而非「迴圈整章」）。**斷行、float 切分、visibleRange 修正、renderable 抽取全部原封不動搬過去** |
| `CoreTextScrollEngine` | `chunks: [CoreTextChunk]` → 由 `FragmentGeometryStore` 提供幾何、chunk 只在 `.laidOut` 態存在；`loadChapter` 改成「取 attributed string ＋ 建 outline」，不再排版 |
| `CoreTextCollectionScrollViewController` | flow layout → `ReaderScrollLayout`；`sizeForItemAt` 移除（改由 layout 問 store）；`willDisplay` 改成觸發實算 |
| `CoreTextChunk` | **不動**。它已經是「一個排好的 fragment」，正是我們要的 `.laidOut` 態載體 |

---

## 6. 哪些現有程式碼可以保留

**全部保留，一行不改**：

- `CoreTextChunk` 整個型別，含 `evictFrame()` / `materializeFrameIfNeeded()` / `applyBuiltFrame()`
- `CoreTextChunkSlicer` 裡所有 CoreText 實算邏輯：段落邊界回退、float 切分、`CTFrameGetVisibleStringRange` 修正、`blockImageHeight` / `floatImageHeight`、`extractBlockRenderables`、attachment 抽取、直排 `sliceVertical` 的壓縮邏輯、背景圖補滿一屏的規則
- `CoreTextChunkCell` / `CoreTextChunkDrawView` 整個繪製路徑
- `CoreTextChunkBackdropView` 與背景圖處理
- VC 裡的：選取、TTS 高亮、註解 popover、VoiceOver、章節預載、`onInternalLinkTap`、RTL 直排軸處理
- `warmChunks` / `evictFrame` 的記憶體策略（半徑值可能要重調）
- `Task.detached` 的非同步排版模式

**這是重點**：這次重構**不碰 CoreText 排版本身**，只把「什麼時候排、排多少」抽出來。EPUB3 能力零損失。

---

## 7. Migration plan

每一階段都可獨立驗證、獨立回退。

### 階段 0 — 量測基準（不改行為）✅ 已落地
在 `slice()` 與 `loadChapter` 加 span，量出真機上：整章 slice 的毫秒數（按章長分佈）、`SuggestFrameSize` 累計時間、`CreateFrame` 累計時間、renderable 抽取時間。**沒有這組數字，後面每一步都是憑感覺。**

#### 實作方式

`CoreTextSliceMetrics`（`Modules/Core/ReaderCore/CoreText/`）是每次 `slice()` 呼叫的成本累加器，以 `inout` 貫穿 `makeHorizontalFrame` / `makeHorizontalChunk` / `padForBackdrop` / `sliceVertical`，隨 `CoreTextChunkSlicer.Output.metrics` 回傳。**累加器是單次呼叫的區域變數**——章節會並行切片，全域計數器既會 race 也會把不同章混在一起。

三個 stage 走 `SourcePerfTrace`（`⏱` 行，Release Console 可見）：

| stage | 內容 |
|---|---|
| `coreText.scroll.loadChapter` | 端到端：`document` / `prepare` / `slice` / `insert` / `warm` 五段 |
| `coreText.scroll.slice` | `slice()` 內部拆解：`framesetter` / `suggest` / `frame` / `extract` / `attach` / `other`，各附呼叫次數 |
| `coreText.scroll.placeholderSlice` | §3.3 那條 main-actor 同步 `slice()`，證明它確實近乎免費 |

> **為什麼不是新增 `ReaderPerfStage` case**：`ReaderPerfStage` 定義在**遠端套件** `YueduCoreText`（pin 0.2.1），加 case 要改套件、發版、再改兩邊的 `ReaderPerfTraceTests`。而且我們要的是**累計值**——signpost 是逐次區間，一章上百個區間得掛 Instruments 才讀得到，拿不到真機 Console 上的一行摘要。既有的 `.chapterLoad` / `.layoutPageRanges` signpost 原封不動保留。

#### 怎麼收數字

Console.app 接真機，filter `⏱ coreText.scroll`。捲動模式開紅樓夢（章長分佈廣）、洪武大帝（多看盒模型），直排開 kusamakura，各翻十幾章。

關鍵欄位是 **`perKChar`**：每千字的毫秒數。

- **今天**應該隨章長大致持平（成本與章長成正比）。
- **階段 3 之後**應該隨章長**下降**——長章跟短章一樣只排一個 viewport。

`perKChar` 從持平變成隨章長下降，就是「章節載入時間與章長脫鉤」在數據上的樣子。

### 階段 0.5 — 拆解 document（因 §3.0 的發現插入）

`slice` 只佔章節載入的 2～17%，所以在動 viewport 之前必須先知道 document 那 5.3 秒花在哪。

七個子階段（`html.parse` / `css.collect` / `css.parse` / `css.match` / `ast.build` /
`ir.convert` / `attributed.render`）本來就有 `ReaderPerfTrace` span，但只是 signpost，真機
Console 看不到，且**只蓋到 `buildChapter` 的中段**。以下四段原本完全沒量，一併補上：

| 缺口 | 為什麼可能很貴 |
|---|---|
| `session.chapterHTML(at:)` | EPUB zip 讀取＋解壓 |
| `styleResolver.registerFontFaces` | 每個內嵌字面一次 `CTFontManagerRegisterGraphicsFont`；重 CSS 書的頭號嫌疑 |
| `FootnoteStore.index` | 走訪整棵 AST |
| `anchorOffsets(in:)` | 走訪整個 attributed string |

輸出是一行 `⏱ coreText.document.buildChapter`，含 `fetch` / `styledAST` / `footnote` /
`background` / `fonts` / `ir` / `render` / `anchors` / `other` 九段；`styledAST` 再由
`coreText.document.{htmlParse,cssCollect,cssParse,astBuild,cssMatch}` 五行細拆。

> **巢狀關係，別相加**：`cssMatch` 在 `astBuild` 裡面；`htmlParse` / `cssCollect` /
> `cssParse` / `astBuild` 四者相加才約等於 `styledAST`。

#### 階段 0.5 實測結果（2026-08-14）

| 階段 | 重 CSS 書 spine 15 | 重 CSS 書 spine 17 | 輕量書 spine 22 |
|---|---|---|---|
| chars / nodes | 14334 / **63** | 10360 / **26** | 21233 / **414** |
| **總計** | **5037ms** | **2187ms** | **325ms** |
| fetch（zip 解壓） | 18.1 | 2.4 | 1.8 |
| styledAST | 441.4 | 105.6 | 171.2 |
| ├ htmlParse | 12 | 4 | 6 |
| ├ cssCollect | 179 | 46 | 1 |
| ├ cssParse | 11 | 0 | 0 |
| └ **cssMatch** | 237 | 55 | **163** |
| background | 37.1 | 76.1 | 0.0 |
| fonts | 273.4 | 0.4 | 0.8 |
| ir | 5.9 | 2.6 | 3.8 |
| **render** | **4257.3 (85%)** | **1999.7 (91%)** | 146.9 (45%) |
| anchors / other | 0.1 / 0.4 | 0.1 / 0.0 | 0.0 / 0.1 |

**結論：兩本書瓶頸不同。**

- **重 CSS 書 → `render`（85–91%）。** 決定性的線索是 node 密度：spine 15 用 **63 個 node**
  裝 14334 字（**67.6ms/node**），輕量書 spine 22 用 414 個 node 裝 21233 字
  （**0.35ms/node**）——**差 200 倍**。這不可能是文字組裝，node 裡面有很貴的 await。
- **輕量書 → `cssMatch`（總計的 50%）。** 與 topLevel 元素數線性相關（816→163ms、377→79ms、
  188→53ms，約 0.2ms/element）。

**被排除的假設：**

| 原本的嫌疑 | 實測 | 結論 |
|---|---|---|
| zip 讀取／解壓 | 1.4–18.1ms | 無罪 |
| CSS 解析 | 0–11ms（`cached=true` 有效） | 無罪 |
| HTML 解析 | 0–12ms | 無罪 |
| 字型註冊 | 首章 273.4ms，之後 0.4ms | 一次性，非主因 |

**另外兩個發現：**

1. **短章的固定成本是 `background`**：spine 14（22 字）花 144.5ms、spine 13（0 字）花
   62.9ms 在背景圖上。這解釋了為什麼上一輪「22 字的章節也要 176ms」。
2. **`document` 有快取**：同章第二次載入 `document=0.0ms`。所以這些是**開書與首次翻到**的成本。

### 階段 0.6 — 拆解 `render` 的 await leaves

`render` 是重 CSS 書的 85–91% 且完全是黑盒，所以再拆一層。`NodeAttributedStringRenderer`
是刻意無狀態的 `struct`，render 是深層 async 遞迴——用 task-local 的參照型 `RenderLeafMetrics`
收集，不動它的設計。bucket 是**被 await 的服務**（`svgRaster` / `svgSize` / `imageLoad` /
`blockBgImage` / `mainActorHop` / `mathml` / `table` / `regexPrewarm` / `imageTrim` /
`svgTrim` / `diagTrim`），加一個 `walk` = 總時間減去所有 leaf，代表樹走訪本身。

輸出 `⏱ coreText.document.renderLeaves`，bucket 由大到小排。

#### 階段 0.6 實測結果（2026-08-14）：**`imageLoad`**

| 書 | spine | nodes | render | **imageLoad** | 次數 | 每次 | mainActorHop | walk |
|---|---|---|---|---|---|---|---|---|
| 重 CSS | 19 | 47 | 3641.6 | **3548.3 (97%)** | **102** | 34.8ms | 11.5 | 81.7 |
| 重 CSS | 17 | 26 | 2541.8 | **2481.2 (98%)** | **54** | 45.9ms | 4.3 | 55.8 |
| 輕量 | 22 | 414 | 202.4 | 121.5 (60%) | 11 | 11.0ms | 0.4 | 80.4 |
| 輕量 | 23 | 64 | 24.8 | 13.6 | 2 | 6.8ms | 0.0 | 11.2 |

**兩個原本的嫌疑都無罪**：`mainActorHop` 102 次只花 11.5ms；`svgRaster` / `diagTrim` 完全
沒出現（這本書不走 SVG 路徑）。`walk`（樹走訪本身）也只有 55–82ms。

**根因：`EPUBAttributedStringBuilder.loadImage` 沒有任何快取。**

```
resourceProvider.response(for:)   →  zip 讀取＋解壓
UIImage(data:)                     →  建立 UIImage
```

每次呼叫都完整重做，旁邊的 `loadCSS` 卻有 `processedCSSCache`。一章 102 次呼叫。

**定案數據（2026-08-14）：**

| spine | imageLoad | 呼叫 | **相異** | **zip** | decode | 單次 zip |
|---|---|---|---|---|---|---|
| 19 | 4178.8ms | 102 | **11** | **4059.0ms (97%)** | 4.7ms | 39.8ms |
| 21 | 1959.6ms | 58 | **2** | **1942.6ms (99%)** | 3.1ms | 33.5ms |
| 20 | 65.5ms | 2 | 1 | 65.3ms | 0.1ms | 32.7ms |

**兩個獨立的問題：**

1. **29 倍重複讀取**（spine 21：58 次呼叫、2 張圖）。成本 100% 在 zip 讀取；
   `UIImage(data:)` 是 0.05ms/次——它本來就惰性，不在這裡解碼像素。
   加快取後 spine 21 的 1942.6ms → 約 67ms（**省 96.6%**），
   spine 19 的 4059ms → 約 438ms（**省 89%**）。
2. **單次 zip 讀取 33–40ms 本身就太慢。** 這是獨立的異常，快取只是讓它從付 102 次
   變成付 11 次。可疑處在 `PublicationSession.response(for:)`：`resource.properties()`
   ＋ `resource.read()` ＋ `transformedDataIfNeeded(…, algorithm:)`——這本書有
   `encryptionAlgorithm`（多看混淆），解密可能就是那 40ms。**尚未查證。**

**現有快取都不適用**（`ReaderStyleAssetImageCache` 是使用者自訂樣式資產、
`AppearancePageBackground` 是外觀背景、`CommentBubbleSVGRecognizer` 是段評氣泡、
`ReviewBadgeRenderer` 是書評徽章），沒有一個涵蓋 EPUB 書內資源讀取。

順帶：`loadImage` 用 `try?` 靜默吞掉錯誤，違反 CLAUDE.md「不吞錯誤」，修快取時一併處理。

#### 已修（2026-08-14）

`EPUBAttributedStringBuilder` 加了 per-book `imageCache: NSCache<NSString, UIImage>`
（countLimit 256、totalCostLimit 32MB，cost 用解碼後像素預算 `w×h×scale²×4` 而非壓縮位元組，
因為 `UIImage(data:)` 是惰性的）。key 是解析後的資源 URL，所以 CSS 的絕對式
`reader-book://…` 與章節相對的 `<img src>` 指到同一份資源時會共用。

選擇 `loadImage` 這一層而非 `PublicationSession.response(for:)`：與同檔案裡
`processedCSSCache` 同一層、同一形狀，值是 `UIImage`（記憶體用量可直接估算），
不必快取字型與大檔的原始 `Data`。

`try?` 一併換成 `do/catch` ＋ `AppLogger.render`（讀取失敗與解碼失敗分開記）。

**實測（2026-08-14，同書同 spine，皆冷開）：**

| spine | chars | 總計 | render |
|---|---|---|---|
| 21 | 8904 | 2123ms → **797ms** | 2015.8 → **309.6ms（−85%）** |
| 20 | 194 | 189ms → **11ms** | 67.6 → **2.0ms** |
| 22 | 168 | 112ms → 232ms ⚠️ | 66.1 → **2.5ms** |

spine 23（39512 html / 16831 字，比先前任何樣本都大）現在是 **365ms**。

**spine 22 反而變慢**：render 掉到 2.5ms，但 `background` 從 39.1 漲到 **220.6ms**——
同一份資源的單次 archive 讀取從 39ms 變 220ms。這是下面那個未修的異常，**它的變異比原本
估計的大得多**。單一樣本，不臆測原因。（旁證：spine 20 的 `background` 現在是 0.1ms，
證明背景圖確實走同一條快取。）

**單次 zip 讀取 33–40ms（實測可達 220ms）的異常沒有修**，只是從付 102 次變成付 11 次；
那是獨立的待辦，嫌疑在 `PublicationSession.response` 的 `transformedDataIfNeeded`。

回歸測試 `EPUBImageCacheTests`：斷言的是**呼叫次數**不是毫秒（毫秒在 CI 上會飄），
「N 次引用只能有 distinct 次 archive 讀取」正是退化掉的那條性質。

> 帶點的 bucket（`imageLoad.zip`）是**巢狀細分**，`totalSeconds` 會排除它們，否則
> `walk` 會被重複扣成負數。

**原本的兩個嫌疑（已由數據排除，保留供日後辨認）：**

1. **`resolvedImageMetrics` 每張圖開頭都是 `await MainActor.run { UIScreen.main.bounds.width }`**。
   `render` 是 `nonisolated async`，跑在 global executor，所以這是每張圖一次的主執行緒往返
   ——而主執行緒此時正忙著別章的 document build。全檔共 6 處相同寫法，都記進 `mainActorHop`。
2. **SVG 路徑上有段診斷碼做了多餘的全圖 pixel 掃描**：`CommentBubbleSVGRecognizer.diag`
   的 `after` 參數會呼叫 `trimmingTransparentPixels()`，而 `diag` 只保留第一次出現的簽章、
   其餘丟棄，真正的 trim 又在三行後重跑一次。記進 `diagTrim`，確認成本後就可以刪。

`spine=` 由 task-local `ReaderDocumentTrace.spineIndex` 帶下去——那幾個 HTML/CSS 檔案刻意不
知道自己在建哪一章，為了純診斷用途去加參數會污染六層簽章。`Task {}` 會繼承 task-local，
`Task.detached` 不會，所以跑進 detached 的階段會印 `spine=?` 而不是印錯的號碼。

### 階段 1 — 抽出 outline（行為不變）🔶 型別已落地，引擎接線未做
`ChapterOutline` ＋ `FragmentDescriptor` ＋ `EstimatedHeightModel`。此時仍然整章實算，但幾何改由 `FragmentGeometryStore` 提供。**驗證：所有 chunk 高度與改前逐一相同。**

#### 已完成（2026-08-14）

四個型別全部落地，且都不碰 `CTFramesetter*`：

| 型別 | 職責 |
|---|---|
| `EstimatedHeightModel` | §4.1 的算術估算。**這個型別裡永遠不得出現 `CTFramesetter*` 呼叫** |
| `FragmentDescriptor` | 四態（`.described`/`.estimated`/`.measured`/`.laidOut`），高度單調性由型別保證 |
| `ChapterOutline` | 掃 `\n` 與 run-delegate attachment 切段落；順帶取樣 CJK 佔比餵給估算模型 |
| `FragmentGeometryStore` | 章 → outline、高度查詢／回寫、`totalHeight`、charOffset → fragment |

`ChapterOutlineTests` 覆蓋 §9 的三條不變量（第三條錨點守恆要等階段 3 才有意義）：

1. **邊界權威**：fragment 的 range 必須**無縫也無重疊地鋪滿整章**——包含沒有結尾換行、
   連續空行、空章三種邊界情形。
2. **高度單調性**：`recordActualHeight` 之後 `demoteToMeasured` 只降狀態不退高度。
3. **總高一致**：store 的 total 恆等於各 fragment 之和，量測前後皆然；跨章 offset 累加、
   prepend 插到最前、移除章節都各有案例。

**設計決定：blank paragraph 佔一行而不是 0 高。** 空行是使用者看得到的間距，估 0 會讓捲動
幾何在空行多的章節系統性偏短。

#### 引擎接線已完成（2026-08-14，150 個測試全綠）

`CoreTextCollectionScrollViewController.sizeForItemAt` 已改問
`CoreTextScrollEngine.scrollExtent(at:)`，不再直接讀 `chunk.height`。

**store 是衍生的，不是同步維護的。** `insert` 有三條分支各自重算內容，讓 store 跟著它們逐步
更新等於開第二套帳。改成 `chunks` 的 `didSet` 只標記 stale、下次讀取整份重建——**任何
mutation 都不可能漏掉失效，這是結構保證不是紀律要求**。

#### ⚠️ 分組只能來自 `chunks`，不能來自 `chapterRanges`（真機回報「開書回跳半天」的真因）

第一版用 `chapterRanges` 分組，**這是真正的 bug**：`chunks` 與 `chapterRanges` 是兩個各自
獨立的 `@Published` 屬性，`insert` 是先後兩次賦值：

```swift
chunks.insert(contentsOf: newChunks, at: insertAt)   // ← 這一行就會同步通知觀察者
chapterRanges = newRanges                            // ← 還沒執行到
```

任何觀察者（SwiftUI 更新、Combine 訂閱、layout pass）在這兩行**中間**跑起來，就會拿舊的
ranges 去分組新的 chunks。沒被涵蓋到的 chunk 掉出 flat index，`height(atFlatIndex:)` 回
`nil`，延伸量變成 **0**；下一輪才修正回來——這就是「跳一下、修正、再跳一下、才穩定」。

> **延遲重建擋不住這個。** 延遲只保證「不在 `insert` 內部重建」，擋不住外部觀察者在兩次
> 賦值中間觸發讀取。**問題不是何時重建，是讀了兩個不同步的來源。**

修法：分組改用**每個 chunk 自己帶的 `chunk.chapterIndex`**（`ChapterOutline.grouped`）。
只讀一個屬性 → 映射在構造上完備：每個 chunk 必落在某個 outline，flat index `i` 恆等於
`chunks[i]`。`chapterRanges` 的 `didSet` 一併移除，store 不再讀它。

**診斷教訓**：症狀出現在換 layout 之後，於是連續兩次都只在 layout 裡找。那是**時序巧合**
——階段 1 的 store 早就壞了，只是 flow layout 每次重新問 delegate、把錯值蓋掉得夠快所以
看不見，換成會快取的自訂 layout 才顯形。**改動 A 之後才出現的症狀，成因可能在更早的 B。**

**顆粒度**：階段 1 的 store 以 **chunk 顆粒度**填充（`ChapterOutline.measured`），每個
descriptor 直接進 `.laidOut` 態並帶著實測高度，所以 `hasEstimates == false`——
**估算值在這個階段進不了畫面**。段落級 `ChapterOutline.make` 已就緒但尚未驅動版面，
階段 3 才換手。

新增的驗證（對真正 slice 出來的 chunk，非手搭替身）：

- `measuredOutlineMatchesChunksExactly` — charRange 與 height **逐一相同**，且無任何
  fragment 處於估算態
- `flatIndexWalksChaptersInScrollOrder` — flat index 跨章按捲動順序走，越界回 `nil`
- `verticalOutlineUsesWidthAsExtent` — 直排以 width 為延伸軸

`scrollExtent(at:)` 回 `nil` 只代表索引超出已載入內容，與呼叫端本來就得處理的
`chunks` 越界是同一個條件——**不是兜底**。

### 階段 2 — 自訂 layout（行為不變）✅ 已落地（156 個測試綠）
`ReaderScrollLayout` 取代 flow layout，仍然吃精確高度。**驗證：捲動位置、章節邊界間距、RTL 直排與改前像素一致。**

#### 實作

`Modules/Features/Reader/ReaderScrollLayout.swift`。閱讀器的 collection view 是**單一 section、
跨軸滿版、零間距**，所以幾何就是沿捲動軸的累加和；章節間距做在 item 的延伸量**之內**
（`sizeForItemAt` 一直都是這樣報的），不是 item 之間的 spacing。

- `sizeForItemAt` 刪除，改由 layout 呼叫 `scrollExtent(forItem:)`——**延伸量只剩一個計算點**
- conformance 從 `UICollectionViewDelegateFlowLayout` 降回 `UICollectionViewDelegate`
- `CoreTextScrollFlowLayout` 刪除
- `extentProvider` 用 `[weak self]`：layout ← collection view ← VC，強引用會成環
- `layoutAttributesForElements` 用 binary search（每次捲動都會呼叫，item 數隨載入章節增長）

#### ⚠️ flow layout 會把 item origin 對齊裝置像素格

**這是等價測試抓到的，讀程式碼絕對想不到。** 第一版直接用全精度累加，前 3 個 item 一致，
從第 4 個起每個差 **1/6 pt**（@3x 螢幕的 1/2 像素）：

```
mine  4428.5              (1997 + 2000 + 431.5)
flow  4428.666666666667   (4428.5 × 3 = 13285.5 → 四捨五入 13286 → ÷3)
```

正確模型是三件事同時成立：

| | 做法 |
|---|---|
| origin | `round(cursor × scale) / scale`，`.5` 一律進位（away from zero） |
| size | **不對齊**，保持精確值（期望值裡仍是 `1204.25`、`2000.75`） |
| 累加 | 用**全精度**推進，不用對齊後的值，否則誤差會累積 |
| `contentSize` | 原始總和（`16377.5`），**不對齊** |

理由是合理的：cell 落在整數實體像素上，CoreText 自繪的文字才不會糊。

binary search 也改用**實際 frame 的邊界**而非原始累加值——對齊會讓 origin 移動最多 1 像素，
兩套數字各算各的就會在邊界上漏掉或多出 cell。

> **若沒有這個測試**：症狀會是「捲動久了位置慢慢偏」，每 item 差 1/6 pt、幾百個 chunk
> 累積成數十 pt，且只在特定章長組合下出現——肉眼看不出來，只會變成使用者回報的「有時候會跳」。

#### ⚠️ 自訂 layout 的兩個必要契約（真機回報「開書回跳半天」後補上）

幾何算對還不夠。第一版上真機後出現「開書回來反覆跳很久才穩定到原位」，根因是兩個
`UICollectionViewLayout` 的契約沒遵守——**兩者單元測試都測不到，因為它們只在
`performBatchUpdates` 與 UIKit 內部改寫時才發作**：

1. **`layoutAttributesFor…` 必須回傳複本，不能回傳快取實例。**
   `UICollectionViewLayoutAttributes` 是 class，UIKit 會**就地修改**它拿到的物件（套用更新
   動畫、inset 調整、內部記帳）。回傳快取實例等於讓 UIKit 改寫我們的快取，之後每一輪讀到
   的都是被污染的 frame。`UICollectionViewFlowLayout` 正是為此一律複製。
2. **必須實作 `initialLayoutAttributesForAppearingItem` /
   `finalLayoutAttributesForDisappearingItem`。**
   章節 prepend 走 `insertItems`，UIKit 會用**舊／新兩套 index path** 詢問屬性；快取只有新的
   一套時，索引位移過的 cell 會落在無關位置，直到後續 pass 才修正。
   本閱讀器不做插入動畫（改用 `contentOffset` 補償），所以兩者都回穩定後的幾何。

回歸測試：拿到屬性後改寫其 frame，再讀一次必須拿回原值。

#### 測試

`ReaderScrollLayoutTests` 立**兩個真的 `UICollectionView`**，一個掛 flow layout、一個掛
`ReaderScrollLayout`，比對 UIKit 實際算出的 `layoutAttributes`（而非跟手算數字比，這樣連
flow layout 沒寫在文件裡的行為也一起對到）。直排與 RTL 兩軸各一組；rect 探測刻意包含
**正好落在 item 邊界上**的偏移。

### 階段 3 — 估算高度上線（行為改變，最危險的一步）🔶 防跳動機制已落地，估算尚未上畫面
outline 出來即插入，高度先用估算值；`willDisplay` ＋ overscan 觸發實算；實算高度回寫 store → layout 失效 → `AnchorCompensator` 修正 offset。**驗證：見第 9 節。**

#### 已完成：`AnchorCompensator`（2026-08-14，160 測試綠）

**順序是刻意的**：補償機制被證明之前，不讓任何估算高度有機會造成跳動。

`ScrollAnchor` 三個欄位：`chapterIndex` ＋ `charOffset` ＋ `distanceIntoFragment`。

| 決定 | 理由 |
|---|---|
| 錨點用 **charOffset** 不用 index path | 章節 prepend／reload 會讓 index 失效，字元位移不會（附錄明訂） |
| 片段內位移用**絕對點數**不用比例 | 錨點的意義是「該 fragment 頂端視覺上不動」；比例會在該 fragment 自己被重新量測時滑動 |
| 內容不在了回 **`nil`** 不回舊值 | 章節被驅逐／換源後硬給數字會把讀者捲到隨機位置，比不調整更糟。**這不是缺兜底，是拒絕猜測** |

`AnchorCompensatorTests` 驗 §9 不變量 3。高度刻意用 `211.5 / 97 / 340.25` 這種不整齊的值，
且上方兩個 fragment **一個變高一個變矮**，算術錯了不會剛好抵銷。核心斷言是：套用補償後
重新錨定得到的 `ScrollAnchor` 必須與原本**完全相等**。涵蓋：

- 視窗上方重新量測 → 補償量恰為淨變化量
- 視窗下方重新量測 → 補償量為 0
- prepend 一整章 → 補償量恰為插入高度
- **整章 8 個 fragment 一次全部重新量測** → 錨點仍守恆
- 章節被驅逐 → 回 `nil`
- `.measured` 不退回估算（否則捲走再回來會被推回去）

#### 未完成：估算值上畫面

還需要（依風險排序）：

1. **邊界權威**（§8.2，最容易出錯）：outline 決定 charRange 後，實算不得再改。目前
   `paragraphBoundaryLookback`、`splitBeforeFloatLocation`、`CTFrameGetVisibleStringRange`
   修正**都會在實算時改變邊界**，與此直接衝突。float 偵測必須前移到 outline 階段。
2. **單一 descriptor 排版**：`CoreTextChunkSlicer` 要從「迴圈整章」改成「排一個 descriptor」。
3. **`willDisplay` ＋ overscan 觸發實算**，實算回寫 → layout 失效 → 套用補償。
4. **拖曳／甩動策略**（§8.1）：拖曳中只補償視窗上方；甩動期間不實算。
5. 直排 `sliceVertical` 末塊壓縮與背景圖補滿一屏，兩者都依賴「知道整章有幾塊」，
   在 lazy 模型下要重新表述。

### 階段 4 — 丟棄策略
遠離 viewport 的 fragment 丟 CTFrame 但**保留 actualHeight**。調整 warm/evict 半徑。

### 階段 5 — 收尾
移除 `insertLoadingPlaceholder` 的同步 `slice`；重估 `defaultHeightCap`（2000pt 在 fragment 模型下可能該改成「一個段落」而非固定高度）。

---

## 8. 可能出現的問題

### 8.1 Scroll jumping（最高風險）

| 情境 | 機制 | 對策 |
|---|---|---|
| 估算→實算高度改變，且該 fragment 在**視窗上方** | 上方內容變高／變矮，下方全部位移 | `AnchorCompensator`：以視窗頂端的 **charOffset** 為錨，實算後重算該 charOffset 的 y，差值直接補進 `contentOffset` |
| 使用者**正在拖曳**時高度變更 | `setContentOffset` 與手勢打架 | 拖曳中只補償**視窗上方**的變更；視窗內與下方的變更延到 `scrollViewDidEndDragging` |
| 快速甩動（fling）掠過大量未實算 fragment | 估算誤差累積 → 捲動條與內容脫節 | 甩動期間**不實算**，只畫估算佔位；`decelerate` 結束後補實算 ＋ 一次補償 |
| 往回捲遇到已 `.measured` 但 frame 已丟的 fragment | 高度已定，**不得**退回估算 | `.measured` 的 `actualHeight` 永久保留，evict 只丟 CTFrame |

### 8.2 Layout inconsistency

- **估算與實算對同一 fragment 給出不同段落起點**：段落邊界回退邏輯（`paragraphBoundaryLookback`）目前是在實算時決定 chunk 邊界的。**outline 必須成為邊界的唯一權威**，實算不得再改邊界 —— 否則 descriptor 與 chunk 的 charRange 會對不上，選取與閱讀位置全歪。這是整個重構最容易出錯的地方。
- **float 切分會改變邊界**：現行 `splitBeforeFloatLocation` 會在實算時把 chunk 切短。這與上一條直接衝突。**必須把 float 偵測前移到 outline 階段**（掃 attributed string 的 float attribute，不需要排版）。
- 直排 `sliceVertical` 的最後一塊壓縮寬度、背景圖補滿一屏 —— 這兩條都依賴「知道整章有幾塊」，在 lazy 模型下要重新表述。

### 8.3 記憶體

- descriptor 常駐：每 fragment 約數十 bytes × 全章 → 可忽略。
- 風險反而是**估算讓更多章節能同時「存在」**（因為插入變便宜），可能使常駐章節數上升。`MemoryTracker` 要加上 outline 這一類。
- `NSAttributedString` 仍是整章常駐，且是目前最大的一塊。lazy layout 不改善它。

---

## 9. 每一步如何驗證

### 效能

用既有 `ReaderPerfTrace`（⏱ 行，Release Console 可見）。**每一步都要回報前後毫秒數**：

| 指標 | 階段 0 基準 | 目標 |
|---|---|---|
| 章節從「內容到手」到「可捲動」 | 量出來 | 階段 3 後應與章長**脫鉤** |
| 首屏可見內容就緒 | 量出來 | 顯著下降 |
| 捲動中每 frame 的實算時間 | 新增 span | 不得出現 >16ms 的單次實算 |
| 快速甩動掉幀 | Instruments Core Animation | 不得比改前差 |

**「章節載入時間與章長脫鉤」是這次重構唯一的成功判準。** 其餘都是副產品。

### 正確性

| 階段 | 驗證方式 |
|---|---|
| 1 | 新測試：同一章，新舊路徑產生的 chunk `charRange` 與 `height` **逐一相同** |
| 2 | 新測試：`ReaderScrollLayout` 與 flow layout 對同一組高度產生相同的 `layoutAttributes` |
| 3 | 新測試：估算高度插入 → 實算回寫 → 錨點 charOffset 的**螢幕 y 座標不變**（這是防跳動的唯一機器驗證） |
| 3 | 新測試：整章實算後，chunk 邊界與階段 1 的基準**完全相同**（防 outline 與實算對邊界的分歧） |
| 全程 | `CoreTextScrollTests`、`CoreTextWritingModeTests`（直排必跑）、`ReaderRenderRefreshTests` |
| 全程 | 真書：紅樓夢（458 章、大量背景圖與註解）、洪武大帝（多看盒模型）、直排的 kusamakura |

### 必須新增的不變量測試

1. **邊界權威**：outline 決定的 charRange，實算後不得改變。
2. **高度單調性**：`.measured` 的高度不得退回估算值。
3. **錨點守恆**：任何高度變更後，錨點 charOffset 的螢幕 y 不變（誤差 < 1pt）。
4. **總高一致**：全章實算後的 `totalHeight` 必須等於階段 1 基準的高度總和。

---

## 附錄：不要做的事

- 不要引入 `NSTextLayoutManager` / `NSTextViewportLayoutController`。它們無法驅動 CoreText。
- 不要為了 lazy 而放寬 EPUB CSS 能力。float、直排、註解、背景圖的既有行為都是回歸測試的一部分。
- 不要在估算階段呼叫任何 `CTFramesetter*` API。一旦呼叫，估算就不便宜，整個架構失去意義。
- 不要用 index path 當錨點。章節 prepend／reload 會讓 index 失效，charOffset 不會。
