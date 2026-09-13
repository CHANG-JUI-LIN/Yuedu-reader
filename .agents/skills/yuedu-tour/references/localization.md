# Yuedu Localization

Paths below are relative to the repository root. Read only the section relevant to the task.

## Localization

All UI strings must use `localized()` in SwiftUI views:

```swift
Text(localized("選取"))
Label(localized("列表"), systemImage: "list.bullet")
```

Do not write raw UI strings directly inside `Text`, `Button`, `Label`, `TextField`, or similar views.

For each new UI key, update all three files:

- `Resources/zh-Hant.lproj/Localizable.strings`
- `Resources/zh-Hans.lproj/Localizable.strings`
- `Resources/en.lproj/Localizable.strings`
