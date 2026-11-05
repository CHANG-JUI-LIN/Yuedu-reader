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
  <a href="https://testflight.apple.com/join/K37t7nXp">
    <img src="https://img.shields.io/badge/TestFlight-Beta-0D96F6?logo=apple&logoColor=white" alt="Join the TestFlight beta">
  </a>
  <a href="https://iosdevweekly.com/issues/751">
    <img src="https://img.shields.io/badge/Featured%20in-iOS%20Dev%20Weekly%20%23751-FF6600" alt="Featured in iOS Dev Weekly #751">
  </a>
  <img src="https://img.shields.io/badge/iOS-17.0%2B-000000?logo=apple&logoColor=white" alt="iOS 17.0+">
  <img src="https://img.shields.io/badge/license-MPL--2.0-blue" alt="MPL 2.0 License">
</p>

> Featured in [iOS Dev Weekly #751](https://iosdevweekly.com/issues/751) — [*From WebView to CoreText: Building a Native EPUB Reader for iOS*](https://yuedureader.com/2026/05/20/from-webview-to-coretext/).

Yuedu is an open-source reading application focused on a high-quality local and open reading experience. One app for EPUB, Kindle files, PDF, comics, audiobooks, RSS, and open catalogs — books are rendered natively with CoreText, not in a WebView.

## Features

| | |
|:--|:--|
| **Formats** | EPUB3 · MOBI / AZW3 · PDF · TXT · Markdown · CBZ comics · Audiobooks |
| **Content** | Local library · WebDAV · OPDS · Calibre · RSS · Sources (Legado format, including video) · Modules · Public-domain libraries (Project Gutenberg, Aozora Bunko) |
| **Discover** | An Explore home you arrange yourself · One search across your shelf, sources, remote libraries and modules · A Book Details page for every work · AI Picks |
| **Reading** | Vertical writing · Full-book search · Text-to-speech · Themes and theme packs · Highlights and notes · Bookmarks |
| **More** | Reading statistics · iCloud sync · Widgets · iPad and iPhone landscape |

## Why CoreText, not WebView

Most readers wrap content in a WebView. Yuedu renders every page with CoreText, which gives precise pagination, true CJK vertical writing, frame-accurate text-to-speech sync, and native text selection — at native performance. The full story is in [*From WebView to CoreText*](https://yuedureader.com/2026/05/20/from-webview-to-coretext/).

## Architecture

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

## Repository layout

| Folder | Contents |
|:--|:--|
| `Modules/` | App source: `Core` (reader engine, parsers, rule engine), `Services` (library, sync, network), `Features` (SwiftUI screens), `SharedUI` (design system) |
| `Targets/` | App entry point, dependency setup, and the iPad shell |
| `Widget/`, `ShareExtension/` | Home Screen widget and share extension |
| `Resources/` | Asset catalog, localized strings (`zh-Hant`, `zh-Hans`, `en`, `ja`, `ko`), and the bundled official modules |
| `Packages/` | Local Swift packages (`CLexbor`, `SwiftSoup`) |
| `Tests/` | Unit tests (`Tests/iOS`), UI tests (`Tests/iOS-UI`), and their fixtures |
| `docs/` | User guides, CoreText docs, release notes, and the layout corpora the tests read |
| `Technotes/` | Design notes and post-mortems |
| `functions/`, `gateway/` | Firebase Cloud Functions and the account gateway; Firestore and Storage rules sit at the root |
| `scripts/` | Simulator, test, localization, and catalog tooling |
| `xcconfig/`, `Configuration/`, `ci_scripts/` | Build settings, the StoreKit test configuration, and the Xcode Cloud script |

## Build

**Requirements:** Xcode 27.1 or later · iOS 17.0+ · Swift 6

```bash
git clone https://github.com/CHANG-JUI-LIN/Yuedu-reader.git
cd Yuedu-reader
open Yuedu-Reader.xcodeproj
```

The project expects a `GoogleService-Info.plist` at the repository root. It is not in the repository (it is gitignored), and the build stops without it: add an iOS app to your own Firebase project and put its plist there.

Then select a simulator (or your device) and run. Self-built versions need their own signing configuration and bundle identifier. Publicly redistributed forks must use distinct app names, icons, and branding and must not imply official endorsement.

## Official App Store build

The source code is open source. The App Store version is the official build maintained, signed, reviewed, distributed, and supported by the project owner. Its purchase price supports ongoing development and release maintenance.

## Documentation

### User guides

- **Sources (Legado format):** [Guide index](docs/book-source/README.md) · [常见症状对照表](docs/book-source/troubleshooting.zh-Hans.md) — import, five-stage validation, rule debugger, syntax cheat sheet, differences from Legado, and symptom→fix troubleshooting.
- **Modules:** [模組開發文件](docs/modules/README.md) (Traditional Chinese) — the JSON format behind lists, search, ISBN lookup, and in-app reading. The built-in official modules use the same format, so they double as examples.
- **Battery SVG templates:** [English](docs/reader-overlay/BatterySVG.en.md) · [简体中文](docs/reader-overlay/BatterySVG.zh-Hans.md) · [繁體中文](docs/reader-overlay/BatterySVG.zh-Hant.md) — template format, dynamic markers, supported SVG subset, and import troubleshooting.
- **Release notes:** [3.0.1](docs/release-notes/3.0.1.md) · [3.0.0](docs/release-notes/3.0.0.md) (Traditional Chinese).

### Developer reference

- [CoreText documentation](docs/coretext/README.md) — reader architecture, rendering pipeline, interaction, and vertical writing.
- [UI design guidelines](docs/design.md) (Traditional Chinese) — HIG-native layout, title rules, and the VoiceOver checklist.
- [EPUB compatibility checklist](docs/epub-compatibility-checklist.md) — implementation and regression checklist.
- [Project architecture](Technotes/Architecture.md) — modules, data flow, and technical boundaries.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for conventions and the PR process.

## License

Source code is licensed under the [Mozilla Public License 2.0](LICENSE). The Yuedu name, app icon, logo, screenshots, and other brand assets are not licensed under the MPL; see [TRADEMARKS.md](TRADEMARKS.md). Versions released before the license transition remain available under the license that applied when they were published; see [LICENSING.md](LICENSING.md).
