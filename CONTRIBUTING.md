# Contributing to yuedu

Thanks for contributing! Here is how to get started.

## Pull Request Process

1. Fork the repo and create a feature branch from `main`.
2. Make your changes. Follow the project conventions below.
3. Build and verify locally:
   ```bash
   xcodebuild -project Yuedu-Reader.xcodeproj -scheme "yuedu app" -destination 'platform=iOS Simulator' build
   ```
4. Open a PR with a clear title and description.
5. Keep PRs focused — one logical change per PR.

## Code Conventions

- **SwiftUI views**: Use `DSColor`, `DSFont`, `DSSpacing` design tokens.
- **Localization**: Every user-facing string must use `localized("Key")`. Add the key to all three `.lproj/Localizable.strings` files.
- **Models vs Views**: Keep layout/rendering code in `Views/`. Data types and stores go in `Models/`.
- **Singletons**: Prefer dependency injection via `@Environment` and `AppDependencies`. Only use singletons for caches and shared managers.
- **File size**: Split files that exceed ~800 lines. Extract reusable components.
- **Comments**: Comment *why*, not *what*. Use `// MARK: - Section` for organization.
- **Language**: Commit messages and documentation in English. Comments may be in Chinese where domain terms are clearer.

## You do not need to know CoreText to contribute

Yuedu has several contribution areas that do not require working on the rendering engine:

- UI polish: SwiftUI screens, Settings, Library, Table of Contents, reader controls.
- Documentation: README, screenshots, usage notes, EPUB compatibility notes.
- EPUB testing: try different EPUB files and report rendering issues with screenshots.
- Localization: improve Traditional Chinese, Simplified Chinese, and English strings.
- Sync and import workflows: WebDAV, OPDS, file import, and error messages.
- Accessibility: VoiceOver labels, Dynamic Type, contrast, and larger touch targets.

CoreText-related changes are welcome, but they should be small, focused, and tested with EPUB regression samples.

## Reporting EPUB rendering bugs

Please use the [EPUB rendering bug template](.github/ISSUE_TEMPLATE/epub_rendering_bug.yml) when reporting layout issues. Include:

- Screenshot from Yuedu Reader
- Screenshot from Apple Books if possible
- EPUB version or type if known
- Chapter/page/spine location
- Expected behavior and actual behavior

Do not upload copyrighted books publicly. A minimal sample EPUB is preferred.

## Areas That Need Help

- Test coverage (unit + UI tests)
- Accessibility (VoiceOver, Dynamic Type)
- iPad multi-window and Stage Manager support
- EPUB CSS property support (shorthand margins, margin-right)
- Vertical writing improvements (selection, link interaction)
- EPUB regression samples
- EPUB rendering bug reports
- UI polish for Settings / TOC / reader controls
- Localization
- WebDAV / OPDS testing
- Documentation and screenshots

## Questions?

Open an issue or start a pull request discussion.
