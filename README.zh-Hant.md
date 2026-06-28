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
  <img src="https://img.shields.io/badge/授權-MIT-blue" alt="MIT 授權">
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

接著選擇模擬器（或實機）執行。

## 貢獻

歡迎貢獻 —— 慣例與 PR 流程請見 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 授權

[MIT](LICENSE)。
