# Yuedu CoreText：DTCoreText 對照、效能改善與獨立開源計畫

> 日期：2026-07-27
>
> 對照基準：DTCoreText `81a4397356e44e5c26e7dd0d0b393b5efb0ea51c`（2026-07-15）
>
> 範圍：`Modules/Core/ReaderCore/CoreText/`、分頁／連續捲動宿主、HTML/CSS 轉換管線、快取與效能追蹤
>
> 方法：原始碼靜態稽核、架構對照、Time Profiler CPU sample，以及兩本 161／224 MiB 外部 EPUB 的 Debug 模擬器前後基準；Release 真機 median／p95 尚待執行

## 執行摘要

目前的慢，不是因為「Core Text 天生慢」，而是昂貴工作在錯誤的時間、執行緒與抽象層重複發生：

1. 大型 EPUB 的第一個實測主因是 `@font-face` 引用了大量未打包字型：每個缺失資源都進入 Readium manifest 查找與錯誤日誌；OPF manifest O(1) availability guard 後，代表章節 build 由 5.3–12.8 秒降到 1.0–3.2 秒。
2. `layoutFingerprint` 在進入 detached task 前掃描整章文字與所有 attributes；長章的「首屏快速路徑 + 完整分頁」還會掃兩次。
3. 同一頁在算 page range、抽圖片、抽 inline annotation、抽 block decoration、實際繪圖時重複建立 `CTFrame`。
4. 連續捲動以約 2,000 pt 高的 chunk 在主執行緒同步建立／繪製文字、裝飾與圖片；預熱沒趕上時，`willDisplay` 還會同步 materialize。
5. 分頁與捲動各自呼叫 `buildChapter`，同一章可能重做 HTML parse、CSS cascade、AST、IR、圖片載入與 attributed string render。
6. CSS matching 對每個 element 掃描並排序全部規則；圖片也大致依文件順序等待，長章與圖片章的延遲會被放大。
7. paginator 另有一份未設容量的完整 layout cache；它與 engine LRU 重疊，memory warning 又沒有清掉所有 layout，容易以記憶體換到不穩定的命中率。

DTCoreText 最值得學的不是把整套程式碼搬過來，而是四個邊界：

- 一份 attributed string 對應一個 layouter／framesetter，layout frame 可用明確 key 快取。
- `CoreTextLayoutFrame` 同時保存 `CTFrame` 與衍生的 lines／glyph runs，繪圖只處理 clip rect 可見範圍。
- 長內容用 `CATiledLayer` 背景分塊繪製，主執行緒只發布 immutable snapshot 與管理互動 view。
- HTML parser 支援串流、取消與單次 builder 結果快取，而不是讓 UI 等完整同步管線。

但 Yuedu 不應退化成一般 rich-text view。我們已經有 DTCoreText 沒有的閱讀器能力：穩定章節位置、分頁與連續模式共用內容語意、CJK 直排、跨頁互動、EPUB CSS／浮動元素／註解／TTS／線上書源。正確方向是保留這些優勢，重建「章節文件、layout session、display list、背景 raster」四個邊界。

建議先做 P0 量測，再依序做 P1 主執行緒止血、P2 章節結果共用、P3 單次 layout artifact、P4 背景分塊繪製。獨立開源則先在 app 內轉成 local Swift Package，等 app 使用同一套 public API 後再發佈 v0.1；不要直接把現在的資料夾複製出去。

## 稽核結論的可信範圍

以下「有沒有做重複工作、工作在哪個 actor、快取是否有上限」是程式碼可直接證明的事實；「每項佔總延遲多少」仍需 P0 的 signpost 與真機 profile 才能排序。

因此本計畫不以猜測的毫秒數承諾成果，而是先建立固定 corpus、固定裝置、Release build 與可重複操作，再讓每一階段以 before／after 數據出場。這也符合專案要求：效能修改必須有 `SourcePerfTrace` 或等價的前後數字。

目前 P0 已完成可提交的 synthetic corpus、22 個 Points of Interest 階段、
兩本大型外部 EPUB corpus contract，以及第一個前後優化。結果也修正了最初
純靜態稽核的排序：代表章節的 pagination 一直低於約 36 ms，首要瓶頸其實在
進入 Core Text 之前的 CSS 字型資源解析。下列 layout／raster 問題仍成立，但
應在完成 Release 真機 capture 後依實測重新排序。

## 架構對照

| 面向 | DTCoreText | Yuedu 現況 | 判斷 |
|---|---|---|---|
| 產品定位 | HTML attributed string + 通用 rich-text view | EPUB/TXT/線上書源閱讀器 | Yuedu 的產品範圍更完整，不應直接換引擎 |
| HTML 處理 | libxml2 串流 parser event，支援 async/cancel | SwiftSoup DOM → Styled AST → `RenderableNode` → attributed string | Yuedu IR 是擴充優勢，但目前有較高延遲與峰值記憶體 |
| Layout owner | `CoreTextLayouter` 持有 attributed string 與 lazy framesetter | builder、paginator、page/scroll engine 分散持有 | 需要 `ChapterDocument` + queue-confined `LayoutSession` |
| Frame reuse | `CoreTextLayoutFrame` 可由 `NSCache` 依 string/frame/range key 重用 | 同一 page range 被多個 extractor 各自建 frame，draw 又建一次 | 這是最明確的重工之一 |
| 長內容繪製 | `CATiledLayer`，背景 tile draw，只畫可見 lines | 大 chunk 的 `UIView.draw(_:)` 同步 raster | 需要 tile／bitmap A/B 實驗 |
| 衍生資料 | layout frame lazy 保存 lines、glyph-run layout | attachment、annotation、block renderable 分開重掃 | 應合併成單次 display list |
| Custom view | 只為 visible rect 配置 attachment views | 圖片主要在 draw 內畫，互動 overlay 另管 | 可保留 overlay 優勢，base layer 改背景 raster |
| Cache | 明確可選的 frame cache，圖片／字型也有 bounded cache | engine LRU + paginator dictionary + snapshot cache 多層重疊 | 統一 ownership、cost 與 memory-warning 行為 |
| 直排 | 未見 `vertical-rl`／`kCTVerticalForms` 的完整支援 | 有完整 CJK 直排、標點正規化、選取／點擊座標處理 | Yuedu 的核心差異化 |
| 閱讀位置 | rich-text range／view 座標 | `(spineIndex, charOffset)`、CFI／進度映射 | Yuedu 的核心差異化 |

