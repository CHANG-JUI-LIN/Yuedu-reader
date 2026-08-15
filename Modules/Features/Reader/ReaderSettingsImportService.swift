import Foundation
import UniformTypeIdentifiers

/// What a file picked by 匯入閱讀設定 turned out to contain, before anything is
/// written. Loading and applying are separate so the header/footer overwrite can
/// be confirmed with the user *after* the file parsed and *before* it lands.
struct ReaderSettingsImportPlan {
    var layout: ReaderLayoutPreset?
    var chapterTitleStyle: ChapterTitleStyle?
    var regexHighlights: RegexHighlightConfiguration?

    /// Header/footer components and positions are hand-placed; replacing them
    /// wholesale is the one part of an import worth confirming first.
    var overwritesOverlayLayout: Bool {
        layout?.readerOverlayLayout != nil
    }

    var isEmpty: Bool {
        layout == nil && chapterTitleStyle == nil && regexHighlights == nil
    }

    var name: String? {
        layout?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ReaderSettingsImportError: LocalizedError {
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return localized("這個檔案沒有可匯入的內容。")
        }
    }
}

/// The single route every 閱讀設定 import takes — the 匯入閱讀設定 button, the
/// 正則高亮 ⋯ menu, and the older 匯入排版參數 file all land here.
///
/// Deliberately one entry point: layout parameters are parsed only by
/// `ReaderLayoutPresetImporter`, styles only by `ReaderStylePackage`. A second
/// parse route is how two files that look identical start importing differently.
@MainActor
enum ReaderSettingsImportService {
    static let readerSettingsContentTypes: [UTType] = [
        .yueduReaderStyle,
        .json,
        UTType(filenameExtension: "zip") ?? .data,
        .data,
    ]

    static let styleContentTypes: [UTType] = [.yueduReaderStyle, .json, .plainText, .data]

    /// Accepts every style file the app writes plus legado's `readConfig.json` /
    /// `.zip`. A `.yuedustyle` holding only one half (章節標題樣式 or 正則高亮) is
    /// accepted here too — the user picked it, and refusing a file we authored
    /// because it is "the wrong kind of ours" is not a useful failure.
    static func loadReaderSettings(from url: URL) async throws -> ReaderSettingsImportPlan {
        guard url.pathExtension.lowercased() == "yuedustyle" else {
            let data = try Data(contentsOf: url)
            if looksLikeChapterTitleJSON(data) {
                return ReaderSettingsImportPlan(
                    layout: nil,
                    chapterTitleStyle: try ReaderStylePackage.decodeLegacyChapterTitleJSON(data),
                    regexHighlights: nil
                )
            }
            return ReaderSettingsImportPlan(
                layout: try await ReaderLayoutPresetImporter.importPreset(from: url),
                chapterTitleStyle: nil,
                regexHighlights: nil
            )
        }

        let payload = try await ReaderStylePackage.import(
            try Data(contentsOf: url),
            assetStore: .shared
        )
        switch payload.kind {
        case .readerSettings:
            let bundle = try payload.decode(ReaderSettingsBundle.self)
            return ReaderSettingsImportPlan(
                layout: try bundle.decodedLayoutPreset(),
                chapterTitleStyle: bundle.chapterTitleStyle?.sanitized(),
                regexHighlights: bundle.regexHighlights?.sanitized()
            )
        case .chapterTitle:
            return ReaderSettingsImportPlan(
                layout: nil,
                chapterTitleStyle: try payload.decode(ChapterTitleStyle.self).sanitized(),
                regexHighlights: nil
            )
        case .regexHighlights:
            return ReaderSettingsImportPlan(
                layout: nil,
                chapterTitleStyle: nil,
                regexHighlights: try payload.decode(RegexHighlightConfiguration.self).sanitized()
            )
        case .appearance:
            throw ReaderStylePackageError.unexpectedKind(
                expected: .readerSettings,
                actual: .appearance
            )
        }
    }

