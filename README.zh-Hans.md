# 阅读

<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/ios_app_icon_novel_reader_1024_no_alpha.png" width="112" alt="阅读 icon">
</p>

<p align="center">
  <strong>一个由 CoreText 驱动的 iOS 原生阅读器。</strong><br>
  EPUB / TXT / Markdown / RSS / 漫画 / OPDS / WebDAV / TTS / CJK 直排阅读。
</p>

<p align="center">
  <a href="README.zh-Hans.md">简体中文</a> ·
  <a href="README.zh-Hant.md">繁體中文</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6772972358">
    <img src="https://img.shields.io/badge/App%20Store-下载-0D96F6?logo=apple&logoColor=white" alt="从 App Store 下载">
  </a>
  <a href="https://testflight.apple.com/join/7hvbzYC1">
    <img src="https://img.shields.io/badge/TestFlight-测试版（最新）-0D96F6?logo=apple&logoColor=white" alt="加入 TestFlight 测试">
  </a>
  <a href="https://t.me/+ZWmmgMwwJ3JiN2Rl">
    <img src="https://img.shields.io/badge/Telegram-加入群组-26A5E4?logo=telegram&logoColor=white" alt="加入 Telegram 群组">
  </a>
  <a href="https://iosdevweekly.com/issues/751">
    <img src="https://img.shields.io/badge/iOS%20Dev%20Weekly-%23751%20收录-FF6600" alt="获 iOS Dev Weekly #751 收录">
  </a>
</p>

<p align="center">
  <a href="#功能">功能</a> ·
  <a href="#截图">截图</a> ·
  <a href="#下载">下载</a> ·
  <a href="#快速开始">快速开始</a> ·
  <a href="#故障排查">故障排查</a> ·
  <a href="#贡献">贡献</a> ·
  <a href="#授权">授权</a>
</p>

<p align="center">
  <img src="docs/demo/cjk-vertical-toc.gif" width="320" alt="阅读 CJK 直排演示">
</p>

阅读是一个 iOS-first 的长文本阅读 app，专注于原生排版、CJK 直排阅读、本地书库、漫画、RSS、网页文章转码、TTS、OPDS 与 WebDAV 导入/同步，以及用户自行提供的书源阅读工作流。

