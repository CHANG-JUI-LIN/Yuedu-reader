# Phase 4C — EPUB Layout Capability Census

日期：2026-08-22

## 結論

下一個只推薦：**Phase 4D — Horizontal Ruby Inline Layout**。

Ruby 在 corpus 中出現在 5／23 本 EPUB、88／7,350 個 chapter，共 5,216 個 `<ruby>` 與 5,216 個 `<rt>`。其中 4 本／75 章／613 組是 horizontal writing，可直接由最小 subset 覆蓋；另外 IDPF Kusamakura 的 13 章／4,603 組位於 vertical publication，先作為同一 inline model 的結構驗證，留待後續 Vertical Writing Phase 接上。

本 census 沒有修改 production layout、`BrowserLayoutCapabilityScanner`、`PageWalker`、pagination geometry 或 Lexbor production path。

## Corpus 與方法

| 來源 | EPUB | Linear chapters | 成功解析 |
|---|---:|---:|---:|
| IDPF／EPUB 3 測試書 | 4 | 2,042 | 2,042 |
| 使用者提供的真實 EPUB | 8 | 5,294 | 5,294 |
| Repo regression samples | 6 | 8 | 8 |
| Repo 內程式生成 fixtures | 5 | 6 | 6 |
| **總計** | **23** | **7,350** | **7,350** |

目前 scanner 會讓 11 本、247 個不重複 chapter fallback；各 reason 會互相重疊，不能直接相加。

統計流程不是 CSS 字串搜尋：

1. 實體 EPUB 由 `PublicationSession` 開啟，linear spine chapter 經 `EPUBBrowserLayoutResourceAdapter` 取得 XHTML 與 stylesheet；程式生成 fixtures 使用 repo 的 `EPUBTestFixtures`。
2. 每章以 SwiftSoup 建立真實 DOM；linked／inline CSS 先拆出 rule，再以 production `CSSParser` 與 `CSSSelector.matches` 對每個 DOM element 做 selector matching。
3. 同一 element 上的 author normal、inline normal、author `!important`、inline `!important` 依 specificity 與 source order 做 cascade；未命中的 rule 與被覆寫的 declaration 不計數。
4. production selector parser 不能解析時，census 才以 SwiftSoup selector 找到實際 element，並把結果標記成 `frontend` layer。這條路在本 corpus 的 unsupported occurrence 中是 **0**。
5. Ruby／table／MathML／script／SVG 由 DOM semantics 判定；float 由 production computed-style tree 判定；vertical 與 fixed layout 同時讀 OPF metadata；`@media` 仍須 selector 實際命中才計數。

Kusamakura 的 Unicode spine href 被 `PublicationSession` percent-encode 後，Readium ZIP lookup 無法找到原 entry。Census 使用明確、僅限測試的 fallback，讀取 decoded XHTML entry 及 DOM 中 `rel=stylesheet` 的 active CSS；`alternate stylesheet` 的 horizontal CSS 不納入。15 章都記在 JSON 的 `ingestionFallbacks`，production resource path 未改。

計數定義：EPUB／chapter count 是該 feature 實際命中至少一個 DOM element 或 metadata 的不重複數；element hits 是 matched、cascade-resolved declaration 或 DOM node 數。不同 feature 及 pattern 可能命中同一章，因此列與列不可相加。

## Ranking

排序綜合真實 EPUB 覆蓋、可交付的最小 subset、BrowserLayout 基礎價值及 geometry regression 風險，不是單純依 chapter 數排序。

