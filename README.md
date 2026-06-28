# Yuedu

<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/AppIcon_1024_white_no_alpha.png" width="112" alt="Yuedu">
</p>

<p align="center">
  Apple Books-inspired open-source reader for iOS.
</p>

<p align="center">
  <a href="README.zh-Hans.md">简体中文</a> ·
  <a href="README.zh-Hant.md">繁體中文</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6772972358">
    <img src="https://img.shields.io/badge/App%20Store-Download-0D96F6?logo=apple&logoColor=white" alt="Download on the App Store">
  </a>
  <a href="https://testflight.apple.com/join/7hvbzYC1">
    <img src="https://img.shields.io/badge/TestFlight-Beta-0D96F6?logo=apple&logoColor=white" alt="Join the TestFlight beta">
  </a>
  <a href="https://iosdevweekly.com/issues/751">
    <img src="https://img.shields.io/badge/Featured%20in-iOS%20Dev%20Weekly%20%23751-FF6600" alt="Featured in iOS Dev Weekly #751">
  </a>
  <img src="https://img.shields.io/badge/iOS-18.0%2B-000000?logo=apple&logoColor=white" alt="iOS 18.0+">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License">
</p>

> Featured in [iOS Dev Weekly #751](https://iosdevweekly.com/issues/751) — [*From WebView to CoreText: Building a Native EPUB Reader for iOS*](https://chang-jui-lin.github.io/Yuedu-reader/2026/05/20/from-webview-to-coretext/).

Yuedu is an open-source reading application focused on a high-quality local and open reading experience. One app for EPUB3, comics, audiobooks, RSS, and open catalogs — rendered natively with CoreText, no WebView.

## Features

| | |
|:--|:--|
| **Formats** | EPUB3 · TXT · CBZ Comics · Audiobook · PDF *(WIP)* |
| **Content** | Local Library · WebDAV · OPDS · RSS · Content Sources |
| **Reading** | Vertical Writing · Themes · Annotation · Bookmarks |
| **More** | Reading Statistics · iCloud Sync |

## Why CoreText, not WebView

Most readers wrap content in a WebView. Yuedu renders every page with CoreText, which gives precise pagination, true CJK vertical writing, frame-accurate text-to-speech sync, and native text selection — at native performance. The full story is in [*From WebView to CoreText*](https://chang-jui-lin.github.io/Yuedu-reader/2026/05/20/from-webview-to-coretext/).

## Architecture

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

## Build

**Requirements:** Xcode 16+ · iOS 18.0+ · Swift 6.0

```bash
git clone https://github.com/CHANG-JUI-LIN/Yuedu-reader.git
cd Yuedu-reader
open Yuedu-Reader.xcodeproj
```

Then select a simulator (or your device) and run.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for conventions and the PR process.

## License

[MIT](LICENSE).