## 效能根因與程式碼證據

### P0 級：主執行緒先做整章 fingerprint

[`CoreTextPaginator.layoutFingerprint`](../../Modules/Core/ReaderCore/CoreText/CoreTextPaginator.swift) 會：

- hash 完整 `attributedString.string`；
- enumerate 整章 attributes；
- 讀 font、paragraph style、vertical forms、hyphenation；
- 解析每個 `CTRunDelegate` 的圖片與 annotation payload。

`paginate` 與 `paginateFirstPage` 都在建立 `CacheKey` 時呼叫它，之後才進 `Task.detached`。呼叫端 `CoreTextPageEngine`／`PaginationManager` 位於 MainActor 路徑，所以「背景分頁」開始前，UI 已先支付一次 O(N) 全章掃描。

長章會先 `paginateFirstPage`，再跑完整 `paginate`，同一份內容因此至少 fingerprint 兩次。直排時，`preparedAttributedString` 的 copy／attribute normalization 也會在兩條 layout 路徑重做。

**改善：**

- `buildChapter` 產出一次性的 `ContentRevision`，layout key 直接引用它。
- revision 必須由內容與 layout-affecting metadata 決定；不要把 Swift `Hasher` 的 process-randomized 結果當持久磁碟 key。
- 若舊 builder 暫時沒有 revision，fingerprint 也必須移到背景 queue，且由 `ChapterDocumentStore` 去重，只算一次。
- first-page 與 full-layout 共用 prepared attributed string 與 revision。

**目前進度（2026-07-28）：** 已加入 opaque、`Hashable & Sendable` 的
`ContentRevision`，由一次 `AttributedChapterBuildResult` 產生並沿
`PaginationRequest` 傳到 first/full/warm layout。production two-phase path 的
完整 fingerprint 次數已由 2 降為 0；沒有 revision 的 legacy direct caller
仍執行原本 fingerprint。prepared attributed string 共用仍留待
`ChapterDocument`／`LayoutSession` 階段處理。

### P0 級：同一頁重複建立 `CTFrame`

[`CoreTextPaginator`](../../Modules/Core/ReaderCore/CoreText/CoreTextPaginator.swift) 的典型完整分頁流程是：

1. `computeLayout` 建 frame，取得 visible range。
2. `extractImages` 對每個 page range 再建 frame。
3. `extractInlineAnnotations` 對每個 page range再建 frame。
4. `extractBlockRenderables` 對每個 page range 再建 frame。
5. [`CoreTextPageView.renderPage`](../../Modules/Core/ReaderCore/CoreText/CoreTextPageView.swift) 顯示／snapshot 時再建 frame。

也就是一般頁面在 layout 階段可被 shape/frame 約四次，之後每次 redraw 還可能繼續建立。浮動元素與 probe 會再增加次數。

**改善：**

- 每頁只建立一次 `PageLayoutArtifact`。
- artifact 保存 range、frame、lines、attachments、inline annotations、block renderables、link/selection hit-test metadata。
- 所有 extractor 改為接受同一個 frame／line snapshot，不得自行建立 frame。
- display list 的 immutable 值可以跨到 raster queue；Core Text layout object 則遵守固定 queue 的生命週期。

**目前進度（2026-07-28）：** 已加入 `PageLayoutArtifact`。最終 page
ranges 與 float notch 確定後，每頁建立一個 artifact，保存 `CTFrame` 與 line
origins；image、inline annotation、block renderable extractor、page draw 與
interaction hit testing 均消費同一 frame。分頁探測與 orphan/widow 修正使用的
暫時 frame 仍保留，因為它們發生在最終 ranges 形成之前。手動建立
`ChapterLayout` 的舊測試值暫時有明確 compatibility branch；正式 paginator
輸出不走該 branch。

### P0 級：連續捲動在主執行緒同步 raster

[`CoreTextChunkDrawView.draw(_:)`](../../Modules/Features/Reader/CoreTextChunkCell.swift) 在 UIKit draw callback 中同步做：

- 必要時 `materializeFrameIfNeeded()`；
- block backgrounds／borders；
- `CTFrameDraw` 或逐行水平排版；
- vertical inline annotations；
- 所有 block／inline image `UIImage.draw`。

chunk 預設高度約 2,000 pt，約數個螢幕。當背景預熱沒有完成，[`willDisplay`](../../Modules/Features/Reader/CoreTextCollectionScrollViewController.swift) 會同步 materialize frame。cell reuse 又會釋放 frame，捲回時可能重建。

此外，[`CoreTextHorizontalLineDrawer.resolveJustifiedLine`](../../Modules/Core/ReaderCore/CoreText/CoreTextHorizontal/CoreTextHorizontalLineDrawer.swift) 會在每次 draw 為需要齊行的 line 重建 attributed substring 與 `CTLine`。

