---
title: 渲染相似度的已知差距
updated: 2026-10-07
tags: [yuedu, browser-layout, fidelity-loop]
---

# 已知差距

[首頁](README.md) · [目標](GOAL.md) · [量法](ORACLE.md)

相似度量測找到、還沒修的差距。分數都來自基線 `baseline-2026-09-30`（[報告](reports/baseline-2026-09-30.md)），記分板在[首頁](README.md)。除了 S001，每一項的「假設的根因」都還沒重現過，動手前先確認。編號是 loop 時期的切片編號，留著方便對照 git 紀錄。

## 卡住沒過的五本

### S001 — 深色模式的 `@media` 被當成版面相關，整章回退（ai-glossary 75.2）
- 依據：回退原因 media-queries 共 16 章，全部是 ai-glossary，沒有任何一章走新引擎
- 代表章節：ai-glossary:1、ai-glossary:3、ai-glossary:8
- 根因：`BrowserLayoutCapabilityScanner.cssContainsMediaQuery` 看到任何 `@media` 就拒絕。這本書的樣式表只有一個 `@media (prefers-color-scheme: dark)`，裡面只改顏色；`CSSParser` 已經把這種區塊分流成 `isDarkMedia` 規則，不影響版面
- 有一份做到一半的修正：loop 第 3 次的候選（8 個檔：只放行獨立的配色查詢，加上通用的 letter-spacing 修正——依最終字級解析 em／rem／px／pt、繼承絕對長度、行尾不多算字距），收在 `refs/archive/fidelity-S001-attempt3`。它讓 ai-glossary 75.2 → 97.7、16 章全走新引擎，其他書不變；**但走新引擎後 ai-glossary:15 的有序清單 1–6 編號不見了**（WebView 和基線都看得到）。要先讓新引擎畫出通用的有序清單 marker，再用這份候選
- 這本書還用了 `max-width: 42em`、`min-height: 100vh`、`linear-gradient`；走新引擎後要再看一次

### S002 — 行內盒的左右 margin 沒有佔位（mahabharata 78.5）
- 依據：inline-start 5.8、line-count 5.3、inline-size 4.9、line-break 4.5（每本書的分數點數）；mahabharata 16 章全走新引擎
- 代表章節：mahabharata:1118、mahabharata:447
- 假設的根因：`span.lin { margin-left: 5em }`、`span.num { margin-left: 2em; margin-right: 1em }`。WebKit 把行內盒的水平 margin 算進行內排版，詩行因此縮排並多折一行（對照組 341 行，我們 192 行）；我們沒有把它算進去。章節的結構是 `<body>` 底下直接放 `<span>…</span><br/>`。padding、border 是同一條規則，一起確認
- 完成的樣子：mahabharata ≥ 80，行數和對照組一致

### S003 — 根元素 `html` 的背景沒有鋪到整個畫面（kusamakura 65.3）
- 依據：paint:other 14.7；kusamakura 走新引擎的 13 章平均不到 70
- 代表章節：kusamakura:3、kusamakura:8
- 假設的根因：`html { background-color: #fff4e7 }`。CSS 規定根元素的背景畫在整個 canvas 上；整頁背景目前看起來只從 `body` 取
- 完成的樣子：這 13 章的 paint:other 降到 3 以下

### S004 — 根元素 `html` 自己的盒子沒有生效（margin、padding、max-height／max-width）
- 依據：line-break 5.2、inline-start 5.0、inline-size 3.1；kusamakura
- 代表章節：kusamakura:3、kusamakura:8
- 假設的根因：`html { margin: auto 1em; padding: 1em 0; max-height: 28em; font-size: 14pt }`。直排時 `max-height` 把每一行限制在 28em，上下的 auto margin 讓它置中；我們把字排滿整個高度。橫排版本的樣式表用的是 `max-width: 28em`，同一條規則
- 完成的樣子：每行字數和對照組一致；kusamakura 走新引擎的章節 ≥ 80

