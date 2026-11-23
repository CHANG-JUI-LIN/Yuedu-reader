---
title: 渲染相似度的已知差距
updated: 2026-11-21
tags: [yuedu, browser-layout, fidelity-loop]
---

# 已知差距

[首頁](README.md) · [目標](GOAL.md) · [量法](ORACLE.md)

相似度量測找到、還沒修的差距。分數都來自基線 `baseline-2026-09-30`（[報告](reports/baseline-2026-09-30.md)），記分板在[首頁](README.md)。除了 S001，每一項的「假設的根因」都還沒在程式碼裡確認過，動手前先確認；症狀從 2026-10-25 起都已經用測試書重現（見下一段）。編號是 loop 時期的切片編號，留著方便對照 git 紀錄。

**每一項都有一本只重現它的測試書**（`scripts/fidelity/fixtures/gaps/`，2026-10-25）：修的時候先量測試書，分數升到接近 100、回退原因消失，再回頭量真書，不用再去找書。`bash scripts/fidelity/measure.sh --corpus corpus-gaps.json --books <id>`（要和第一次的結果比，照 [README](README.md) 用同一台模擬器）；怎麼加新的測試書見 [ORACLE.md](ORACLE.md)「測試書語料」。第一次量（run `gaps-2026-10-25`：iPhone 18 Pro Max／iOS 27.0、main `f05898d4` 加未提交改動、YueduCoreText 0.10.0）11 本都重現了對應的差距，分數寫在每一項底下；4 本過 80 不代表沒問題，它們的差距在畫面分或少數字上。

## 卡住沒過的五本

### S001 — 深色模式的 `@media` 被當成版面相關，整章回退（ai-glossary 75.2）
- 測試書：[`s001a-dark-media-query`](../../../scripts/fidelity/fixtures/gaps/S001a-dark-media-query/)（`gaps-2026-10-25`：84.7，回退 media-queries）
- 測試書：[`s001b-ordered-list-markers`](../../../scripts/fidelity/fixtures/gaps/S001b-ordered-list-markers/)（`gaps-2026-10-25`：88.4，走新引擎但 1–6 編號全部沒畫，畫面分 66.1；另外扣的 font-size 是 `<h2>`，屬於 S011）
- 依據：回退原因 media-queries 共 16 章，全部是 ai-glossary，沒有任何一章走新引擎
- 代表章節：ai-glossary:1、ai-glossary:3、ai-glossary:8
- 根因：`BrowserLayoutCapabilityScanner.cssContainsMediaQuery` 看到任何 `@media` 就拒絕。這本書的樣式表只有一個 `@media (prefers-color-scheme: dark)`，裡面只改顏色；`CSSParser` 已經把這種區塊分流成 `isDarkMedia` 規則，不影響版面
- 有一份做到一半的修正：loop 第 3 次的候選（8 個檔：只放行獨立的配色查詢，加上通用的 letter-spacing 修正——依最終字級解析 em／rem／px／pt、繼承絕對長度、行尾不多算字距），收在 `refs/archive/fidelity-S001-attempt3`。它讓 ai-glossary 75.2 → 97.7、16 章全走新引擎，其他書不變；**但走新引擎後 ai-glossary:15 的有序清單 1–6 編號不見了**（WebView 和基線都看得到）。要先讓新引擎畫出通用的有序清單 marker，再用這份候選
- 這本書還用了 `max-width: 42em`、`min-height: 100vh`、`linear-gradient`；走新引擎後要再看一次

### S002 — 行內盒的左右 margin 沒有佔位（mahabharata 78.5）
- 測試書：[`s002-inline-margin`](../../../scripts/fidelity/fixtures/gaps/S002-inline-margin/)（`gaps-2026-10-25`：61.7，左右 margin 完全沒佔位；line-break、indent、inline-size、line-count 都扣分）
- 依據：inline-start 5.8、line-count 5.3、inline-size 4.9、line-break 4.5（每本書的分數點數）；mahabharata 16 章全走新引擎
- 代表章節：mahabharata:1118、mahabharata:447
- 假設的根因：`span.lin { margin-left: 5em }`、`span.num { margin-left: 2em; margin-right: 1em }`。WebKit 把行內盒的水平 margin 算進行內排版，詩行因此縮排並多折一行（對照組 341 行，我們 192 行）；我們沒有把它算進去。章節的結構是 `<body>` 底下直接放 `<span>…</span><br/>`。padding、border 是同一條規則，一起確認
- 完成的樣子：mahabharata ≥ 80，行數和對照組一致