> 获 [iOS Dev Weekly #751](https://iosdevweekly.com/issues/751) 收录 —— [*From WebView to CoreText: Building a Native EPUB Reader for iOS*](https://chang-jui-lin.github.io/Yuedu-reader/2026/05/20/from-webview-to-coretext/)。

## 为什么选择阅读

- 使用 SwiftUI 和 CoreText 构建的 iOS 原生阅读界面，不以 WebView 作为主要阅读层。
- CoreText 分页让阅读位置、高亮和 TTS 进度更稳定。
- 支持 CJK 直排、由右至左阅读流与直排目录。
- Local-first 书库，支持 EPUB、TXT、Markdown 和本地漫画压缩包。
- 支持用户自行提供的 RSS、OPDS、WebDAV、网页与兼容书源规则。
- 项目边界清楚：阅读不内置、不推荐、也不分发受版权保护的内容来源。

## 功能

| 领域 | 能力 | 状态 |
| --- | --- | --- |
| 本地书籍 | EPUB reflowable 阅读，含章节导航、图片、链接、书签、高亮、标注和 TTS | Available |
| 本地书籍 | TXT 和 Markdown 阅读 | Available |
| 漫画 | 本地 `.cbz` / `.zip` 漫画压缩包与兼容书源漫画阅读 | Available |
| 有声书 | 书源有声书流媒体播放器 | Available |
| 阅读模式 | 分页与滚动阅读模式 | Available |
| CJK 排版 | 直排、由右至左阅读流、CJK 标点处理与直排目录 | Available |
| 书库导入 | OPDS 目录导入 | Available |
| 同步/导入 | WebDAV 导入与同步 | Available |
| 在线阅读 | RSS / Atom feed 与原生文章阅读 | Beta |
| 在线阅读 | 网页文章转码成干净的长文本阅读内容 | Beta |
| 书源 | 用户自行提供的 Legado 兼容书源规则 | Beta |
| 渲染质量 | IDPF EPUB3 官方样本集已验证（至 Linear Algebra），MathML 渲染，EPUB regression samples 与兼容性 checklist | Available |
| EPUB 版面 | Fixed-layout EPUB prototype | Experimental |
| 无障碍 | 更完整的 VoiceOver、Dynamic Type 与触控目标改善 | Planned |

## 支持格式

| 类别 | 支持 | 说明 |
| --- | --- | --- |
| 本地书籍 | EPUB、TXT、Markdown | EPUB 支持聚焦 reflowable 书籍与 CoreText 原生渲染。 |
| 漫画压缩包 | CBZ、ZIP | 使用专属图片阅读器打开。 |
| 有声书 | M4A、M4B、MP3、FLAC、OGG、WAV、AAC、AIFF | 通过书源有声管线与本地 TTS 引擎播放。 |
| 在线订阅 | RSS、Atom | 文章会提取后在原生阅读器内阅读。 |
| 目录与同步 | OPDS、WebDAV | 从目录与 WebDAV 服务器导入书籍，并通过 WebDAV 同步。 |
| 书源规则 | Legado 兼容规则 | 只代表格式兼容；不内置第三方书源规则。 |
| 目前非主轴 | PDF、MOBI、AZW3、FB2、DOCX | 阅读刻意聚焦 iOS 原生与 CoreText，而不是跨平台全格式套件。 |

## 截图

### 书库与阅读器

阅读展示 local-first 书库、原生阅读器控制、CJK 直排、高亮标注、TTS、漫画、RSS 与导入工作流。

<p align="center">
  <img src="docs/demo/library.png" width="220" alt="阅读书库">
  <img src="docs/demo/reader-menu.png" width="220" alt="阅读器控制栏">
  <img src="docs/demo/dark-mode.png" width="220" alt="阅读深色模式">
</p>

### 阅读体验

CJK 直排、高亮、标注与 TTS 都属于原生阅读界面的一部分。

<p align="center">
  <img src="docs/screenshots/cjk-vertical.png" width="220" alt="CJK 直排阅读">
  <img src="docs/demo/highlights-annotations.png" width="220" alt="阅读高亮与标注">
  <img src="docs/demo/tts.png" width="220" alt="阅读 TTS 播放">
</p>

### 工作流

阅读也支持漫画阅读、RSS 阅读、OPDS/WebDAV 导入，以及兼容的用户自备书源工作流。

<p align="center">
  <img src="docs/demo/manga-reader.png" width="220" alt="阅读漫画阅读器">
  <img src="docs/demo/rss-reader.png" width="220" alt="阅读 RSS 阅读器">
  <img src="docs/demo/opds-webdav-import.png" width="220" alt="阅读 OPDS 与 WebDAV 导入">
</p>

<p align="center">
  <img src="docs/demo/book-source-reading.gif" width="320" alt="在线书源网文阅读演示">
</p>

## 下载

- [从 App Store 下载](https://apps.apple.com/app/id6772972358)
- [加入最新 TestFlight 测试](https://testflight.apple.com/join/7hvbzYC1)
- [支持](https://chang-jui-lin.github.io/Yuedu-reader/support.html)
- [隐私政策](https://chang-jui-lin.github.io/Yuedu-reader/privacy.html)
- [Telegram 群组](https://t.me/+ZWmmgMwwJ3JiN2Rl)

阅读目前目标系统为 iOS 18.0+。

## 路线图

### 现在

- 改善 EPUB 渲染兼容性。
- 打磨 CJK 直排阅读与目录行为。
- 增加 EPUB 渲染 bug template 与 regression samples。
- 改善 RSS 加载错误处理。

### 接下来

- 更好的网页文章转码。
- 更完整的漫画书源与阅读器手势。
- Fixed-layout EPUB prototype。

### 之后

- TestFlight 反馈循环。
- 更多无障碍工作。
- 更多自动化渲染 regression tests。

如果想贡献，可以查看标有 `help wanted` 或 `good first issue` 的 issue。

## 快速开始

开发环境需求：

- iOS 18.0+
- Xcode 16+
- Xcode 项目目前使用 Swift 5 language mode

```bash
git clone https://github.com/CHANG-JUI-LIN/Yuedu-reader.git
cd Yuedu-reader
open Yuedu-Reader.xcodeproj
```

选择 `Yuedu-Reader` scheme，构建到模拟器或真机。或直接执行：

```bash
./scripts/build.sh
```

## 故障排查

- **App Store 与 TestFlight**：App Store 是稳定版。TestFlight 会先收到较新的 build，可能包含尚未完成的行为。
- **EPUB 渲染问题**：请使用 [EPUB rendering bug template](.github/ISSUE_TEMPLATE/epub_rendering_bug.yml)。请附上阅读截图、可行的话附 Apple Books 截图、EPUB 类型/版本、章节/页面位置、预期行为与实际行为。
- **WebDAV、OPDS、RSS 或书源规则问题**：请提供 URL 或服务器类型、可见错误消息、失败操作，以及内容来源合法且由用户自行提供的确认。
- **受版权保护内容**：请勿公开上传受版权保护的书籍。建议提供最小化合成 EPUB 或已去标识的样例。

## 项目边界

阅读是阅读器引擎和应用外壳，不内置、不托管、不推荐、也不分发任何受版权保护的内容来源。

用户需要自行确保导入文件、RSS feed、网站、自定义规则、cookie、账号和生成内容符合当地法律、版权要求和网站服务条款。

本项目不接受内置盗版源、DRM 绕过、付费墙绕过、私有 token 分享、cookie 提取或反爬绕过逻辑等贡献。

Legado 兼容性只代表书源规则格式兼容；阅读不内置第三方书源规则，也不是 [Legado](https://github.com/gedoor/legado) 项目的官方关联产品。

## 架构说明

多数 EPUB 阅读器使用 WebView。阅读使用 CoreText 作为主要阅读渲染层，所以可以更精准控制分页、文字范围、高亮、TTS 同步和 CJK 直排。

阅读目前有两条 EPUB 渲染路径，它们共用同一套 CSS resolution 和 CoreText 绘制层：

- Legacy HTML attributed-string builder
- RenderableNode IR pipeline

多数贡献者在处理 UI、文档、本地化、EPUB 测试、WebDAV、RSS 或书源规则功能前，不需要先理解完整引擎。

详细内容见：

- [CoreText contributor notes](docs/coretext/README.md)
- [Architecture notes](Technotes/Architecture.md)
- [EPUB compatibility checklist](docs/epub-compatibility-checklist.md)
- [EPUB regression samples](docs/epub-regression/README.md)

## 贡献

阅读欢迎文档、截图、EPUB 测试、本地化、无障碍、WebDAV/OPDS 测试、阅读器 UI 打磨与渲染兼容性等聚焦贡献。

从这里开始：

- [Contributing guide](CONTRIBUTING.md)
- [EPUB rendering bug template](.github/ISSUE_TEMPLATE/epub_rendering_bug.yml)
- [CoreText contributor notes](docs/coretext/README.md)
- [EPUB regression samples](docs/epub-regression/README.md)
- [演示素材流程](docs/demo/README.md)

## 目录结构

```text
Modules/
├── Core/                 # EPUB/TXT/MD 解析器、CoreText 引擎、书源、RuleEngine、TTS、漫画
├── Features/             # SwiftUI 画面：书库、阅读器、RSS、书源、搜索、设置...
├── Services/             # LibraryStore、Online、WebDAV、iCloud、OPDS、Network、Account...
└── SharedUI/             # DesignSystem、Components、Extensions、Adaptive layout
Resources/                # Assets.xcassets、Assets/、en.lproj、zh-Hans.lproj、zh-Hant.lproj
Targets/Yuedu/            # SharedApp、iPhone/、iPad/ 入口
```

## 开发注意事项

- 用户字符串使用 `localized()`，更新三个 `.lproj` 文件。
- 阅读位置以内容坐标为准，不用页码。
- UI 样式使用设计 token API：`DSColor`、`DSFont`、`DSSpacing`。
- 新增或修改 View 时，尽量加入可编译的 `#Preview` 或 `PreviewProvider`。
- 新增 CSS 属性至 `ResolvedStyle` 时，同步 `RenderStyle` 字段、更新 `RenderStyle.from`，并处理两条渲染路径。
- 嵌套区块 CSS 边距通过 `inheritedBlockMarginLeft` 累加。
- 书源和规则引擎相关工作必须限定在合法、用户自行提供内容的流程。

## AI 协同开发声明

本仓库重度使用 AI 协同开发，包括代码生成、重构、文档撰写和审查辅助。项目仍会保留人工审阅与维护责任。

如果你偏好完全由人手撰写的代码，或对 AI 辅助开发有疑虑，请在使用或贡献前自行评估。

## 授权

[MIT](https://opensource.org/license/mit)。详见 [LICENSE](LICENSE)。本项目链接 [Readium](https://github.com/readium) 组件，Readium 使用 BSD 授权。