**改善：**

- base text／decoration／non-interactive image 改成背景 tile 或 offscreen bitmap。
- selection、underline、TTS、link focus 等互動 overlay 留在主執行緒，以 range + display list 對齊。
- 對齊後的 `CTLine` 或其 draw command 只建一次。
- 圖片進 display list 前先 `prepareForDisplay`／decode，避免第一次 draw 才解碼。
- collection prefetch 應準備 document、layout artifact 與 raster，不只是提前 materialize 一部分 frame。

### P1 級：分頁與捲動重建同一份章節

[`CoreTextPageEngine`](../../Modules/Core/ReaderCore/CoreText/CoreTextPageEngine.swift) 與 [`CoreTextScrollEngine`](../../Modules/Core/ReaderCore/CoreText/CoreTextScrollEngine.swift) 都持有 builder 並各自 `buildChapter`。[`EPUBAttributedStringBuilder`](../../Modules/Core/ReaderCore/CoreText/EPUBAttributedStringBuilder.swift) 每次又建立新的 HTML builder。

切換閱讀模式或兩個 engine 各自載入同章時，可能重做：

- resource fetch；
- HTML parse；
- stylesheet fetch／parse；
- CSS cascade；
- Styled AST；
- `RenderableNode`；
- attributed string；
- 圖片載入／raster。

**改善：**

- 新增 actor `ChapterDocumentStore`，key 至少包含 publication/resource identity、content revision、typography input、render width 與 writing mode。
- in-flight task 必須去重；相同 key 只允許一個 build。
- `PageEngine` 與 `ScrollEngine` 只消費同一份 immutable `ChapterDocument`。
- theme 的純色彩變更不得重做 layout；只有字型、字級、行距、內容寬度、writing mode 等 layout-affecting input 才失效。

**目前進度（2026-07-28）：** 已加入 bounded、generation-aware 的
`ChapterDocumentStore`，相同 request 的 in-flight build 只執行一次。EPUB、
TXT 與線上內容的 page／scroll engine 由 `EPUBPageRenderer` 注入同一 store；
容量固定為 8，明確 invalidation 會使舊 task 結果失效。整合 mutation 暫時繞過
scroll store 時測試由 5/5 降為 4/5，還原後相關 focused suites 53/53 通過。

### P1 級：CSS cascade 是 element × rules 的全掃描與排序

[`HTMLAttributedStringBuilder.resolvedStyle`](../../Modules/Core/ReaderCore/CoreText/HTMLAttributedStringBuilder.swift) 對每個 element：

1. `filter` 全部 rules；
2. 對 matched rules 依 specificity／order 排序；
3. 分別套用 normal／important declarations。

大型 EPUB stylesheet 與深 DOM 會接近 `O(elements × rules)`，並產生大量短命 array／sort 工作。

**改善：**

- parse 時預先排序規則。
- 以 selector 最右側 subject 建 candidate index：`id`、class、tag、universal。
- element 只匹配候選集合；最後仍依 CSS specificity/order 套用，不能破壞 cascade 正確性。
- stylesheet 依 publication + resource URL + bytes revision 快取；同一外部 CSS 不重複 parse。
- 先以既有 CSS fixture 做 parity test，再量 CPU／allocation。

### P1 級：Metadata 被每個 chunk 重掃

[`CoreTextChunkSlicer`](../../Modules/Core/ReaderCore/CoreText/CoreTextChunkSlicer.swift) 在建立水平 frame 與計算 float height 時都可能呼叫 `CoreTextPaginator.floatMarkers(in:)`。這個 API enumerate 整份 attributed string，因而可能形成 `O(chunks × chapter runs)`。

**改善：**

- `ChapterDocument` build 完成時只掃一次 page break、float、image、annotation、anchor 等 marker。
- 以 sorted offsets／interval index 供 page/chunk 二分查詢。
- paginator 與 slicer 不再掃全章 attributed attributes。

### P1 級：圖片依樹狀順序等待，draw 時可能才解碼

[`NodeAttributedStringRenderer`](../../Modules/Core/ReaderCore/CoreText/NodeAttributedStringRenderer.swift) 多處依 children 順序 `await render`，圖片載入也發生在遞迴 render 中。多圖章節容易把可平行的 I/O 串成關鍵路徑；圖片第一次 `draw` 又可能支付 decode 成本。

**改善：**

- AST／IR 完成後先收集 resource manifest。
- `ImageRepository` 以 URL/resource identity 去重並限制併發，不可無上限 task group。
- 首屏資源優先，非首屏資源背景載入；layout 若需 intrinsic size，先讀 metadata 或 thumbnail，不必等完整 decode。
- 進入可見 raster 範圍前準備 display-ready image。

### P1 級：Cache ownership 重疊且不完全受控

- `CoreTextPageEngine` 的 `_layouts` 是 capacity 8 的 distance-aware LRU。
- `CoreTextPaginator.cache` 是未設容量的 `[CacheKey: ChapterLayout]`。
- snapshot `NSCache` 有 cost/count limit，但可能保留數十至數百 MB。
- memory warning 目前清 snapshot 並取消 preload，沒有同步清 engine layouts／paginator cache。

因此 engine 已 evict 的完整 layout 仍可能留在 paginator；多尺寸、字級、writing mode、內容 revision 都會製造新 key。

**改善：**

- cache owner 只能有一個：`ChapterDocumentStore` 管文件，`LayoutArtifactCache` 管 layout，`RasterCache` 管 bitmap。
- 每層明確設定 count/cost，key 與 invalidation policy 文件化。
- memory warning 先清 raster，再清非當前／非相鄰 layout，再清可重建文件；當前可見 artifact 保留。
- 加入 cache hit/miss/eviction、estimated bytes signpost。

