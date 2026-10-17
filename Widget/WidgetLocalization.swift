import Foundation

/// Looks `key` up in this extension's own `Widget/<language>.lproj/Localizable.strings`.
///
/// The widget extension is a separate bundle that syncs only `Widget/`, so the app's
/// `localized()` and `Resources/*.lproj` are out of its reach; it carries its own tables, the
/// way `ShareExtension` does. `Bundle.main` here is the `.appex`, which is where those tables
/// land. Keys are the zh-Hant text, as in the app, and a key with more than one argument uses
/// positional placeholders (`%1$@`) so a language can reorder them:
/// `String(format: localized("…%1$@…%2$d…"), title, count)`.
///
/// `scripts/check_localizations.rb` checks that every literal key passed here exists in
/// `Widget/zh-Hant.lproj/Localizable.strings` and that the five tables agree.
func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