### S003 — 根元素 `html` 的背景沒有鋪到整個畫面（kusamakura 65.3）
- 測試書：[`s003-root-background`](../../../scripts/fidelity/fixtures/gaps/S003-root-background/)（`gaps-2026-10-25`：85.1，`html` 的背景整頁都沒畫，畫面分 71.7；另外扣的 font-size 是 `<h2>`，屬於 S011）
- 依據：paint:other 14.7；kusamakura 走新引擎的 13 章平均不到 70
- 代表章節：kusamakura:3、kusamakura:8
- 假設的根因：`html { background-color: #fff4e7 }`。CSS 規定根元素的背景畫在整個 canvas 上；整頁背景目前看起來只從 `body` 取
- 完成的樣子：這 13 章的 paint:other 降到 3 以下
- 狀態：2026-11-22 完成（套件 0.29.0）：`html` 的背景是整頁背景，`body` 的只在 `html` 沒有時才取代它。測試書 85.9 → 98.8。草枕內文在 scorer 2 下 98–99（視覺分只剩不到 0.1% 的格子在比，不再有權重）

### S004 — 根元素 `html` 自己的盒子沒有生效（margin、padding、max-height／max-width）
- 測試書：[`s004-root-box-vertical`](../../../scripts/fidelity/fixtures/gaps/S004-root-box-vertical/)（`gaps-2026-10-25`：61.0，欄長沒有被 `max-height: 28em` 限制、也沒有上下置中；line-break 13.8、inline-start 11.5）
- 依據：line-break 5.2、inline-start 5.0、inline-size 3.1；kusamakura
- 代表章節：kusamakura:3、kusamakura:8
- 假設的根因：`html { margin: auto 1em; padding: 1em 0; max-height: 28em; font-size: 14pt }`。直排時 `max-height` 把每一行限制在 28em，上下的 auto margin 讓它置中；我們把字排滿整個高度。橫排版本的樣式表用的是 `max-width: 28em`，同一條規則
- 完成的樣子：每行字數和對照組一致；kusamakura 走新引擎的章節 ≥ 80
- 狀態：2026-11-22 完成（套件 0.28.0）。測試書 61.0 → 82.6（排版 99.5）；kusamakura 走新引擎的 14 章 81–84。測試書剩下的扣分在視覺（背景），和 S003、S014 是同一類，不是盒子

### S005 — 直排章節只要有圖就整章回退（redchamber-vertical 76.6、kusamakura）
- 測試書：[`s005-vertical-images`](../../../scripts/fidelity/fixtures/gaps/S005-vertical-images/)（`gaps-2026-10-25`：66.1，行內記號（第 1 章）和區塊圖／行內區塊裡的圖（第 2 章）都讓整章回退 vertical-writing-mode）
- 依據：回退原因 vertical-writing-mode 共 16 章（redchamber-vertical 14 章、kusamakura 2 章），平均 71.5
- 代表章節：redchamber-vertical:51、redchamber-vertical:8、kusamakura:0
- 假設的根因：`VerticalTextSupport.accepts` 遇到 `img` 就拒絕。redchamber-vertical 的圖是一個字大小的行內標記（17×17 的 gif，一章幾十到幾百個）；kusamakura:0 是區塊圖和 `inline-block` 裡的圖
- 做法：這是新的排版能力，先寫設計（行內圖在欄裡怎麼定位和佔行長、區塊圖、哪些情況繼續回退），再分步做。先做行內圖
- 完成的樣子：redchamber-vertical 的章節走新引擎，這本書 ≥ 80

### S006 — 表格排版（georgia 58.3）
- 測試書：[`s006-table`](../../../scripts/fidelity/fixtures/gaps/S006-table/)（`gaps-2026-10-25`：37.0，回退 table；舊引擎畫成圖，missing-text 76.5）
- 依據：回退原因 table 共 12 章（georgia 全書、hongwu 2 章、orv 9 章）
- 代表章節：georgia:0、hongwu:43、orv:13
- 假設的根因：新引擎沒有表格排版，`table`／`tr`／`td` 一出現就回退；舊引擎把整張表畫成一張圖
- 做法：先寫設計（支援的子集：固定與自動欄寬、`colspan`／`rowspan`、邊框模型；不支援時照舊回退），再分步做。orv 的章節同時還有 flex／grid，表格做完它們仍會回退
- 注意：舊引擎畫成圖的表格，量法看不到裡面的字（見下面「雜訊」），所以這些章節現在的分數偏低。走新引擎之後才量得到真正的差距
- 完成的樣子：georgia 走新引擎而且 ≥ 80