### P2 級：Theme 更新複製整章並重建 framesetter

[`ChapterLayout.withUpdatedAppearance`](../../Modules/Core/ReaderCore/CoreText/CoreTextPaginator.swift) 會 mutable-copy attributed string、enumerate attributes，並建立新 framesetter。純 foreground/background 變色不應改變 page ranges。

**改善：**

- layout-affecting typography 與 paint-only palette 分離。
- display list 保存 semantic color token，而不是把每次 theme 的最終 `UIColor` 烘焙進 layout。
- theme switch 只 invalidate raster／可見 layer，不重做 HTML、CSS、pagination。

### P2 級：以 16 ms polling 等首個 layout

[`CoreTextPageEngine.awaitFirstLayout`](../../Modules/Core/ReaderCore/CoreText/CoreTextPageEngine.swift) 每 16 ms `Task.sleep` 查 `_layouts`。這不是最大 CPU 熱點，但它是計時式狀態同步，會增加不必要的首屏量化延遲，也違反本專案「不用 sleep 掩蓋狀態」的規則。

**改善：**

- preload task 安裝 partial/full layout 時 resume continuation 或發送 typed event。
- cancellation、失敗、generation change 必須都有明確終止事件，不得以 timeout/fallback 掩蓋。

### P2 級：HTML 管線峰值記憶體偏高

Yuedu 同時經過 SwiftSoup DOM、Styled AST、`RenderableNode`、`NSAttributedString`。這換來清楚的語意層、測試性與多來源一致性，是值得保留的設計；問題在於中間結果的生命週期與整章 materialization。

**改善：**

- instrument 各階段 retained bytes。
- `ChapterDocument` 建立完成後釋放 DOM／Styled AST，不讓 cache 捕捉整條 pipeline。
- 長章評估 section/block streaming，但只在 P0 數據顯示 parse/IR 或峰值記憶體是主要問題後進行。
- 不直接照搬 DTCoreText 的 parser；那會犧牲現有 IR 上的 EPUB 語意與擴充能力。

## 可以向 DTCoreText 學什麼

### 1. Layouter 與 layout frame 的所有權

`CoreTextLayouter` 將 attributed string 與 lazy framesetter 綁在一起；`CoreTextLayoutFrame` 再保存 frame、lines 與 glyph-run layout。Yuedu 應採用相似責任邊界，但輸出閱讀器需要的 `PageLayoutArtifact`／`ChunkLayoutArtifact`。

### 2. Clip-aware 的可見範圍繪製

DTCoreText 不會把整份長內容每次全部畫完，而是依 clip rect 選擇 visible lines 和 custom views。Yuedu 即使選 offscreen bitmap，也應讓 raster job 以 tile rect 為輸入，只產生需要的 draw commands。

### 3. `CATiledLayer` 背景繪製

DTCoreText 的 `AttributedTextView` 強制使用無 fade 的 `CATiledLayer`，並透過 locked immutable snapshot 讓 tile callback 在背景執行。這非常適合作為 Yuedu 連續模式的第一個 A/B prototype。

### 4. Builder 的取消與結果生命週期

DTCoreText 的 HTML builder 能 async build、取消，並在 builder instance 上快取結果。Yuedu 應把這個概念提升成跨 page/scroll engine 的 `ChapterDocumentStore`，而不是只快取單一 builder。

### 5. Package 與 public API 紀律

DTCoreText 已是 Swift Package，核心 layout、UI view、HTML builder 的責任相對可辨識。Yuedu 開源前也應先讓 app 自己成為 package 的第一個外部使用者，才能找到隱藏的 app-global coupling。

## 不要直接照抄什麼

- 不要用 DTCoreText 取代 `RenderableNode`；我們的 EPUB／線上內容語意與測試資產更豐富。
- 不要把 `CATiledLayer` 當成未量測的唯一答案；它要和 offscreen `CGImage` 比較記憶體、取消成本、快速捲動與直排結果。
- 不要把 `CTFramesetter`／`CTFrame` 任意共享給多個 detached tasks。Apple 文件指出 Core Text API 可跨執行緒呼叫，但 layout object 應限制在建立它的單一 operation／work queue／thread 使用。開源 API 要把 queue confinement 寫成 contract。
- 不要把 DTCoreText 的通用 rich-text API 直接套到 reader navigation；`(resourceIndex, charOffset)` 必須保持第一級型別。
- 不要加入「背景失敗就主線同步重做」的隱性 fallback。每個失敗都要有精確原因、可觀測狀態與唯一正式路徑。

## Yuedu 現有優點

### 閱讀器語意

- 穩定位置 `(spineIndex, charOffset)`，不依賴會因設定改變的 global page index。
- EPUB CFI、章節 anchor、進度與翻頁模式之間可以互相映射。
- partial first page、相鄰章預載、lazy chapter loading 已有正確產品方向。

### CJK 與直排

- `vertical-rl`、`kCTVerticalForms`、標點正規化、ASCII／Latin sideways handling。
- 直排選取、link hit testing、標註與頁面流向。
- 橫排／直排共用內容 IR，而不是兩套 parser。

### EPUB 呈現能力

- forced page breaks、CSS float、block background/border、inline annotations。
- ruby、MathML、table、SVG／image、image-only cover、footnote、media。
- publisher CSS 與讀者 typography 設定之間已有明確處理。

### 互動與可存取性

- 選取、畫線／註記、TTS 同步 overlay、連結、媒體。
- reader page action 與章節導覽，而不只是可朗讀的 rich text。

