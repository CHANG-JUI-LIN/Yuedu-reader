# 紅樓夢斷行基線重錄（2026-10-06，中日韓文字依語言選字）

狀態：已重錄。`redchamber.tsv` 換成直排排版計畫 Task 5 之後的結果；10/1 的檔案留在 `redchamber-2026-10-01.tsv` 備查。錄製環境同 10/1：iPhone 18 Pro、iOS 27.0、`-testLanguage zh-Hant -testRegion TW`。

## 起因

[直排排版計畫](../../superpowers/plans/2026-10-06-vertical-typography.md) Task 5 讓中日韓文字改用它語言的字型（`CJKTypography.applyFonts`）：繁中 PingFang TC、簡中 PingFang SC、日文冬青黑體、韓文 Apple SD Gothic Neo；英數用系統字體。同一批改動裡：

- 瀏覽器引擎找不到字型家族時用系統字體，不再寫死 PingFang SC；
- `ReaderFontCascade` 不再列 PingFang SC、STHeiti SC。

這個測試自己組 `BrowserLayoutConfig`，原本沒有帶 `cjkTypographyStyle`，選字處理不會執行，漢字會落到系統的備援字型——而 iOS 的系統備援依程序語言選字，不看文字。測試改成跟閱讀器一樣帶入風格（與 `BrowserLayoutPageEngine.makeBrowserConfig` 同一個解析），但每章只看自己的文字、不用整本書的記憶，這樣用 `YUEDU_LINEBREAK_STRIDE` 抽樣跑時，每一章的排法和整本跑時相同。這本書判定為簡體，漢字用 PingFang SC。

## 變了多少

458 章中 276 章和 10/1 的基線不同。表中的「行」是測試的 `lines` 欄，實際是文字片段數。

| 變化 | 章數 |
|---|---:|
| 片段數減少（合計 −1,381，單章最多 −41） | 202 |
| 片段數增加（合計 +29，單章最多 +6） | 16 |
| 片段數不變，只有中間的斷點不同 | 58 |
| 少一頁 | 28 |
| 多一頁 | 0 |

逐章的頁數與片段數前後值見 [rerecord-2026-10-06-cjk-fonts.tsv](rerecord-2026-10-06-cjk-fonts.tsv)。

## 原因

17 pt 下，同一段簡體文字的字寬（pt），以模擬器實測：

| 字型取得方式 | 漢字 | ， | 。 | 、 | ！ | “ ” |
|---|---:|---:|---:|---:|---:|---:|
| 系統字體＋舊備援清單（10/1 以前） | 17.3 | 17.3 | 21.6 | 13.1 | 13.1 | 7.4（SF） |
| 直接指定 PingFang SC（現在） | 17.0 | 17.0 | 17.0 | 17.0 | 17.0 | 9.1 |

PingFang SC 經由系統字體的備援清單取得時，CoreText 把它放大約 1.8%，標點寬度也跟字型本身不同；直接指定時用字型自己的度量：漢字一個 em，標點全形，符合 CLREQ。每個漢字窄 0.3 pt，一行二十字就省下 6 pt，常常多放一個字，所以大多數章的片段數減少。引號在中文旁邊改用 PingFang SC（9.1 pt，原本 SF 是 7.4 pt），反而讓有引號的行變長。

對照：把瀏覽器的預設字型改回 PingFang SC、其他不動，比對結果完全相同（276 章、−1,352 片段）。這本書的 CSS 指定了 iOS 上沒有的字型家族，正文本來就落在系統字體，所以差異全部來自漢字與標點如何取得字型，與預設字型無關。

## 三個樣本章

- **spine 4**（頁數 12、片段 26 都沒變）：書名頁的標題字，每個漢字寬度從 18.19 pt 變成 17.85 pt（標題字級 17.85 pt），所以字的位置和片段寬度都動了，斷行沒有變。
- **spine 15**（片段 852 → 846）：第 2 頁的一段，舊排法第二行開頭是一個 13.6 pt 的系統字體字元；新排法的第一行放得下它，第二行因此由 19 字變 20 字，之後各行的斷點跟著往後移。
- **spine 17**（片段 594 → 593）：一段對話，引號由 SF（6.0 pt）改為 PingFang SC（約 8.6–9.1 pt），這段第一行少放兩個字，之後各行的斷點往前移。

## 驗證

- 重錄後在同一環境再比對一次：全部 458 章相同。
- 對照組（預設字型改回 PingFang SC）的暫時改動已還原，沒有留在產品程式裡。

## 怎麼跑

和 [10/1 的說明](rerecord-2026-10-01.md#怎麼跑)相同：

```bash
bash scripts/xctest.sh -t 1500 -- -only-testing:'yuedu appTests/BrowserLayoutLineBreakBaselineTests' -testLanguage zh-Hant -testRegion TW
```
