# Phase 5A — Lexbor CSS Frontend Production Migration Design

日期：2026-09-04

## 結論

BrowserLayout 將以固定的 Lexbor `v3.0.0`
（commit `2ae88a1c6b5261830eff73ee12bb3cdf805f3cfe`）
作為新的 HTML／DOM／CSS syntax／selectors／style frontend，經 Yuedu
adapter 轉成既有 `ComputedStyleNode`。`BoxTreeBuilder` 以下的 layout、
fragmentation、display list 與 paint 完全不改。

Integration 採官方 `single.pl` 生成的 deterministic amalgamation，僅選取
`html css selectors style` 與 generator 自動解析出的必要依賴。Generated
`.c/.h`、Apache-2.0 LICENSE、版本／commit、生成參數、輸出 hashes 與手動
regeneration script 全部 commit。Swift Package build 只編譯 committed
source，永不下載、永不重新生成，也不依賴 Homebrew 或 Lexbor Layout。

Production 起初仍使用 Current frontend。只有 synthetic、完整 corpus
style/layout differential、scanner、lifetime、效能、Debug/Release/archive
所有 gate 都通過後，才把 BrowserLayout production default 切成 Lexbor；
Current/Legacy frontend 與 DEBUG switch 暫時保留作 rollback。

## 固定基準與範圍

唯一 BrowserLayout production geometry baseline 是 commit `b674e672`
（`browser-layout: close horizontal correctness baseline`）：

- 23 EPUB／7,350 chapters；
- BrowserAuto supported 7,140，Legacy fallback 210；
- layout failures、invariant violations、nondeterminism 均為 0；
- focused regression 300 passed／0 failed；
- line-break baseline 全綠。

Phase 5A 可以修改 resource/frontend/scanner/admission 與 tests，但不得修改：

- `BoxTreeBuilder` 的 box semantics；
- `BlockLayout`／`InlineLayout`；
- `PageFragmentation`／`PageWalker`；
- `DisplayList`／paint；
- 既有 CSS used-value/layout algorithms；
- Table、Vertical Writing、Flex/Grid 或任何新 layout capability。

任何 geometry difference 必須由可觀察的 DOM／cascade／ComputedStyle
difference 解釋；不能更新 layout golden 接受不明差異。

## Vendoring 與 Swift Package

### Upstream identity

Vendoring 固定為：

- repository：`https://github.com/lexbor/lexbor.git`；
- release/tag：`v3.0.0`；
- commit：`2ae88a1c6b5261830eff73ee12bb3cdf805f3cfe`；
- license：Apache License 2.0；
- requested modules：`html css selectors style`；
- port：`posix`；
- generator：該 commit 自帶的 `single.pl`。

`Packages/CLexbor/` 是唯一 build input：

```text
Packages/CLexbor/
├── Package.swift
├── LICENSE
├── NOTICE.md
├── VENDOR-MANIFEST.json
├── Sources/CLexbor/
│   ├── include/CLexbor.h
│   ├── CLexborBridgeImplementation.inc
│   ├── lexbor-amalgamated.generated.c
│   └── lexbor-amalgamated.generated.h
└── Tests/CLexborTests/
```

`CLexbor.h` 只公開 Yuedu 需要的 opaque C bridge，Swift 不直接 import 巨大的
Lexbor public API。Generated `.c` 是唯一被 C target 編譯的 translation unit；
它 include generated `.h` 與 committed bridge implementation。這避免同一
amalgamated implementation 被多個 `.c` include 而出現 duplicate symbols。

### Deterministic generation

`scripts/vendor_lexbor.sh <verified-upstream-checkout>` 是人工執行的維護工具，
不是 Xcode build phase 或 SwiftPM plugin。它：

1. 驗證 checkout 的 tag、exact commit、`version` 與 LICENSE hash；
2. 以固定 `LC_ALL=C`、`TZ=UTC` 和參數
   `perl single.pl --port=posix html css selectors style` 生成官方 combined
   output；
3. deterministic 地產生 private amalgamated `.h` 與唯一 `.c` translation
   unit；
4. 只正規化 upstream generator header 中由執行時間產生的 `Date:` 與動態
   copyright end-year，改為 manifest 固定的 release metadata；
5. 不重排、不格式化、不修改 Lexbor declarations／resources／source code；
6. 寫入 requested modules、resolved dependency modules、generator arguments、
   source commit 與 SHA-256 output hashes；
7. 立即再生成一次並 byte-compare，任何差異都失敗。

日常 build 不執行此 script，也沒有 network path。Package 不使用 binary
artifact、Homebrew、CocoaPods 或遠端 Swift package。

## C boundary 與 lifetime ownership

