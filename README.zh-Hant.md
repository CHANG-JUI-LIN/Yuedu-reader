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
  <a href="https://testflight.apple.com/join/7hvbzYC1">
    <img src="https://img.shields.io/badge/TestFlight-測試版-0D96F6?logo=apple&logoColor=white" alt="加入 TestFlight 測試">
  </a>
  <a href="https://iosdevweekly.com/issues/751">
    <img src="https://img.shields.io/badge/iOS%20Dev%20Weekly-%23751%20收錄-FF6600" alt="獲 iOS Dev Weekly #751 收錄">
  </a>
  <img src="https://img.shields.io/badge/iOS-18.0%2B-000000?logo=apple&logoColor=white" alt="iOS 18.0+">
  <img src="https://img.shields.io/badge/授權-MPL--2.0-blue" alt="MPL 2.0 授權">
</p>

> 獲 [iOS Dev Weekly #751](https://iosdevweekly.com/issues/751) 收錄 —— [*From WebView to CoreText: Building a Native EPUB Reader for iOS*](https://chang-jui-lin.github.io/Yuedu-reader/2026/05/20/from-webview-to-coretext/)。

Yuedu 是一個專注於高品質本地與開放閱讀體驗的開源閱讀應用。一個 App 涵蓋 EPUB3、漫畫、有聲書、RSS 與開放目錄 —— 全程以 CoreText 原生渲染，無 WebView。

## 功能

| | |
|:--|:--|
| **格式** | EPUB3 · TXT · CBZ 漫畫 · 有聲書 · PDF *(開發中)* |
| **內容** | 本地書庫 · WebDAV · OPDS · RSS · 內容源 |
| **閱讀** | 直排 · 主題 · 標註 · 書籤 |
| **更多** | 閱讀統計 · iCloud 同步 |

## 為什麼用 CoreText，而非 WebView

多數閱讀器把內容包進 WebView。Yuedu 每一頁都以 CoreText 渲染 —— 換來精準的分頁、真正的中日韓直排、逐幀對齊的語音朗讀同步，以及原生文字選取，且維持原生效能。完整來龍去脈見 [*From WebView to CoreText*](https://chang-jui-lin.github.io/Yuedu-reader/2026/05/20/from-webview-to-coretext/)。

## 架構

```
UI (SwiftUI)
  ↓
Reader (CoreText)
  ↓
Parser (EPUB / TXT / CBZ / RSS / Audio)
  ↓
Storage (Local-first)
  ↓
Sync (WebDAV / iCloud / OPDS)
```

## 建置

**環境需求：** Xcode 16+ · iOS 18.0+ · Swift 6.0

```bash
git clone https://github.com/CHANG-JUI-LIN/Yuedu-reader.git
cd Yuedu-reader
open Yuedu-Reader.xcodeproj
```

接著選擇模擬器（或實機）執行。自行建置的版本需要自己的簽章設定與 Bundle Identifier；公開重新散布的分支版本必須使用不同的 App 名稱、圖示與品牌素材，且不得暗示獲得官方背書。

## App Store 官方版本

原始碼維持開源。App Store 版本是由專案作者維護、簽署、送審、發布並提供支援的官方版本；購買費用用於支持持續開發與版本維護。

## 文件

### 使用指南

- **書源（Legado 格式）指南：** [繁體中文總覽](docs/book-source/quickstart.zh-Hant.md) · [規則語法速查](docs/book-source/rule-syntax.zh-Hant.md) · [與 Legado 的差異](docs/book-source/legado-differences.zh-Hant.md) · [常見症狀對照表](docs/book-source/troubleshooting.zh-Hant.md) — 匯入、五階段驗證、規則調試器、語法速查、與 Legado 的差異、症狀→解法對照。
- **電量 SVG 模板：** [繁體中文](docs/reader-overlay/BatterySVG.zh-Hant.md) · [简体中文](docs/reader-overlay/BatterySVG.zh-Hans.md) · [English](docs/reader-overlay/BatterySVG.en.md) — 模板格式、動態標記、支援的 SVG 子集與匯入疑難排解。

### 開發者參考

- [CoreText 文件](docs/coretext/README.md) — 閱讀器架構、渲染流程、互動與直排。
- [EPUB 相容性檢查清單](docs/epub-compatibility-checklist.md) — 實作與回歸測試檢查項目。
- [專案架構](Technotes/Architecture.md) — 模組、資料流與技術邊界。

## 貢獻

歡迎貢獻 —— 慣例與 PR 流程請見 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 授權

原始碼採用 [Mozilla Public License 2.0](LICENSE)。Yuedu／閱讀名稱、App 圖示、Logo、截圖及其他品牌素材不包含在 MPL 授權內，詳見 [TRADEMARKS.md](TRADEMARKS.md)。授權切換前發布的版本仍適用其發布時的授權，詳見 [LICENSING.md](LICENSING.md)。
