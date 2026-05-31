# 閱讀

<p align="center">
  <img src="iOS/Assets.xcassets/AppIcon.appiconset/ios_app_icon_novel_reader_1024_no_alpha.png" width="112" alt="閱讀 icon">
</p>

<p align="center">
  <strong>一個由 CoreText 驅動的 iOS 原生閱讀器。</strong><br>
  EPUB / TXT / RSS / 漫畫 / WebDAV / TTS / CJK 直排閱讀。
</p>

<p align="center">
  <a href="README.zh-Hans.md">简体中文</a> ·
  <a href="README.zh-Hant.md">繁體中文</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <a href="https://testflight.apple.com/join/7hvbzYC1">
    <img src="https://img.shields.io/badge/TestFlight-加入測試-0D96F6?logo=apple&logoColor=white" alt="加入 TestFlight 測試">
  </a>
  <a href="https://t.me/+ZWmmgMwwJ3JiN2Rl">
    <img src="https://img.shields.io/badge/Telegram-加入群組-26A5E4?logo=telegram&logoColor=white" alt="加入 Telegram 群組">
  </a>
  <a href="https://iosdevweekly.com/issues/751">
    <img src="https://img.shields.io/badge/iOS%20Dev%20Weekly-%23751%20收錄-FF6600" alt="獲 iOS Dev Weekly #751 收錄">
  </a>
</p>

<p align="center">
  <a href="https://chang-jui-lin.github.io/Yuedu-reader/support.html">支援</a> ·
  <a href="https://chang-jui-lin.github.io/Yuedu-reader/privacy.html">隱私權政策</a>
</p>

<p align="center">
  <img src="docs/demo/cjk-vertical-toc.gif" width="320" alt="閱讀 CJK 直排演示">
</p>

閱讀是一個使用 SwiftUI 和 CoreText 建構的 iOS 原生閱讀器，專注於長文本閱讀、CJK 排版、本地 EPUB/TXT 書庫、漫畫、網頁內容轉碼、RSS、TTS、OPDS 與 WebDAV 匯入／同步，以及不依賴 WebView 的原生閱讀介面。