| Rank / Feature | EPUB count | Chapter count | Actual patterns | Current fallback reason | Implementation scope | Risk to existing geometry | Expected compatibility gain |
|---|---:|---:|---|---|---|---|---|
| **1. Ruby** | **5** | **88** | 5,216 `<ruby>`、5,216 `<rt>`；5,215 組 `text + rt`、1 組 `span + rt`；每組恰好 1 個 direct `<rt>`；`rp=0`；3 本／54 章／568 nodes 實際套用 `ruby-align:center` | `ruby`：5 本／88 章 | Horizontal inline ruby formatting context；base／annotation measure、line-height、break、paint、hit geometry | **中**：只改 ruby inline runs，但會正確改變所在行高、換行與分頁 | 直接覆蓋 4 本 horizontal EPUB／75 章／613 組；建立之後 vertical 可重用的 CJK inline model |
| **2. `text-indent` 最小 subset** | **至少 6** | **至少 4,755** | 最大單一 pattern：`p { text-indent:2em }` 命中 5 本／4,742 章／288,968 個 `<p>`；另有 `1em`、class-specific `2em`；Kusamakura 再增加 1 本／13 章／344 nodes 的 `1em` | **無**；scanner 目前沒有拒絕，屬 silent geometry gap | Inherited length/percentage；只縮排 block 的 first formatted line，接入 line construction | **高**：會改變至少 4,755 章的大量換行、char offset 到 page mapping 與 baseline artifact | 幾何 fidelity 最高，但不是目前 fallback 解鎖量；必須另立 scanner-contract／大規模 pagination baseline phase |
| **3. Table** | **4** | **43** | Semantic table 4 本／25 章：classless `<tr>` pattern 341 hits、classless `<table>` pattern 16 hits，另有 asset/scbg class variants；1 本另用 chat bubble `display:inline-table`，incoming 19 章／209 nodes、outgoing 6 章／19 nodes | DOM 為 `table`：4／25；CSS table display 落入 `unknown-block-display` | Table formatting context、column width、row/cell measurement、cell spanning、fragmentation；`inline-table` 應分開 | **高**：新 formatting context 與跨頁 row policy | 可處理資料表與 chat UI，但 patterns 並非同一個可小交付 subset |
| **4. Unsupported Float subset** | **2** | **25** | 全部是 non-replaced `float` + `width:auto`：chat bubbles 228、其他訊息／資訊 boxes 82；無 nested-float 命中 | `float`：2／25 | 在 Phase 4B 既有 float FC 上加入 shrink-to-fit used width | **中高**：影響 float exclusion、相鄰文字寬度與 clear position | 小而具延續性；覆蓋 310 個 boxes，但 book breadth 低於 Ruby |
| **5. Flex** | **2** | **18** | `h3` center layout 10 章／42 nodes；ability／skill／resource UI 1–3 章，主要是 `display:flex` + `align-items` + `justify-content`，共 507 applied declarations | `flex-grid` 2／18，且 display 也落入 `unknown-block-display` | 至少 single-line row/column、main/cross sizing、alignment、flex item min-size | **高**：新增 formatting context，且與 absolute/calc patterns 重疊 | 18 章；多為特殊 UI block，不是一般 prose 基礎 |
| **6. Vertical writing** | **2** | **108** | 真實豎排書 93 章有 OPF vertical、其中 92 章 body 同時命中三種 `vertical-rl` declaration；Kusamakura 15 章由 OPF + active `html {-epub-writing-mode:vertical-rl}` 命中 | Publication gate 直接留在 legacy；CSS scanner `vertical-writing-mode` 為 2／107 | Logical axes、vertical CoreText runs、block/inline layout、fragmentation、paint、selection/link geometry 全鏈路 | **極高** | 108 章，但應在 horizontal ruby model 穩定後獨立進行 |
| **7. `@media`** | **1** | **16** | 只有 `(prefers-color-scheme:dark)`；733 個 matched elements，全部是 paint-only 或非 layout declarations | `media-queries` 1／16，scanner 目前看到任意 `@media` 就拒絕 | **Frontend/scanner 精度問題**：解析 conditional rules、判斷目前環境與 layout relevance | **低至中**；本 corpus 不應改 geometry | 最多移除 16 章的 false-positive fallback；沒有證據支持先做 media layout engine |
| **8. `position:absolute/fixed/sticky`** | **1** | **9** | 實際只有 `absolute`，149 nodes；集中於 ability／skill panel；`fixed=0`、`sticky=0` | `positioned` 1／9 | Containing block、out-of-flow layout、inset、stacking、fragment ownership | **高** | 9 章，且與 flex/calc 同書重疊；單做 position 未必解除 fallback |
| **9. `calc/min/max/clamp`** | **1** | **1** | 只有 `.skill-status-label { width:calc(100% - 110px) }`，1 node；`min()/max()/clamp()=0` | `calc-modern-functions` 1／1 | Typed length expression與 containing-block percentage resolution | **中** | 1 章、1 node；架構有用但目前收益太低 |
| **10. MathML** | **1** | **1** | 1 個真實 `<math>` | `mathml` 1／1 | Math DOM → typesetting/metrics/paint/accessibility；不是一般 CSS box subset | **高** | 1 個 generated regression chapter |
| **11. Scripted / interactive** | **1** | **1** | 1 個 `<object>`；沒有實際 `<script>` 命中 | `scripted-interactive` 1／1 | Embedded object policy、security、fallback content；不只是 layout | **高／產品風險** | 1 個 generated regression chapter；不適合作為下一 layout phase |
| **12. Grid** | **0** | **0** | 無 selector-matched `grid/inline-grid` 或 grid declarations | 無 | 完整 grid formatting context | **極高** | 目前 corpus 為 0 |
| **13. Unsupported SVG** | **0** | **0** | 每個 `<svg>` 都先經 `svgWrappedImageSource` 判斷；沒有 complex inline SVG | 無 | Inline SVG viewport、shape/text layout 與 paint | **高** | 目前 corpus 為 0；既有 image-wrapper SVG 不屬 unsupported |
| **14. 其他 unknown display** | **0** | **0** | 排除 table/flex/grid 後，沒有其他實際套用的 unknown `display` value | 無；現有 `unknown-block-display` 3 本／45 章全由 table/flex display 造成 | 視未來 pattern 再定 | 未知 | 目前 corpus 為 0 |