### S005 — 直排章節只要有圖就整章回退（redchamber-vertical 76.6、kusamakura）
- 依據：回退原因 vertical-writing-mode 共 16 章（redchamber-vertical 14 章、kusamakura 2 章），平均 71.5
- 代表章節：redchamber-vertical:51、redchamber-vertical:8、kusamakura:0
- 假設的根因：`VerticalTextSupport.accepts` 遇到 `img` 就拒絕。redchamber-vertical 的圖是一個字大小的行內標記（17×17 的 gif，一章幾十到幾百個）；kusamakura:0 是區塊圖和 `inline-block` 裡的圖
- 做法：這是新的排版能力，先寫設計（行內圖在欄裡怎麼定位和佔行長、區塊圖、哪些情況繼續回退），再分步做。先做行內圖
- 完成的樣子：redchamber-vertical 的章節走新引擎，這本書 ≥ 80

### S006 — 表格排版（georgia 58.3）
- 依據：回退原因 table 共 12 章（georgia 全書、hongwu 2 章、orv 9 章）
- 代表章節：georgia:0、hongwu:43、orv:13
- 假設的根因：新引擎沒有表格排版，`table`／`tr`／`td` 一出現就回退；舊引擎把整張表畫成一張圖
- 做法：先寫設計（支援的子集：固定與自動欄寬、`colspan`／`rowspan`、邊框模型；不支援時照舊回退），再分步做。orv 的章節同時還有 flex／grid，表格做完它們仍會回退
- 注意：舊引擎畫成圖的表格，量法看不到裡面的字（見下面「雜訊」），所以這些章節現在的分數偏低。走新引擎之後才量得到真正的差距
- 完成的樣子：georgia 走新引擎而且 ≥ 80

## 已過關的書裡看得見的缺陷

### S007 — 帶 `:link` 的選擇器整條被丟掉
- 依據：font-size 5.1 與邊框位移；hail-mary:40（85.7，全書其他章節接近 100）
- 假設的根因：`.pcalibre4:link { font-size: 1.2em }`。`CSSParser.parseComponent` 遇到 `:first-child`、`:first-of-type` 以外的偽類就放棄整條規則，所以連結拿到的是另一條規則的 1.125em。未造訪的連結（`a[href]`）符合 `:link`；`:visited`、`:hover`、`:active`、`:focus` 在靜態排版裡不成立
- 完成的樣子：hail-mary:40 的 font-size 扣分歸零

### S008 — HTML 的 `dir` 屬性沒有決定區塊的方向
- 依據：image-position、inline-start、indent 與畫面分；israelsailing:1（44.8）
- 假設的根因：`<div dir="rtl">`。行應該從右邊開始、行內圖靠右；我們當成由左至右。這本書其他章節同樣寫了 `dir="rtl"`，但段落另外有 `text-align: right`，所以分數是 94–100；這一頁只靠 `dir`
- 完成的樣子：israelsailing:1 ≥ 85

### S009 — float 容器裡的圖片，百分比寬度算成一半
- 依據：image-size 與 paint:image 33.7；quanzhi:418（79.4）
- 假設的根因：`<div class="ctleft">`（float，寬度是 body 的一半）裡的 `<img width="85%">`。WebKit 的圖寬 152.4（容器 179.3 的 85%）；我們是 76.2，剛好一半，像是容器的百分比被多套了一次
- 完成的樣子：兩張圖的寬度和對照組相差 2pt 以內

### S010 — 首字放大這類非圖片的 float 需要 shrink-to-fit 寬度
- 依據：回退原因 float 共 26 章（the-deal 13、harry-potter 12、orv 1），平均 85.4
- 代表章節：the-deal:12、harry-potter:100
- 假設的根因：`float: left; font-size: 3em; line-height: 100%` 的 `<span>`，寬度是 auto。`validateFloats` 對非 replaced、`width: auto` 的 float 一律拒絕，因為還沒有 shrink-to-fit（CSS 2.1 §10.3.5）。只含行內文字的 float，寬度就是它的 max-content 寬度
- 完成的樣子：這 26 章走新引擎，而且 the-deal、harry-potter 的分數不下降

還沒細查的：flex／grid 與 `position`（orv 10 章、game-designer:10）；UA 預設的標題字級沒有跟著根字級（sherlock:21，34 對 32）；整頁背景圖的大小與位置（guimi:64、redchamber:305）；行內小圖相對容器左移沒有生效（game-designer:58）；版面相關的 `@media`（寬度查詢）求值。

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
