import Foundation

/// Every `ReaderStyleAssetStore` image a reader-style value points at.
///
/// One place for the whole app: 章節標題樣式, 正則高亮 and 整套閱讀設定 all export
/// through `ReaderStylePackage`, which packs exactly the asset IDs it is handed.
/// A caller that computes its own list and misses a reference ships a package
/// that imports as a rule with a blank background — which is why this is a
/// single shared computation rather than a per-screen one.
enum ReaderStyleAssetReferences {
    static func assetIDs(in layer: ChapterTitleLayer) -> [UUID] {
        var values: [UUID] = []
        if case let .image(id) = layer.content { values.append(id) }
        for style in [layer.lightStyle, layer.darkStyle] {
            if let id = style.imagePresentation?.assetID { values.append(id) }
            if let id = style.ruleStyle.decoration.backgroundImage?.assetID {
                values.append(id)
            }
        }
        return ordered(values)
    }

    static func assetIDs(in design: ChapterTitleDesign) -> [UUID] {
        ordered(design.layers.flatMap(assetIDs(in:)))
    }

    static func assetIDs(in style: ChapterTitleStyle) -> [UUID] {
        guard let design = style.design else { return [] }
        return assetIDs(in: design)
    }

    static func assetIDs(in rule: RegexHighlightRule) -> [UUID] {
        ordered(
            [
                rule.lightStyle.decoration.backgroundImage?.assetID,
                rule.darkStyle.decoration.backgroundImage?.assetID,
            ].compactMap { $0 }
        )
    }

    static func assetIDs(in configuration: RegexHighlightConfiguration) -> [UUID] {
        ordered(configuration.evaluationRules.flatMap(assetIDs(in:)))
    }

    static func assetIDs(in style: ReaderDialogueBubbleStyle) -> [UUID] {
        ordered(ReaderDialogueBubbleSide.allCases.flatMap { side -> [UUID] in
            let sideStyle = style.side(side)
            return [sideStyle.skin?.assetID, sideStyle.avatar?.assetID].compactMap { $0 }
        })
    }

    /// Every picture a reading setup shows. iCloud carries the setup as settings that name
    /// their pictures by ID, so these go along as files (`ICloudSyncManager`).
    static func assetIDs(in settings: AppearanceThemeReadingSettings) -> [UUID] {
        var values: [UUID] = []
        if let chapterTitleStyle = settings.chapterTitleStyle {
            values += assetIDs(in: chapterTitleStyle)
        }
        if let dialogueBubbleStyle = settings.dialogueBubbleStyle {
            values += assetIDs(in: dialogueBubbleStyle)
        }
        if let regexHighlights = settings.regexHighlights {
            values += assetIDs(in: regexHighlights)
        }
        return ordered(values)
    }

    /// De-duplicated but stable: `Set` iteration order changes between runs, and
    /// an export whose manifest reshuffles on every save produces a different
    /// archive for identical settings.
    private static func ordered(_ values: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return values.filter { seen.insert($0).inserted }
    }
}
