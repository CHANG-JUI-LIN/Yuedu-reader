import Foundation

struct ReaderCommentBubbleCustomStyle: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var svg: String
    /// Overall bubble size scale imported from bubble.json (`sizeScale`).
    /// Kept for reference/future use; the active scale still lives in GlobalSettings.commentBubbleScale.
    var sizeScale: Double?
    /// Text-color hex strings (e.g. `#808080`) materialized into the `${color}`
    /// SVG placeholder at render time. Both day & night, each split into a
    /// normal colour and an "emphasis" colour used when the count overflows (`99+`)
    /// or numerically reaches 100+.
    var dayEmphasisColor: String?
    var dayNormalColor: String?
    var nightEmphasisColor: String?
    var nightNormalColor: String?

    init(
        id: UUID = UUID(),
        name: String,
        svg: String,
        sizeScale: Double? = nil,
        dayEmphasisColor: String? = nil,
        dayNormalColor: String? = nil,
        nightEmphasisColor: String? = nil,
        nightNormalColor: String? = nil
    ) {
        self.id = id
        self.name = name
        self.svg = svg
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
        let normal = svg.lowercased()
        return normal.contains("${color}") || normal.contains("${num}")
    }

    /// Returns the hex color to substitute for `${color}` given the count text
    /// (`"12"`, `"99+"`, …) and whether the reader is currently in night mode.
    /// Falls back to a neutral gray when the JSON did not specify a slot.
    func resolvedColorHex(forCount count: String, isNight: Bool) -> String {
        let emphasis = Self.isEmphasisCount(count)
        if isNight {
            return (emphasis ? nightEmphasisColor : nightNormalColor) ?? "#808080"
        }
        return (emphasis ? dayEmphasisColor : dayNormalColor) ?? "#808080"
    }

    /// "Emphasis" is triggered when the displayed count overflows (`99+`, `100+`)
    /// or the numeric value reaches 100. Plain two-digit counts use the normal slot.
    static func isEmphasisCount(_ count: String) -> Bool {
        let trimmed = count.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("+") { return true }
        return (Int(trimmed) ?? 0) >= 100
    }
}

/// Schema of a "bubble.json" package file produced by external authors (a
/// wrapped SVG template with `${num}` / `${color}` placeholders and four
/// day/night × normal/emphasis text colours). Decoded into a
/// `ReaderCommentBubbleCustomStyle` for storage.
struct BubblePackageFile: Decodable {
    var name: String?
    var dirName: String?
    var dayEmphasisColor: String?
    var dayNormalColor: String?
    var nightEmphasisColor: String?
    var nightNormalColor: String?
    var sizeScale: Double?
    var svgTemplate: String?

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
            sizeScale: sizeScale,
            dayEmphasisColor: dayEmphasisColor,
            dayNormalColor: dayNormalColor,
            nightEmphasisColor: nightEmphasisColor,
            nightNormalColor: nightNormalColor
        )
    }
}

extension ReaderCommentBubbleCustomStyle {
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
        guard let matchingIndex = styles.firstIndex(where: { $0.id == style.id }) else {
            return styles + [style]
        }

        var updatedStyles = styles
        updatedStyles[matchingIndex] = style
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
