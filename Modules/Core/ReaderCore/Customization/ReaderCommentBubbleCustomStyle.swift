import Foundation

struct ReaderCommentBubbleCustomStyle: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var svg: String
    /// The style's voice version, for a paragraph with a spoken comment: the same `${color}` /
    /// `__TEXT__` conventions as `svg`. Nil draws `svg` with a sound wave under its count.
    var voiceSVG: String?
    /// Last local edit time, stamped by `ReaderCommentBubbleCustomStyleLibrary.upserting`.
    /// Drives the iCloud last-write-wins merge clock (`updatedAt` in the sync
    /// record); nil for styles that predate the sync feature (old UserDefaults
    /// payloads decode with a missing key) — they fall back to distantPast.
    var updatedAt: Date?
    /// Overall bubble size scale imported from bubble.json (`sizeScale`).
    /// Kept for reference/future use; the active scale still lives in GlobalSettings.commentBubbleScale.
    var sizeScale: Double?
    /// Text-color hex strings (e.g. `#808080`) materialized into the `${color}`
    /// SVG placeholder at render time. Both day & night, each split into a
    /// normal colour and an "emphasis" colour for a paragraph the site marks hot.
    var dayEmphasisColor: String?
    var dayNormalColor: String?
    var nightEmphasisColor: String?
    var nightNormalColor: String?

    init(
        id: UUID = UUID(),
        name: String,
        svg: String,
        voiceSVG: String? = nil,
        updatedAt: Date? = nil,
        sizeScale: Double? = nil,
        dayEmphasisColor: String? = nil,
        dayNormalColor: String? = nil,
        nightEmphasisColor: String? = nil,
        nightNormalColor: String? = nil
    ) {
        self.id = id
        self.name = name
        self.svg = svg
        self.voiceSVG = voiceSVG
        self.updatedAt = updatedAt
        self.sizeScale = sizeScale
        self.dayEmphasisColor = dayEmphasisColor
        self.dayNormalColor = dayNormalColor
        self.nightEmphasisColor = nightEmphasisColor
        self.nightNormalColor = nightNormalColor
    }

    /// Whether this style was imported from a bubble.json definition (carries
    /// the `${color}` / `${num}` placeholder convention) and therefore benefits
    /// from color materialization at render time.
    var usesColorTemplate: Bool {
        [svg, voiceSVG ?? ""].contains { template in
            let normal = template.lowercased()
            return normal.contains("${color}") || normal.contains("${num}")
        }
    }

    /// The slot colour for a bubble, or nil when the style left that slot empty — for a
    /// QiReader `__TEXT__` style that means "follow the reading theme" (`AUTO`).
    ///
    /// The emphasis slot is for a paragraph the site marks hot, never for a count's size
    /// (maintainer 2026-11-17: 分色 follows what the site marks).
    func slotColorHex(isHot: Bool, isNight: Bool) -> String? {
        if isNight {
            return isHot ? nightEmphasisColor : nightNormalColor
        }
        return isHot ? dayEmphasisColor : dayNormalColor
    }
}

/// Schema of a "bubble.json" package file produced by external authors (a
/// wrapped SVG template with `${num}` / `${color}` placeholders and four
/// day/night × normal/emphasis text colours). Decoded into a
/// `ReaderCommentBubbleCustomStyle` for storage.
struct BubblePackageFile: Codable {
    var name: String?
    var dirName: String?
    var dayEmphasisColor: String?
    var dayNormalColor: String?
    var nightEmphasisColor: String?
    var nightNormalColor: String?
    var sizeScale: Double?
    var svgTemplate: String?
    /// The style's voice version (`ReaderCommentBubbleCustomStyle.voiceSVG`); Yuedu's own key.
    var voiceSvgTemplate: String?

    /// Builds a custom style from the package, taking the SVG template verbatim
    /// (placeholders preserved so the renderer can substitute `${color}` per
    /// theme and `${num}` per paragraph).
    func makeStyle(id: UUID = UUID()) -> ReaderCommentBubbleCustomStyle? {
        guard let svg = svgTemplate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !svg.isEmpty else {
            return nil
        }
        let resolvedName = (name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            ? (dirName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
                ? "自訂 SVG"
                : dirName!)
            : name!
        return ReaderCommentBubbleCustomStyle(
            id: id,
            name: resolvedName,
            svg: svg,
            voiceSVG: voiceSvgTemplate.flatMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            },
            sizeScale: sizeScale,
            dayEmphasisColor: dayEmphasisColor,
            dayNormalColor: dayNormalColor,
            nightEmphasisColor: nightEmphasisColor,
            nightNormalColor: nightNormalColor
        )
    }
}

