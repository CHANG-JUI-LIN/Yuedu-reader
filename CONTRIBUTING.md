# Contributing to yuedu

Thanks for contributing! Here is how to get started.

## Pull Request Process

1. Fork the repo and create a feature branch from `main`.
2. Make your changes. Follow the project conventions below.
3. Build and verify locally:
   ```bash
   xcodebuild -project "yuedu app.xcodeproj" -scheme "yuedu app" -destination 'platform=iOS Simulator' build
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

## Areas That Need Help

- Test coverage (unit + UI tests)
- Accessibility (VoiceOver, Dynamic Type)
- iPad multi-window and Stage Manager support
- EPUB CSS property support (shorthand margins, margin-right)
- Vertical writing improvements (selection, link interaction)

## Questions?

Open a [discussion](https://github.com/yuedu-reader/yuedu-app/discussions).