> 📝 獲 [iOS Dev Weekly #751](https://iosdevweekly.com/issues/751) 收錄 —— [*From WebView to CoreText: Building a Native EPUB Reader for iOS*](https://chang-jui-lin.github.io/Yuedu-reader/2026/05/20/from-webview-to-coretext/)。

## CJK 直排閱讀

閱讀不是只做基本 EPUB 顯示，而是針對嚴肅 CJK 閱讀場景設計。

它支援直排、由右至左閱讀流、CJK 標點、行內批註、直排目錄，以及 CoreText 分頁。

<p align="center">
  <img src="docs/screenshots/cjk-vertical.png" width="280" alt="CJK 直排閱讀">
</p>

亮點：

- CJK 直排文字渲染
- 直排書籍的右至左目錄
- CJK 標點處理
- 行內批註與高密度註解 EPUB 測試
- 基於 CoreText 分頁，不以 WebView 作為主要閱讀介面

## 英文 EPUB 也正常

閱讀不只支援中文書。標準英文 EPUB 也可以渲染，包括出版商 CSS、章節導航、圖片、連結和分頁。

<p align="center">
  <img src="docs/screenshots/english-epub.png" width="260" alt="英文 EPUB 渲染">
  <img src="docs/screenshots/toc.png" width="260" alt="英文 EPUB 目錄">
</p>

支援的 EPUB 能力包括：

- Reflowable EPUB
- 出版商 CSS cascade
- Drop caps 和段落樣式
- 圖片與 SVG rasterization
- `toc.ncx` 和 `nav.xhtml` 導航
- 高亮、書籤和 TTS

## 閱讀工作流

閱讀不只是本地 EPUB 閱讀器，也包含 RSS 閱讀和網頁文章轉碼，支援線上閱讀工作流。

- **RSS 閱讀器**：RSS / Atom feed、文章擷取，並在原生閱讀器內閱讀。
- **網頁文章轉碼**：將網頁轉成乾淨的長文本閱讀內容。
- **書源閱讀**：相容 Legado 書源的線上網文閱讀——搜尋、瀏覽目錄，並在原生 CoreText 閱讀器內閱讀。
- **漫畫閱讀**：透過相容書源閱讀漫畫，或匯入本地漫畫（`.cbz` / `.zip`），以專屬圖片閱讀器瀏覽。
- **書庫匯入**：在書架的新增書籍選單中，直接從 OPDS 目錄與 WebDAV 伺服器加入書籍。

<p align="center">
  <img src="docs/demo/book-source-reading.gif" width="320" alt="線上書源網文閱讀演示">
</p>

## 功能

- SwiftUI + CoreText 原生 iOS 閱讀器
- EPUB / TXT / Markdown 本地閱讀
- CJK 直排與右至左閱讀 UI
- 分頁與滾動閱讀模式
- 高亮、書籤、標註
- TTS 與自動閱讀
- 漫畫閱讀，專屬圖片閱讀器（書源 + 本地 `.cbz` / `.zip` 匯入）
- OPDS 目錄匯入
- WebDAV 匯入與同步
- RSS / 網頁文章閱讀
- Legado 相容書源規則
- EPUB regression samples 用於渲染相容性檢查

## 為什麼使用 CoreText？

多數 EPUB 閱讀器使用 WebView。閱讀使用 CoreText 作為主要閱讀渲染層，所以可以更精準控制分頁、文字範圍、高亮、TTS 同步和 CJK 直排。

這讓以下能力變得可控：

- 基於 `(spineIndex, charOffset)` 的穩定閱讀位置
- 精準頁面渲染
- 原生文字選取與高亮
- TTS 進度同步
- 自訂 CJK 直排布局行為

## 渲染管線

閱讀有兩條 EPUB 渲染路徑，它們共用同一套 CSS resolution 和 CoreText 繪製層：

- Legacy HTML attributed-string builder
- RenderableNode IR pipeline

多數貢獻者在處理 UI、文件、在地化、EPUB 測試、WebDAV 或書源規則功能前，不需要先理解完整引擎。

詳細內容見：

- [CoreText contributor notes](docs/coretext/README.md)
- [Architecture notes](Technotes/Architecture.md)

## EPUB 相容性

閱讀包含小型 EPUB regression corpus 和相容性 checklist，用來測試渲染行為。

- [EPUB compatibility checklist](docs/epub-compatibility-checklist.md)
- [EPUB regression samples](docs/epub-regression/README.md)

## 環境需求

- iOS 18.0+
- Xcode 16+
- Xcode 專案目前使用 Swift 5 language mode

## 快速開始

```bash
git clone https://github.com/CHANG-JUI-LIN/Yuedu-reader.git
cd Yuedu-reader
open Yuedu-Reader.xcodeproj
```

選擇 `Yuedu-Reader` scheme，建置至模擬器或實機。或直接執行：

```bash
./scripts/build.sh
```

## 專案邊界

閱讀是閱讀器引擎和應用外殼，不內建、不託管、不推薦、也不散布任何受版權保護的內容來源。

使用者需要自行確保匯入檔案、RSS feed、網站、自訂規則、cookie、帳號和產生內容符合當地法律、版權要求和網站服務條款。

本專案不接受內建盜版源、DRM 繞過、付費牆繞過、私有 token 分享、cookie 擷取或反爬繞過邏輯等貢獻。

Legado 相容性只代表書源規則格式相容；閱讀不內建第三方書源規則，也不是 [Legado](https://github.com/gedoor/legado) 專案的官方關聯產品。

## AI 協同開發聲明

本倉庫重度使用 AI 協同開發，包括程式碼生成、重構、文件撰寫和審查輔助。專案仍會保留人工審閱與維護責任。

如果你偏好完全由人手撰寫的程式碼，或對 AI 輔助開發有疑慮或排斥，請在使用或貢獻前自行評估，並請見諒。

## 目錄結構

```text
iOS/
├── Models/
│   ├── App/              # 全域設定、DesignTokens、AppDependencies
│   ├── Book/             # ReadingBook、Bookmark、BookStore
│   ├── BookSource/       # 書源定義與擷取管線
│   ├── LocalBook/        # EPUB/TXT/Markdown 解析器
│   ├── Online/           # 線上閱讀與網頁正規化
│   ├── RSS/              # RSS 模型、訂閱解析
│   ├── Reader/CoreText/  # CoreText 翻頁引擎、滾動引擎、CSS 解析、渲染
│   ├── RuleEngine/       # CSS/XPath/Regex/JSON 規則提取
│   ├── Sync/             # WebDAV 同步管理
│   └── TTS/              # 語音播放協調
├── Views/                # SwiftUI 畫面
├── ViewModels/           # ObservableObject ViewModel
├── Assets/               # 資產目錄與規則引擎資源
└── *.lproj/              # 本地化：zh-Hant、zh-Hans、en
```

## 開發

- 使用者字串使用 `localized()`，更新三個 `.lproj` 檔案。
- 閱讀位置以內容座標為準，不用頁碼。
- UI 樣式使用設計 token API：`DSColor`、`DSFont`、`DSSpacing`。
- 新增或修改 View 時，盡量加入可編譯的 `#Preview` 或 `PreviewProvider`。
- 新增 CSS 屬性至 `ResolvedStyle` 時，同步 `RenderStyle` 欄位、更新 `RenderStyle.from`，並處理兩條渲染路徑。
- 巢狀區塊 CSS 邊距透過 `inheritedBlockMarginLeft` 累加。
- 書源和規則引擎相關工作必須限定在合法、使用者自行提供內容的流程。

請見 [CONTRIBUTING.md](CONTRIBUTING.md)。演示素材流程見 [docs/demo/README.md](docs/demo/README.md)。

## 授權

[MIT](https://opensource.org/license/mit)。詳見 [LICENSE](LICENSE)。本專案連結 [Readium](https://github.com/readium) 元件，Readium 使用 BSD 授權。
