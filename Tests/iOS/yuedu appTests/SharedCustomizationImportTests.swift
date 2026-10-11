import Foundation
import Testing
import UniformTypeIdentifiers
@testable import yuedu_app

@Suite("Shared theme and style imports", .serialized)
@MainActor
struct SharedCustomizationImportTests {
    @Test("Native, QiReader and Reeden packages advertise the system Open In entry", arguments: ["yuedustyle", "qitheme", "red"])
    func registration(ext: String) throws {
        let type = try #require(UTType(filenameExtension: ext))
        #expect(!type.isDynamic)
        let declarations = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let identifiers = declarations.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        #expect(identifiers.contains(type.identifier))
    }

    @Test("Every exported theme JSON shape opens and applies as a theme", arguments: ["single", "collection", "array", "bundle"])
    func themeJSON(shape: String) async throws {
        let file = AppearanceThemeExportFile(customTheme: theme())
        let data: Data
        switch shape {
        case "single": data = try JSONEncoder().encode(file)
        case "collection": data = try JSONEncoder().encode(AppearanceThemeCollectionFile(themes: [file]))
        case "array": data = try JSONEncoder().encode([file])
        default: data = try JSONEncoder().encode(AppearanceCustomizationBundle(snapshot: .init(themes: [theme()])))
        }
        let document = try await receive(data, extension: "json")
        #expect(document.kind == .appearanceJSON)
        try await applyAppearance(document)
    }

    @Test("All four native package kinds reach their existing importer", arguments: [
        ReaderStylePackageKind.appearance, .chapterTitle, .regexHighlights, .readerSettings
    ])
    func nativePackages(kind: ReaderStylePackageKind) async throws {
        let payload: ReaderStylePackagePayload
        switch kind {
        case .appearance:
            payload = try .encode(AppearanceCustomizationBundle(snapshot: .init(themes: [theme()])), kind: kind, assetIDs: [])
        case .chapterTitle:
            payload = try .encode(ChapterTitleStyle.default, kind: kind, assetIDs: [])
        case .regexHighlights:
            payload = try .encode(RegexHighlightConfiguration.disabled, kind: kind, assetIDs: [])
        case .readerSettings:
            payload = try .encode(ReaderSettingsBundle(layoutConfig: nil, chapterTitleStyle: .default, regexHighlights: nil), kind: kind, assetIDs: [])
        }
        let data = try await ReaderStylePackage.export(payload, assetStore: .shared)
        let document = try await receive(data, extension: "yuedustyle")
        #expect(document.kind == .nativePackage)
        if kind == .appearance {
            try await applyAppearance(document)
        } else {
            let savedTitle = ReaderConfig.shared.chapterTitleStyle
            let savedGlobalTitle = GlobalSettings.shared.chapterTitleStyle
            let savedHighlights = GlobalSettings.shared.regexHighlightConfiguration
            defer {
                // Both copies: ReaderConfig reaches GlobalSettings only after a 120 ms
                // debounce, so restoring one leaves the next case starting with them apart.
                GlobalSettings.shared.chapterTitleStyle = savedGlobalTitle
                ReaderConfig.shared.chapterTitleStyle = savedTitle
                GlobalSettings.shared.regexHighlightConfiguration = savedHighlights
            }
            let plan = try await SharedCustomizationImportService.load(document)
            guard case .reader(let readerPlan) = plan else { Issue.record("Style routed to appearance"); return }
            #expect(!readerPlan.isEmpty)
            _ = try await SharedCustomizationImportService.apply(plan)
            if let style = readerPlan.chapterTitleStyle { #expect(ReaderConfig.shared.chapterTitleStyle == style) }
            if let rules = readerPlan.regexHighlights { #expect(GlobalSettings.shared.regexHighlightConfiguration == rules) }
        }
    }

    @Test("QiReader packages use the same parser and apply the selected theme")
    func qiTheme() async throws {
        let root = UUID().uuidString
        let archive = try await EPUBTestFixtures.makeArchive(entries: [
            "\(root)/manifest.json": try JSONSerialization.data(withJSONObject: [
                "id": root, "name": "Shared Theme Fixture", "accentColorHex": "123456"
            ])
        ])
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let document = try await receive(Data(contentsOf: archive), extension: "qitheme")
        #expect(document.kind == .qiTheme)
        try await applyAppearance(document)
    }

    /// Nothing is asked: the pack's reading setup is its theme's own, worn with the theme
    /// and gone with it (2026-09-29 — it used to ask 跟隨主題 or 取代全域設定).
    @Test("A QiReader pack's reading setup rides its theme, without a question")
    func qiReadingRidesTheTheme() async throws {
        let settings = GlobalSettings.shared
        let saved = settings.readerBarLayout
        let savedThemes = settings.customAppearanceThemes
        let savedID = settings.appearanceThemeID
        let savedBaseline = settings.appearanceExtrasBaseline
        let stores = ReadingSettingsStoresSnapshot()
        defer {
            settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.customAppearanceThemes = savedThemes
            _ = settings.saveReaderBarLayout(saved)
            stores.restore()
            settings.appearanceExtrasBaseline = savedBaseline
            settings.appearanceThemeID = savedID
        }
        settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
        let overlay = ReaderOverlayLayout(components: [], contentReservations: .init(top: 31, bottom: 42))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(overlay))
        let config = try JSONSerialization.data(withJSONObject: ["readerOverlayLayout": object])
        let pack = QiThemeImport(name: "Overlay Fixture", themeFile: AppearanceThemeExportFile(customTheme: theme()),
                                 layoutConfig: config, overlayLayout: overlay)
        let plan = SharedCustomizationImportService.Plan.qiTheme(pack)
        #expect(plan.prompt == nil)

        let overview = try await SharedCustomizationImportService.apply(plan)
        let imported = ReaderBarLayoutMigration.snap(overlay).normalized(preservingVersion: false)
        #expect(settings.readerBarLayout == imported)
        #expect(overview.readingItems.map(\.id).contains(ReadingSetupPart.headerFooter.titleKey))
        #expect(overview.readingPlacement == .followsTheme(name: "Shared Theme Fixture"))

        settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
        #expect(settings.readerBarLayout == saved)
    }

    @Test("Broken packages report failure instead of becoming a book", arguments: ["qitheme", "yuedustyle"])
    func invalidPackage(ext: String) async throws {
        let document = try await receive(Data("broken archive".utf8), extension: ext)
        await #expect(throws: (any Error).self) {
            _ = try await SharedCustomizationImportService.load(document)
        }
    }