## 已過關的書裡看得見的缺陷

### S007 — 帶 `:link` 的選擇器整條被丟掉
- 測試書：[`s007-link-pseudo-class`](../../../scripts/fidelity/fixtures/gaps/S007-link-pseudo-class/)（`gaps-2026-10-25`：88.9，根因確認：連結字級 WebKit 20.4、我們 19.13，註腳裡 17.34 對 16.26，正好是 1.2em 對 1.125em；所在的行跟著移，line-break 9.7）
- 依據：font-size 5.1 與邊框位移；hail-mary:40（85.7，全書其他章節接近 100）
- 假設的根因：`.pcalibre4:link { font-size: 1.2em }`。`CSSParser.parseComponent` 遇到 `:first-child`、`:first-of-type` 以外的偽類就放棄整條規則，所以連結拿到的是另一條規則的 1.125em。未造訪的連結（`a[href]`）符合 `:link`；`:visited`、`:hover`、`:active`、`:focus` 在靜態排版裡不成立
- 完成的樣子：hail-mary:40 的 font-size 扣分歸零

### S008 — HTML 的 `dir` 屬性沒有決定區塊的方向
- 測試書：[`s008-dir-attribute`](../../../scripts/fidelity/fixtures/gaps/S008-dir-attribute/)（`gaps-2026-10-25`：67.1，整塊照由左至右排：行從左邊開始、短行和行內圖靠左，畫面分 27.8）
- 依據：image-position、inline-start、indent 與畫面分；israelsailing:1（44.8）
- 假設的根因：`<div dir="rtl">`。行應該從右邊開始、行內圖靠右；我們當成由左至右。這本書其他章節同樣寫了 `dir="rtl"`，但段落另外有 `text-align: right`，所以分數是 94–100；這一頁只靠 `dir`
- 完成的樣子：israelsailing:1 ≥ 85

### S009 — float 容器裡的圖片，百分比寬度算成一半
- 測試書：[`s009-float-percentage-image`](../../../scripts/fidelity/fixtures/gaps/S009-float-percentage-image/)（`gaps-2026-10-25`：65.5，根因的前半確認：圖寬 74.4pt，WebKit 148.8pt，剛好一半。另外看到：圖說 `<p class="caption">` 被排到圖的右邊，WebKit 在圖下方，還沒查）
- 依據：image-size 與 paint:image 33.7；quanzhi:418（79.4）
- 假設的根因：`<div class="ctleft">`（float，寬度是 body 的一半）裡的 `<img width="85%">`。WebKit 的圖寬 152.4（容器 179.3 的 85%）；我們是 76.2，剛好一半，像是容器的百分比被多套了一次
- 完成的樣子：兩張圖的寬度和對照組相差 2pt 以內
- **2026-10-31：YueduCoreText PR #3–#15 一起合併後修好。** 測試書 65.5 → 99.7（run `prcheck2-after-gaps`，整合分支；套件 0.10.1 加這些 PR）

### S010 — 首字放大這類非圖片的 float 需要 shrink-to-fit 寬度
- 測試書：[`s010-drop-cap-float`](../../../scripts/fidelity/fixtures/gaps/S010-drop-cap-float/)（`gaps-2026-10-25`：75.6，回退 float）
- 依據：回退原因 float 共 26 章（the-deal 13、harry-potter 12、orv 1），平均 85.4
- 代表章節：the-deal:12、harry-potter:100
- 假設的根因：`float: left; font-size: 3em; line-height: 100%` 的 `<span>`，寬度是 auto。`validateFloats` 對非 replaced、`width: auto` 的 float 一律拒絕，因為還沒有 shrink-to-fit（CSS 2.1 §10.3.5）。只含行內文字的 float，寬度就是它的 max-content 寬度
- 完成的樣子：這 26 章走新引擎，而且 the-deal、harry-potter 的分數不下降
- **2026-10-31：YueduCoreText PR #7（float 的 shrink-to-fit）修好。** 測試書改走新引擎，75.6 → 91.3；基線裡 the-deal 走新引擎的章節 3 → 16、harry-potter 4 → 16（run `prcheck2-after-base`）。the-deal 的聊天章節因此改走新引擎，接著暴露出 S012

