# 閱讀

<p align="center">
  <img src="iOS/Assets.xcassets/AppIcon.appiconset/ios_app_icon_novel_reader_1024_no_alpha.png" width="112" alt="閱讀 icon">
</p>

<p align="center">
  <strong>一個由 CoreText 驅動的 iOS 原生閱讀器。</strong><br>
  EPUB / TXT / RSS / WebDAV / TTS / CJK 直排閱讀。
</p>

<p align="center">
  <a href="README.zh-Hans.md">简体中文</a> ·
  <a href="README.zh-Hant.md">繁體中文</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <img src="docs/demo/cjk-vertical-toc.gif" width="320" alt="閱讀 CJK 直排演示">
</p>

閱讀是一個使用 SwiftUI 和 CoreText 建構的 iOS 原生閱讀器，專注於長文本閱讀、CJK 排版、本地 EPUB/TXT 書庫、網頁內容轉碼、RSS、TTS、WebDAV 同步，以及不依賴 WebView 的原生閱讀介面。

## CJK 直排閱讀

閱讀不是只做基本 EPUB 顯示，而是針對嚴肅 CJK 閱讀場景設計。

它支援直排、由右至左閱讀流、CJK 標點、行內批註、直排目錄，以及 CoreText 分頁。

<p align="center">
  <img src="docs/screenshots/cjk-vertical.png" width="260" alt="CJK 直排閱讀">
  <img src="docs/screenshots/toc.png" width="260" alt="CJK 直排目錄">
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
  <img src="docs/screenshots/english-epub.png" width="280" alt="英文 EPUB 渲染">
</p>

支援的 EPUB 能力包括：

- Reflowable EPUB
- 出版商 CSS cascade
- Drop caps 和段落樣式
- 圖片與 SVG rasterization
- `toc.ncx` 和 `nav.xhtml` 導航
- 高亮、書籤和 TTS

## 功能

- SwiftUI + CoreText 原生 iOS 閱讀器
- EPUB / TXT / Markdown 本地閱讀
- CJK 直排與右至左閱讀 UI
- 分頁與滾動閱讀模式
- 高亮、書籤、標註
- TTS 與自動閱讀
- WebDAV 同步
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

<p align="center">
  <img src="docs/banner.svg" alt="渲染管線架構圖" width="680">
</p>

兩條平行路徑都會產出 CoreText 屬性字串：

```text
舊路徑：      HTMLAttributedStringBuilder.build() -> NSAttributedString
                       |                            |
RenderableNode：HTMLStyledASTRenderableNodeConverter -> RenderableNode IR -> NodeAttributedStringRenderer
                       |                            |
                共享層：CSSParser -> ResolvedStyle -> CoreTextPageView.drawLines()
```

任何 CSS 屬性變更都必須更新兩條路徑。共享層負責 CSS 解析、`ResolvedStyle` 和 `CoreTextPageView` 的 frame 繪製。

更多細節：

- [架構筆記](Technotes/Architecture.md)
- [CoreText 貢獻者筆記](docs/coretext/README.md)
- [EPUB 相容性 checklist](docs/epub-compatibility-checklist.md)
- [EPUB regression samples](docs/epub-regression/README.md)

## 專案邊界

閱讀是閱讀器引擎和應用外殼，不內建、不託管、不推薦、也不散布任何受版權保護的內容來源。

使用者需要自行確保匯入檔案、RSS feed、網站、自訂規則、cookie、帳號和產生內容符合當地法律、版權要求和網站服務條款。

本專案不接受內建盜版源、DRM 繞過、付費牆繞過、私有 token 分享、cookie 擷取或反爬繞過邏輯等貢獻。

Legado 相容性只代表書源規則格式相容；閱讀不內建第三方書源規則，也不是 [Legado](https://github.com/gedoor/legado) 專案的官方關聯產品。

## AI 協同開發聲明

本倉庫重度使用 AI 協同開發，包括程式碼生成、重構、文件撰寫和審查輔助。專案仍會保留人工審閱與維護責任，但 AI 輔助產出的程式碼會明確存在於專案中。

如果你偏好完全由人手撰寫的程式碼，或對 AI 輔助開發有疑慮或排斥，請在使用或貢獻前自行評估，並請見諒。

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

## 演示素材

README 演示素材建議放在：

```text
docs/demo/
  cjk-vertical-toc.gif
  reader-page-turn.gif
  import-flow.gif
docs/screenshots/
  cjk-vertical.png
  english-epub.png
  toc.png
```

首屏 GIF 建議控制在 5-10 秒、寬度 300-360 px，最好不要超過 10 MB。如果 GIF 太大，可以把 MP4 放在 `docs/demo/` 或 release asset，README 用截圖連結過去。

模擬器錄影：

```bash
xcrun simctl io booted recordVideo demo.mov
```

轉 GIF：

```bash
ffmpeg -i demo.mov -vf "fps=12,scale=640:-1:flags=lanczos" -loop 0 docs/demo/cjk-vertical-toc.gif
```

更小的 GIF：

```bash
ffmpeg -i demo.mov -vf "fps=10,scale=480:-1:flags=lanczos" -loop 0 docs/demo/cjk-vertical-toc.gif
```

MP4 fallback：

```bash
ffmpeg -i demo.mov -vf "scale=720:-2" -c:v libx264 -crf 28 -preset slow -pix_fmt yuv420p docs/demo/cjk-vertical-toc.mp4
```

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

## 開發規則

- 使用者字串使用 `localized()`，更新三個 `.lproj` 檔案。
- 閱讀位置以內容座標為準，不用頁碼。
- UI 樣式使用設計 token API：`DSColor`、`DSFont`、`DSSpacing`。
- 新增或修改 View 時，盡量加入可編譯的 `#Preview` 或 `PreviewProvider`。
- 新增 CSS 屬性至 `ResolvedStyle` 時，同步 `RenderStyle` 欄位、更新 `RenderStyle.from`，並處理兩條渲染路徑。
- 巢狀區塊 CSS 邊距透過 `inheritedBlockMarginLeft` 累加。
- 書源和規則引擎相關工作必須限定在合法、使用者自行提供內容的流程。

請見 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 授權

MIT。詳見 [LICENSE](LICENSE)。本專案連結 [Readium](https://github.com/readium) 元件，Readium 使用 BSD 授權。