    /// Both `ChapterTitleStyle` and legado's `readConfig.json` decode every field
    /// with `decodeIfPresent`, so **either** decoder accepts **any** JSON object
    /// and silently returns a full set of defaults. A bare `.json` therefore has
    /// to be told apart by the keys it carries, not by which decoder throws —
    /// otherwise importing a 章節標題樣式 file quietly resets the type size to 18pt.
    nonisolated static func looksLikeChapterTitleJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let keys = Set(object.keys)
        // Keys unique to one schema. Anything both share (there is nothing today)
        // must stay out of both sets.
        let titleKeys: Set<String> = [
            "visible", "topSpacing", "bottomSpacing", "weight", "alignment",
            "followsBodyFont", "splitEnabled", "numberRelativeSize",
            "numberFontPostScript", "nameFontPostScript",
            "advancedCSSEnabled", "lightTemplate", "darkTemplate", "design",
        ]
        let layoutKeys: Set<String> = [
            "textSize", "textBold", "lineSpacingExtra", "paragraphSpacing",
            "paddingLeft", "paddingRight", "paddingTop", "paddingBottom",
            "pageAnim", "headerMode", "readerOverlayLayout",
        ]
        return !titleKeys.isDisjoint(with: keys) && layoutKeys.isDisjoint(with: keys)
    }

    @discardableResult
    static func apply(_ plan: ReaderSettingsImportPlan) throws -> ReaderSettingsImportSummary {
        guard !plan.isEmpty else { throw ReaderSettingsImportError.emptyFile }

        var summary = ReaderSettingsImportSummary()
        if let layout = plan.layout {
            try applyLayout(layout)
            summary.appliedLayout = true
        }
        if let style = plan.chapterTitleStyle {
            ReaderConfig.shared.chapterTitleStyle = style
            summary.appliedChapterTitleStyle = true
        }
        if let highlights = plan.regexHighlights {
            GlobalSettings.shared.regexHighlightConfiguration = highlights
            summary.appliedRegexHighlights = true
        }
        return summary
    }

    private static func applyLayout(_ preset: ReaderLayoutPreset) throws {
        let settings = GlobalSettings.shared
        let readerConfig = ReaderConfig.shared

        // The overlay layout goes first and can veto the whole apply: a partial
        // import that changed the type size but silently dropped the header/footer
        // is worse than a reported failure.
        if let overlayLayout = preset.readerOverlayLayout,
           !settings.saveReaderOverlayLayout(overlayLayout) {
            throw ReaderOverlayLayoutPersistenceError.writeFailed
        }

        if let fontSize = preset.fontSize {
            readerConfig.fontSize = fontSize
        }
        if let isBold = preset.isBold {
            readerConfig.readerFontBold = isBold
        }
        if let lineHeightMultiple = preset.lineHeightMultiple {
            readerConfig.lineHeightMultiple = lineHeightMultiple
        }
        if let letterSpacing = preset.letterSpacing {
            readerConfig.letterSpacing = letterSpacing
        }
        if let paragraphSpacingMultiplier = preset.paragraphSpacingMultiplier {
            readerConfig.paragraphSpacingMultiplier = paragraphSpacingMultiplier
        }
        if let pageMarginH = preset.pageMarginH {
            readerConfig.pageMarginH = pageMarginH
        }
        if let pageMarginV = preset.pageMarginV {
            readerConfig.pageMarginV = pageMarginV
        }
        if let titleVisible = preset.titleVisible {
            settings.readerTitleVisible = titleVisible
        }
        if let titleSize = preset.titleSize {
            settings.readerTitleSize = Double(titleSize)
        }
        if let titleTopSpacing = preset.titleTopSpacing {
            settings.readerTitleTopSpacing = Double(titleTopSpacing)
        }
        if let titleBottomSpacing = preset.titleBottomSpacing {
            settings.readerTitleBottomSpacing = Double(titleBottomSpacing)
        }
        if let scrollMode = preset.scrollMode {
            settings.scrollMode = scrollMode
        }
        if let pageTurnStyle = preset.pageTurnStyle, preset.scrollMode != true {
            settings.pageTurnStyle = pageTurnStyle
        }
    }
}

enum ReaderOverlayLayoutPersistenceError: LocalizedError {
    case writeFailed

    var errorDescription: String? {
        localized("無法儲存頁首頁尾設定")
    }
}

/// The cheap main-actor value read a 匯出閱讀設定 archive is built from — no
/// encoding and no disk I/O, because `ShareLink` menu/list content is rebuilt on
/// every layout pass. `ReaderSettingsExportPayload` does the work in its
/// transfer closure, where a failure can surface instead of being swallowed.
struct ReaderSettingsExportInputs: Sendable {
    var layout: ReaderLayoutSnapshot
    var chapterTitleStyle: ChapterTitleStyle
    var regexHighlights: RegexHighlightConfiguration

    func makeBundle() throws -> ReaderSettingsBundle {
        ReaderSettingsBundle(
            layoutConfig: try ReaderLayoutPresetExporter.encode(layout),
            chapterTitleStyle: chapterTitleStyle,
            regexHighlights: regexHighlights
        )
    }
}

@MainActor
enum ReaderSettingsExportSnapshot {
    static func make() -> ReaderSettingsExportInputs {
        let settings = GlobalSettings.shared
        let readerConfig = ReaderConfig.shared
        let style = readerConfig.chapterTitleStyle
        let snapshot = ReaderLayoutSnapshot(
            name: localized("閱讀設定"),
            fontSize: readerConfig.fontSize,
            isBold: readerConfig.readerFontBold,
            lineHeightMultiple: readerConfig.lineHeightMultiple,
            letterSpacing: readerConfig.letterSpacing,
            paragraphSpacingMultiplier: readerConfig.paragraphSpacingMultiplier,
            pageMarginH: readerConfig.pageMarginH,
            pageMarginV: readerConfig.pageMarginV,
            footerBottomPadding: readerConfig.footerBottomPadding,
            footerTextGap: readerConfig.footerTextGap,
            titleVisible: style.visible,
            titleSize: style.size,
            titleTopSpacing: style.topSpacing,
            titleBottomSpacing: style.bottomSpacing,
            pageTurnStyle: settings.pageTurnStyle,
            scrollMode: settings.scrollMode,
            readerOverlayLayout: settings.readerOverlayLayout
        )
        return ReaderSettingsExportInputs(
            layout: snapshot,
            chapterTitleStyle: style,
            regexHighlights: settings.regexHighlightConfiguration
        )
    }
}