### S011 — UA 預設的標題字級用 16 算，沒有跟著根字級
- 測試書：沒有單獨的一本；`s001b-ordered-list-markers`、`s003-root-background` 的 `<h2>` 都重現了（`gaps-2026-10-25`：這兩本各自扣的 font-size 就是它）
- 依據：`<h2>` 在 WebKit 是 25.5（1.5 × 17），我們是 24（1.5 × 16）；sherlock:21 的標題 34 對 32 是同一個比例（2em）
- 假設的根因：標題的 UA 字級（h1 2em、h2 1.5em…）是對 16 的預設字級解析，而不是對根元素的字級（閱讀設定給的 17）。如果成立，App 裡讀者調大字級時，標題不會跟著等比例變大；沒有在 App 裡確認過
- 完成的樣子：上面兩本測試書的 font-size 扣分歸零；sherlock:21 標題 34

### S012 — 行內盒裡的區塊整塊消失；聊天泡泡（inline-block）畫不出外形
- 測試書：[`s012-block-in-inline`](../../../scripts/fidelity/fixtures/gaps/S012-block-in-inline/)（`fix-before-gaps`，套件 0.10.1：48.2，470 字只對上 297；`fix-after-gaps`，整合分支 `5fb62a4`：66.9，470 字全部對上，剩下的扣分是泡泡背景沒畫，background 57.4）
- 依據：the-deal 的聊天章節（第 7、11、12、22、23、32、35、38 章，共 65 個泡泡）、orv:5（16 個）。S010 修好後這些章節改走新引擎：the-deal:12 少 456 字、the-deal:23 少 154 字
- 根因（已確認）：`BoxTreeBuilder.collectInline` 遇到行內盒裡的區塊子元素就跳過，區塊和裡面的字全部丟掉，從套件 0.3.0 就是這樣。`5fb62a4` 照 CSS 2.1 §9.2.1.1 把行內盒拆開；同一條規則也修了「容器最後一個區塊後面的行內文字，從容器頂端開始排、壓在第一個區塊上」。hongwu:11 的章標題因此對齊 WebKit（首圖 y：295.9 → 340.1，WebKit 340.0）
- 還沒做：inline-block 是不可拆的原子盒（CSS 2.1 §9.2.2），引擎還沒有這種排版，泡泡被當成行內盒拆開，所以背景、圓角、內距都沒畫。the-deal:12 因此是 74.0（版面 99.5、畫面 48.5），低於 0.10.1 走舊引擎時的 82.1（版面 87.2、畫面 76.9）；the-deal:23 是 91.6，高於舊引擎的 85.2；orv:5 是 91.6，舊引擎 74.2。the-deal 另外 6 章聊天章節不在抽樣裡，沒有量過
- 完成的樣子：測試書的 background 扣分歸零；the-deal:12 ≥ 82.1
- **2026-11-01：整合分支 `2910434` 修好（還沒發佈成套件版本）。** inline-block 照 §9.2.2 做成原子盒：自己排版、寬度 auto 時 shrink-to-fit、坐在最後一行的基線上；放得進一頁就整個換頁，比一頁高才在它自己的行之間分頁；捲動模式只在它那一行要排字時才排它。測試書 66.9 → 97.4、the-deal:12 74.0 → 99.3、the-deal:23 91.6 → 99.4（run `ib-after-gaps`、`ib-after-base`，對 `fix-after-*`）；orv:5 的泡泡同時是 float，走 float 的路，沒變。其他新引擎章節變動都在 0.3 以內
- 還沒做：`vertical-align` 只支援相對基線的位移，`middle`／`top`／`bottom` 還沒有（語料裡沒有 inline-block 用到）；shrink-to-fit 沒有 min-content 下限（CSS 會讓放不進一行、又不能斷開的內容把泡泡撐得比容器寬；我們的泡泡最寬就是行寬）；直排章節裡有非圖片的 inline-block 時整章交給舊引擎