### 可開源的技術資產

- 約 61 個 Swift 檔、26K LOC 的 CoreText 實作與大量垂直排版／EPUB parity tests。
- `RenderableNode` 是很好的跨 HTML、Markdown、線上內容轉換邊界。
- page/chunk 共用 typography 與 attachment 模型的基礎已存在。

## 效能量測契約

### 固定測試 corpus

至少建立以下可提交、無版權問題的 synthetic fixtures：

| Fixture | 規模／特性 | 主要觀察 |
|---|---|---|
| `plain-10k` | 10K chars，純文字 | 小章基準與額外 overhead |
| `plain-100k` | 100K chars，500+ paragraphs | fingerprint、pagination、峰值記憶體 |
| `css-heavy-50k` | 50K chars，1,000 elements，300 rules | selector candidate index |
| `image-40` | 40 張本地圖片，混合尺寸 | load/decode/raster/prefetch |
| `vertical-cjk-50k` | 50K CJK、ruby、標點、Latin | 直排 normalize/layout/draw |
| `mixed-epub` | float、table、MathML、SVG、footnote | 功能 parity 與 display list |
| `online-latency` | 可控 fake resource loader | I/O 去重、取消、首屏優先 |

### Signpost 階段

新增 reader 專用 trace（可沿用 `SourcePerfTrace` 底層，但 category 分離）：

```text
chapter.load
html.parse
css.collect
css.parse
css.match
ast.build
ir.convert
attributed.render
resource.image.load
resource.image.decode
layout.fingerprint
layout.vertical.prepare
layout.framesetter.create
layout.pageRanges
layout.displayList
layout.firstPage.publish
render.page
render.chunk
render.tile
cache.document
cache.layout
cache.raster
```

每個 signpost 至少帶：resource identity、content length、element/rule/page/chunk count、writing mode、cache result、main/background executor、generation。

### 基準環境

- Release configuration，實體裝置；固定 iOS 版本與裝置型號。
- 至少一台 60 Hz 裝置；若專案目標包含 ProMotion，再加一台 120 Hz。
- 每個 scenario warm/cold 各跑至少 10 次，報 median、p95、peak RSS。
- 捲動採 10 秒可重複 scripted scroll，記錄 hitch ratio、frame duration 與 raster miss。
- Instruments 使用 Time Profiler、Core Animation、Allocations、Points of Interest。

### 階段驗收門檻

- `html.*`、`attributed.render`、`layout.*` 不在 MainActor 執行；主執行緒只 publish state，單次目標 ≤ 4 ms。
- 固定裝置與 corpus 上，cached local chapter 首屏 p95 至少改善 35%；通過 P0 後再鎖定絕對毫秒門檻，初始建議 ≤ 300 ms。
- 10 秒 scripted scroll hitch ratio < 1%；p95 main-thread frame work 不超過該裝置 refresh budget（60 Hz 16.7 ms、120 Hz 8.3 ms）。
- peak RSS 相較 baseline 不得退步超過 10%；memory warning 後非可見 raster/layout cache 可觀察地釋放。
- page ranges、`(spineIndex, charOffset)`、anchor、selection、annotation 位置在 fixture 中 100% parity。
- `CoreTextWritingModeTests` 與垂直 fixture 零退步。

## 分階段改善計畫

### P0 — 建立可重複 baseline（1–2 天）

**工作**

- 建 synthetic fixtures 與 scripted reader benchmark。
- 用 `OSSignposter` 補齊上列階段；以 `XCTOSSignpostMetric` 建可自動比較的 performance tests。
- 在 reference device 錄 cold/warm、paged/scroll、horizontal/vertical baseline。
- 匯出 flame graph／top stacks、main-thread blocking、allocation 與 cache hit table。

**出口條件**

- 每次 PR 能重跑相同 corpus。
- 知道 TTFP、完整 layout、scroll hitch、peak RSS 前三大成本各是什麼。
- 後續每個效能 PR 附 before／after，不接受只以體感宣稱。

### P1 — 主執行緒止血與重複掃描消除（2–4 天）

**工作**

- `ContentRevision` 在 build 完成時產生；fingerprint 移出 MainActor且只算一次。
- first-page/full-layout 共用 prepared attributed string。
- `awaitFirstLayout` 改成 continuation／event，不再 16 ms polling。
- 建章節 marker index；float/page break/annotation/anchor 不再每 chunk 全掃。
- 圖片 metadata 與 decode prefetch；可見 draw 不做首次 decode。
- paginator dictionary 改 bounded cost cache，補 memory warning policy。

**出口條件**

- Main Thread Checker／signpost 看不到整章 hash、attribute enumeration、圖片 decode。
- 首屏快速路徑只做一份 revision 與 prepared string。
- cache 可被測試地 evict，memory warning 後資源下降。

### P2 — 一章只 build 一次（4–7 天）

**工作**

- 引入 immutable `ChapterDocument`：

```swift
public struct ChapterDocument: @unchecked Sendable {
    public let identity: ResourceIdentity
    public let revision: ContentRevision
    public let attributedString: NSAttributedString
    public let markers: ChapterMarkerIndex
    public let anchors: [String: Int]
    public let resources: ChapterResourceManifest
    public let metadata: ChapterMetadata
}
```

- 由 `ChapterDocumentStore` actor 管 cache、in-flight dedup、cancellation。
- page/scroll engine 改為消費同一 document。
- external stylesheet 快取與 selector candidate index。
- 明確分離 layout config 與 paint palette。

**出口條件**

- 相同 key 同時請求 page/scroll，trace 只出現一次 `chapter.load`。
- mode switch 不重做 HTML/CSS/IR。
- theme switch 不重做 pagination。

