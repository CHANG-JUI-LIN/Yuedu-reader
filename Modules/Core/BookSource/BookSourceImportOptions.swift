import Foundation

// MARK: - BookSourceImportOptions

/// What to keep from the local copy when an import overwrites a source the library
/// already has, plus an optional destination group — Legado's import-dialog menu
/// (保留原名 / 保留分組 / 保留啟用狀態 / 分組) expressed as one value.
///
/// A source's name, group and enabled flags are things the *user* sets locally; the
/// pack author's JSON carries their own values for all three. Overwriting silently
/// resets them, which is why upstream makes each one a switch rather than a policy.
struct BookSourceImportOptions: Equatable {
    /// Keep the local `bookSourceName` instead of the incoming one.
    var keepName: Bool = false
    /// Keep the local `bookSourceGroup`. Applied before `groupName`, so 附加分組
    /// adds onto the restored local groups.
    var keepGroup: Bool = false
    /// Keep the local `enabled` and `enabledExplore`.
    var keepEnable: Bool = false
    /// Keep the local `customOrder`, so an update does not throw the source back to
    /// wherever the pack author happened to place it in their own list.
    var keepCustomOrder: Bool = false
    /// A group to file the imported sources under. `nil`/blank leaves grouping alone.
    var groupName: String?
    /// `true` adds `groupName` to the source's existing groups; `false` replaces them.
    var addsToExistingGroups: Bool = false

    /// Straight overwrite with everything the JSON declares — what a whole-pack restore
    /// wants, and the behaviour every import path had before the confirmation list existed.
    static let direct = BookSourceImportOptions()

    /// The defaults a manual import through the confirmation list starts from: local
    /// ordering survives an update, mirroring upstream, which always carries `customOrder`
    /// over. The three keep-switches stay off, as they do upstream.
    static let manualDefaults = BookSourceImportOptions(keepCustomOrder: true)

    /// Whether anything here needs the local copy at all.
    var needsLocalCopy: Bool {
        keepName || keepGroup || keepEnable || keepCustomOrder
    }

    var trimmedGroupName: String? {
        guard let groupName else { return nil }
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - BookSourceImportRoute

/// Which import screen confirmed a write. It names the write in the disk-write tally
/// (`import.share`, `import.deeplink`, …) and in the import breadcrumb, so a library rewrite
/// seen in a field log says where it came from.
enum BookSourceImportRoute: String, Sendable {
    /// No confirmation list: `importFromJSON` / `importFromData`, which only tests call.
    case direct
    /// 來源配置管理's own importers: 本地導入, 網路導入, 粘貼源.
    case manage
    /// A `yuedu://import/…` or `legado://import/…` link, from another app or a source's
    /// `java.openUrl`.
    case deepLink = "deeplink"
    /// A file or link handed over by the Share Extension or Open In.
    case shared = "share"
    /// An import link tapped on a page inside a source's own browser.
    case sourcePage = "sourcepage"
}

// MARK: - Applying options

extension BookSourceImportOptions {
    /// Folds the local copy's user-owned fields into the incoming source, then files it
    /// under `groupName`. Called by `BookSourceStore` at the point where both copies are
    /// in hand, so there is one place that decides what an overwrite preserves.
    func merged(incoming: BookSource, local: BookSource?) -> BookSource {
        var source = incoming
        if let local {
            if keepName {
                source.bookSourceName = local.bookSourceName
            }
            if keepGroup {
                source.bookSourceGroup = local.bookSourceGroup
            }
            if keepEnable {
                source.enabled = local.enabled
                source.enabledExplore = local.enabledExplore
            }
            if keepCustomOrder {
                source.customOrder = local.customOrder
            }
        }
        if let group = trimmedGroupName {
            if addsToExistingGroups {
                source.bookSourceGroup = Self.groupsByAdding(group, to: source.bookSourceGroup)
            } else {
                source.bookSourceGroup = group
            }
        }
        return source
    }

    /// Adds one group to a Legado group string, keeping order and dropping duplicates.
    /// Legado splits groups on `,`, `;`, `，`, `；` and whitespace runs
    /// (`AppPattern.splitGroupRegex`) and rejoins with `,`.
    static func groupsByAdding(_ group: String, to existing: String) -> String {
        var names: [String] = []
        var seen = Set<String>()
        for name in splitGroups(existing) where !seen.contains(name) {
            seen.insert(name)
            names.append(name)
        }
        if !seen.contains(group) {
            names.append(group)
        }
        return names.joined(separator: ",")
    }

    /// Splits a Legado group string into its individual group names.
    static func splitGroups(_ raw: String) -> [String] {
        raw.split(whereSeparator: { separator in
            separator == "," || separator == ";" || separator == "，" || separator == "；"
                || separator.isWhitespace
        })
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
}

// MARK: - BookSource: ImportableSource

extension BookSource: ImportableSource {
    var importDisplayName: String {
        bookSourceName.isEmpty ? bookSourceUrl : bookSourceName
    }

    var importIdentityKey: String { bookSourceUrl }

    var importUpdateClock: Int64 { lastUpdateTime }

    var importComment: String? {
        bookSourceComment.isEmpty ? nil : bookSourceComment
    }

    /// The per-row editor shows the same Legado-shaped JSON that 複製書源 JSON produces —
    /// `CodingKeys` already spell the upstream field names, so encoding is the round trip.
    var importEditableJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    static func importParse(editedJSON: String) -> BookSource? {
        // One decode path: the same parser every importer uses, so an edited row cannot
        // accept JSON the real import would reject.
        guard let parsed = BookSourceStore.parseSources(editedJSON)?.first,
              !parsed.bookSourceUrl.isEmpty else {
            return nil
        }
        return parsed
    }
}
