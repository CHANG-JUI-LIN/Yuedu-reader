import Foundation

/// The file bytes are captured while Open In still owns security-scoped access.
/// Parsing and applying reuse the same services as the settings file pickers.
enum SharedCustomizationKind: Equatable {
    case appearanceJSON
    case nativePackage
    case qiTheme

    static func isAppearanceJSON(_ root: Any) -> Bool {
        if let object = root as? [String: Any], let format = object["format"] as? String {
            return [AppearanceThemeExportFile.formatIdentifier,
                    AppearanceThemeCollectionFile.formatIdentifier,
                    AppearanceCustomizationBundle.formatIdentifier].contains(format)
        }
        if let objects = root as? [[String: Any]], !objects.isEmpty {
            return objects.contains {
                $0["format"] as? String == AppearanceThemeExportFile.formatIdentifier
            }
        }
        return false
    }
}

struct SharedCustomizationDocument: Identifiable {
    let id = UUID()
    let data: Data
    let kind: SharedCustomizationKind
}

@MainActor
enum SharedCustomizationImportService {
    enum Plan {
        case appearance(Data)
        case reader(ReaderSettingsImportPlan)
        case qiTheme(QiThemeImport)

        /// The question to ask before anything is written, or nil when there is nothing
        /// to decide: a look only adds a theme, a theme pack's reading setup is its theme's
        /// own, and a settings file without a layout changes no more than its name says.
        @MainActor
        var prompt: CustomizationImportPrompt? {
            switch self {
            case .appearance:
                return nil
            case .reader(let plan):
                guard plan.layout != nil else { return nil }
                return .readingSettings(
                    named: plan.name,
                    parts: ReadingSetupPart.parts(in: plan.readingSettings),
                    themeName: GlobalSettings.shared.readingImportThemeName(for: plan.readingSettings.items)
                )
            case .qiTheme:
                return nil
            }
        }
    }

    static func load(_ document: SharedCustomizationDocument) async throws -> Plan {
        switch document.kind {
        case .appearanceJSON:
            return .appearance(document.data)
        case .qiTheme:
            return .qiTheme(try await QiThemeImportService.load(document.data))
        case .nativePackage:
            let payload = try await ReaderStylePackage.import(document.data, assetStore: .shared)
            if payload.kind == .appearance {
                let bundle = try payload.decode(AppearanceCustomizationBundle.self)
                guard bundle.format == AppearanceCustomizationBundle.formatIdentifier else {
                    throw AppearanceThemeImportError.invalidFile
                }
                return .appearance(payload.encodedModel)
            }
            return .reader(try ReaderSettingsImportService.plan(from: payload))
        }
    }

    /// Runs once `plan.prompt`, if any, has been answered 取代.
    static func apply(_ plan: Plan) async throws -> CustomizationImportOverview {
        let settings = GlobalSettings.shared
        switch plan {
        case .appearance(let data):
            let summary = try settings.importAppearanceCustomization(from: data)
            let selected = summary.selectedThemeID.flatMap { id in
                settings.customAppearanceThemes.first { $0.id == id }
            }
            return CustomizationImportOverview(appearance: summary, selectedTheme: selected)
        case .reader(let plan):
            try ReaderSettingsImportService.apply(plan)
            return CustomizationImportOverview(
                readingSettings: plan,
                placement: .current(for: plan.readingSettings)
            )
        case .qiTheme(let theme):
            return CustomizationImportOverview(
                qiTheme: try await QiThemeImportService.apply(theme)
            )
        }
    }
}