extension BubblePackageFile {
    /// The package a custom style exports as — what `makeStyle` reads back, colours and
    /// size included, which a bare `.svg` cannot carry.
    init(style: ReaderCommentBubbleCustomStyle) {
        self.init(
            name: style.name,
            dirName: nil,
            dayEmphasisColor: style.dayEmphasisColor,
            dayNormalColor: style.dayNormalColor,
            nightEmphasisColor: style.nightEmphasisColor,
            nightNormalColor: style.nightNormalColor,
            sizeScale: style.sizeScale,
            svgTemplate: style.svg,
            voiceSvgTemplate: style.voiceSVG
        )
    }
}

extension ReaderCommentBubbleCustomStyle {
    /// Whether the style carries anything a bare `.svg` would lose on export.
    var needsPackageToExport: Bool {
        usesColorTemplate
            || [dayEmphasisColor, dayNormalColor, nightEmphasisColor, nightNormalColor].contains { $0 != nil }
            || sizeScale != nil
            || voiceSVG != nil
    }

    /// Attempts to parse a `bubble.json` package from raw file contents.
    /// Returns nil when the contents are not valid JSON or are missing the
    /// required `svgTemplate` field. (Plain `.svg` content falls through to
    /// the regular import path.)
    static func fromBubblePackage(_ data: Data) -> ReaderCommentBubbleCustomStyle? {
        guard let pkg = try? JSONDecoder().decode(BubblePackageFile.self, from: data) else {
            return nil
        }
        return pkg.makeStyle()
    }
}

enum ReaderCommentBubbleCustomStyleLibrary {
    enum V2DecodingResult: Equatable {
        case missing
        case valid([ReaderCommentBubbleCustomStyle])
        case invalid
    }

    static func decodeV2(
        keyExists: Bool,
        data: Data?
    ) -> V2DecodingResult {
        guard keyExists else { return .missing }
        guard let data,
              let styles = try? JSONDecoder().decode(
                  [ReaderCommentBubbleCustomStyle].self,
                  from: data
              ) else {
            return .invalid
        }
        return .valid(styles)
    }

    static func uniqued(
        _ styles: [ReaderCommentBubbleCustomStyle]
    ) -> [ReaderCommentBubbleCustomStyle] {
        var seenIDs = Set<UUID>()
        return styles.filter { seenIDs.insert($0.id).inserted }
    }

    static func validatedSelectedID(
        _ selectedID: UUID?,
        in styles: [ReaderCommentBubbleCustomStyle]
    ) -> UUID? {
        guard let selectedID,
              styles.contains(where: { $0.id == selectedID }) else {
            return nil
        }
        return selectedID
    }

    static func upserting(
        _ style: ReaderCommentBubbleCustomStyle,
        into styles: [ReaderCommentBubbleCustomStyle]
    ) -> [ReaderCommentBubbleCustomStyle] {
        // Every upsert is a local edit: stamp the iCloud merge clock so the
        // edited style outranks older copies on other devices.
        var stamped = style
        stamped.updatedAt = Date()
        guard let matchingIndex = styles.firstIndex(where: { $0.id == style.id }) else {
            return styles + [stamped]
        }

        var updatedStyles = styles
        updatedStyles[matchingIndex] = stamped
        return updatedStyles
    }

    static func deleting(
        id: UUID,
        from styles: [ReaderCommentBubbleCustomStyle]
    ) -> [ReaderCommentBubbleCustomStyle] {
        styles.filter { $0.id != id }
    }

    static func migratingLegacyStyleIfNeeded(
        in savedStyles: [ReaderCommentBubbleCustomStyle],
        legacySVG: String,
        generatedPlaceholderSVG: String,
        migratedName: String,
        migratedID: UUID = UUID()
    ) -> [ReaderCommentBubbleCustomStyle] {
        guard savedStyles.isEmpty else { return savedStyles }

        let trimmedLegacySVG = legacySVG.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLegacySVG.isEmpty else { return savedStyles }

        let trimmedPlaceholderSVG = generatedPlaceholderSVG.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLegacySVG != trimmedPlaceholderSVG else { return savedStyles }

        return [
            ReaderCommentBubbleCustomStyle(
                id: migratedID,
                name: migratedName,
                svg: trimmedLegacySVG
            )
        ]
    }
}

/// The iCloud-synced part of the bubble *selection* (which custom style is
/// active). Synced as ONE always-present last-write-wins record (`modifiedAt`
/// advances only when the user actually changes the selection — see
/// `GlobalSettings.commentBubbleSelectionSyncClock`). "Cleared" is a nil
/// `selectedCustomStyleID` value, never an absent record, so the sync merge
/// cannot mistake a nil selection for a deletion and tombstone the constant
/// record id with a `now` timestamp (which would kill a newer selection picked
/// on another device). Scale / follow-source toggles stay per-device display
/// preferences and are deliberately excluded.
struct ReaderCommentBubbleSyncSelection: Codable, Equatable {
    var selectedCustomStyleID: UUID?
    var modifiedAt: Date?
}
