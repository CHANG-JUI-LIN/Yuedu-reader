# 阅读

[English](README.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md)

<p align="center">
  <img src="iOS/Assets.xcassets/AppIcon.appiconset/ios_app_icon_novel_reader_1024_no_alpha.png" alt="Yuedu Reader 图标" width="128">
</p>

<p align="center">
  <strong>一个用 SwiftUI 和 CoreText 打造的 iOS 原生 EPUB/TXT 阅读器。</strong><br>
  不以 WebView 作为主阅读面。CJK 优先，重视排版，面向长篇阅读。
</p>

`阅读` 是一款 iOS 原生阅读 App，支持本地书库、在线文章、RSS 订阅、TTS 朗读与 WebDAV 同步。它的主阅读面由 CoreText 渲染，而不是交给 WebView，因此分页、连续滚动、EPUB CSS、中文竖排、CJK/拉丁混排、阅读位置恢复等能力都由应用自己的渲染管线处理。

> 目前重心：CJK 优先。中文阅读、CJK/拉丁混排、长篇小说场景为主要目标。英文 EPUB/TXT 渲染也已支持，并包含 EPUB 排版能力，例如首字放大、出版者 CSS、章节版式和目录导航。

## 展示

> 宣传仓库前建议先补截图。推荐放：
>
> - 中文竖排与行内批注
> - 英文 EPUB 首字放大
> - 目录导航
> - 阅读设置 / 主题

| 中文竖排与行内批注 | 英文 EPUB 排版 | 目录导航 |
| :---: | :---: | :---: |
| <img src="docs/screenshots/cjk-vertical.png" width="220" alt="CJK vertical writing"> | <img src="docs/screenshots/english-epub.png" width="220" alt="English EPUB typography"> | <img src="docs/screenshots/toc.png" width="220" alt="Table of contents"> |

## 渲染亮点

* **原生 CoreText 渲染**：左右翻页和连续滚动都不以 WebView 作为主阅读面。
* **CJK 竖排**：支持繁简中文竖排、CJK 标点处理、CJK/拉丁混排和长篇小说阅读。
* **复杂 CJK EPUB 处理**：已用竖排中文 EPUB 结构测试，包括行内批注、彩色注解、小字批语和大量行内来源标记。
* **英文 EPUB 排版**：支持出版者 CSS、章节标题、段落缩排、`:first-letter` 首字放大、嵌套区块边距、分隔线、字体样式层叠和目录导航。
* **稳定阅读位置**：阅读进度基于稳定内容坐标，而不是容易随排版变化漂移的临时页码。

## 为什么用 CoreText？

很多 EPUB 阅读器可以直接把排版交给 WebView。`阅读` 刻意使用 CoreText 作为主阅读面，是为了让应用直接控制分页、滚动布局、字体排版、主题、阅读位置和 CJK 特有行为。

这会让渲染器更难实现，但也让这个项目更像一个原生 iOS 阅读引擎实验，尤其适合 CJK 排版和长篇小说场景。

## 功能

