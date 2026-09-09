# Browser 捲動入口、行內背景與正文兩端對齊

2026-09-09，主工作目錄未提交變更。本頁涵蓋使用者要求的正常 EPUB 捲動 BrowserAuto、畫冊白字缺紫底，以及正文兩端對齊。12 類、121 項相關回歸通過，0 failed／0 skipped；另重跑原書 2 項並新增頁頂幾何斷言。各類別最後通過結果及來源雜湊見 [verification.json](browser-scroll-inline/verification.json)。

## 根因與修改

- 正常 EPUB 捲動原先只發布 CoreTextChunk，並未使用已有的 BrowserScrollDocument。現在與翻頁持有同一個 BrowserLayoutPageEngine 的 Auto 決策；接受的章節透過共用 CSS／box tree／PageWalker 做連續排版，collection 只切分最多 2000pt 的繪圖區域。圖像不因繪圖區域邊界重新排版。
- BoxTreeBuilder 攤平行內元素時，丟掉背景與 padding，留下白色字。現在保留行內裝飾所屬節點與 shaping advance，PageWalker 完成行定位後先畫背景、再畫文字；翻頁與捲動共用修正。
- Browser 未接上閱讀器的正文預設兩端對齊，而且排版器只有左右／置中偏移，沒有實際伸展 justified 行。正式入口現在傳入 `.justified` 預設；作者 CSS 的明確對齊仍透過 cascade 優先。一般換行以增加字距完成對齊，段落末行與硬換行不拉滿。繪圖、選取、游標及背景均使用同一份展開後的 CTLine 幾何。
- Browser 捲動 cell 使用既有 Browser 文字互動與圖片預覽；補齊 collection 長按仲裁、DOM 段落選取範圍、標註／TTS、媒體章位置、影片及主題資產預熱。頁眉頁腳繼續由固定捲動宿主管理。

## 邊界

這次不是完整 CSS 相容性結案。Auto 的既有能力判斷仍保留；例如定位／Flex 被拒絕的章節仍選 Legacy，兩個橫排宿主共用這個決策。直排捲動維持既有 RTL 欄位宿主，直到 Browser 連續 x 軸排版可用，不把 y 軸繪圖區域套在直排。

Browser 的 CSS frontend 仍是 Current／LegacyCSSFrontend；沒有啟用 Lexbor production cutover，沒有改 golden。沒有改動另一 task 的 AutoRead 實作。

## 回歸範圍

正式 EPUB 入口與主題／尺寸重建、作者 CSS 對齊優先、CJK／英文實際右緣與選取、原書六個紫色字牌與 padding 像素、Browser 捲動 cell 互動、連續文件幾何、Legacy 捲動及頁眉頁腳。


## 原書畫面

[正式入口翻頁內容](browser-scroll-inline/reported-gallery-normal-scroll/paged.png) · [正式捲動 cell（2000pt 繪圖區域）](browser-scroll-inline/reported-gallery-normal-scroll/scroll-cell.png) · [相同設定的翻頁](browser-scroll-inline/reported-gallery-inline-paint/paged.png)／[連續視窗](browser-scroll-inline/reported-gallery-inline-paint/continuous.png)

這些是內容繪圖，不是包含固定頁眉頁腳的整個閱讀器截圖。頁眉頁腳另由 EPUBPageBarsLifecycleTests 驗證。原始 PNG 紫色字牌的像素範圍為 x=112–277、y=29–53，頁頂留白完整；正常入口的文字幾何斷言亦通過。
