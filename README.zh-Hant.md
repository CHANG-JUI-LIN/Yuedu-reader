# Yuedu

<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/AppIcon_1024_white_no_alpha.png" width="112" alt="Yuedu">
</p>

<p align="center">
  受 Apple Books 啟發的開源 iOS 閱讀器。
</p>

<p align="center">
  <a href="README.zh-Hans.md">简体中文</a> ·
  <a href="README.zh-Hant.md">繁體中文</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6772972358">
    <img src="https://img.shields.io/badge/App%20Store-下載-0D96F6?logo=apple&logoColor=white" alt="從 App Store 下載">
  </a>
  <a href="https://testflight.apple.com/join/K37t7nXp">
    <img src="https://img.shields.io/badge/TestFlight-測試版-0D96F6?logo=apple&logoColor=white" alt="加入 TestFlight 測試">
  </a>
  <a href="https://iosdevweekly.com/issues/751">
    <img src="https://img.shields.io/badge/iOS%20Dev%20Weekly-%23751%20收錄-FF6600" alt="獲 iOS Dev Weekly #751 收錄">
  </a>
  <img src="https://img.shields.io/badge/iOS-17.0%2B-000000?logo=apple&logoColor=white" alt="iOS 17.0+">
  <img src="https://img.shields.io/badge/授權-MPL--2.0-blue" alt="MPL 2.0 授權">
</p>

