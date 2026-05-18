# 閱讀

[English](README.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md)

<p align="center">
  <img src="iOS/Assets.xcassets/AppIcon.appiconset/ios_app_icon_novel_reader_1024_no_alpha.png" alt="Yuedu Reader 圖示" width="128">
</p>

<p align="center">
  <strong>一個用 SwiftUI 和 CoreText 打造的 iOS 原生 EPUB/TXT 閱讀器。</strong><br>
  不以 WebView 作為主閱讀面。CJK 優先，重視排版，面向長篇閱讀。
</p>

`閱讀` 是一款 iOS 原生閱讀 App，支援本機書庫、線上文章、RSS 訂閱、TTS 朗讀與 WebDAV 同步。它的主閱讀面由 CoreText 渲染，而不是交給 WebView，因此分頁、連續滾動、EPUB CSS、中文直排、CJK/拉丁混排、閱讀位置復原等能力都由應用自己的渲染管線處理。

> 目前重心：CJK 優先。中文閱讀、CJK/拉丁混排、長篇小說場景為主要目標。英文 EPUB/TXT 渲染也已支援，並包含 EPUB 排版能力，例如首字放大、發行者 CSS、章節版式和目錄導覽。

## 展示

> 宣傳倉庫前建議先補截圖。推薦放：
>
> - 中文直排與行內批註
> - 英文 EPUB 首字放大
> - 目錄導覽
> - 閱讀設定 / 主題

<p align="center">
  <img src="docs/screenshots/cjk-vertical.png" width="220" alt="CJK vertical writing">
  <img src="docs/screenshots/english-epub.png" width="220" alt="English EPUB typography">
  <img src="docs/screenshots/toc.png" width="220" alt="Table of contents">
</p>

## 渲染亮點

* **原生 CoreText 渲染**：左右翻頁和連續滾動都不以 WebView 作為主閱讀面。
* **CJK 直排**：支援繁簡中文直排、CJK 標點處理、CJK/拉丁混排和長篇小說閱讀。
* **複雜 CJK EPUB 處理**：已用直排中文 EPUB 結構測試，包括行內批註、彩色註解、小字批語和大量行內來源標記。
* **英文 EPUB 排版**：支援發行者 CSS、章節標題、段落縮排、`:first-letter` 首字放大、巢狀區塊邊距、分隔線、字型樣式層疊和目錄導覽。
* **穩定閱讀位置**：閱讀進度基於穩定內容座標，而不是容易隨排版變化漂移的暫時性頁碼。

## 為什麼用 CoreText？

很多 EPUB 閱讀器可以直接把排版交給 WebView。`閱讀` 刻意使用 CoreText 作為主閱讀面，是為了讓應用直接控制分頁、滾動佈局、字型排版、主題、閱讀位置和 CJK 特有行為。

這會讓渲染器更難實作，但也讓這個專案更像一個原生 iOS 閱讀引擎實驗，尤其適合 CJK 排版和長篇小說場景。

## 功能

