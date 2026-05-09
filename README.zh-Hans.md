# yuedu

[English](README.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md)

一个使用 SwiftUI 和 CoreText 构建的高度可定制 iOS 原生阅读器。

yuedu 专注于 CJK 中文长文本阅读体验，支持自定义排版、大体积书籍、EPUB/TXT 导入、RSS、TTS 听书、WebDAV，以及用户自定义网页内容转码。

> 状态说明：本项目是 CJK-first 阅读器。中文阅读、中文与英文/数字混排、长篇小说场景是主要目标。英文 EPUB/TXT 基本可读，但目前还不是主要测试目标。

## 主要特性

- **CJK-first 中文排版** — 针对中文长文本阅读优化，包括标点处理、段落间距、段首缩进和竖排阅读。
- **自研 CoreText 渲染器** — 支持分页和纵向滚动，不依赖 WebView 作为主要阅读界面。
- **EPUB & TXT 导入** — 支持本地书籍导入、解析、缓存和阅读位置恢复。
- **大体积书籍处理** — 已使用 1400 万字 TXT 和 800 万字 EPUB 进行测试。
- **TTS 听书** — 支持 AVSpeechSynthesizer 和基于 HTTP 的自定义 TTS 后端。
- **RSS 订阅** — 支持标准 RSS/Atom，也支持规则化内容提取。
- **WebDAV 支持** — 用于备份、恢复、书库和阅读进度同步相关流程。
- **网页内容转码** — 将用户自行提供的网页文章或小说页面转换为阅读器内部格式。
- **书签与标注** — 支持段落级书签和下划线标注持久化。
- **高度可定制阅读界面** — 字体、字号、行距、页边距、主题、分页/滚动模式和竖排模式。

## 项目边界

yuedu 是阅读器引擎和应用外壳，不内置、不托管、不推荐任何受版权保护的内容来源。

用户需要自行确保导入的文件、网页内容、RSS 订阅和自定义规则符合当地法律、版权要求和网站服务条款。

本项目不接受内置盗版源、DRM 绕过、付费墙绕过、私有 token、cookie、反爬绕过逻辑等相关贡献或请求。

## 环境要求

- iOS 18.0+
- Xcode 16.0+
- Swift 6

## 快速开始

```bash
git clone https://github.com/yuedu-reader/yuedu-app.git
cd yuedu-app
open "yuedu app.xcodeproj"
```

选择 `yuedu app` scheme，然后在模拟器或真机上构建运行。

## 项目结构

```text
yuedu app/
├── Models/               # 数据模型、存储、引擎
│   ├── App/              # 全局设置、设计 token、依赖注入
│   ├── Book/             # 书籍模型、BookStore、书签
│   ├── BookSource/       # 用户自定义来源抓取流程
│   ├── LocalBook/        # EPUB/TXT/Markdown 解析器
│   ├── Online/           # 在线阅读与网页内容转码流程
│   ├── RSS/              # RSS 模型、抓取器、解析器
│   ├── Reader/CoreText/  # CoreText 排版与分页引擎
│   ├── RuleEngine/       # CSS/XPath/Regex/JSON 规则提取
│   ├── TTS/              # 听书协调逻辑
│   └── ...               # Comic、Migration、Network、Sync、Server
├── Views/                # SwiftUI 视图
│   ├── Reader/           # 阅读器界面与控制
│   ├── Bookshelf/        # 首页书架
│   ├── BookSource/       # 来源管理
│   ├── RSS/              # RSS 订阅界面
│   ├── Settings/         # 应用设置
│   └── ...               # Search、Stats、TTS 等
├── ViewModels/           # ObservableObject ViewModel
├── Assets/               # 资源目录和规则引擎资源
└── *.lproj/              # 本地化文件（zh-Hant、zh-Hans、en）
```

## 架构说明

- **EPUB 解析**：使用 Readium 组件处理 EPUB package 解析与资源管理。
- **阅读渲染**：`EPUBPageRenderer` 根据阅读模式分发到 `CoreTextPageEngine` 或 `CoreTextScrollEngine`。页面由 `CoreTextPageView` 通过 CoreText `CTFrame` 绘制。
- **CJK 排版**：渲染器围绕中文长文本场景设计，处理 CJK 标点、段首缩进、中英混排和从右到左的竖排布局。
- **书籍来源**：`BookSourceFetcher` → `OnlineReadingPipeline` → `RuleEngine`，从用户自定义规则中提取章节与标准化内容。
- **RSS**：`RSSFetcher` 处理标准 XML feed 和基于规则的 HTML 提取。
- **TTS**：TTS 协调器将可朗读文本块映射到播放状态和阅读位置。
- **同步**：WebDAV 和账号相关服务用于备份、恢复和阅读进度同步。
- **依赖注入**：通过 `AppDependencies` 和 `@Environment` 提供服务，必要时集中管理缓存和 manager。

## 本地化

所有界面字符串都必须使用 `localized()`，不要硬编码用户可见文本。

添加本地化 key 时，需要同时更新以下三个文件：

- `zh-Hant.lproj/Localizable.strings`
- `zh-Hans.lproj/Localizable.strings`
- `en.lproj/Localizable.strings`

## 建议补充的 README 资源

正式公开 GitHub 前，建议补充：

- 书架截图
- 阅读页截图
- 排版/设置页截图
- 翻页动画 GIF
- TTS 播放 GIF 或短视频
- 导入性能测试表
- 架构图

## 贡献

详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

贡献应集中在阅读器引擎、UI、本地化、EPUB/TXT 处理、RSS、WebDAV、无障碍、测试和合法的用户自定义内容流程。

## 许可证

MIT — 见 [LICENSE](LICENSE)。

本项目链接了 [Readium](https://github.com/readium) 组件，Readium 组件使用 BSD 许可证。Readium 名称和标志是 Readium Foundation 的商标。