`CLexbor.h` 公開 opaque `YLXLexborDocumentRef`，以及 create/parse/destroy、
DOM traversal、attribute/text access、stylesheet/style application、diagnostic
enumeration所需的窄 API。Lexbor 的 C struct、enum 與 raw node pointer 不出現在
任何 public Swift model。

Swift frontend 內部由 `LexborDocumentOwner` 單獨持有 opaque document ref：

```text
LexborCSSFrontend.buildStyleTree
└── LexborDocumentOwner
    ├── HTML document / DOM
    ├── CSS parser and selector engine
    ├── stylesheet/style allocations
    └── node handles valid only inside withDocument closure
```

所有 bridge traversal 都在 non-escaping `withDocument` closure 內完成。離開
`buildStyleTree` 前，每個 element、text node、attribute、matched source 與
computed value 都轉成 Swift value types；`CSSFrontendResult` 不保留 C handle。
`deinit` 唯一且同步地 destroy document/parser/style allocations。Cancellation
只能在 value-snapshot boundary 檢查，不允許一邊 destroy 一邊由 callback
存取 document。

Bridge 每個 fallible API 回傳 typed status 與 diagnostic；parse/memory failure
不會被當成空 body 或無 CSS。沒有 retry、alternate parser 或 delay fallback。

## Frontend-neutral input 與 stylesheet ingestion

EPUB ZIP/resource I/O 繼續只由 `PublicationSession`、
`ReadiumBookResourceAdapter` 與 `EPUBStyleResolver` 負責。Lexbor 不開 ZIP、
不直接讀 publication URL，也不建立第二份 CSS/font/image cache。

為了保留真正的 source order，frontend input 從匿名 `[String]` 提升為 typed
`CSSFrontendInput`：

```swift
struct CSSFrontendInput {
    let html: String
    let stylesheets: [AuthorStylesheet]
}

struct AuthorStylesheet {
    enum Source { case inline(nodeOrdinal: Int); case linked(href: String) }
    let source: Source
    let text: String
    let sourceOrder: Int
    let media: String?
    let isAlternate: Bool
}
```

Production resource adapter 仍沿用現有 `EPUBStyleResolver`：local `@import`
在原位置 inlining、`@font-face` 交由既有註冊流程、relative `url()` 改寫成
publication absolute URL。它按 `<head>` child order 產生 inline `<style>` 與
linked stylesheet entries；frontend 不再自行把全部 inline styles append 到
external stylesheets 之後。

Contract 如下：

- linked stylesheet：載入並保留 DOM source order；
- inline `<style>`：由同一 DOM order entry 送入 cascade；
- `style=""`：由 Lexbor style API 以 inline author origin 處理；
- local `@import`：由既有 resolver 展開，保留 import position；
- remote `@import`：明確 diagnostic + scanner fallback，不 silent drop；
- `media`：只有已明確支援且當前環境可判定的 `all`／空值可套用；其他
  media 產生 capability rejection；
- alternate stylesheet：未被選用時不套用，狀態記入 ingestion diagnostic；
- fetch/decode failure：產生 resource diagnostic，該章不可被當成 semantic
  parity success。

Current 與 Lexbor differential 必須吃同一份 `CSSFrontendInput`，避免把 resource
loader difference 誤算成 parser difference。既有方便 unit test 的
`html + cssTexts` initializer 可在 test boundary 轉成 source-order 明確的
synthetic input。

## DOM 與 HTML semantics

`LexborHTMLSemanticAdapter` 將 Lexbor DOM element 同步映射到既有
`HTMLSemanticElement(tagName:attributes:)`，使
`HTMLPresentationalHintExtractor` 維持唯一 implementation。不得複製
`width`／`height` attribute parser。

Style tree snapshot 保留：

- deterministic preorder `nodeID`；
- element tag、namespace、attributes 與 child order；
- raw text node Unicode；
- element id anchors；
- `<a href>` ownership；
- EPUB footnote semantic attributes；
- image/SVG source attributes；
- style-source identity for differential diagnostics。

Lexbor HTML recovery 若與 SwiftSoup DOM 不同，先分類成 standards correction、
Current-correct 或 integration bug，不能靠 node index 直接比較。Corpus node
matching 使用 stable semantic path（namespace/tag + sibling ordinal + id when
present），並另記 raw preorder identity。

Phase 4F0 precedence 必須維持：

```text
UA/default
→ HTML presentational hints
→ author stylesheet
→ inline style
→ !important
```

Mandatory proofs：

- `<img width="15%">` 保留 `.percent(0.15)`；
- `.hero { width:40% }` 覆蓋 attribute hint；
- inline `style="width:30%"` 覆蓋 attribute hint；
- 正確的 author `!important` precedence；
- invalid attribute 不產生 hint、不 crash、不變 0。