- **原生 CoreText 閱讀器**：左右翻頁和上下滾動渲染，不用 WebView 作為主要閱讀面。
- **EPUB CSS 渲染**：支援出版者 CSS，包括 `:first-letter` 首字放大、巢狀區塊邊距累加、`<hr>` 分隔線含 `width`/`margin`/`alignment`、`text-indent`（含負值 hanging indent）、`font-size`/`font-weight`/`font-style` 層疊，以及百分比邊距/內距/寬度解析。
- **CJK 排版**：段落縮排、標點處理、行距、邊距、CJK/拉丁混排、直排支援。
- **本機書庫**：匯入 EPUB、TXT 及 Markdown 文字檔，支援解析、快取、封面、書籤、註解與閱讀進度復原。
- **大書處理**：已用長篇 TXT 及 EPUB 驗證，含數百萬字閱讀流程。
- **線上閱讀管線**：將使用者提供的網頁及規則型書源正規化為統一閱讀格式。
- **Legado 相容書源規則**：匯入並執行相容於 [Legado](https://github.com/gedoor/legado) 規則格式的使用者自訂書源。
- **RSS 閱讀器**：RSS/Atom 訂閱、規則型內容擷取、OPML 匯入，以及文章渲染。
- **TTS 朗讀**：本機 `AVSpeechSynthesizer` 播放及 HTTP 自訂 TTS 服務。
- **同步與備份**：WebDAV 備份、還原、書庫同步與進度同步。
- **閱讀器自訂**：字體、字級、行距、段落間距、邊距、背景主題、翻頁/滾動模式、直排模式。

## 專案邊界

Yuedu Reader 是一個閱讀引擎與 App 外殼，不內建、不託管、不推薦、不分發受版權保護的內容來源。

使用者有責任確保匯入的檔案、RSS 訂閱、網站、自訂規則、Cookie、帳號及生成內容符合適用法律、版權要求及網站條款。

本專案不接受內建盜版來源、DRM 破解、付費牆繞過、私密 Token 分享、Cookie 收集或反爬蟲邏輯的貢獻。

Legado 相容性僅為書源規則格式相容目標。Yuedu Reader 不捆綁第三方書源規則，與 Legado 專案無關聯。

## AI 輔助開發

本倉庫以重度 AI 輔助協作方式開發，包含程式碼生成、重構、文件與審查支援。人類審查與專案所有權仍為工作流程的一部分，但 AI 輔助程式碼在整個專案中是有意存在的。

若你強烈偏好嚴格人工編寫的程式碼，或對 AI 輔助開發感到不適，請以此預期審視本專案。感謝理解。

## 系統需求

- iOS 18.0+
- Xcode 16+
- Swift 5 語言模式

## 快速開始

```bash
git clone https://github.com/CHANG-JUI-LIN/Yuedu-reader.git
cd Yuedu-reader
open Yuedu-Reader.xcodeproj
```

選擇 `Yuedu-Reader` scheme，建置至 iOS 模擬器或實機。

```bash
./scripts/build.sh
```

等效指令：

```bash
xcodebuild \
  -project "Yuedu-Reader.xcodeproj" \
  -scheme "Yuedu-Reader" \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  build
```

## 目錄結構

```text
iOS/
├── Models/               # 資料模型、儲存、服務、渲染器、解析器
│   ├── App/              # 全域設定、設計 Token、依賴注入
│   ├── Book/             # 書籍模型、BookStore、書籤、中繼資料
│   ├── BookSource/       # 使用者書源擷取
│   ├── LocalBook/        # EPUB/TXT/Markdown 匯入
│   ├── Online/           # 線上閱讀與網頁正規化管線
│   ├── RSS/              # RSS 模型、訂閱擷取、解析器、文章工具
│   ├── Reader/CoreText/  # CoreText 分頁、滾動佈局、繪製、CSS 解析
│   ├── RuleEngine/       # CSS/XPath/Regex/JSON 規則擷取
│   ├── Sync/             # WebDAV 與同步邏輯
│   └── TTS/              # 語音播放協調
├── Views/                # SwiftUI 畫面與可重用 UI
│   ├── Reader/           # 閱讀器表面、控制項、設定、覆疊層
│   ├── Bookshelf/        # 首頁書架與書籍管理
│   ├── BookSource/       # 書源管理與診斷
│   ├── Online/           # 瀏覽器/匯入流程
│   ├── RSS/              # RSS 訂閱與文章畫面
│   └── Settings/         # App 設定、個人資料、同步、TTS、遷移
├── ViewModels/           # ObservableObject ViewModel
├── Assets/               # 資產目錄與規則引擎資源
└── *.lproj/              # 本地化：zh-Hant、zh-Hans、en

ShareExtension/           # iOS 分享擴充
Widget/                   # 主畫面小工具
Tests/                    # 單元及 UI 測試 Target
Technotes/                # 架構筆記
scripts/                  # 本機自動化腳本
xcconfig/                 # 共用 Xcode 組態
```

## 架構筆記

- **EPUB**：Readium 元件處理 EPUB 套件解析與資源存取。發行物的 CSS（含 `@import`、`@font-face` 及連結樣式表）按章節載入、處理並解析。
- **渲染管線**：兩條平行路徑產出 CoreText 屬性字串：
  - 舊路徑：`HTMLAttributedStringBuilder.build()` → 直接 `NSAttributedString`
  - RenderableNode 路徑：`HTMLStyledASTRenderableNodeConverter` → `RenderableNode` IR → `NodeAttributedStringRenderer`
  - 兩者共用 `CSSParser`、CSS 解析、`ResolvedStyle` 及 `CoreTextPageView.drawLines`。任何 CSS 屬性變更必須同時更新兩條路徑。
- **翻頁 vs 滾動**：`EPUBPageRenderer` 將內容路由至 `CoreTextPageEngine`（左右翻頁）或 `CoreTextScrollEngine`（連續滾動）。`CoreTextPageView` 及區塊 Cell 繪製最終 CoreText 畫面。
- **EPUB 目錄**：閱讀器目錄面板優先使用 `toc.ncx`/`nav.xhtml` 條目，優於 spine 章節清單。spine 中的非目錄項目（連續目錄圖片頁、分割的後記頁）會被排除。spine fallback 包含相同標題去重。
- **閱讀位置**：持久位置以 `(spineIndex, charOffset)` 為準，而非頁碼。因為章節載入或佈局變更後，頁碼會漂移。
- **線上內容**：`BookSourceFetcher`、`OnlineReadingPipeline`、`ModernRuleEngine` 及網頁擷取器將使用者內容轉換為正規化章節。
- **RSS**：訂閱 XML 解析與規則型文章擷取，和線上閱讀共用相同的清理與渲染原則。
- **TTS**：播放狀態與渲染分離協調，使閱讀器高亮及系統媒體控制項可跟隨當前文字段落。
- **依賴注入**：`AppDependencies` 及 SwiftUI 環境值提供 App 服務；共享管理器集中在需要持久化或快取所有權的位置。

更多細節：[Technotes/Architecture.md](Technotes/Architecture.md)。

## 開發規則

- 使用者可見字串使用 `localized()`，並更新三個本地化檔案：
  - `iOS/zh-Hant.lproj/Localizable.strings`
  - `iOS/zh-Hans.lproj/Localizable.strings`
  - `iOS/en.lproj/Localizable.strings`
- 閱讀位置以穩定內容座標為準，勿用暫時性頁碼。
- UI 樣式使用 App 設計 Token API：`DSColor`、`DSFont`、`DSSpacing`（位於 `Models/App/DesignTokens.swift`）。
- 新建或修改 View 時，盡可能加入可編譯的 SwiftUI Preview（`#Preview` 或 `PreviewProvider`）。
- 書源/規則引擎相關工作限於合法、使用者提供內容的流程。
- 新增 CSS 屬性至 `ResolvedStyle` 時，需同步 `RenderStyle` 對應欄位、更新轉換器（`RenderStyle.from`），並同時處理兩條渲染路徑。
- 巢狀區塊 CSS 邊距須透過 `inheritedBlockMarginLeft` 累加 — CoreText 使用單一 frame，父層邊距不會自動疊加至子層段落縮排。

請見 [CONTRIBUTING.md](CONTRIBUTING.md) 了解貢獻慣例。

## 授權

MIT。詳見 [LICENSE](LICENSE)。

本專案連結 [Readium](https://github.com/readium) 元件，採用 BSD 授權。Readium 名稱及標誌為 Readium Foundation 商標。