> 獲 [iOS Dev Weekly #751](https://iosdevweekly.com/issues/751) 收錄 —— [*From WebView to CoreText: Building a Native EPUB Reader for iOS*](https://yuedureader.com/2026/05/20/from-webview-to-coretext/)。

Yuedu 是一個專注於高品質本地與開放閱讀體驗的開源閱讀應用。一個 App 涵蓋 EPUB、Kindle 檔案、PDF、漫畫、有聲書、RSS 與開放目錄 —— 書本全程以 CoreText 原生渲染，不用 WebView。

## 功能

| | |
|:--|:--|
| **格式** | EPUB3 · MOBI／AZW3 · PDF · TXT · Markdown · CBZ 漫畫 · 有聲書 |
| **內容** | 本地書庫 · WebDAV · OPDS · Calibre · RSS · 來源配置（Legado 格式，含影片） · 模組 · 公有領域書庫（古騰堡計畫、青空文庫） |
| **探索** | 自己編排的探索首頁 · 一次搜尋書架、來源配置、遠端書庫與模組 · 每部作品一頁作品詳情 · AI 推薦 |
| **閱讀** | 直排 · 全書搜尋 · 語音朗讀 · 主題與主題包 · 高亮與筆記 · 書籤 |
| **更多** | 閱讀統計 · iCloud 同步 · 小工具 · iPad 與 iPhone 橫向 |

## 為什麼用 CoreText，而非 WebView

多數閱讀器把內容包進 WebView。Yuedu 每一頁都以 CoreText 渲染 —— 換來精準的分頁、真正的中日韓直排、逐幀對齊的語音朗讀同步，以及原生文字選取，且維持原生效能。完整來龍去脈見 [*From WebView to CoreText*](https://yuedureader.com/2026/05/20/from-webview-to-coretext/)。

## 架構

```
UI (SwiftUI)
  ↓
Reader (CoreText)
  ↓
Parsers (EPUB / MOBI → EPUB / PDF / TXT / Markdown / CBZ / RSS / Audio)
  ↓
Content (Local · Sources · Modules · OPDS / WebDAV / Calibre)
  ↓
Storage (local-first) · Sync (iCloud / WebDAV)
```

## 資料夾結構

| 資料夾 | 內容 |
|:--|:--|
| `Modules/` | App 原始碼：`Core`（閱讀引擎、解析器、規則引擎）、`Services`（書庫、同步、網路）、`Features`（SwiftUI 畫面）、`SharedUI`（設計系統） |
| `Targets/` | App 進入點、依賴注入與 iPad 外殼 |
| `Widget/`、`ShareExtension/` | 主畫面小工具與分享擴充功能 |
| `Resources/` | 素材目錄、各語言字串（`zh-Hant`、`zh-Hans`、`en`、`ja`、`ko`）與內建官方模組 |
| `Packages/` | 本地 Swift 套件（`CLexbor`、`SwiftSoup`） |
| `Tests/` | 單元測試（`Tests/iOS`）、UI 測試（`Tests/iOS-UI`）與測試素材 |
| `docs/` | 使用指南、CoreText 文件、更新日誌，以及測試會讀取的排版語料 |
| `Technotes/` | 設計筆記與事後檢討 |
| `functions/`、`gateway/` | Firebase Cloud Functions 與帳號閘道；Firestore／Storage 規則在根目錄 |
| `scripts/` | 模擬器、測試、在地化與目錄工具 |
| `xcconfig/`、`Configuration/`、`ci_scripts/` | 建置設定、StoreKit 測試設定與 Xcode Cloud 腳本 |

## 建置

**環境需求：** Xcode 27.1 以上 · iOS 17.0+ · Swift 6

```bash
git clone https://github.com/CHANG-JUI-LIN/Yuedu-reader.git
cd Yuedu-reader
open Yuedu-Reader.xcodeproj
```

專案需要根目錄有一份 `GoogleService-Info.plist`。它不在 repo 裡（已列入 gitignore），沒有它建置會失敗：請在你自己的 Firebase 專案新增一個 iOS App，把它的 plist 放到根目錄。

接著選擇模擬器（或實機）執行。自行建置的版本需要自己的簽章設定與 Bundle Identifier；公開重新散布的分支版本必須使用不同的 App 名稱、圖示與品牌素材，且不得暗示獲得官方背書。

## App Store 官方版本

原始碼維持開源。App Store 版本是由專案作者維護、簽署、送審、發布並提供支援的官方版本；購買費用用於支持持續開發與版本維護。

## 文件

### 使用指南

- **來源配置（Legado 格式）指南：** [繁體中文總覽](docs/book-source/quickstart.zh-Hant.md) · [規則語法速查](docs/book-source/rule-syntax.zh-Hant.md) · [與 Legado 的差異](docs/book-source/legado-differences.zh-Hant.md) · [常見症狀對照表](docs/book-source/troubleshooting.zh-Hant.md) — 匯入、五階段驗證、規則調試器、語法速查、與 Legado 的差異、症狀→解法對照。
- **模組：** [模組開發文件](docs/modules/README.md) — 清單、搜尋、ISBN 補資料與在 App 內閱讀背後的 JSON 格式。內建官方模組用的是同一種格式，也可以直接當範例看。
- **電量 SVG 模板：** [繁體中文](docs/reader-overlay/BatterySVG.zh-Hant.md) · [简体中文](docs/reader-overlay/BatterySVG.zh-Hans.md) · [English](docs/reader-overlay/BatterySVG.en.md) — 模板格式、動態標記、支援的 SVG 子集與匯入疑難排解。
- **更新日誌：** [3.0.1](docs/release-notes/3.0.1.md) · [3.0.0](docs/release-notes/3.0.0.md)

### 開發者參考

- [CoreText 文件](docs/coretext/README.md) — 閱讀器架構、渲染流程、互動與直排。
- [UI 設計規範](docs/design.md) — HIG 原生版面、標題規則與 VoiceOver 檢查清單。
- [EPUB 相容性檢查清單](docs/epub-compatibility-checklist.md) — 實作與回歸測試檢查項目。
- [專案架構](Technotes/Architecture.md) — 模組、資料流與技術邊界。

## 貢獻

歡迎貢獻 —— 慣例與 PR 流程請見 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 授權

原始碼採用 [Mozilla Public License 2.0](LICENSE)。Yuedu／閱讀名稱、App 圖示、Logo、截圖及其他品牌素材不包含在 MPL 授權內，詳見 [TRADEMARKS.md](TRADEMARKS.md)。授權切換前發布的版本仍適用其發布時的授權，詳見 [LICENSING.md](LICENSING.md)。