### S014 — 整頁背景圖一律被當成 `cover`
- 測試書：[`s014-root-background-image`](../../../scripts/fidelity/fixtures/gaps/S014-root-background-image/)（還沒量；量法自己畫整頁背景時只畫一格，見下面）
- 依據：使用者回報（2026-11-21，三國演義注評版「版本說明」頁）：整頁被幾條又粗又糊的黑條蓋住
- 根因（已確認）：`#b { background-image: url(back2.png); background-repeat: repeat-y; background-position: left; background-size: contain }`，圖是 1024×57 的花邊。套件裡畫整頁背景的四個地方（分頁 `injectBodyBackground`、整批分頁、整章文件、捲動宿主用的 `BrowserPageBackground.imageRect`）都呼叫 `coverRect` 而沒帶模式，等於一律 `cover`；`background-repeat` 解析了但沒有任何地方讀。57 點高的圖被放大約 15 倍去蓋滿頁高。另外兩個同源的錯：`cover` 溢出的那一軸一律貼齊起點（寫 `center` 也不置中）；`background-size` 等屬性寫在 `background-image` 前面時整個被丟掉
- 修法：套件分支 `background-geometry`。新增 `BackgroundImageGeometry`，照 CSS Backgrounds 3 §3 算第一格的大小與位置、兩軸各自是否重複；四個地方都改走它。`background-size` 支援 `auto`／`cover`／`contain`／長度與百分比，`background-position` 支援一到四個值，`background-repeat` 支援 `repeat-x`／`repeat-y` 與兩值寫法，`background` 簡寫會重設沒寫到的屬性。捲動宿主把會重複的圖先合成一頁再貼
- 還沒做：量法（`RenderFidelityOracleTests`，鎖定）畫整頁背景時用的是 `imageRect`，只會畫第一格，所以這本測試書的第 1、2 章現在量不準；要照「改量法」的程序改。直排整章路徑的定位範圍仍是整章而不是一頁（原本就是這樣，沒動）

### S015 — 樣式表裡有 `@media` 就整章回退（S001 的通用解法）
- 測試書：[`s015-media-types-and-width`](../../../scripts/fidelity/fixtures/gaps/S015-media-types-and-width/)（還沒量）；配色查詢見 `s001a-dark-media-query`
- 依據：基線 `phaseout-baseline-ios27-2026-11-21` 回退原因 media-queries 48 章（AI 術語詞典、Yesteryear、Thinking, Fast and Slow）。三本書用到的查詢：`(prefers-color-scheme: dark)`、Kindle 的媒體類型（`amzn-kf8`、`amzn-mobi`、`amzn-et`、`not amzn-kf8`）、`screen and (max-width: 512px)`、`(hover: hover)`
- 根因（已確認）：掃描器看到 `@media` 就拒絕；解析器只留深色區塊，其他區塊整個丟掉，所以光是放行會漏掉手機寬度下該生效的規則
- **2026-11-21：YueduCoreText 0.21.0 修好。** `CSSMediaQuery` 照實際頁面求值；規則解析時保留條件、排版時才過濾（一次解析仍供各種頁面尺寸共用）。AI 術語詞典 81.7 → 97.8、Thinking, Fast and Slow 75.2 → 89.3、Yesteryear 85.6 → 91.2，48 章全部走新引擎，沒有章節下降（run `phaseout-1-1-1-2-after`）
- 還沒做：範圍語法（`width <= 512px`）、`aspect-ratio`、`or` 一律當不符合；`<link media>` 屬性仍只接受空值與 `all`；`@supports` 區塊仍整個丟掉

### S016 — 直排章節因為被覆蓋掉的橫排宣告、`em` 寬度、SVG 封面而回退
- 依據：基線回退原因 vertical-writing-mode 29 章。逐章查的結果：紅樓夢脂評 93 章有 83 章只因為行內小圖 `img { width: 1em }`；ナミヤ雑貨店の奇蹟每一章都因為範本的 `html { writing-mode: horizontal-tb }`（同一個 `<html class="vrtl">` 上被 `.vrtl` 覆蓋），封面頁另外因為 `<svg><image/></svg>`；有 4 章因為 `-webkit-text-combine-upright: all`
- 根因（已確認）：直排准入看的是「有沒有出現過」非 `vertical-rl` 的宣告，不看層疊後誰贏；寬度只收 `auto` 與 px；`svg` 一律拒絕；`-webkit-text-combine-upright` 沒被當成 `text-combine-upright` 的別名
- **2026-11-21：YueduCoreText 0.21.0 修好。** 紅樓夢脂評直排 75.4 → 78.9（16 章全走新引擎）、ナミヤ 36.6 → 57.5（量測時別名還沒修，14 章裡 8 章走新引擎）
- 還沒做：ナミヤ的封面、版權頁在 WebView 是橫排（那幾個檔沒有宣告書寫方向），App 依書的方向排成直排，26–53 分；草枕封面的 `min-width`、float 圖、非圖片的 inline-block 仍回退