    @Test("Malformed native theme JSON stays on the theme error path")
    func invalidTheme() async throws {
        let document = try await receive(Data(#"{"format":"yuedu-appearance-theme"}"#.utf8), extension: "json")
        let plan = try await SharedCustomizationImportService.load(document)
        await #expect(throws: (any Error).self) {
            _ = try await SharedCustomizationImportService.apply(plan)
        }
    }

    @Test("Presenting one theme does not discard another pending import")
    func pendingDocuments() async throws {
        let drainer = SharedImportQueueDrainer(defaults: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["first.yuedustyle", "second.qitheme"] {
            let url = directory.appendingPathComponent(name)
            try Data().write(to: url)
            _ = await drainer.openFile(url)
        }
        let first = try #require(drainer.customizationRequest)
        drainer.didPresentCustomization(requestID: UUID())
        #expect(drainer.customizationRequests.count == 2)
        drainer.didPresentCustomization(requestID: first.id)
        #expect(drainer.customizationRequest?.kind == .qiTheme)
        #expect(drainer.customizationRequests.count == 1)
    }

    private func receive(_ data: Data, extension ext: String) async throws -> SharedCustomizationDocument {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Shared Theme.\(ext)")
        try data.write(to: url)
        let drainer = SharedImportQueueDrainer(defaults: nil, importBookFile: { _ in
            Issue.record("Customization was sent to the book importer")
            return 1
        })
        let outcome = await drainer.openFile(url)
        #expect(outcome.failureCount == 0)
        #expect(outcome.importedBookCount == 0)
        #expect(drainer.readerRequest == nil)
        #expect(drainer.lastOutcome == nil)
        #expect(try Data(contentsOf: url) == data)
        let document = try #require(drainer.customizationRequest)
        #expect(document.data == data)
        return document // The source disappears here; its captured bytes remain importable.
    }

    private func applyAppearance(_ document: SharedCustomizationDocument) async throws {
        let settings = GlobalSettings.shared
        let savedThemes = settings.customAppearanceThemes
        let savedID = settings.appearanceThemeID
        defer {
            settings.appearanceThemeID = savedID
            settings.customAppearanceThemes = savedThemes
        }
        let plan = try await SharedCustomizationImportService.load(document)
        #expect(plan.prompt == nil)
        _ = try await SharedCustomizationImportService.apply(plan)
        let imported = try #require(settings.customAppearanceThemes.last)
        #expect(imported.name == "Shared Theme Fixture")
        #expect(settings.appearanceThemeID == imported.id)
        #expect(settings.customAppearanceThemes.count == savedThemes.count + 1)
    }

    private func theme() -> AppearanceCustomTheme {
        AppearanceCustomTheme(name: "Shared Theme Fixture", backgroundHex: 0xFFFFFF,
                              textHex: 0x111111, barHex: 0xEEEEEE,
                              accentHex: 0x123456, dialogueHex: 0x654321)
    }
}