## Lexbor cascade 與 Yuedu adapter

`LexborCSSFrontend` 負責 parse HTML/CSS、stylesheet application、selector
matching、specificity、cascade 與 inheritance traversal；
`LexborComputedStyleAdapter` 是 Lexbor → Yuedu 的唯一映射點。

Adapter 不把 C pointer 寫入 `ComputedStyle`，也不以第二份自由格式 CSS parser
重新解析整個 stylesheet。Lexbor bridge 將 winning declaration 暴露成 typed
property/value snapshot；adapter 將其映射到現有 Yuedu types：

- keywords → `CSSDisplay`、`CSSFloat`、`CSSClear`、`WhiteSpaceMode`、Ruby enums；
- length/percentage/auto → `CSSLength`／`CSSTextIndent`，保留 used-value 所需
  symbolic semantics；
- number/integer → line-height multiplier、font weight；
- color → RGBA/`UIColor`；
- font family list → `[String]`；
- background components → `BackgroundImageStyle`；
- borders → typed width/style/color/radius；
- unsupported/custom → diagnostic，不默認成初始值後假裝 identical。

Coverage 必須包含 `ComputedStyle.swift` 目前所有 fields：display、visibility、
font family/size/style/weight、line-height、color、white-space、width/height、
min/max sizes、margin/padding、border/radius、background、text-align、text-indent、
float/clear、Ruby 與既有 reader config defaults。

若規格要求的 property 在目前 `ComputedStyle` 沒有可承載的欄位（例如某個
尚未實作的 min/max constraint 或 display category），Lexbor frontend 將它
保存在 value-typed `FrontendCapabilityFacts` sidecar，連同 winning value 與
source identity 交給 scanner。Scanner 必須 whole-chapter fallback；不得丟掉
該 value 後用 initial `ComputedStyle` 假裝兩個 frontend identical。只有目前
BrowserLayout 已有語意的欄位才寫入 layout-facing `ComputedStyle`。

Lexbor 能 parse 但 Yuedu model 無 representation 的值分類為 `ADAPTER_GAP`。
Lexbor 能 parse 且 adapter 能表示、但 BrowserLayout 不會 layout 的 property
仍由 capability scanner拒絕；frontend coverage 不等於 layout support。

## Current frontend、selection 與 rollback

`LegacyCSSFrontend`、`CSSParser`、`CSSSelector` 不刪除。新增：

- `CurrentCSSFrontend`：對現有 implementation 的明確命名 facade；
- `LexborCSSFrontend`；
- `BrowserLayoutCSSFrontendMode.current/lexbor`；
- `BrowserLayoutCSSFrontendFactory`。

Cutover 前 production factory 固定 `.current`。DEBUG switch 只改 frontend，
不改 Legacy/Browser layout engine switch；diagnostic UI 顯示 effective frontend。
Tests 可以直接注入任一 `CSSFrontend`，不讀 global mode。

Cutover commit 只把 production factory default 改成 `.lexbor`，不刪 Current。
Rollback 是一行 factory default 變更，不改 EPUB loader或 BrowserLayout。

## Capability scanner

Scanner admission 與 frontend parsing 能力保持獨立。它使用 frontend 已解析的
DOM/style diagnostics，而不是因 Lexbor 接受一個 selector/property 就直接
放行。以下仍是 rejection：table、absolute/fixed/sticky、flex/grid、vertical
writing、unsupported float/text-indent、complex SVG、MathML、scripted content、
unsupported media/modern functions。

`CSSFrontendResult` 同時攜帶 computed tree 與 `FrontendCapabilityFacts`；
production orchestration 將同一次 frontend evaluation 先交 scanner，再把已
通過的 computed tree 交給 `BoxTreeBuilder`。Scanner 不為 admission 另跑第二套
CSS parser，layout 也不為同一章重新建立另一棵 DOM/style tree。

Differential 同時記錄 Current 與 Lexbor scanner decision/reasons。若 Lexbor
揭露 Current 曾 silent-drop 的 unsupported layout declaration，正確結果是
增加 whole-chapter Legacy fallback，分類為 standards safety correction；不是
讓 BrowserLayout forced render。

Scanner 不得有書名、class、src 或 spine 特判。

## Differential model

所有 difference 使用同一 enum：

```text
IDENTICAL
SEMANTICALLY_EQUIVALENT
LEXBOR_SPEC_CORRECTION
CURRENT_SPEC_CORRECT
LEXBOR_INTEGRATION_BUG
ADAPTER_GAP
```

### Synthetic frontend differential

