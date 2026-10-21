# Yuedu

<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/AppIcon_1024_white_no_alpha.png" width="112" alt="Yuedu">
</p>

<p align="center">
  受 Apple Books 启发、源代码公开的 iOS 阅读器。
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
    <img src="https://img.shields.io/badge/TestFlight-测试版-0D96F6?logo=apple&logoColor=white" alt="加入 TestFlight 测试">
  </a>
  <a href="https://iosdevweekly.com/issues/751">
    <img src="https://img.shields.io/badge/iOS%20Dev%20Weekly-%23751%20收录-FF6600" alt="获 iOS Dev Weekly #751 收录">
  </a>
  <img src="https://img.shields.io/badge/iOS-17.0%2B-000000?logo=apple&logoColor=white" alt="iOS 17.0+">
  <img src="https://img.shields.io/badge/许可证-PolyForm%20Strict%201.0.0-blue" alt="PolyForm Strict 1.0.0 许可证">
</p>

> 获 [iOS Dev Weekly #751](https://iosdevweekly.com/issues/751) 收录 —— [*From WebView to CoreText: Building a Native EPUB Reader for iOS*](https://chang-jui-lin.github.io/Yuedu-reader/2026/05/20/from-webview-to-coretext/)。

Yuedu 是一个专注于高品质本地与开放阅读体验、源代码公开的阅读应用。一个 App 涵盖 EPUB3、漫画、有声书、RSS 与开放目录 —— 全程以 CoreText 原生渲染，无 WebView。

## 功能

| | |
|:--|:--|
| **格式** | EPUB3 · TXT · CBZ 漫画 · 有声书 · PDF *(开发中)* |
| **内容** | 本地书库 · WebDAV · OPDS · RSS · 内容源 |
| **阅读** | 直排竖排 · 主题 · 标注 · 书签 |
| **更多** | 阅读统计 · iCloud 同步 |

## 为什么用 CoreText，而非 WebView

多数阅读器把内容包进 WebView。Yuedu 每一页都以 CoreText 渲染 —— 换来精准的分页、真正的中日韩竖排、逐帧对齐的语音朗读同步，以及原生文本选择，且保持原生性能。完整来龙去脉见 [*From WebView to CoreText*](https://chang-jui-lin.github.io/Yuedu-reader/2026/05/20/from-webview-to-coretext/)。

## 架构

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

## 构建

**环境要求：** Xcode 16+ · iOS 17.0+ · Swift 6.0

```bash
git clone https://github.com/CHANG-JUI-LIN/Yuedu-reader.git
cd Yuedu-reader
open Yuedu-Reader.xcodeproj
```

然后选择模拟器（或真机）运行。自行构建的版本需要自己的签名配置与 Bundle Identifier，且仅限个人非商业使用：许可证不允许分发构建版本或修改后的版本，详见[许可证](#许可证)。

## App Store 官方版本

源代码保持公开。App Store 版本是由项目作者维护、签名、审核、发布并提供支持的官方版本；购买费用用于支持持续开发与版本维护。

## 文档

### 使用指南

- **来源配置（Legado 格式）指南：** [简体中文总览](docs/book-source/quickstart.zh-Hans.md) · [规则语法速查](docs/book-source/rule-syntax.zh-Hans.md) · [与 Legado 的差异](docs/book-source/legado-differences.zh-Hans.md) · [常见症状对照表](docs/book-source/troubleshooting.zh-Hans.md) — 导入、五阶段验证、规则调试器、语法速查、与 Legado 的差异、症状→解法对照。
- **电量 SVG 模板：** [简体中文](docs/reader-overlay/BatterySVG.zh-Hans.md) · [繁體中文](docs/reader-overlay/BatterySVG.zh-Hant.md) · [English](docs/reader-overlay/BatterySVG.en.md) — 模板格式、动态标记、支持的 SVG 子集与导入故障排查。

### 开发者参考

- [CoreText 文档](docs/coretext/README.md) — 阅读器架构、渲染流程、交互与竖排。
- [EPUB 兼容性检查清单](docs/epub-compatibility-checklist.md) — 实现与回归测试检查项。
- [项目架构](Technotes/Architecture.md) — 模块、数据流与技术边界。

## 贡献

欢迎贡献 —— 约定与 PR 流程请见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

源代码以 [PolyForm Strict License 1.0.0](LICENSE) 公开：可以阅读，也可以为个人非商业用途自行构建，但不得分发，也不得发布修改后的版本。这不是开源许可证。Yuedu／阅读名称、App 图标、Logo、截图及其他品牌素材不在源代码许可范围内，详见 [TRADEMARKS.md](TRADEMARKS.md)。每次许可证变更前发布的版本仍适用其发布时的许可证（先是 MIT，后为 MPL-2.0），详见 [LICENSING.md](LICENSING.md)。
