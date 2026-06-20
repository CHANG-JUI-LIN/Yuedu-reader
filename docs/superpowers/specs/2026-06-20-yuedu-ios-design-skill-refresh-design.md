# Yuedu iOS Design Skill Refresh

Date: 2026-06-20
Status: Approved design, pending implementation plan

## Objective

Refresh Yuedu's iOS design guidance using current Apple Human Interface Guidelines and SwiftUI documentation, while preserving explicit Yuedu product conventions. Keep the Claude and Codex skill entry points synchronized and use `docs/design.md` as the detailed source of truth.

## Scope

Update these files together:

- `.claude/skills/yuedu-ios-design/SKILL.md`
- `.agents/skills/yuedu-ios-design/SKILL.md`
- `docs/design.md`

The work changes design guidance only. It does not perform a repository-wide SwiftUI migration, change application behavior, add lint infrastructure, or modify `DesignTokens.swift`.

## Source Hierarchy

Rules must identify their authority instead of presenting every preference as Apple guidance:

1. **Apple requirement or platform behavior**: supported directly by Apple HIG or SwiftUI documentation.
2. **Yuedu convention**: a deliberate product-level choice that may be stricter than Apple guidance.
3. **Contextual recommendation**: a default that can change when the screen's task or platform context requires it.

When these conflict, Apple platform behavior and accessibility requirements take priority. Yuedu conventions remain binding only when they do not contradict platform behavior.

## Documentation Architecture

### Skill entry points

Both `SKILL.md` files will contain the same compact operational rules:

- when the skill applies;
- required files to inspect before editing UI;
- authority labels and decision order;
- nonnegotiable localization, token, accessibility, native-component, and reading-comfort rules;
- a presentation-context matrix for titles and modal controls;
- required verification commands;
- a maintenance instruction requiring all three documents to remain aligned.

The entry points must not duplicate the full rationale or extensive SwiftUI examples from `docs/design.md`.

### Detailed design guide

`docs/design.md` remains the progressive-disclosure source of truth. It will contain:

- source links and the authority model;
- navigation and presentation matrices;
- toolbar action placement and overflow considerations;
- accessibility and adaptive-layout rules;
- page archetypes and reader-specific constraints;
- implementation examples and a review checklist.

## Required Rule Corrections

### Titles and navigation

Replace the universal `.inlineLarge` rule with a context-based matrix:

| Context | Default | Notes |
| --- | --- | --- |
| Top-level scrollable library or browsing surface | `.automatic` or `.large` | Use when a collapsing large title improves orientation. |
| Pushed detail or focused task | `.inline` | Preserves navigation hierarchy and toolbar space. |
| Modal sheet | `.inline` | Keeps modal actions and title compact. |
| Reader chrome or transient overlay | Context-specific, usually no large title | Reading content remains primary. |
| Deliberate persistent large title | `.inlineLarge` | Yuedu exception; use only after checking that moving leading or centered toolbar items into overflow is acceptable. |

The guide must state that `.inlineLarge` is a SwiftUI behavior, not a universal Apple HIG recommendation. It must accurately document that this mode displays a large title inside the toolbar and can move leading or centered toolbar items into overflow.

### Sheets and modal actions

Document these semantics:

- Cancel or Close dismisses without saving and belongs on the leading edge for a single-view sheet.
- Done completes or explicitly saves and belongs on the trailing edge.
- A Done action needs a Cancel/Close alternative, or Back in a multistep flow.
- Back navigates within a sheet and does not dismiss it.
- Avoid presenting Cancel, Done, and Back simultaneously.
- Use standard system symbols for visible close and confirmation affordances when their meaning remains clear; preserve localized accessibility labels.
- Keep textual cancel roles in alerts and confirmation dialogs unless that system presentation calls for another standard treatment.

### Control sizing and spacing

Replace “every hit target must be at least 44×44 pt” with current Apple terminology:

- Target 44×44 pt as the default iOS/iPadOS control size.
- Treat 28×28 pt as the platform minimum only in genuinely compact contexts.
- Compensate compact controls with sufficient spacing and verify them with touch and accessibility testing.
- Continue to prefer 44×44 pt for reader chrome and primary actions.

### Typography and Dynamic Type

Require semantic text styles and verify the largest accessibility sizes. At large sizes:

- avoid truncating useful text in scrollable content;
- move horizontally crowded metadata into stacked layouts;
- reduce grid columns when necessary;
- ensure custom reader fonts respond to text-size and Bold Text settings;
- keep symbols visually aligned and scaling with adjacent text.

### Accessibility and motion

Retain VoiceOver labels, non-color-only status communication, and light/dark contrast checks. Add explicit checks for:

- Increase Contrast;
- Reduce Motion and reduced repetitive, zooming, or scaling animation;
- decorative-element hiding and sensible accessibility grouping;
- localized VoiceOver reading order and action outcomes.

### Adaptive layout

Require layouts to respond to measured window context rather than device names. Cover:

- safe areas, system margins, and system bars;
- portrait, landscape, iPad window resizing, and split layouts;
- multiple localizations and text sizes;
- delaying compact-layout switches until the regular layout no longer fits;
- system navigation containers such as adaptive `TabView` and `NavigationSplitView` instead of custom sidebars.

### Native component and visual guidance

Preserve native SwiftUI components, semantic colors, SF Symbols, design tokens, localization, empty/loading/error states, and reading-first behavior. Do not import the third-party example's card shadows, fixed type sizes, hard-coded padding, or dashboard-oriented patterns as general Yuedu rules.

## Verification

Implementation must verify:

1. The two `SKILL.md` files express the same rules and point to the repository-root `docs/design.md` correctly.
2. No contradictory universal title-mode or 44×44-minimum statements remain.
3. Every Apple-derived statement has a direct Apple documentation link in `docs/design.md`.
4. Markdown links and referenced repository paths resolve.
5. `rg` checks cover stale phrases such as universal `.inlineLarge`, “minimum 44×44”, and missing sheet distinctions.
6. `git diff --check` passes.

No application build is required because this scope changes Markdown only.

## Acceptance Criteria

- Claude and Codex load equivalent, concise operational guidance.
- `docs/design.md` clearly distinguishes Apple requirements, SwiftUI behavior, Yuedu conventions, and contextual defaults.
- Title, sheet, control-size, accessibility, Dynamic Type, and adaptive-layout guidance reflects the cited Apple documentation.
- The rules remain specific to a mature native reading app and do not encourage web-dashboard styling.
- Existing unrelated working-tree changes remain untouched and are not included in the documentation commit.

## Primary Apple References

- [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [`toolbarTitleDisplayMode(_:)`](https://developer.apple.com/documentation/swiftui/view/toolbartitledisplaymode(_:))
- [`ToolbarTitleDisplayMode.inlineLarge`](https://developer.apple.com/documentation/swiftui/toolbartitledisplaymode/inlinelarge)
