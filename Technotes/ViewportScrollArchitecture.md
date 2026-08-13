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
3. 每章一次的 `chapterDocumentStore.document(for:)` 產生**整章的 `NSAttributedString`**。這是 CSS／HTML → attributed string 的成本，與 CoreText 排版無關，lazy layout 不會改善它。要改善得動 `HTMLAttributedStringBuilder`，屬於另一個題目。

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

### 階段 0 — 量測基準（不改行為）
在 `slice()` 與 `loadChapter` 加 `ReaderPerfTrace` span，量出真機上：整章 slice 的毫秒數（按章長分佈）、`SuggestFrameSize` 累計時間、`CreateFrame` 累計時間、renderable 抽取時間。**沒有這組數字，後面每一步都是憑感覺。**

### 階段 1 — 抽出 outline（行為不變）
`ChapterOutline` ＋ `FragmentDescriptor` ＋ `EstimatedHeightModel`。此時仍然整章實算，但幾何改由 `FragmentGeometryStore` 提供。**驗證：所有 chunk 高度與改前逐一相同。**

### 階段 2 — 自訂 layout（行為不變）
`ReaderScrollLayout` 取代 flow layout，仍然吃精確高度。**驗證：捲動位置、章節邊界間距、RTL 直排與改前像素一致。**

### 階段 3 — 估算高度上線（行為改變，最危險的一步）
outline 出來即插入，高度先用估算值；`willDisplay` ＋ overscan 觸發實算；實算高度回寫 store → layout 失效 → `AnchorCompensator` 修正 offset。**驗證：見第 9 節。**

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