### S017 — 有 `<script>` 的章節一律回退
- 依據：全書普查（2026-11-21，12,984 章）回退 679 章，其中 590 章是波西傑克森系列與迷霧之子系列：每章 `<head>` 都掛 `<script src="../Misc/main.js">`，檔案只有 3 個位元組
- 根因（已確認）：准入把 `script` 和 `iframe`、`canvas` 等放在同一條。腳本兩個引擎都不執行，舊引擎直接略過這個元素，回退沒有換到任何東西
- **2026-11-21：YueduCoreText 0.21.0 修好。** `iframe`、`object`、`embed`、`canvas`、`audio` 仍回退。這兩本書不在當時的量測語料裡，還沒量過分數

### S018 — 合併邊框的表格與另外三種表格寫法（S006 的後續）
- 測試書：[`s018-table-collapse-and-shapes`](../../../scripts/fidelity/fixtures/gaps/S018-table-collapse-and-shapes/)（還沒量）
- 依據：全書普查（2026-11-21）回退原因 table 共 64 章：`border-collapse: collapse` 36 章（洪武大帝、Thinking, Fast and Slow、哈利波特、全知讀者視角、全能遊戲設計師、Atomic Habits）、`display: inline-table` 19 章（全能遊戲設計師的聊天氣泡）、沒有表格包著的 `display: table-cell` 10 章（三國演義注評版的 `div.tupian`）、`<colgroup>` 2 章
- 根因（已確認）：表格子集只收分離邊框模型，其餘在准入就拒絕
- **2026-11-21：YueduCoreText 0.22.0 修好。** 合併邊框照 CSS 2.1 §17.6.2：每條格線選一個贏家，置中畫在格線上、每條只畫一次，儲存格各佔一半寬度。匿名表格盒（§17.2.1）、包著一般內容的 inline-table 當行內區塊、`colgroup`／`col` 略過。六本書有表格的 35 章全部改走新引擎、沒有章節下降（run `tables-after` 對 `tables-before`）：洪武大帝 48.8 → 85.6、全能遊戲設計師 60.4 → 94.3、Thinking, Fast and Slow 64.7 → 88.3、哈利波特 66.3 → 89.6、三國演義注評版 67.0 → 89.7、Atomic Habits 65.1 → 87.2。「改之前」偏低有一部分是量法看不到舊引擎畫成圖的表格（見「雜訊」）
- 一併修的既有問題：寫了 `width` 的欄位（年表的 `width: 25%`）在表格寬度不夠時被和其他欄位一起等比例壓縮，日期欄剩一個字寬；儲存格自己的百分比寬度在欄位裡又被套一次
- 還沒做：`rowspan`、巢狀表格、`<caption>` 仍回退（語料沒遇到）；`<col>` 的寬度不採用；虛線邊框跨多格時每格各自起算虛線；走新引擎後仍偏低的章節：哈利波特 251（61.8）、洪武大帝 43（67.3）、41（70.8），原因還沒查

### S019 — 只包著文字的 flex 容器
- 測試書：沒有單獨的一本
- 依據：全書普查回退原因 flex 18 章。全知讀者視角 10 章是 `h3 { display: flex; align-items: flex-start; justify-content: center }`，裡面只有標題文字；全能遊戲設計師 8 章的 flex 也只包文字，但同一批章節還用了 `position: absolute`
- **2026-11-21：YueduCoreText 0.23.0 修好文字這一種。** 容器裡只有文字時是一個 flex 項目（Flexbox §4），等於一個行內區塊照 `justify-content` 擺在行上。全知讀者視角 88.0 → 97.1，16 章全走新引擎（run `flex-after` 對 `flex-before`）
- 還沒做：容器裡有元素（多個項目）仍回退；固定高度容器的交叉軸對齊沒套用；`grid` 不排版

還沒細查的：flex／grid 與 `position`（orv 10 章、game-designer:10）；整頁背景圖的大小與位置（guimi:64、redchamber:305）；行內小圖相對容器左移沒有生效（game-designer:58）；版面相關的 `@media`（寬度查詢）求值。

