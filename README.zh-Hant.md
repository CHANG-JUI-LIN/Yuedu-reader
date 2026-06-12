# 閱讀

<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/ios_app_icon_novel_reader_1024_no_alpha.png" width="112" alt="閱讀 icon">
</p>

<p align="center">
  <strong>一個由 CoreText 驅動的 iOS 原生閱讀器。</strong><br>
  EPUB / TXT / Markdown / RSS / 漫畫 / OPDS / WebDAV / TTS / CJK 直排閱讀。
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
    <img src="https://img.shields.io/badge/TestFlight-測試版（最新）-0D96F6?logo=apple&logoColor=white" alt="加入 TestFlight 測試">
  </a>
  <a href="https://t.me/+ZWmmgMwwJ3JiN2Rl">
    <img src="https://img.shields.io/badge/Telegram-加入群組-26A5E4?logo=telegram&logoColor=white" alt="加入 Telegram 群組">
  </a>
  <a href="https://iosdevweekly.com/issues/751">
    <img src="https://img.shields.io/badge/iOS%20Dev%20Weekly-%23751%20收錄-FF6600" alt="獲 iOS Dev Weekly #751 收錄">
  </a>
</p>

<p align="center">
  <a href="#功能">功能</a> ·
  <a href="#截圖">截圖</a> ·
  <a href="#下載">下載</a> ·
  <a href="#快速開始">快速開始</a> ·
  <a href="#故障排除">故障排除</a> ·
  <a href="#貢獻">貢獻</a> ·
  <a href="#授權">授權</a>
</p>

<p align="center">
  <img src="docs/demo/cjk-vertical-toc.gif" width="320" alt="閱讀 CJK 直排演示">
</p>

閱讀是一個 iOS-first 的長文本閱讀 app，專注於原生排版、CJK 直排閱讀、本地書庫、漫畫、RSS、網頁文章轉碼、TTS、OPDS 與 WebDAV 匯入／同步，以及使用者自行提供的書源閱讀工作流。

