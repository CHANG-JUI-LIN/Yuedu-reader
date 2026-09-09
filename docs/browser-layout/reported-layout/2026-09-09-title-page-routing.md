# 第一回扉頁：引擎路由與 CSS 實際呈現

## 原因與已啟用的入口

修正前，主工作目錄的正常 EPUB 入口在 `EPUBPageRenderer.load` 直接建立並指定
`CoreTextPageEngine`。只有 DEBUG 模擬器的 `-reader-interaction-browser-auto`
測試參數會注入 BrowserAuto。`BrowserLayoutFeature.mode` 亦為 `legacy`。
因此回報時正常閱讀出現 Legacy，不能解釋成 Auto 已評估這頁而拒絕 Browser。

依使用者明確要求，已將正常 EPUB 入口改為 BrowserAuto，移除僅 DEBUG 模擬器
參數可啟用的限制。`BrowserLayoutFeature.mode` 改為 `browserAuto`，
`browserEnabled` 改為 true。原書回歸直接透過正式 EPUBPageRenderer.load 開書。

原書為《红楼梦+大观红楼》人民文学出版.epub，依閱讀順序尋找第一回標題，
定位至 spine 14。實際 BrowserAuto 引擎載入這章後選擇 `browser`，且產生一頁。

## 原始 CSS 與核對條件

原書 `.k1` 指定 `width: 15em; margin: 25% auto 0 auto; padding: .4em`，
半透明白底與 12px 圓角；`.k2` 指定 `padding: 2.2em 0`、1px 點線邊框。
背景為 body 的固定、置中、cover 圖片。

以 390 × 844、字級 17、四側 contentInsets 12 執行：Browser 的 k1 內容寬為
255pt，上方 margin 約 89.67pt，左右 margin 各約 45.04pt。
這是受控設定的引擎輸出，沒有模擬使用者個人頁眉頁腳或字級。

## 驗證邊界

上一輪翻頁／捲動相同 CTFrame 的像素一致，只證明 Legacy 的繪製合成一致，
不能證明原書 CSS 呈現正確，更不能證明 Browser 已接入正常閱讀流程。
此處應以原始 CSS 的尺寸與 Browser 實際畫面核對，不能把 Legacy 當成標準答案。

BrowserLayoutPageEngine 已實作 PageBarsProviding；Browser 的 view 與 snapshot
共用 ReaderPageBars 繪製。設定更新同步到已存在的頁面，回退章節的 delegate
頁碼映射至 BrowserAuto 的頁碼後才取頁眉頁腳。章節頁數改變時同步刷新映射與
快照；VoiceOver 透過與 CoreText 相同的自訂內容介面讀取頁眉頁腳。

正常捲動仍建立 CoreTextScrollEngine，這輪啟用不代表捲動已改用 Browser。
BrowserAuto 的既有逐章能力檢查與失敗回退保留；未切換 Lexbor CSS frontend。

## 實際畫面

下圖是正式入口選到 Browser 後的第一回扉頁，並非 WebView 或人工重畫。

![BrowserAuto 原書扉頁](title-page-routing/browser-auto.png)

[引擎選擇與尺寸紀錄](title-page-routing/routing.json)。

## 啟用後回歸結果

最新主工作目錄依序執行，25 個測試通過，0 失敗、0 跳過：

- EPUBPageBarsLifecycleTests：4，涵蓋首次回退、預先綁定、頁面／快照一致、VoiceOver、替換與純圖片頁。
- BrowserLayoutPageEngineTests：17，涵蓋混合章節、回退映射、閱讀位置、選取、主題與重排。
- BrowserLayoutReportedTitlePageTests：1，正式入口開啟原書第一回，實際選 Browser 並核對 15em 寬度。
- EPUBAutoRoutingTests：2，重新開書與捲動返回翻頁不撤換 Auto 引擎。
- BrowserLayoutFeatureTests：1，正常預設為 BrowserAuto。

[測試結果、xcresult 路徑與來源 SHA-256](title-page-routing/verification.json)。