## 分頁模式

量測工具只量捲動版面，這裡的問題是 2026-11-23 為 1-7 做的分頁普查看到的（全書 12,984 章 × 直拿 330×760／橫拿 760×300，字級 17；有浮動的 739 章另外加跑字級 30；套件 0.30.0；普查程式沒有進版本庫）。除了標明 0.30.0 的那一條，其餘的成因都在 0.30.0 之前就有：0.30.0 以前就排得出來的章節裡看得到同樣的問題，而 0.30.0 只改了有浮動的章節的排版。

### 橫拿時整頁空白的第一頁，以及它讓下一頁的起點查到空白頁
- 看到的事：橫拿時 157 章的第 1 頁什麼都沒有：book-d53a7692 120 章、redchamber 22 章、book-772d4bf7 11 章、book-0be89331 2 章、book-8fbb4b7b 和 orv 各 1 章。book-d53a7692 是書自己的 CSS 造成的：章名 `h1.chapter { margin-top: 50% }`，百分比照寬度算，橫拿時是 380 點，比一頁（300）還高，標題整個落到第 2 頁；直拿時 165 點，不會空白
- 引擎的問題：沒有內容的頁面，範圍記成「章末、長度 0」（`BrowserPageGeometry.sourceRange(of:)`），頁首因此不再照順序遞增。其中 155 章用第 2 頁的起點查頁會查到這張空白頁。App 是照位置翻頁的（FB-140），從空白頁往後翻可能翻不過去。新舊查頁寫法在這裡結果相同，所以不是 0.30.0 造成的
- 原因：六本書都是第一個內容前面的 margin 比一頁高（百分比 margin 照寬度算，橫拿時變大；redchamber、book-772d4bf7 是標題外框的 margin，orv 是外框的 margin 只留得下框的上緣、放不下第一行）。分頁的規則是章節開頭的 margin 要保留（CSS Fragmentation：只有非強制分頁後的 margin 才丟），所以內容整個被推到第 2 頁，第 1 頁只剩背景。book-8fbb4b7b 是書末頁：書裡缺 `penguinLogo_small.gif`，圖沒有排出來，剩下的 margin 加上標題的 margin 比一頁高
- **2026-11-23：YueduCoreText 0.30.1 修好。** 這是閱讀器自己的做法，不是規格：第一頁排完時上面沒有任何字或圖，就把第一頁重排一次，內容前面的 margin 照非強制分頁後的頁面丟掉；重排後的第一頁有東西才採用。也就是說 margin 只在內容也放得進第一頁時保留。分頁後的頁面也改成先丟 margin、再決定內容落在哪一頁（以前是先選頁，margin 比剩下的空間高時內容會先被推到下一頁）
- 普查（全書 12,984 章，字級 17，0.30.1 對 0.30.0）：橫拿那 157 章每章剛好少一頁、第 1 頁都有內容，第 2 頁起點查到空白頁 155 → 0；其他章的頁數和檢查結果完全不變。直拿完全不變，直排章節在兩種版面頁數也都沒變，所以語料裡沒有直排章遇到（直排的直拿頁面理論上一樣會發生，套件加了測試）。有浮動的 739 章字級 30：修正開關兩次的結果完全相同
- App：iPhone 17 Pro Max 模擬器（iOS 27.2）橫拿，從目錄跳到 book-d53a7692（三國演義注評版）第一回，第 1 頁就是章名頁。量測（run `s3-0301`，只量捲動版面）和 `s3-0300` 比沒有一章分數變動超過 0.05，36 本書分數相同
- 沒改的：第一頁因為 margin 以外的原因空白時（例如比一頁高、只有背景色的盒子）保持原樣；沒有內容的頁面範圍仍記成章末，語料的橫排章節裡已經沒有這種頁面（普查只在橫排章節檢查空白頁；直排章節只檢查了查頁，沒有查錯）
- 還不知道的事：WebKit 分頁時，比一頁高的 margin 是截斷還是留一張白頁（量測工具只量捲動版面）
- 狀態：已修（套件 0.30.1）

### 字排到頁面上緣之外
- 看到的事：直拿、橫拿都有：哈利波特 7 章（各卷的書名頁，y = 5，也就是上方留白裡 15 點的位置），book-772d4bf7 第 2 章（直拿 −84、橫拿 −291）
- 狀態：未查