> `@unchecked Sendable` 只是一個 API 草圖警示：正式實作前要逐項驗證 payload 的 thread-safety；能用 immutable value wrapper 取代時，不應直接留下 unchecked。

### P3 — 一頁只 layout 一次（4–7 天）

**工作**

- 引入 `LayoutSession` 與 `PageLayoutArtifact`／`ChunkLayoutArtifact`。
- page range、frame、lines、attachments、block renderables、hit-test data 在同一 pass 產生。
- cache justified lines／draw commands。
- Core Text object 採 queue confinement：每個 session 固定 layout executor；跨 queue 只傳 immutable value/display list 或已 raster image。
- 移除 extractor 內部自行建 frame 的 API。

**出口條件**

- trace 顯示每個 page/chunk 只有一次 frame creation。
- attachment／annotation／block geometry 與舊輸出 parity。
- Thread Sanitizer 與壓力切頁不出現共享 layout object race。

### P4 — 連續捲動背景 raster A/B（3–6 天）

先抽象唯一的 `ChunkRasterizer` protocol，在實驗 branch 比較兩種實作：

1. **A：clip-aware `CATiledLayer`（推薦先做）**

   與 DTCoreText 相同方向，天然按可見 tile 背景 draw，快速捲動時不必先產生整個 2,000 pt bitmap。

2. **B：offscreen `CGImage` cache**

   可完全控制 prefetch、取消與快取 cost，cell 顯示成本低，但長 chunk 的記憶體與過期 bitmap 成本可能較高。

兩者都使用 P3 的 immutable display list；selection／annotation／TTS／link overlay 仍是主執行緒 vector layer。

**決策規則**

- 同 corpus 比較 hitch ratio、main-thread time、raster latency、取消浪費、peak RSS、scroll-back cache hit。
- 實驗完成後保留勝出的單一路徑；不把另一條當長期 fallback。
- 若直排與橫排結果不同，先修 display list，不以模式分叉兩套 renderer。

**出口條件**

- 達成 scroll hitch 與 frame-budget 門檻。
- raster miss 不會在主執行緒同步 layout。
- 快速反向捲動可取消無效 job，且 cell reuse 不造成 layout 重建風暴。

### P5 — CSS／資源與峰值記憶體深化（3–7 天，依 P0 排名）

**工作**

- selector candidate index、pre-sorted cascade、stylesheet parse cache。
- bounded-concurrency `ImageRepository` 與首屏資源優先。
- DOM／Styled AST／IR 生命週期檢查；build 完即釋放不再需要的 stage。
- 若數據仍顯示超長章峰值過高，再設計 block streaming document build。

**出口條件**

- CSS-heavy fixture 的 `css.match` CPU 與 allocation 有明確下降。
- image fixture 不再依圖片數量線性增加首屏等待。
- peak RSS 達標且內容 parity 不退步。

### P6 — 轉成內部 Swift Package 並準備公開（5–10 天）

這階段可在 P2 API 穩定後開始；不必等所有 P4/P5 最佳化完成，但 package boundary 必須先符合 concurrency 與 cache contract。

**工作**

- 在同 repo 建 local package，app 改成 package consumer。
- 反轉 `ReaderRenderSettings`、`GlobalSettings`、`AppLogger`、Readium、線上書源依賴。
- 整理 public API、DocC、sample app、benchmark、license/NOTICE。
- 先發 `0.1.0`，承諾功能範圍與非穩定 API，不過早鎖死 ABI。

**出口條件**

- app 不使用 package 的 `internal`／app-global shortcut。
- core target 無 Readium、SwiftSoup、WebKit、SwiftUI、AVKit、app logger/settings。
- package tests 可獨立執行。
- sample 能顯示 horizontal/vertical、paged/scroll、selection/annotation 的最小完整流程。

## 獨立開源邊界

目前 `Modules/Core/ReaderCore/CoreText/` 約 61 個 Swift 檔、26K LOC，但還直接或間接耦合：

- app 內的 `ReaderRenderSettings`／`ReaderWritingMode`；
- `GlobalSettings`、`AppLogger`；
- Readium `PublicationSession`／resource provider；
- `BookContentProvider`／線上服務；
- SwiftSoup、WebKit、iosMath、AVKit、SwiftUI。

建議 package 結構：

```text
YueduCoreText/
├─ Package.swift
├─ Sources/
│  ├─ YueduCoreText/
│  │  ├─ Document/
│  │  │  ├─ ChapterDocument.swift
│  │  │  ├─ RenderableNode.swift
│  │  │  └─ TextLocation.swift
│  │  ├─ Layout/
│  │  │  ├─ LayoutSession.swift
│  │  │  ├─ PageLayoutArtifact.swift
│  │  │  ├─ ChunkLayoutArtifact.swift
│  │  │  └─ WritingMode.swift
│  │  ├─ DisplayList/
│  │  ├─ Typography/
│  │  └─ Resources/
│  ├─ YueduCoreTextHTML/
│  │  ├─ HTMLDocumentBuilder.swift
│  │  ├─ CSS/
│  │  └─ SwiftSoupAdapter.swift
│  ├─ YueduCoreTextUIKit/
│  │  ├─ Paged/
│  │  ├─ Scrolling/
│  │  └─ Interaction/
│  └─ YueduCoreTextExtras/
│     ├─ MathML/
│     └─ SVG/
├─ Tests/
│  ├─ YueduCoreTextTests/
│  ├─ HTMLParityTests/
│  └─ PerformanceTests/
├─ Examples/
│  └─ ReaderDemo/
├─ Documentation.docc/
├─ LICENSE
└─ NOTICE
```

