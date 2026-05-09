# yuedu

[English](README.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md)

一個使用 SwiftUI 和 CoreText 建構的高度可客製化 iOS 原生閱讀器。

yuedu 專注於 CJK 中文長文本閱讀體驗，支援自訂排版、大體積書籍、EPUB/TXT 匯入、RSS、TTS 聽書、WebDAV，以及使用者自訂網頁內容轉碼。

> 狀態說明：本專案是 CJK-first 閱讀器。中文閱讀、中文與英文/數字混排、長篇小說場景是主要目標。英文 EPUB/TXT 基本可讀，但目前還不是主要測試目標。

## 主要特性

- **CJK-first 中文排版** — 針對中文長文本閱讀最佳化，包括標點處理、段落間距、段首縮排和直排閱讀。
- **自研 CoreText 渲染器** — 支援分頁和縱向捲動，不依賴 WebView 作為主要閱讀介面。
- **EPUB & TXT 匯入** — 支援本地書籍匯入、解析、快取和閱讀位置恢復。
- **大體積書籍處理** — 已使用 1400 萬字 TXT 和 800 萬字 EPUB 進行測試。
- **TTS 聽書** — 支援 AVSpeechSynthesizer 和基於 HTTP 的自訂 TTS 後端。
- **RSS 訂閱** — 支援標準 RSS/Atom，也支援規則化內容擷取。
- **WebDAV 支援** — 用於備份、恢復、書庫和閱讀進度同步相關流程。
- **網頁內容轉碼** — 將使用者自行提供的網頁文章或小說頁面轉換為閱讀器內部格式。
- **書籤與標註** — 支援段落級書籤和底線標註持久化。
- **高度可客製化閱讀介面** — 字體、字級、行距、頁邊距、主題、分頁/捲動模式和直排模式。

## 專案邊界

yuedu 是閱讀器引擎和應用外殼，不內建、不託管、不推薦任何受版權保護的內容來源。

使用者需要自行確保匯入的檔案、網頁內容、RSS 訂閱和自訂規則符合當地法律、版權要求和網站服務條款。

本專案不接受內建盜版源、DRM 繞過、付費牆繞過、私有 token、cookie、反爬繞過邏輯等相關貢獻或請求。

## 環境需求

- iOS 18.0+
- Xcode 16.0+
- Swift 6

## 快速開始

```bash
git clone https://github.com/yuedu-reader/yuedu-app.git
cd yuedu-app
open "yuedu app.xcodeproj"
```

選擇 `yuedu app` scheme，然後在模擬器或真機上建置執行。

## 專案結構

```text
yuedu app/
├── Models/               # 資料模型、儲存、引擎
│   ├── App/              # 全域設定、設計 token、依賴注入
│   ├── Book/             # 書籍模型、BookStore、書籤
│   ├── BookSource/       # 使用者自訂來源抓取流程
│   ├── LocalBook/        # EPUB/TXT/Markdown 解析器
│   ├── Online/           # 線上閱讀與網頁內容轉碼流程
│   ├── RSS/              # RSS 模型、抓取器、解析器
│   ├── Reader/CoreText/  # CoreText 排版與分頁引擎
│   ├── RuleEngine/       # CSS/XPath/Regex/JSON 規則擷取
│   ├── TTS/              # 聽書協調邏輯
│   └── ...               # Comic、Migration、Network、Sync、Server
├── Views/                # SwiftUI 視圖
│   ├── Reader/           # 閱讀器介面與控制
│   ├── Bookshelf/        # 首頁書架
│   ├── BookSource/       # 來源管理
│   ├── RSS/              # RSS 訂閱介面
│   ├── Settings/         # 應用設定
│   └── ...               # Search、Stats、TTS 等
├── ViewModels/           # ObservableObject ViewModel
├── Assets/               # 資源目錄和規則引擎資源
└── *.lproj/              # 在地化檔案（zh-Hant、zh-Hans、en）
```

## 架構說明

- **EPUB 解析**：使用 Readium 元件處理 EPUB package 解析與資源管理。
- **閱讀渲染**：`EPUBPageRenderer` 根據閱讀模式分發到 `CoreTextPageEngine` 或 `CoreTextScrollEngine`。頁面由 `CoreTextPageView` 透過 CoreText `CTFrame` 繪製。
- **CJK 排版**：渲染器圍繞中文長文本場景設計，處理 CJK 標點、段首縮排、中英混排和從右到左的直排布局。
- **書籍來源**：`BookSourceFetcher` → `OnlineReadingPipeline` → `RuleEngine`，從使用者自訂規則中擷取章節與標準化內容。
- **RSS**：`RSSFetcher` 處理標準 XML feed 和基於規則的 HTML 擷取。
- **TTS**：TTS 協調器將可朗讀文字區塊映射到播放狀態和閱讀位置。
- **同步**：WebDAV 和帳號相關服務用於備份、恢復和閱讀進度同步。
- **依賴注入**：透過 `AppDependencies` 和 `@Environment` 提供服務，必要時集中管理快取和 manager。

## 在地化

所有介面字串都必須使用 `localized()`，不要硬編碼使用者可見文字。

新增在地化 key 時，需要同時更新以下三個檔案：

- `zh-Hant.lproj/Localizable.strings`
- `zh-Hans.lproj/Localizable.strings`
- `en.lproj/Localizable.strings`

## 建議補充的 README 資源

正式公開 GitHub 前，建議補充：

- 書架截圖
- 閱讀頁截圖
- 排版/設定頁截圖
- 翻頁動畫 GIF
- TTS 播放 GIF 或短影片
- 匯入效能測試表
- 架構圖

## 貢獻

詳見 [CONTRIBUTING.md](CONTRIBUTING.md)。

貢獻應集中在閱讀器引擎、UI、在地化、EPUB/TXT 處理、RSS、WebDAV、無障礙、測試和合法的使用者自訂內容流程。

## 授權

MIT — 見 [LICENSE](LICENSE)。

本專案連結了 [Readium](https://github.com/readium) 元件，Readium 元件使用 BSD 授權。Readium 名稱和標誌是 Readium Foundation 的商標。