### 只裝一張整頁高圖片的那一行，比一頁高 5–8 點
- 看到的事：橫拿時 book-c0e3d541 8 章（其中 4 章是 0.30.0 才排得出來的浮動章節，另外 4 章以前就排得出來）、哈利波特 35 章（字級 30 時 39 章，各章第 2 頁）、guimi 1 章，行框底部超出頁面下緣 2–8 點。超出的是行框，不是圖：圖縮到剛好一頁高（`BlockLayout.resolveInlineReplacedSizes` 把行內圖限制在一頁內），但圖坐在基線上，基線下面還有這一行的字體下伸部（book-c0e3d541 的浮動 `line-height: 1`，多 5 點）。多出的部分落在頁面下方 20 點的留白裡，沒有內容被切掉
- 還不知道的事：WebKit 分頁時同樣的行會怎麼處理（推到下一頁、或讓行框超出）；要不要把縮放的上限扣掉這一行的下伸部
- 狀態：未處理

### 比一頁高的浮動：圖放不進目前這頁時，浮動的外框從哪一頁開始
- 做法回顧（0.30.0）：浮動的第一塊（圖或第一行）放得進一頁、但放不進目前這頁剩下的空間時，整個浮動和旁邊的文字從下一頁開始。第一塊本身比一頁高時（圖縮到剛好一頁高、下面還有同一行的下伸部），浮動不整個推過去，由圖自己移到下一頁；旁邊的文字排在圖之後，跟著過去（`PageWalker.gatherBesideFloat` 讓浮動到第一塊為止都照浮動的上緣排序）
- 還不知道的事：後一種情況下，浮動的盒子本身還從前一頁開始。浮動有背景或邊框時，前一頁底部可能會畫出一截空的框。沒有測試書，語料裡也還沒看到
- 狀態：未查

### 圖片上壓著字
- 看到的事：直拿時全能遊戲設計師 1,181 章（幾乎整本，都在第 1 頁的同一個位置 y = 28），另有 redchamber 4 章、quanzhi、book-d53a7692、哈利波特各 1 章，有文字和圖片重疊。全能遊戲設計師可能是書本來就把標題疊在圖上（這本書用了 `position: absolute`）
- 還不知道的事：是不是刻意的設計；捲動模式是否一樣
- 狀態：未查

## 舊引擎

### 捲動模式漏畫「獨佔一塊的圖」
- 看到的事：量測用的設定（段距 0、行距 1.5）下，舊引擎把一張圖單獨切成一塊時，那一塊的 CoreText frame 是 0 行，什麼都沒畫。ai-glossary 的封面（spine 0）和 the-deal 最後一章的章末圖（spine 50）都是這樣
- 還不知道的事：一般的設定（段距不是 0）會不會遇到。沒有在 App 裡實際開書確認過
- 狀態：2026-10-01 在 Claude Code 開過一個獨立工作「Fix legacy scroll chunks that paint a lone image as nothing」，還沒做

## 雜訊

量法看不準、不該拿來當修改依據的扣分。完整的限制清單在 [ORACLE.md](ORACLE.md)「它看不到的東西」。

- **舊引擎的表格是一張圖。** 裡面的字量不到位置，算成缺字：georgia:0（missing-text 14.5）、hongwu:43（21.7 分）、orv 有表格的 9 章。實際看起來沒有分數說的那麼差。
- **舊引擎漏畫獨佔一塊的圖。** ai-glossary:0（4.0）、the-deal:50（50.3）的 image-missing 來自這裡，見上面「舊引擎」。
- **harry-potter 有 8 章指定了載不到的字型。** 對照組等了 8 秒後照替代字型量；這是 WebView 實際會顯示的樣子，不是誤差，只是列出來備查。
- **舊引擎的章節每次量會小幅漂移。** 在同一台模擬器上把整份基線重量一次（`repeat-2026-10-01`）：走新引擎的 177 章每一章分數都完全相同；走舊引擎的 72 章最多差 2.8（hongwu:43）。kusamakura:0 在更早的幾次量測裡，舊引擎排出的整塊寬度在 559–580pt 之間跳。`compare` 已經把兩次都走舊引擎的章節排除在外；看報告裡的書分數時，差 0.3 以內不要當真。
- **redchamber:305 這類整頁只有一條裝飾背景的章節。** 沒有文字可比，整章分數只看那條裝飾；一章的 81 分不代表版面有問題。