- **原生 CoreText 阅读器**：左右翻页和上下滚动渲染，不用 WebView 作为主要阅读面。
- **EPUB CSS 渲染**：支持出版者 CSS，包括 `:first-letter` 首字放大、嵌套区块边距累加、`<hr>` 分隔线含 `width`/`margin`/`alignment`、`text-indent`（含负值 hanging indent）、`font-size`/`font-weight`/`font-style` 层叠，以及百分比边距/内距/宽度解析。
- **CJK 排版**：段落缩排、标点处理、行距、边距、CJK/拉丁混排、竖排支持。
- **本地书库**：导入 EPUB、TXT 及 Markdown 文本文件，支持解析、缓存、封面、书签、注解与阅读进度恢复。
- **大书处理**：已用长篇 TXT 及 EPUB 验证，含数百万字阅读流程。
- **在线阅读管线**：将用户提供的网页及规则型书源正规化为统一阅读格式。
- **Legado 兼容书源规则**：导入并执行兼容于 [Legado](https://github.com/gedoor/legado) 规则格式的用户自定义书源。
- **RSS 阅读器**：RSS/Atom 订阅、规则型内容提取、OPML 导入，以及文章渲染。
- **TTS 朗读**：本地 `AVSpeechSynthesizer` 播放及 HTTP 自定义 TTS 服务。
- **同步与备份**：WebDAV 备份、还原、书库同步与进度同步。
- **阅读器自定义**：字体、字号、行距、段落间距、边距、背景主题、翻页/滚动模式、竖排模式。

## 项目边界

Yuedu Reader 是一个阅读引擎与 App 外壳，不内置、不托管、不推荐、不分发受版权保护的内容来源。

用户有责任确保导入的文件、RSS 订阅、网站、自定义规则、Cookie、账号及生成内容符合适用法律、版权要求及网站条款。

本项目不接受内置盗版来源、DRM 破解、付费墙绕过、私密 Token 分享、Cookie 收集或反爬虫逻辑的贡献。

Legado 兼容性仅为书源规则格式兼容目标。Yuedu Reader 不捆绑第三方书源规则，与 Legado 项目无关联。

## AI 辅助开发

本仓库以重度 AI 辅助协作方式开发，包含代码生成、重构、文档与审查支持。人类审查与项目所有权仍为工作流程的一部分，但 AI 辅助代码在整个项目中是有意存在的。

若你强烈偏好严格人工编写的代码，或对 AI 辅助开发感到不适，请以此预期审视本项目。感谢理解。

## 系统需求

- iOS 18.0+
- Xcode 16+
- Swift 5 语言模式

## 快速开始

```bash
git clone https://github.com/CHANG-JUI-LIN/Yuedu-reader.git
cd Yuedu-reader
open Yuedu-Reader.xcodeproj
```

选择 `Yuedu-Reader` scheme，构建至 iOS 模拟器或实机。

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

## 目录结构

```text
iOS/
├── Models/               # 数据模型、存储、服务、渲染器、解析器
│   ├── App/              # 全局设置、设计 Token、依赖注入
│   ├── Book/             # 书籍模型、BookStore、书签、元数据
│   ├── BookSource/       # 用户书源获取
│   ├── LocalBook/        # EPUB/TXT/Markdown 导入
│   ├── Online/           # 在线阅读与网页正规化管线
│   ├── RSS/              # RSS 模型、订阅获取、解析器、文章工具
│   ├── Reader/CoreText/  # CoreText 分页、滚动布局、绘制、CSS 解析
│   ├── RuleEngine/       # CSS/XPath/Regex/JSON 规则提取
│   ├── Sync/             # WebDAV 与同步逻辑
│   └── TTS/              # 语音播放协调
├── Views/                # SwiftUI 画面与可重用 UI
│   ├── Reader/           # 阅读器表面、控件、设置、叠加层
│   ├── Bookshelf/        # 首页书架与书籍管理
│   ├── BookSource/       # 书源管理与诊断
│   ├── Online/           # 浏览器/导入流程
│   ├── RSS/              # RSS 订阅与文章画面
│   └── Settings/         # App 设置、个人资料、同步、TTS、迁移
├── ViewModels/           # ObservableObject ViewModel
├── Assets/               # 资产目录与规则引擎资源
└── *.lproj/              # 本地化：zh-Hant、zh-Hans、en

ShareExtension/           # iOS 分享扩展
Widget/                   # 主屏幕小组件
Tests/                    # 单元及 UI 测试 Target
Technotes/                # 架构笔记
scripts/                  # 本地自动化脚本
xcconfig/                 # 共享 Xcode 配置
```

## 架构笔记

- **EPUB**：Readium 组件处理 EPUB 套件解析与资源访问。出版物的 CSS（含 `@import`、`@font-face` 及链接样式表）按章节加载、处理并解析。
- **渲染管线**：两条平行路径产出 CoreText 属性字符串：
  - 旧路径：`HTMLAttributedStringBuilder.build()` → 直接 `NSAttributedString`
  - RenderableNode 路径：`HTMLStyledASTRenderableNodeConverter` → `RenderableNode` IR → `NodeAttributedStringRenderer`
  - 两者共享 `CSSParser`、CSS 解析、`ResolvedStyle` 及 `CoreTextPageView.drawLines`。任何 CSS 属性变更必须同时更新两条路径。
- **翻页 vs 滚动**：`EPUBPageRenderer` 将内容路由至 `CoreTextPageEngine`（左右翻页）或 `CoreTextScrollEngine`（连续滚动）。`CoreTextPageView` 及区块 Cell 绘制最终 CoreText 画面。
- **EPUB 目录**：阅读器目录面板优先使用 `toc.ncx`/`nav.xhtml` 条目，优于 spine 章节列表。spine 中的非目录项目（连续目录图片页、分割的后记页）会被排除。spine fallback 包含相同标题去重。
- **阅读位置**：持久位置以 `(spineIndex, charOffset)` 为准，而非页码。因为章节加载或布局变更后，页码会漂移。
- **在线内容**：`BookSourceFetcher`、`OnlineReadingPipeline`、`ModernRuleEngine` 及网页获取器将用户内容转换为正规化章节。
- **RSS**：订阅 XML 解析与规则型文章提取，和在线阅读共享相同的清理与渲染原则。
- **TTS**：播放状态与渲染分离协调，使阅读器高亮及系统媒体控件可跟随当前文本段落。
- **依赖注入**：`AppDependencies` 及 SwiftUI 环境值提供 App 服务；共享管理器集中在需要持久化或缓存所有权的位置。

更多细节：[Technotes/Architecture.md](Technotes/Architecture.md)。

## 开发规则

- 用户可见字符串使用 `localized()`，并更新三个本地化文件：
  - `iOS/zh-Hant.lproj/Localizable.strings`
  - `iOS/zh-Hans.lproj/Localizable.strings`
  - `iOS/en.lproj/Localizable.strings`
- 阅读位置以稳定内容坐标为准，勿用临时性页码。
- UI 样式使用 App 设计 Token API：`DSColor`、`DSFont`、`DSSpacing`（位于 `Models/App/DesignTokens.swift`）。
- 新建或修改 View 时，尽可能加入可编译的 SwiftUI Preview（`#Preview` 或 `PreviewProvider`）。
- 书源/规则引擎相关工作限于合法、用户提供内容的流程。
- 新增 CSS 属性至 `ResolvedStyle` 时，需同步 `RenderStyle` 对应字段、更新转换器（`RenderStyle.from`），并同时处理两条渲染路径。
- 嵌套区块 CSS 边距须通过 `inheritedBlockMarginLeft` 累加 — CoreText 使用单一 frame，父层边距不会自动叠加至子层段落缩排。

请见 [CONTRIBUTING.md](CONTRIBUTING.md) 了解贡献惯例。

## 授权

MIT。详见 [LICENSE](LICENSE)。

本项目链接 [Readium](https://github.com/readium) 组件，采用 BSD 授权。Readium 名称及标志为 Readium Foundation 商标。
。Readium 名称及标志为 Readium Foundation 商标。
