# Yuedu

<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/AppIcon_1024_white_no_alpha.png" width="112" alt="Yuedu">
</p>

<p align="center">
  受 Apple Books 启发的开源 iOS 阅读器。
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
  <a href="https://testflight.apple.com/join/K37t7nXp">
    <img src="https://img.shields.io/badge/TestFlight-测试版-0D96F6?logo=apple&logoColor=white" alt="加入 TestFlight 测试">
  </a>
  <a href="https://iosdevweekly.com/issues/751">
    <img src="https://img.shields.io/badge/iOS%20Dev%20Weekly-%23751%20收录-FF6600" alt="获 iOS Dev Weekly #751 收录">
  </a>
  <img src="https://img.shields.io/badge/iOS-17.0%2B-000000?logo=apple&logoColor=white" alt="iOS 17.0+">
  <img src="https://img.shields.io/badge/许可证-MPL--2.0-blue" alt="MPL 2.0 许可证">
</p>

> 获 [iOS Dev Weekly #751](https://iosdevweekly.com/issues/751) 收录 —— [*From WebView to CoreText: Building a Native EPUB Reader for iOS*](https://yuedureader.com/2026/05/20/from-webview-to-coretext/)。

Yuedu 是一个专注于高品质本地与开放阅读体验的开源阅读应用。一个 App 涵盖 EPUB、Kindle 文件、PDF、漫画、有声书、RSS 与开放目录 —— 书本全程以 CoreText 原生渲染，不用 WebView。

## 功能

| | |
|:--|:--|
| **格式** | EPUB3 · MOBI／AZW3 · PDF · TXT · Markdown · CBZ 漫画 · 有声书 |
| **内容** | 本地书库 · WebDAV · OPDS · Calibre · RSS · 来源配置（Legado 格式，含视频） · 模块 · 公有领域书库（古腾堡计划、青空文库） |
| **探索** | 自己编排的探索首页 · 一次搜索书架、来源配置、远程书库与模块 · 每部作品一页作品详情 · AI 推荐 |
| **阅读** | 竖排 · 全书搜索 · 语音朗读 · 主题与主题包 · 高亮与笔记 · 书签 |
| **更多** | 阅读统计 · iCloud 同步 · 小组件 · iPad 与 iPhone 横屏 |

## 为什么用 CoreText，而非 WebView

多数阅读器把内容包进 WebView。Yuedu 每一页都以 CoreText 渲染 —— 换来精准的分页、真正的中日韩竖排、逐帧对齐的语音朗读同步，以及原生文本选择，且保持原生性能。完整来龙去脉见 [*From WebView to CoreText*](https://yuedureader.com/2026/05/20/from-webview-to-coretext/)。

## 架构

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

## 目录结构

| 目录 | 内容 |
|:--|:--|
| `Modules/` | App 源代码：`Core`（阅读引擎、解析器、规则引擎）、`Services`（书库、同步、网络）、`Features`（SwiftUI 界面）、`SharedUI`（设计系统） |
| `Targets/` | App 入口、依赖注入与 iPad 外壳 |
| `Widget/`、`ShareExtension/` | 主屏幕小组件与分享扩展 |
| `Resources/` | 素材目录、各语言字符串（`zh-Hant`、`zh-Hans`、`en`、`ja`、`ko`）与内置官方模块 |
| `Packages/` | 本地 Swift 包（`CLexbor`、`SwiftSoup`） |
| `Tests/` | 单元测试（`Tests/iOS`）、UI 测试（`Tests/iOS-UI`）与测试素材 |
| `docs/` | 使用指南、CoreText 文档、更新日志，以及测试会读取的排版语料 |
| `Technotes/` | 设计笔记与事后复盘 |
| `functions/`、`gateway/` | Firebase Cloud Functions 与账号网关；Firestore／Storage 规则在根目录 |
| `scripts/` | 模拟器、测试、本地化与目录工具 |
| `xcconfig/`、`Configuration/`、`ci_scripts/` | 构建设置、StoreKit 测试配置与 Xcode Cloud 脚本 |

## 构建

**环境要求：** Xcode 27.1 及以上 · iOS 17.0+ · Swift 6

```bash
git clone https://github.com/CHANG-JUI-LIN/Yuedu-reader.git
cd Yuedu-reader
open Yuedu-Reader.xcodeproj
```

项目需要根目录有一份 `GoogleService-Info.plist`。它不在仓库里（已加入 gitignore），没有它构建会失败：请在你自己的 Firebase 项目里添加一个 iOS App，把它的 plist 放到根目录。

然后选择模拟器（或真机）运行。自行构建的版本需要自己的签名配置与 Bundle Identifier；公开重新分发的分支版本必须使用不同的 App 名称、图标与品牌素材，且不得暗示获得官方背书。

## App Store 官方版本

源代码保持开源。App Store 版本是由项目作者维护、签名、审核、发布并提供支持的官方版本；购买费用用于支持持续开发与版本维护。

## 文档

### 使用指南

- **来源配置（Legado 格式）指南：** [简体中文总览](docs/book-source/quickstart.zh-Hans.md) · [规则语法速查](docs/book-source/rule-syntax.zh-Hans.md) · [与 Legado 的差异](docs/book-source/legado-differences.zh-Hans.md) · [常见症状对照表](docs/book-source/troubleshooting.zh-Hans.md) — 导入、五阶段验证、规则调试器、语法速查、与 Legado 的差异、症状→解法对照。
- **模块：** [模組開發文件](docs/modules/README.md)（繁体中文）— 清单、搜索、ISBN 补资料与在 App 内阅读背后的 JSON 格式。内置官方模块用的是同一种格式，也可以直接当范例看。
- **电量 SVG 模板：** [简体中文](docs/reader-overlay/BatterySVG.zh-Hans.md) · [繁體中文](docs/reader-overlay/BatterySVG.zh-Hant.md) · [English](docs/reader-overlay/BatterySVG.en.md) — 模板格式、动态标记、支持的 SVG 子集与导入故障排查。
- **更新日志：** [3.0.1](docs/release-notes/3.0.1.md) · [3.0.0](docs/release-notes/3.0.0.md)（繁体中文）

### 开发者参考

- [CoreText 文档](docs/coretext/README.md) — 阅读器架构、渲染流程、交互与竖排。
- [UI 设计规范](docs/design.md)（繁体中文）— HIG 原生布局、标题规则与 VoiceOver 检查清单。
- [EPUB 兼容性检查清单](docs/epub-compatibility-checklist.md) — 实现与回归测试检查项。
- [项目架构](Technotes/Architecture.md) — 模块、数据流与技术边界。

## 贡献

欢迎贡献 —— 约定与 PR 流程请见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

源代码采用 [Mozilla Public License 2.0](LICENSE)。Yuedu／阅读名称、App 图标、Logo、截图及其他品牌素材不包含在 MPL 许可内，详见 [TRADEMARKS.md](TRADEMARKS.md)。许可证切换前发布的版本仍适用其发布时的许可证，详见 [LICENSING.md](LICENSING.md)。
