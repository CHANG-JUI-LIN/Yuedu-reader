---
name: yuedu-ios-design
description: Use when creating, reviewing, or modifying Yuedu user-facing SwiftUI views, screens, sheets, toolbars, lists, settings, reader overlays, dialogs, or localized UI.
---

# Yuedu iOS Design

Apply these guardrails to every user-facing SwiftUI change. Read the repo-root `docs/design.md` before substantial design work; it is the detailed source of rationale, examples, page archetypes, and review guidance.

## Required Context

From the repository root, consult:

- `docs/design.md` for the complete design specification.
- `Modules/SharedUI/DesignSystem/DesignTokens.swift` for `DSColor`, `DSFont`, `DSSpacing`, `DSLayout`, `DSRadius`, and `DSAnimation`.
- `Resources/zh-Hant.lproj/Localizable.strings`, `Resources/zh-Hans.lproj/Localizable.strings`, and `Resources/en.lproj/Localizable.strings` for user-visible text.

## Decision Order

Resolve conflicts in this order: **Apple platform behavior and accessibility > explicit Yuedu conventions > contextual recommendations**. Yuedu preferences are product conventions, not universal Apple HIG rules.

## Hard Rules

1. Choose title mode by context:
   - Top-level scrolling destinations: `.automatic` or `.large`.
   - Pushed details and sheets: `.inline`.
   - Reader and immersive surfaces: context-specific.
   - `.inlineLarge` is a deliberate Yuedu exception only; justify it and accept its toolbar overflow behavior after testing available width and localization.
2. Route every user-visible string through `localized("...")` and keep zh-Hant, zh-Hans, and en synchronized.
3. Use `DS*` tokens for colors, semantic fonts, spacing, layout, radius, and animation. Add a missing token before use; avoid magic values. Only system-backed color and semantic font tokens adapt automatically. Validate fixed-size font and animation tokens with the Dynamic Type and Reduce Motion patterns in `docs/design.md`.
4. Prefer native `NavigationStack`, `TabView`, `NavigationSplitView`, `List`, `Form`, `Sheet`, `Menu`, `Picker`, `ToolbarItem`, `contextMenu`, `swipeActions`, and `searchable` behavior.
5. Prefer SF Symbols. Every icon-only control needs a localized `accessibilityLabel`.
6. Use official size terms: 44×44pt is the default control size. A 28×28pt minimum is only for genuinely compact controls with sufficient spacing; it does not relax the general hit region. Reader chrome and primary actions remain at least 44×44pt.
7. Support Dynamic Type through accessibility sizes, logical VoiceOver order and announced outcomes, Light/Dark and Increase Contrast, Reduce Motion, and state cues that do not rely on color alone.
8. Every data-backed screen needs empty, loading, and error states.
9. Protect reading comfort: decoration, density, transparency, motion, and backgrounds must not reduce body-text legibility.

## Sheet Rules

- Put Cancel or Close leading; dismiss without saving unconfirmed changes.
- Put Done, or a clearer task-specific alternative, trailing; save or complete the task.
- Use Back only for internal sheet navigation; it must not dismiss the sheet.
- Never show Back, Cancel/Close, and Done together at one hierarchy level.
- Visible Yuedu modal chrome uses `xmark` and `checkmark` with localized accessibility labels.
- Alerts and confirmation dialogs keep textual cancel actions.

## Avoid

- Dashboard, landing-page, Tailwind-like, dense web-form, or novelty-first UI.
- Hard-coded styling, text, fixed font sizes, animation durations, or magic layout values.
- Treating `.inlineLarge` as a universal default.
- Visual effects or controls that harm reader legibility.

## Verification

Run:

```bash
ruby scripts/check_localizations.rb
git diff --check
```

For code changes, also run the smallest reliable build or test for the touched area.

## Maintenance

Update `.claude/skills/yuedu-ios-design/SKILL.md`, `.agents/skills/yuedu-ios-design/SKILL.md`, and `docs/design.md` together. Keep detailed rationale and examples in `docs/design.md`; keep both skill files concise and byte-identical.
