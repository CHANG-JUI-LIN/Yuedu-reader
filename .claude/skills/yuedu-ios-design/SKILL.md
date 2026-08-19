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

1. Title mode: only the main root screens get `.inlineLarge`, always via `toolbarTitleDisplayModeInlineLargeOrInline()` (iOS 18+ shows `.inlineLarge`, iOS 17 falls back to `.inline`). Main roots = Tab roots currently using it: `HomeView` (書架), `ExploreHomeView` (探索), `RSSListView` (RSS), `SettingsView` (設定). Everything else — pushed details, sheets, overlays, reader surfaces — uses `.inline`. Never use `.automatic`, `.large`, or a bare `.toolbarTitleDisplayMode(.inlineLarge)`.
2. Route every user-visible string through `localized("...")` and keep zh-Hant, zh-Hans, and en synchronized.
3. Use `DS*` tokens for colors, semantic fonts, spacing, layout, radius, and animation. Add a missing token before use; avoid magic values. Only system-backed color and semantic font tokens adapt automatically. Validate fixed-size font and animation tokens with the Dynamic Type and Reduce Motion patterns in `docs/design.md`.
4. Use native components; do not re-implement them. Use `NavigationStack`, `TabView`, `NavigationSplitView`, `List`/`Form` with `Section`, `Toggle`, `Picker`, `Stepper`, `NavigationLink`, `.sheet`, `Menu`, `ToolbarItem`, `contextMenu`, `swipeActions`, `searchable`, `confirmationDialog`, and `alert`. Never hand-roll List/Form rows with `ScrollView` + `VStack`/`HStack`, custom toolbars or button bars, custom switches, pickers, or dialogs. Exclusive choices use one selected value (`Picker`), not several independent toggles; a `Toggle` keeps its built-in label instead of `.labelsHidden()` on a hand-rolled `HStack`.
5. Prefer SF Symbols. Every icon-only control needs a localized `accessibilityLabel`.
6. Use official size terms: 44×44pt is the default control size. A 28×28pt minimum is only for genuinely compact controls with sufficient spacing; it does not relax the general hit region. Reader chrome and primary actions remain at least 44×44pt.
7. Support Dynamic Type through accessibility sizes, logical VoiceOver order and announced outcomes, Light/Dark and Increase Contrast, Reduce Motion, and state cues that do not rely on color alone.
8. Every data-backed screen needs empty, loading, and error states (prefer `ContentUnavailableView` for empty on iOS 17+); long-running tasks (TTS, downloads, sync) also handle offline, slow-network, permission-denied, and interruption/resume.
9. Protect reading comfort: decoration, density, transparency, motion, and backgrounds must not reduce body-text legibility.
10. Attach accessibility modifiers to the element itself, never to a container. `.accessibilityLabel`/`.accessibilityHint` on an `HStack`/`VStack` propagates to every child element, so a row of buttons ends up sharing one name; label each `Button` separately. Decorative `Image(systemName:)` needs `.accessibilityHidden(true)` — SF Symbols are focusable by default and speak their raw symbol name. A `Slider` needs its own `.accessibilityLabel` and `.accessibilityValue`, reusing the computed property behind the value shown on screen. See `docs/design.md` §7.1 for the shipped bugs behind each of these.
11. Preserve background continuity in themed `List`/`Form` screens. `.scrollContentBackground(.hidden)` hides only the scroll container background, not row backgrounds. When a page background should remain continuous, give every row/section `.listRowBackground(Color.clear)`; when rows intentionally need contrast, use an explicit `DSColor.surface*` token. Never leave accidental system-white rows against a themed page background. Check content, empty, loading, and error rows. Every surface must visibly differ from its background.
12. Ask permissions in context at the moment of need, never at launch, with an explanation screen first and a designed denied path. Use `alert`/`confirmationDialog` only for critical decisions (2 buttons preferred, max 3). Every custom gesture needs a visible button/menu alternative; never intercept system gestures (edge-swipe back, notifications/Control Center pull-downs).

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
- Using `.inlineLarge` outside the main root screens, or a bare `.toolbarTitleDisplayMode(.inlineLarge)` (no iOS 17 fallback).
- Hand-rolled rows, toolbars, or controls (`ScrollView` + `VStack` lists, custom switches/pickers/dialogs) where a native component exists.
- Over-decorated cards (22pt+ corner radii, decorative gradients/borders, custom dividers), full-screen blocking spinners, or `minimumScaleFactor` text-shrinking to save layout.
- Visual effects or controls that harm reader legibility.

## Verification

Run:

```bash
ruby scripts/check_localizations.rb
git diff --check
grep -rn -E "toolbarTitleDisplayMode\(\.(automatic|large|inlineLarge)\)|toolbarTitleDisplayModeInlineLarge\(\)|toolbarTitleDisplayModeInlineLargeOrInline\(\)" Modules Targets --include="*.swift"
```

The grep flags every `.automatic` / `.large` / bare `.inlineLarge` / old-helper use, and every root-helper use; only the whitelisted main roots (`HomeView`, `ExploreHomeView`, `RSSListView`, `SettingsView`) may use `toolbarTitleDisplayModeInlineLargeOrInline()`.

For code changes, also run the smallest reliable build or test for the touched area.

## Maintenance

Update `.claude/skills/yuedu-ios-design/SKILL.md`, `.agents/skills/yuedu-ios-design/SKILL.md`, and `docs/design.md` together. Keep detailed rationale and examples in `docs/design.md`; keep both skill files concise and byte-identical.