Raw `other-layout` bucket 的總量是 11 本／4,972 章／309,282 hits，除了上表獨立列出的 `text-indent`，還包括：`box-sizing:border-box`（chapter title 1,181 章）、`overflow:hidden`（clear/chat containers）、`page-break-inside`／`break-inside:avoid`（forum/chat blocks）、`min-height`、list markers，以及 Kusamakura 的 `max-height/min-width`。這不是單一 capability，不應把整個 bucket 當成一個 implementation phase。

## Frontend parsing 還是 layout

| 類型 | Census 判斷 |
|---|---|
| Selector parsing / cascade | 實際 unsupported occurrences 中沒有 `frontend` layer 命中；production parser 可表示目前命中的 selector/declaration。不是下一 phase 的主因。 |
| Conditional CSS | `@media` 是 frontend/scanner precision gap；本 corpus 的 query 全為 dark-mode paint branch，沒有實際 layout declaration。 |
| Value resolution | `calc()` 已被 declaration parser 保留，但 layout length model不能求值；屬 layout/value-resolution。 |
| DOM semantic layout | Ruby、semantic table、MathML、complex SVG、embedded object。Ruby 與 table 有真實命中；unsupported SVG 為 0。 |
| Formatting context / geometry | Vertical、float shrink-to-fit、flex、position、text-indent、table。 |
| Publication routing | OPF `rendition:writing-mode=vertical-rl` 已在 publication 層阻止 BrowserLayout；不能只靠 chapter scanner 統計。 |

Scanner reason 與 feature census 的差異也是實際結果：table 的 DOM reason 只有 25 章，但 `display:inline-table` 令 table feature 總數成為 43；vertical feature 是 108 章，但 CSS scanner 是 107，剩下的 metadata-only chapter 由 publication gate 處理；`text-indent` 則完全沒有 scanner reason。

## Ruby pattern 分類與最小通用 subset

### 實際 pattern

- 5,216 組全部恰好有一個 direct `<rt>`；`<rp>`、`<rb>`、`<rtc>`、nested ruby 都未命中。
- 5,215 組是 `ruby text node + rt`；1 組是 `ruby span + rt`。因此不能把 base 限死為 plain text，但第一階段只需一般 inline base content。
- Horizontal corpus：4 本／75 章／613 組；這是 Phase 4D 可立即啟用的範圍。
- Vertical corpus：Kusamakura 1 本／13 章／4,603 組；Phase 4D 只建立可重用 model，不在 vertical mode 啟用。
- `ruby-align:center` 實際作用於 3 本／54 章／568 nodes。沒有命中的 `ruby-position` 變體。

### Phase 4D 最小通用 implementation subset

1. **只支援 horizontal writing mode**，且只處理 normal inline flow。
2. Box tree 建立一個不可在內部分行的 ruby inline unit；base 允許 text 或一般 inline descendants，annotation 使用其 `<rt>` computed style。
3. 分別 measure base 與 annotation，ruby advance 取兩者所需寬度；預設／`ruby-align:center` 置中，annotation 放在 base 上方。
4. Ruby unit 只允許在 unit 前後換行；annotation 必須納入 line ascent／height、pagination fragment、display list 與 hit/selection geometry，不能只做 paint overlay。
5. 支援 corpus 的 one-base／one-`rt` pairing；render 時不把 `<rt>` 混入正文 base text。`<rp>` 在支援模式下隱藏，即使本 corpus 未出現。
6. Scanner 只有在上述 layout、fragment、paint、interaction regression 全部通過後，才可對這個精確 subset 放行；其他 ruby grammar 繼續整章 fallback。

明確排除：vertical ruby、`ruby-position:under/inter-character`、`ruby-merge`、多 base／多 annotation pairing、`rb/rtc`、nested ruby、跨行 ruby、Bopomofo 特別排版。這些需由新 corpus pattern 或後續 Vertical Writing Phase 驅動，不能在 Phase 4D 猜測。

## 為何不是先做 `text-indent`

`text-indent` 是 census 發現的最大 silent gap，不能忽略；但它和 Ruby 的「下一個 capability」決策不同：

- 兩者最常見 pattern 都覆蓋 5 本 EPUB；`text-indent` 的 chapter 數因幾本超長連載 EPUB 被放大到 4,742 章。
- `text-indent` 目前沒有 scanner fallback，直接實作會一次改動 288,968+ 段落的換行與分頁 baseline，geometry regression 面遠高於 Ruby。
- Ruby 的真實 DOM grammar 高度一致，horizontal subset 邊界清楚，並直接解除明確的 `ruby` capability reason；它也為日後 vertical CJK inline annotation 提供必要模型。
- 因此下一 phase 只做 Ruby。`text-indent` 應另開一個帶 scanner-contract、char-offset/page baseline 與大 corpus golden comparison 的 phase，不能順手塞進 Ruby phase。

## Artifacts

- Machine-readable census：`docs/browser-layout/phase4c-layout-capability-census.json`
- Kusamakura deterministic shard：`docs/browser-layout/phase4c-census-parts/kusamakura.json`
- Census harness：`Tests/iOS/yuedu appTests/BrowserLayoutCapabilityCensusTests.swift`
- Deterministic shard merger：`scripts/merge_phase4c_census.py`