### Target 依賴方向

```text
YueduCoreText
    ↑
YueduCoreTextHTML
    ↑
YueduCoreTextUIKit

YueduCoreTextExtras → YueduCoreText
Yuedu app adapters → all needed package targets
```

`YueduCoreText` 只依賴 Foundation、CoreText、CoreGraphics，以及最低限度 UIKit（若 `UIFont`／`UIColor` 尚未完全 value-化）。理想上 core layout config 使用自有 value types，UIKit conversion 留在 UIKit target。

Readium、publication storage、線上書源、媒體播放、使用者設定、資料庫與 app logging 留在 Yuedu app。HTML target 才依賴 SwiftSoup；MathML／SVG 依賴放 Extras，避免所有使用者被迫引入。

### 第一個可獨立編譯的切片

依目前檔案級依賴盤點，第一個 Local Package compile-check 不應包含
`CoreTextPageEngine`、`CoreTextPaginator` 或整個 `RenderableNode`。它們仍直接
依賴 app-owned settings、EPUB media、具體 builder payload 與尚未穩定的 cache /
executor contract。

建議先建立不含第三方 dependency 的 `YueduCoreTextTypography` target：

```text
CJKTypographyProcessor.swift
CoreTextFramesetterFactory.swift
CoreTextCommon/ReaderHyphenation.swift
CoreTextCommon/String+VerticalNormalization.swift
CoreTextCommon/VerticalGlyphClassifier.swift
CoreTextCommon/VerticalLayoutConfig.swift
```

這一批只依賴 Apple frameworks，且已有 `CJKTypographyProcessorTests` 與
`CJKLineBreakPolicyTests` 可搬成 package tests。它的目的只是在 app 內驗證
SwiftPM 邊界、直排 typography parity 與 license/header 流程；不宣稱 layout
engine 已完成獨立化。

