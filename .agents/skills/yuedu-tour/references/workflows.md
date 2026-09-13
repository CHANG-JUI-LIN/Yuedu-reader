# Yuedu Workflows

Paths below are relative to the repository root. Read only the section relevant to the task.

## Workflows

### New Feature

1. Locate the feature area and entry files.
2. Search for an existing protocol, registry, store method, feature flag, or dependency injection point.
3. Read one or two nearby implementations and match the local style.
4. Implement through the existing extension point. Add a new abstraction only when the current ones cannot represent the behavior.

### Bug Fix

1. Search the exact error text, function name, notification, or state property.
2. Trace the call chain backward to the state owner.
3. Reproduce or inspect the broken invariant before changing code.
4. For CoreText reading-position bugs, verify whether the issue is caused by using `globalPage` as identity instead of `(spineIndex, charOffset)`.

### UI Change

1. Locate the view.
2. Follow `@EnvironmentObject`, `@ObservedObject`, `@State`, and bindings back to their model owner.
3. Use existing `DesignTokens` and localization patterns.
4. Add all localization keys immediately.

### CoreText Change

1. Read the relevant CoreText pitfalls above.
2. Preserve the margin, layout invalidation, and reading-position identity flows.
3. Verify both paged and scroll modes when the touched code can affect both.
