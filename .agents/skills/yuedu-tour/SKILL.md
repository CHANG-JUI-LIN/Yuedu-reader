---
name: yuedu-tour
description: Locate Yuedu module ownership and cross-module data flows when the relevant entry points or boundaries are unclear.
---

# Yuedu Code Tour

Use this map when code ownership or a cross-module path is unclear. A known local edit does not require a tour. Search the relevant symbol first and read only the matching reference section.

Swift sources live in `Modules/` and `Targets/`; resources in `Resources/`; regression tests in `Tests/iOS/yuedu appTests/`. File-system-synchronized Xcode groups include new Swift files automatically.

## References by Task

- [Module map](references/module-map.md): find entry points, service owners, and extension points.
- [CoreText](references/coretext.md): rendering, CSS, pagination, scrolling, and position invariants. Search for the affected property or engine; do not load all pitfalls by default.
- [Online reading](references/online-reading.md): book sources, rule extraction, and chapter flow.
- [Library services](references/library-services.md): bookshelf persistence, account sign-in, or RSS; read the matching section.
- [Localization](references/localization.md): adding or changing user-facing strings.
- [Workflows](references/workflows.md): guidance when the relevant implementation path remains unclear.

Follow repository AGENTS.md for regression testing, title modes, localization, and the single online-session path. Use CLAUDE.md's Build & Test section when actually running Xcode; resolve the toolchain and simulator with `scripts/sim.sh`, never a hardcoded device name. Known historical failures are diagnostic clues, not proof that a current failure is unrelated.

## Maintenance

This repository-local skill and its references are the canonical code tour. Global aliases and the Claude entry point link here; update this source rather than maintaining duplicated copies. Preserve task-specific evidence in the appropriate reference, not in the description or a mandatory all-task checklist.