**目前進度（2026-07-28）：** 第一批六個檔案已發佈至公開的
[`YueduCoreText`](https://github.com/CHANG-JUI-LIN/YueduCoreText)
`YueduCoreTextTypography` target；app 與 test target 透過 0.1.x 遠端 Swift
Package product 使用。獨立套件 7/7 測試通過，App 的 CJK／直排整合測試
39/39 通過。套件包含 MPL-2.0、NOTICE、CONTRIBUTING、SECURITY、DocC、GitHub
CI／issue templates，並以自動 boundary test 禁止 Readium、SwiftSoup、
WebKit、Firebase、app setting 與 logging 耦合。這完成的是 typography v0.1
切片，不代表 paginator、HTML 或 UIKit renderer 已對外公開。

下一批可評估 `ReaderContentMetrics`、`TextSelectionManager` 與
`ReaderPerfTrace`。`LayoutCache` 雖然容易搬，但必須等 P2 決定唯一 cache owner
與 eviction contract，避免為了讓 package 先編譯而固化錯誤架構。

### 建議 public protocols

```swift
public protocol ResourceLoading: Sendable {
    func data(for request: ResourceRequest) async throws -> ResourceResponse
}

public protocol PerformanceTracing: Sendable {
    func begin(_ event: TraceEvent, metadata: TraceMetadata) -> TraceToken
    func end(_ token: TraceToken, outcome: TraceOutcome)
}

public struct TextLocation: Hashable, Codable, Sendable {
    public let resourceIndex: Int
    public let characterOffset: Int
}

public struct LayoutConfiguration: Hashable, Sendable {
    public let viewport: CGSize
    public let contentInsets: EdgeInsets
    public let typography: Typography
    public let writingMode: WritingMode
}
```

核心不直接讀 singleton。resource、trace、image preparation、font resolution、cache policy 全部注入，並提供 no-op／合理預設。

## 開源方式選項

### 方案 A — 先 local package，再開新 repo（推薦）

**優點：** app 先驗證真實 public API；容易清掉 app globals；可以從乾淨 v0.1 開始。

**代價：** 初期看不到完整逐檔 git history，但可在 NOTICE 註明來源 commit，必要時保留 history archive。

### 方案 B — 直接複製現有 CoreText 資料夾

**優點：** 最快看到 repo。

**代價：** 現在無法獨立 build，會把 Readium、GlobalSettings、logger 與 app model 耦合一起公開。後續破壞性 API 搬遷最多，不建議。

### 方案 C — `git filter-repo`／subtree 保留 history

**優點：** provenance 最完整。

**代價：** 相關型別散落在多個資料夾，現在 filter 出來仍不能獨立 build；history rewrite 與後續同步較複雜。

**建議：** 先做 A；等檔案集中到 package 後，如果非常重視歷史，再從該 consolidation commit 發佈，或額外提供 history-preserving archive。

## 名稱選項

1. **`YueduCoreText`（推薦）**：來源清楚、搜尋性高，也不會暗示它是 Apple 官方元件。
2. `ReaderCoreTextKit`：較通用，但辨識度低。
3. `YueduReaderKit`：未來可擴大，但 v0.1 實際只涵蓋文字 layout，名稱可能過寬。

不建議 `YueduTextKit`，因為容易和 Apple TextKit 1/2 混淆。

## License 選項

現有 Yuedu repo 是 MPL-2.0；從本 repo 搬出的程式碼預設仍受既有 license 約束。即使目前 CoreText 相關 commit 看起來皆為同一作者，正式 relicense 前仍要確認著作權、僱傭／委託關係與第三方貢獻。

1. **MPL-2.0（推薦）**：與現有 repo 一致，file-level copyleft，法律遷移最單純。
2. Apache-2.0：較寬鬆且有明確 patent grant；需先確認有權 relicense。
3. MIT：最簡單、採用門檻低，但 patent 條款較弱；同樣需要 relicense 權利確認。

發佈前需跑 dependency license audit，特別是 SwiftSoup、Readium、iosMath、任何搬入的 sample assets/font，並建立 `NOTICE`。這裡是工程規劃，不取代法律意見。

## v0.1 建議範圍

**包含**

- iOS 17+、Swift 6。
- `RenderableNode` → attributed string。
- horizontal／vertical Core Text layout。
- paged／continuous layout artifacts。
- image／ruby／basic table／block decorations。
- selection/link/annotation geometry。
- HTML adapter 與最小 UIKit sample。

**延後**

- 降低 deployment target。
- Readium publication adapter。
- 線上書源。
- TTS coordinator、媒體播放。
- app theme/settings/persistence。
- ABI stability 與 1.0 API 承諾。

## v0.1 發佈 Gate

- `swift build` 與 `swift test` 可在乾淨 clone 獨立完成。
- public API 有 DocC、concurrency contract、cache policy 與最小 migration guide。
- sample 不需要 Yuedu app target 或 private assets。
- horizontal/vertical fixtures 有 screenshot/layout parity。
- performance baseline 與 reference device／corpus 一起公開。
- 無未標示的 singleton、global setting、app logger、Readium/WebKit dependency。
- LICENSE、NOTICE、dependency attribution 完成。
- Security/Privacy 說明：package 不自行連網，只有注入的 `ResourceLoading` 能取得資源。
- GitHub issue templates、contributing guide、semantic versioning policy 完成。

## 建議實作順序與 PR 切法

1. `perf: add reader pipeline signposts and benchmark fixtures`
2. `perf: move content revision work off the main actor`
3. `refactor: replace first-layout polling with completion events`
4. `perf: index chapter markers and bound layout caches`
5. `refactor: introduce shared ChapterDocumentStore`
6. `perf: index CSS selector candidates and stylesheet cache`
7. `refactor: introduce queue-confined layout artifacts`
8. `perf: reuse page frames and cached justified lines`
9. `perf: prototype tiled and bitmap chunk rasterizers`
10. `refactor: move renderer core into a local Swift package`
11. `docs: add DocC sample licensing and v0.1 release metadata`

每個效能 PR 只處理一個 concern，附 signpost before／after、功能 parity 測試與 cache/concurrency 影響。不要把「新架構 + 新 raster + CSS 最佳化」包成一個無法歸因的大改。

## 需要做的三個產品決定

都不會阻擋 P0–P3，可在準備公開 repo 前決定：

1. **名稱**：推薦 `YueduCoreText`。
2. **License**：推薦沿用 MPL-2.0；若目標是最大化第三方採用，再做權利確認後評估 Apache-2.0。
3. **History**：推薦乾淨 v0.1 repo + NOTICE/provenance；不要為保留分散 history 延後 package boundary。

## 參考來源

### DTCoreText

- [DTCoreText repository](https://github.com/Cocoanetics/DTCoreText)
- [`CoreTextLayouter.swift`（本次檢視 commit）](https://github.com/Cocoanetics/DTCoreText/blob/81a4397356e44e5c26e7dd0d0b393b5efb0ea51c/Sources/DTCoreText/CoreTextLayouter.swift)
- [`CoreTextLayoutFrame.swift`](https://github.com/Cocoanetics/DTCoreText/blob/81a4397356e44e5c26e7dd0d0b393b5efb0ea51c/Sources/DTCoreText/CoreTextLayoutFrame.swift)
- [`AttributedTextView.swift`](https://github.com/Cocoanetics/DTCoreText/blob/81a4397356e44e5c26e7dd0d0b393b5efb0ea51c/Sources/DTCoreText/AttributedTextView.swift)
- [`AttributedTextContentView.swift`](https://github.com/Cocoanetics/DTCoreText/blob/81a4397356e44e5c26e7dd0d0b393b5efb0ea51c/Sources/DTCoreText/AttributedTextContentView.swift)
- [`HTMLAttributedStringBuilder.swift`](https://github.com/Cocoanetics/DTCoreText/blob/81a4397356e44e5c26e7dd0d0b393b5efb0ea51c/Sources/DTCoreText/HTMLAttributedStringBuilder.swift)

### Apple

- [CATiledLayer](https://developer.apple.com/documentation/quartzcore/catiledlayer)
- [Core Text](https://developer.apple.com/documentation/coretext)
- [Recording performance data](https://developer.apple.com/documentation/os/recording-performance-data)
- [XCTOSSignpostMetric](https://developer.apple.com/documentation/xctest/xctossignpostmetric)
- [UIImage.prepareForDisplay](https://developer.apple.com/documentation/uikit/uiimage/preparefordisplay%28completionhandler%3A%29)

## 最終建議

把第一個里程碑定義成：「所有章節建置／layout 都離開 MainActor、同章只 build 一次、同頁只建一個 frame，且有真機數字證明」。這會直接解決目前最明確的結構性浪費，也同時形成可開源的 `ChapterDocument` 與 `LayoutSession` 邊界。

第二個里程碑才是「連續捲動背景 raster」。先有 display list 和 queue confinement，再比較 `CATiledLayer` 與 offscreen bitmap，才能避免把目前的重複 layout 搬到另一條背景 queue，表面不掉幀、實際卻耗更多 CPU 與記憶體。

第三個里程碑是「Yuedu app 完全透過 local Swift Package 使用 renderer」。這個狀態通過後，公開 repo 才不是把內部程式碼丟出去，而是真正可被別人採用、測試與貢獻的開源元件。