Table-driven fixtures 覆蓋 tag/class/id/attribute selectors、descendant/child/
adjacent/general sibling combinators、`:not()`／`:is()`／`:nth-child()`、
specificity、source order、duplicate declarations、inline/important、invalid
selector/declaration recovery、margin/padding/border shorthands、inheritance、
font family/size/em/rem、percentage width、float/clear、text-indent、
presentational hints、comments、escaped identifiers、strings 與 `url()`。

每個非 identical case 要保存 Current result、Lexbor result、expected result、
spec citation 與 classification。`LEXBOR_INTEGRATION_BUG`、`ADAPTER_GAP` 或
unclassified 會令 suite fail。

### Full style differential

23-book／7,350-chapter harness 比較同一 stable semantic node 的：

- node identity/path；
- complete `ComputedStyle` fingerprint；
- inherited values；
- style-source identity；
- presentational hints；
- scanner decision/reasons。

輸出 book/chapter/element totals 與每一分類的完整 provenance。任何 unexplained
difference 都阻止 cutover。

### Layout differential

Current 與 Lexbor 分別產生 `ComputedStyleNode`，再餵給相同的 b674e672
BrowserLayout。對 `IDENTICAL`／`SEMANTICALLY_EQUIVALENT` chapters，以下必須
exact identical：

- supported/fallback decision；
- page count；
- logical line count；
- source/page ranges；
- fragment count；
- geometry digest。

ComputedStyle identical 但 geometry 不同一律是 integration bug。Standards
correction 造成的 geometry change 必須有 synthetic reproduction 與逐章
provenance；不得重錄既有 layout golden。

## Build、效能與 memory gates

使用同一台 Mac、同一 Xcode/SDK、同一 simulator/device settings，記錄 Lexbor
加入前後：

- app executable 與 archive size；
- C target compile time 與 total build time；
- Lexbor runtime initialization；
- XHTML parse、CSS parse、style tree、total frontend time；
- peak physical footprint；
- repeated open/close 與 sequential chapter memory。

不建立獨立 DerivedData；沿用目前 shared DerivedData。效能測量不沿用早期 PoC
數字。Memory suite 至少包含重複 document create/destroy、parse failure、
cancellation boundary、大量 chapters sequentially，並檢查 owner/deinit counters
回到 0；Address Sanitizer run 驗證無 leak/use-after-free。

Build matrix：

- Debug Apple Silicon simulator arm64；
- Debug device arm64；
- Release device arm64；
- unit tests；
- archive/link。

若當下沒有連接實機，device compile 可以用 generic iOS destination，但
production cutover 仍需真實 Debug device launch/parse acceptance；缺該證據時
結論只能是 `production cutover: NO`。

## Error handling 與 diagnostics

Frontend error 明確區分 HTML parse、CSS parse、selector/style、resource
ingestion、adapter gap 與 memory allocation。Metrics/diagnostics 可帶 stage、
stylesheet identity、semantic node path、property 與 Lexbor status，但不得帶
C pointer address作穩定 identity。

Production Current default 階段，Lexbor differential failure只阻止 cutover，
不在 runtime 自動 retry Current。Cutover 後若 Lexbor production parse failure，
BrowserAuto 依明確 frontend failure reason whole-chapter fallback Legacy renderer；
不得在同一 BrowserLayout request 內偷偷重跑 Current frontend。

## Commit strategy

Phase 5A 分開提交：

1. vendored `CLexbor` package、license/manifest/regeneration verification；
2. opaque C bridge與 lifetime tests；
3. typed stylesheet input與 Current facade parity；
4. Lexbor DOM/semantic adapter與 presentational hints；
5. Lexbor cascade/ComputedStyle adapter與 synthetic differential；
6. scanner differential與安全 rejection；
7. full corpus style/layout/performance/memory evidence；
8. production default cutover（只有 gate 全通時）。

每筆 code commit 前跑直接相關 tests。最後一筆 cutover 不包含 BrowserLayout
layout、Vertical/Table/Flex、其他 CSS property 或 unrelated UI。

## Cutover gate

Production default 只有以下全成立才可由 Current 改為 Lexbor：

1. Debug/Release/device/simulator/archive/link 全通；
2. synthetic frontend differential 全部分類且沒有 integration/adapter gap；
3. 23 EPUB／7,350 chapter style differential 全部分類；
4. semantic-equivalent chapter geometry exact identical；
5. 無 unexplained ComputedStyle/layout difference；
6. scanner 沒有放行 unsupported capability；
7. Phase 4F0 presentational hints 無 regression；
8. lifetime/memory/ASan 無 leak或 use-after-free；
9. focused BrowserLayout regression 全綠；
10. deterministic repeat 全綠；
11. `git diff --check` 通過；
12. production diff 不含 book/class/src/spine special-case。

任一條失敗即回報 `production cutover: NO` 與精確 blocker，保留 Current default，
不開始下一個 layout capability。
