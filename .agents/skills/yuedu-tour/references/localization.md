# Yuedu Localization

Paths below are relative to the repository root. Read only the section relevant to the task.

## Localization

All UI strings must use `localized()` in SwiftUI views:

```swift
Text(localized("選取"))
Label(localized("列表"), systemImage: "list.bullet")
```

Do not write raw UI strings directly inside `Text`, `Button`, `Label`, `TextField`, or similar views.

For each new UI key, update `Localizable.strings` in every language folder:

- `Resources/zh-Hant.lproj/Localizable.strings` (development region)
- `Resources/zh-Hans.lproj/Localizable.strings`
- `Resources/en.lproj/Localizable.strings`
- `Resources/ja.lproj/Localizable.strings`
- `Resources/ko.lproj/Localizable.strings`

Text that iOS reads from `Info.plist`, such as permission prompts (`NSPhotoLibraryAddUsageDescription`) and UTType descriptions, is localized in each language's `InfoPlist.strings` under the same rule. A language missing one of its keys shows the unlocalized `Info.plist` value. The share extension keeps its own `Localizable.strings` and `InfoPlist.strings` under `ShareExtension/*.lproj`.

`Resources/en.lproj/Localizable.stringsdict` adds English plural forms. The other languages read the same for any number, so they have no `.stringsdict`.

Verify with `ruby scripts/check_localizations.rb` (macOS only; it parses with `plutil`). It compares the keys of every `.strings` table across the `.lproj` folders in `Resources` and `ShareExtension`, and fails when the keys differ or a language lacks a table.