> 獲 [iOS Dev Weekly #751](https://iosdevweekly.com/issues/751) 收錄 —— [*From WebView to CoreText: Building a Native EPUB Reader for iOS*](https://chang-jui-lin.github.io/Yuedu-reader/2026/05/20/from-webview-to-coretext/)。

## 為什麼選閱讀

- 使用 SwiftUI 和 CoreText 建構的 iOS 原生閱讀介面，不以 WebView 作為主要閱讀層。
- CoreText 分頁讓閱讀位置、高亮和 TTS 進度更穩定。
- 支援 CJK 直排、由右至左閱讀流與直排目錄。
- Local-first 書庫，支援 EPUB、TXT、Markdown 和本地漫畫壓縮檔。
- 支援使用者自行提供的 RSS、OPDS、WebDAV、網頁與相容書源規則。
- 專案邊界清楚：閱讀不內建、不推薦、也不散布受版權保護的內容來源。

## 功能

| 領域 | 能力 | 狀態 |
| --- | --- | --- |
| 本地書籍 | EPUB reflowable 閱讀，含章節導航、圖片、連結、書籤、高亮、標註和 TTS | Available |
| 本地書籍 | TXT 和 Markdown 閱讀 | Available |
| 漫畫 | 本地 `.cbz` / `.zip` 漫畫壓縮檔與相容書源漫畫閱讀 | Available |
| 有聲書 | 書源有聲書串流播放器 | Available |
| 閱讀模式 | 分頁與滾動閱讀模式 | Available |
| CJK 排版 | 直排、由右至左閱讀流、CJK 標點處理與直排目錄 | Available |
| 書庫匯入 | OPDS 目錄匯入 | Available |
| 同步／匯入 | WebDAV 匯入與同步 | Available |
| 線上閱讀 | RSS / Atom feed 與原生文章閱讀 | Beta |
| 線上閱讀 | 網頁文章轉碼成乾淨的長文本閱讀內容 | Beta |
| 書源 | 使用者自行提供的 Legado 相容書源規則 | Beta |
| 渲染品質 | IDPF EPUB3 官方樣本集已驗證（至 Linear Algebra），MathML 渲染，EPUB regression samples 與相容性 checklist | Available |
| EPUB 版面 | Fixed-layout EPUB prototype | Experimental |
| 無障礙 | 更完整的 VoiceOver、Dynamic Type 與觸控目標改善 | Planned |

## 支援格式

| 類別 | 支援 | 說明 |
| --- | --- | --- |
| 本地書籍 | EPUB、TXT、Markdown | EPUB 支援聚焦 reflowable 書籍與 CoreText 原生渲染。 |
| 漫畫壓縮檔 | CBZ、ZIP | 使用專屬圖片閱讀器開啟。 |
| 有聲書 | M4A、M4B、MP3、FLAC、OGG、WAV、AAC、AIFF | 透過書源有聲管線與本地 TTS 引擎播放。 |
| 線上訂閱 | RSS、Atom | 文章會擷取後在原生閱讀器內閱讀。 |
| 目錄與同步 | OPDS、WebDAV | 從目錄與 WebDAV 伺服器匯入書籍，並透過 WebDAV 同步。 |
| 書源規則 | Legado 相容規則 | 只代表格式相容；不內建第三方書源規則。 |
| 目前非主軸 | PDF、MOBI、AZW3、FB2、DOCX | 閱讀刻意聚焦 iOS 原生與 CoreText，而不是跨平台全格式套件。 |

## 截圖

### 書庫與閱讀器

閱讀展示 local-first 書庫、原生閱讀器控制、CJK 直排、高亮標註、TTS、漫畫、RSS 與匯入工作流。

<p align="center">
  <img src="docs/demo/library.png" width="220" alt="閱讀書庫">
  <img src="docs/demo/reader-menu.png" width="220" alt="閱讀器控制列">
  <img src="docs/demo/dark-mode.png" width="220" alt="閱讀深色模式">
</p>

### 閱讀體驗

CJK 直排、高亮、標註與 TTS 都屬於原生閱讀介面的一部分。

<p align="center">
  <img src="docs/screenshots/cjk-vertical.png" width="220" alt="CJK 直排閱讀">
  <img src="docs/demo/highlights-annotations.png" width="220" alt="閱讀高亮與標註">
  <img src="docs/demo/tts.png" width="220" alt="閱讀 TTS 播放">
</p>

### 工作流

閱讀也支援漫畫閱讀、RSS 閱讀、OPDS/WebDAV 匯入，以及相容的使用者自備書源工作流。

<p align="center">
  <img src="docs/demo/manga-reader.png" width="220" alt="閱讀漫畫閱讀器">
  <img src="docs/demo/rss-reader.png" width="220" alt="閱讀 RSS 閱讀器">
  <img src="docs/demo/opds-webdav-import.png" width="220" alt="閱讀 OPDS 與 WebDAV 匯入">
</p>

<p align="center">
  <img src="docs/demo/book-source-reading.gif" width="320" alt="線上書源網文閱讀演示">
</p>

## 下載

- [從 App Store 下載](https://apps.apple.com/app/id6772972358)
- [加入最新 TestFlight 測試](https://testflight.apple.com/join/7hvbzYC1)
- [支援](https://chang-jui-lin.github.io/Yuedu-reader/support.html)
- [隱私權政策](https://chang-jui-lin.github.io/Yuedu-reader/privacy.html)
- [Telegram 群組](https://t.me/+ZWmmgMwwJ3JiN2Rl)

閱讀目前目標系統為 iOS 18.0+。

## 路線圖

### 現在

- 改善 EPUB 渲染相容性。
- 打磨 CJK 直排閱讀與目錄行為。
- 增加 EPUB 渲染 bug template 與 regression samples。
- 改善 RSS 載入錯誤處理。

### 接下來

- 更好的網頁文章轉碼。
- 更完整的漫畫書源與閱讀器手勢。
- Fixed-layout EPUB prototype。

### 之後

- TestFlight 回饋循環。
- 更多無障礙工作。
- 更多自動化渲染 regression tests。

如果想貢獻，可以查看標有 `help wanted` 或 `good first issue` 的 issue。

## 快速開始

開發環境需求：

- iOS 18.0+
- Xcode 16+
- Xcode 專案目前使用 Swift 5 language mode

```bash
git clone https://github.com/CHANG-JUI-LIN/Yuedu-reader.git
cd Yuedu-reader
open Yuedu-Reader.xcodeproj
```

選擇 `Yuedu-Reader` scheme，建置至模擬器或實機。或直接執行：

```bash
./scripts/build.sh
```

## 故障排除

- **App Store 與 TestFlight**：App Store 是穩定版。TestFlight 會先收到較新的 build，可能包含尚未完成的行為。
- **EPUB 渲染問題**：請使用 [EPUB rendering bug template](.github/ISSUE_TEMPLATE/epub_rendering_bug.yml)。請附上閱讀截圖、可行的話附 Apple Books 截圖、EPUB 類型／版本、章節／頁面位置、預期行為與實際行為。
- **WebDAV、OPDS、RSS 或書源規則問題**：請提供 URL 或伺服器類型、可見錯誤訊息、失敗操作，以及內容來源合法且由使用者自行提供的確認。
- **受版權保護內容**：請勿公開上傳受版權保護的書籍。建議提供最小化合成 EPUB 或已去識別的範例。

## 專案邊界

閱讀是閱讀器引擎和應用外殼，不內建、不託管、不推薦、也不散布任何受版權保護的內容來源。

使用者需要自行確保匯入檔案、RSS feed、網站、自訂規則、cookie、帳號和產生內容符合當地法律、版權要求和網站服務條款。

本專案不接受內建盜版源、DRM 繞過、付費牆繞過、私有 token 分享、cookie 擷取或反爬繞過邏輯等貢獻。

Legado 相容性只代表書源規則格式相容；閱讀不內建第三方書源規則，也不是 [Legado](https://github.com/gedoor/legado) 專案的官方關聯產品。

## 架構說明

多數 EPUB 閱讀器使用 WebView。閱讀使用 CoreText 作為主要閱讀渲染層，所以可以更精準控制分頁、文字範圍、高亮、TTS 同步和 CJK 直排。

閱讀目前有兩條 EPUB 渲染路徑，它們共用同一套 CSS resolution 和 CoreText 繪製層：

- Legacy HTML attributed-string builder
- RenderableNode IR pipeline

多數貢獻者在處理 UI、文件、在地化、EPUB 測試、WebDAV、RSS 或書源規則功能前，不需要先理解完整引擎。

詳細內容見：

- [CoreText contributor notes](docs/coretext/README.md)
- [Architecture notes](Technotes/Architecture.md)
- [EPUB compatibility checklist](docs/epub-compatibility-checklist.md)
- [EPUB regression samples](docs/epub-regression/README.md)

## 貢獻

閱讀歡迎文件、截圖、EPUB 測試、在地化、無障礙、WebDAV/OPDS 測試、閱讀器 UI 打磨與渲染相容性等聚焦貢獻。

從這裡開始：

- [Contributing guide](CONTRIBUTING.md)
- [EPUB rendering bug template](.github/ISSUE_TEMPLATE/epub_rendering_bug.yml)
- [CoreText contributor notes](docs/coretext/README.md)
- [EPUB regression samples](docs/epub-regression/README.md)
- [演示素材流程](docs/demo/README.md)

## 目錄結構

```text
Modules/
├── Core/                 # EPUB/TXT/MD 解析器、CoreText 引擎、書源、RuleEngine、TTS、漫畫
├── Features/             # SwiftUI 畫面：書庫、閱讀器、RSS、書源、搜尋、設定...
├── Services/             # LibraryStore、Online、WebDAV、iCloud、OPDS、Network、Account...
└── SharedUI/             # DesignSystem、Components、Extensions、Adaptive layout
Resources/                # Assets.xcassets、Assets/、en.lproj、zh-Hans.lproj、zh-Hant.lproj
Targets/Yuedu/            # SharedApp、iPhone/、iPad/ 入口
```

## 開發注意事項

- 使用者字串使用 `localized()`，更新三個 `.lproj` 檔案。
- 閱讀位置以內容座標為準，不用頁碼。
- UI 樣式使用設計 token API：`DSColor`、`DSFont`、`DSSpacing`。
- 新增或修改 View 時，盡量加入可編譯的 `#Preview` 或 `PreviewProvider`。
- 新增 CSS 屬性至 `ResolvedStyle` 時，同步 `RenderStyle` 欄位、更新 `RenderStyle.from`，並處理兩條渲染路徑。
- 巢狀區塊 CSS 邊距透過 `inheritedBlockMarginLeft` 累加。
- 書源和規則引擎相關工作必須限定在合法、使用者自行提供內容的流程。

## AI 協同開發聲明

本倉庫重度使用 AI 協同開發，包括程式碼生成、重構、文件撰寫和審查輔助。專案仍會保留人工審閱與維護責任。

如果你偏好完全由人手撰寫的程式碼，或對 AI 輔助開發有疑慮，請在使用或貢獻前自行評估。

## 授權

[MIT](https://opensource.org/license/mit)。詳見 [LICENSE](LICENSE)。本專案連結 [Readium](https://github.com/readium) 元件，Readium 使用 BSD 授權。
