# Yuedu

<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/AppIcon_1024_white_no_alpha.png" width="112" alt="Yuedu">
</p>

<p align="center">
  Premium native reading, without ecosystem lock-in.
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

> **Your books. Your sources. Your reading experience.** Yuedu is a native iOS reader for local files, open catalogs, self-hosted libraries, feeds, and user-chosen content sources.

> Featured in [iOS Dev Weekly #751](https://iosdevweekly.com/issues/751) — [*From WebView to CoreText: Building a Native EPUB Reader for iOS*](https://chang-jui-lin.github.io/Yuedu-reader/2026/05/20/from-webview-to-coretext/).

## OpenAI Build Week 2026

During Build Week, Codex with GPT-5.6 helped turn the official IDPF EPUB 3 Samples into a reproducible compatibility program for Yuedu's production CoreText reader.

| Capture | Production revision | Official smoke result |
|:--|:--|:--|
| Before | `build-week-baseline` / `dd62d80` | 29 passed · 14 failed · 0 skipped |
| After | `df45d95` | **43 passed · 0 failed · 0 skipped** |

The corpus contains 42 official sample EPUBs and 43 designated checks. Passing them is bounded compatibility evidence, not a claim of complete EPUB 3 support.

- [Compatibility matrix](docs/build-week/epub3/compatibility-matrix.md)
- [Seven before/after evidence packages](docs/build-week/epub3/evidence/)
- [Reproducible corpus harness](docs/build-week/epub3/README.md)

Yuedu is an open-source reading application focused on a high-quality local and open reading experience. One app for EPUB3, comics, audiobooks, RSS, and open catalogs — rendered natively with CoreText, no WebView.

## Features

| | |
|:--|:--|
| **Formats** | EPUB3 · TXT · CBZ Comics · Audiobook · PDF *(WIP)* |
| **Content** | Local Library · WebDAV · OPDS · RSS · Content Sources |
| **Reading** | Vertical Writing · Themes · Annotation · Bookmarks |
| **More** | Reading Statistics · iCloud Sync |

## What changed during Build Week

- Built a checksum-pinned manifest, safe batch downloader, structural scanner, and opt-in production-pipeline smoke suite for all official downloadable samples.
- Fixed non-ASCII EPUB resource IRIs and reliable table-of-contents navigation.
- Routed mixed-layout spine items correctly and restored fixed-layout resource and direct-image pages.
- Improved MathML attachment sizing, baseline alignment, raster clarity, fallback safety, and complex table handling.
- Added language-aware English hyphenation, soft-hyphen handling, and eligible line justification.
- Preserved authored static fallback text when controls-less media cannot surface a native player.

Every claimed repair links a minimal synthetic fixture, focused automated test, implementation commit, matrix row, and before/after evidence package.

## Existing capabilities, not Build Week additions

Yuedu already had its native CoreText reader and support for EPUB CFI, MathML conversion, Ruby, fixed layout, Media Overlay, audio/video, RTL/Bidi, PLS/SSML, vertical writing, TTS synchronization, and text selection before the event baseline. Build Week hardened selected compatibility paths; it did not create those capabilities from scratch.

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

## How Codex and GPT-5.6 accelerated the work

Codex helped inspect the native reader pipeline, design the official-sample harness, rank observed failures, reduce each production defect into a small EPUB fixture, and work through red-green regression tests. It also drove exact before/after capture, result-bundle verification, and consistency checks across the manifest, evidence packages, commits, and compatibility matrix.

The implementation stayed in the production renderer. No demo-only renderer or committed copy of the official EPUB corpus was introduced.

## Reproduce the Build Week results

Validate and download the checksum-pinned external corpus:

```bash
python3 scripts/epub3_samples.py manifest-check
python3 scripts/epub3_samples.py fetch
python3 scripts/epub3_samples.py scan
python3 scripts/epub3_samples.py matrix-check
```

Run the focused regression suites for the seven evidenced repair families:

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj \
  -scheme 'Yuedu-Reader' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/ReaderTOCSelectionTimingTests' \
  -only-testing:'yuedu appTests/EPUBResourceIRITests' \
  -only-testing:'yuedu appTests/EPUBMixedLayoutRoutingTests' \
  -only-testing:'yuedu appTests/EPUBFixedImageSpineTests' \
  -only-testing:'yuedu appTests/MathMLBaselineTests' \
  -only-testing:'yuedu appTests/EnglishEPUBTypographyTests' \
  -only-testing:'yuedu appTests/EPUBMediaFallbackTests' \
  -parallel-testing-enabled NO
```

Run all 42 official samples through the dedicated production-pipeline suite:

```bash
ROOT=$(git rev-parse --show-toplevel)
TEST_RUNNER_YUEDU_RUN_EPUB3_CORPUS=1 \
TEST_RUNNER_YUEDU_EPUB3_CORPUS_DIR="$ROOT/.build-week/epub3-samples/books" \
xcodebuild test -project Yuedu-Reader.xcodeproj \
  -scheme 'Yuedu-Reader EPUB3 Corpus' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'IDPFEPUB3CorpusTests/IDPFEPUB3SampleSmokeTests' \
  -parallel-testing-enabled NO
```

The downloaded EPUB files and generated results remain under the Git-ignored `.build-week/` directory.

## Build

**Requirements:** Xcode 16+ · iOS 18.0+ · Swift 6.0

```bash
git clone https://github.com/CHANG-JUI-LIN/Yuedu-reader.git
cd Yuedu-reader
open Yuedu-Reader.xcodeproj
```

Then select a simulator (or your device) and run.

## Documentation

### User guides

- **Battery SVG templates:** [English](docs/reader-overlay/BatterySVG.en.md) · [简体中文](docs/reader-overlay/BatterySVG.zh-Hans.md) · [繁體中文](docs/reader-overlay/BatterySVG.zh-Hant.md) — template format, dynamic markers, supported SVG subset, and import troubleshooting.

### Developer reference

- [CoreText documentation](docs/coretext/README.md) — reader architecture, rendering pipeline, interaction, and vertical writing.
- [EPUB compatibility checklist](docs/epub-compatibility-checklist.md) — implementation and regression checklist.
- [Project architecture](Technotes/Architecture.md) — modules, data flow, and technical boundaries.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for conventions and the PR process.

## License

[MIT](LICENSE).
