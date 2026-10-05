---
name: yuedu-ios-design
description: Use when creating, reviewing, or modifying Yuedu user-facing SwiftUI views, screens, sheets, toolbars, lists, settings, reader overlays, dialogs, or localized UI.
---

# Yuedu iOS Design

Apply these guardrails to every user-facing SwiftUI change. Read the repo-root `docs/design.md` before substantial design work; it is the detailed source of rationale, examples, page archetypes, and review guidance.

## Required Context

Consult only the context needed for the change:

- `docs/design.md`: the matching section for substantial design work or an unresolved convention.
- `Modules/SharedUI/DesignSystem/DesignTokens.swift`: the relevant token definitions when changing styling.
- `Resources/*.lproj/Localizable.strings` (zh-Hant, zh-Hans, en, ja, ko): search the affected keys when changing user-visible text. Do not read any of these files in full.

## Decision Order

Resolve conflicts in this order: **Apple platform behavior and accessibility > explicit Yuedu conventions > contextual recommendations**. Yuedu preferences are product conventions, not universal Apple HIG rules.

## Hard Rules

1. Title mode: only the main root screens get a large title, always via `rootTabTitle(_:onScroll:)` — 探索, RSS, 設定 and 搜索 pass `.minimizesBar`, so on iOS 27 the native bar — title and buttons together — slides away and the native search field rises into its place — (a leading toolbar-item title that looks the same from iOS 17 on; the system `.inlineLarge` is only a small centred title on an iOS 17 iPhone). Main roots = the tab roots: `HomeView` (書架), `ExploreHomeView` (探索), `RSSListView` (RSS), `SettingsView` (設定), and the 搜索 tab's `SearchView(isTabRoot: true)`. Everything else — pushed details, sheets, overlays, reader surfaces — uses `.inline`. Never use `.automatic`, `.large`, or `.inlineLarge`.
2. Route every user-visible string through `localized("...")` and keep every `Resources/*.lproj` synchronized: zh-Hant, zh-Hans, en, ja, ko. Text iOS shows from `Info.plist`, such as a permission prompt, goes in each language's `InfoPlist.strings`.
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
13. Section footers: all section-level explanatory notes, hints, and limits must use native `Section { ... } footer: { Text(...) }` with `.dsSectionFooter()` (Apple HIG standard 13pt Footnote + `DSColor.textSecondary`). Never hand-roll explanatory notes as standard rows inside a Section, subtitle text inside a `Toggle`'s `VStack`, or standalone empty-content Sections.
14. **A footer earns its place or it does not exist.** Write one only for what the reader cannot work out from the control itself: a cost, a risk, a side effect, a non-obvious precondition, or where the data came from. If the label already says it, there is no footer — 「重新整理名單」 needs no paragraph explaining that it rebuilds the list. Aim for one sentence; two is the ceiling. Do not restate the button, narrate the implementation, or explain a feature's rationale. Before adding one, ask what the reader would get wrong without it; if the answer is "nothing", delete it.
15. Settings rows use `SettingsRows` (`Modules/SharedUI/Components/SettingsRows.swift`): wrap native controls with `SettingsRowLabel` / `SettingsValueLabel` / `SettingsSliderRow` / `SettingsLockedRow` so every row on a page shares one icon size, colour and alignment. A pushed page's title matches its row's name. zh-Hant wording: 匯入/匯出, 自訂, 介面, 儲存, 重設, 閱讀背景, 頁首頁尾, 全域 — see `docs/design.md` §4.

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
- Using `rootTabTitle(_:onScroll:)` outside the main root screens, or any `.inlineLarge` (an iOS 17 iPhone draws it as `.inline`).
- Hand-rolled rows, toolbars, or controls (`ScrollView` + `VStack` lists, custom switches/pickers/dialogs) where a native component exists.
- Over-decorated cards (22pt+ corner radii, decorative gradients/borders, custom dividers), full-screen blocking spinners, or `minimumScaleFactor` text-shrinking to save layout.
- Visual effects or controls that harm reader legibility.

## Verification

Run:

```bash
ruby scripts/check_localizations.rb
git diff --check
grep -rn -E "toolbarTitleDisplayMode\(\.(automatic|large|inlineLarge)\)|navigationBarTitleDisplayMode\(\.(automatic|large)\)|rootTabTitle\(" Modules Targets --include="*.swift"
```

The grep flags every `.automatic` / `.large` / `.inlineLarge` use, and every `rootTabTitle(` use; only the whitelisted main roots (`HomeView`, `ExploreHomeView`, `RSSListView`, `SettingsView`, and `BookSearchView`'s tab-root branch) and its own definition in `RootTabTitle.swift` may use `rootTabTitle(_:onScroll:)`.

For code changes, run the directly relevant regression required by AGENTS.md. Reuse results for unchanged code and environment; the static checks above do not replace that regression.

## Maintenance

Update `.claude/skills/yuedu-ios-design/SKILL.md`, `.agents/skills/yuedu-ios-design/SKILL.md`, and `docs/design.md` together. Keep detailed rationale and examples in `docs/design.md`; keep both skill files concise and byte-identical.
