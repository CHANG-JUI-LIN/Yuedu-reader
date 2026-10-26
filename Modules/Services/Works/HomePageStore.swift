import Combine
import Foundation

/// Unified library 5a: the Explore home, `explore_home.json`; since 5d-4 every 首頁配置 in it
/// (`HomeConfigurations`, Phase 5 plan, decision 22).
///
/// - It is read once, when the store is made. `home` is nil until something saves one; the
///   home decides when to save `HomePageDefaults` (5c).
/// - `page`, `edit` and `save` act on the selected configuration, so 編輯首頁, a section's long
///   press and 聚合設定's 首頁欄目 edit whichever one 範圍 shows.
/// - Writes replace the file atomically on one serial queue.
/// - A file of this version that does not decode is copied aside
///   (`explore_home.corrupt-<mtime>.json`) before anything is written over it.
/// - A file that cannot be read, or cannot be copied aside, is never written over.
/// - A file from a newer build is read section by section, skipping what does not decode, and
///   never written over: writing it back would drop what this build cannot name.
/// - The custom pages move in once (5d-4): when a file older than 5d-4 is read, or when the
///   first home is made. `custom_explore_pages.json` is left where it is.
/// - A 預設 still as the defaults of 2026-10-13 to 2026-10-25 made it takes the 2026-10-25
///   layouts once (`HomeDefaultsRhythmMigration`).
@MainActor
final class HomePageStore: ObservableObject {
    /// The app's home; the editor (5d) changes the same one the home draws.
    static let shared = HomePageStore(insertsForYouOnce: true, appliesDefaultsRhythmOnce: true)

    /// Every configuration; nil until the home is first made.
    @Published private(set) var home: HomeConfigurations?

    /// The selected configuration's sections.
    var page: HomePage? {
        home.map { HomePage(sections: $0.sections(of: $0.selectedID)) }
    }

    var selectedConfiguration: HomeConfigurationID { home?.selectedID ?? .defaults }

    /// 首頁配置's page: the reader's own, with 預設 where it was moved to unless it was deleted.
    var configurations: [HomeConfigurationListing] {
        (home ?? HomeConfigurations(sections: [])).listings
    }

    /// Each 首頁配置's photo, in a folder beside the file.
    let photos: HomeConfigurationPhotos

    /// Whether saves stay in memory this launch, because the file could not be read or comes
    /// from a newer build.
    private(set) var isReadOnly = false

    /// The 最新 sections' 排除的來源 the file still holds from before 5d-3f, which
    /// `AggregationSettingsStore` adopts as 顯示在最新. Read once, with the file.
    private(set) var legacyLatestExcluded: [SourceInstanceKey] = []

    private let fileURL: URL
    private let customPagesURL: URL
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.yuedu.explore.home")
    /// Whether this store puts 為你推薦 on a saved home once; only the app's own does, so a
    /// test's home is read as it was saved.
    private let insertsForYouOnce: Bool
    /// Whether this store gives an untouched 預設 the 2026-10-25 layouts once; only the app's own
    /// does, as `insertsForYouOnce`.
    private let appliesDefaultsRhythmOnce: Bool

    /// - Parameter customPagesURL: the custom pages that move in; beside the home by default.
    init(fileURL: URL = StorageLocations.applicationSupportRoot.appendingPathComponent("explore_home.json"),
         customPagesURL: URL? = nil, defaults: UserDefaults = .standard, insertsForYouOnce: Bool = false,
         appliesDefaultsRhythmOnce: Bool = false) {
        self.fileURL = fileURL
        self.customPagesURL = customPagesURL
            ?? fileURL.deletingLastPathComponent().appendingPathComponent("custom_explore_pages.json")
        self.defaults = defaults
        self.insertsForYouOnce = insertsForYouOnce
        self.appliesDefaultsRhythmOnce = appliesDefaultsRhythmOnce
        photos = HomeConfigurationPhotos(directory: fileURL.deletingLastPathComponent()
            .appendingPathComponent("HomeConfigurationPhotos", isDirectory: true))
        load()
    }

    /// The selected configuration, or the defaults for this reader as 預設, saved now so they
    /// never change under them (5a step 3), with the custom pages moved in beside it.
    ///
    /// Call it only once the book-source library is read (`ExploreTabModel.isLoaded`): before
    /// that `mode` cannot tell a reader with sources from a new install, and the wrong order
    /// would be saved for good. The region is taken as it stands: a public-library section
    /// saved before the region is known has no row in China, where its provider is hidden.
    func pageOrDefaults(mode: ExploreMode, publicLibrariesAvailable: Bool, languages: [String]) -> HomePage {
        if let page { return page }
        let defaultPage = HomePageDefaults.page(mode: mode, publicLibrariesAvailable: publicLibrariesAvailable,
                                                languages: languages)
        // The defaults have 為你推薦 already; it is never inserted again.
        if insertsForYouOnce { defaults.set(true, forKey: Self.forYouInsertedKey) }
        // They have the 2026-10-25 layouts already; a reader who changes them keeps theirs.
        if appliesDefaultsRhythmOnce, !isReadOnly { defaults.set(true, forKey: Self.defaultsRhythmKey) }
        var made = HomeConfigurations(sections: defaultPage.sections)
        if !isReadOnly { moveCustomPages(into: &made) }
        home = made
        write()
        AppLogger.cache("⟐ explore home starts from its defaults", context: [
            "mode": mode.rawValue, "publicLibraries": "\(publicLibrariesAvailable)", "sections": "\(defaultPage.sections.count)",
            "configurations": "\(made.configurations.count)",
        ])
        return page ?? defaultPage
    }

    /// 編輯首頁 and a section's long press (5d-2): changes the selected configuration. Nothing
    /// to change before the home has read or made one.
    func edit(_ change: (inout HomePage) -> Void) {
        guard var page else { return }
        change(&page)
        save(page)
    }

    /// Replaces the selected configuration's sections; before any home, makes one with them
    /// as 預設.
    func save(_ page: HomePage) {
        if var home {
            home.setSections(page.sections, of: home.selectedID)
            self.home = home
        } else {
            home = HomeConfigurations(sections: page.sections)
        }
        write()
    }

    // MARK: 首頁配置

    func select(_ id: HomeConfigurationID) {
        change { $0.selected = id == .defaults ? nil : id }
    }

    /// 新增首頁配置 from a template: 空白模板 with no section; 預設配置 with the defaults the app
    /// keeps for this reader, whatever their 預設 has become (maintainer, 2026-10-23: they emptied
    /// 預設 and 預設配置 copied it, empty). The new one is selected.
    func createConfiguration(named name: String, from template: HomeConfigurationTemplate,
                             defaults context: HomePageDefaults.Context) {
        let sections = switch template {
        case .blank: [HomeSection]()
        case .defaults: HomePageDefaults.page(for: context).sections
        }
        change { home in
            let id = home.create(named: name, sections: sections)
            AppLogger.cache("⟐ 首頁配置 made from a template", context: [
                "configuration": id.rawValue, "template": template.rawValue, "mode": context.mode.rawValue,
                "sections": "\(sections.count)",
            ])
        }
    }

    func renameConfiguration(_ id: HomeConfigurationID, to name: String) {
        change { $0.rename(id, to: name) }
    }

    /// Its photo goes with it; the last one left is kept (`HomeConfigurations.delete`).
    func deleteConfiguration(_ id: HomeConfigurationID) {
        guard configurations.count > 1, configurations.contains(where: { $0.id == id }) else { return }
        change { $0.delete(id) }
        photos.removePhoto(for: id)
    }

    /// 首頁配置's 編輯: the list reordered, 預設 among the reader's own.
    func moveConfigurations(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        change { $0.move(fromOffsets: offsets, toOffset: destination) }
    }

    /// 加入首頁配置.
    func addCategory(_ reference: ExploreCategoryReference, to id: HomeConfigurationID) {
        change { $0.addCategory(reference, to: id) }
    }

    func contains(_ reference: ExploreCategoryReference, in id: HomeConfigurationID) -> Bool {
        home?.contains(reference, in: id) ?? false
    }

    /// The 模組 page's 首頁欄目引用 (M6): sections removed from every 首頁配置 at once.
    func removeSections(_ ids: Set<UUID>) {
        change { $0.removeSections(ids) }
    }

    private func change(_ body: (inout HomeConfigurations) -> Void) {
        guard var home else { return }
        body(&home)
        self.home = home
        write()
    }

    private func write() {
        guard let home else { return }
        guard !isReadOnly else {
            AppLogger.cache("⟐ explore home not saved: the file is read-only this launch",
                            context: ["configurations": "\(home.configurations.count)"])
            return
        }
        let url = fileURL
        queue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(home)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                AppLogger.cache("⟐ explore home could not be saved", error: error,
                                context: ["sections": "\(home.sections.count)"])
            }
        }
    }

    #if DEBUG
    /// Drains queued writes, for tests.
    nonisolated func waitForPendingWritesForTesting() {
        queue.sync {}
    }
    #endif

    // MARK: - 為你推薦

    /// Set once 為你推薦 has been put on a home: by the defaults, or inserted into a saved one.
    static let forYouInsertedKey = "home.forYouInserted"

    /// Everyone gets 為你推薦 once (Discovery Phase 7a, maintainer's decision 4): a saved home
    /// gets it in the 首頁配置 the reader is on, after 系列下一本, else 繼續閱讀, else first. Deleting it afterwards
    /// sticks. Not on a file this build only reads.
    private func insertForYouOnce(into home: inout HomeConfigurations) {
        guard insertsForYouOnce, !isReadOnly, !defaults.bool(forKey: Self.forYouInsertedKey) else { return }
        defaults.set(true, forKey: Self.forYouInsertedKey)
        let target = home.selectedID
        var sections = home.sections(of: target)
        guard !sections.contains(where: { $0.binding == .forYou }) else { return }
        let after = sections.lastIndex { $0.binding == .nextInSeries } ?? sections.lastIndex { $0.binding == .continueReading }
        sections.insert(HomeSection(layout: .row, binding: .forYou), at: after.map { $0 + 1 } ?? 0)
        home.setSections(sections, of: target)
        AppLogger.cache("⟐ 為你推薦 put on the saved home", context: ["configuration": target.rawValue])
    }

    // MARK: - The 2026-10-25 layouts

    /// Set once 預設 has been looked at for the 2026-10-25 layouts, or made with them.
    static let defaultsRhythmKey = "home.defaultsRhythm20261025"

    /// An untouched 預設 takes the 2026-10-25 layouts once (`HomeDefaultsRhythmMigration`), so a
    /// reader who puts a section back the way it was keeps it. Not on a file this build only
    /// reads. Returns whether a section changed.
    @discardableResult
    private func applyDefaultsRhythmOnce(to home: inout HomeConfigurations) -> Bool {
        guard appliesDefaultsRhythmOnce, !isReadOnly, !defaults.bool(forKey: Self.defaultsRhythmKey) else { return false }
        defaults.set(true, forKey: Self.defaultsRhythmKey)
        guard !home.defaultsDeleted, let outcome = HomeDefaultsRhythmMigration.apply(to: home.sections) else {
            AppLogger.cache("⟐ 預設 keeps its layouts: not the defaults of 2026-10-13 to 2026-10-25", context: [
                "sections": "\(home.sections.count)", "defaultsDeleted": "\(home.defaultsDeleted)",
            ])
            return false
        }
        home.sections = outcome.sections
        AppLogger.cache("⟐ 預設 takes the 2026-10-25 layouts", context: [
            "changed": "\(outcome.changed)", "kept": "\(outcome.kept)",
        ])
        return outcome.changed > 0
    }

    // MARK: - Custom pages

    /// The custom pages as configurations; the 首頁頁面 the reader had chosen, if a page,
    /// becomes the selected one (the deleted setting, `ExploreSettings.legacyLandingKey`).
    /// A file that could not be read is tried again on the next launch.
    private func moveCustomPages(into home: inout HomeConfigurations) {
        switch LegacyCustomExplorePages.read(customPagesURL) {
        case .absent:
            home.customPagesPending = false
        case .unreadable:
            home.customPagesPending = true
            return
        case .pages(let pages):
            home.adopt(pages)
            home.customPagesPending = false
            AppLogger.cache("⟐ custom pages moved into 首頁配置", context: ["pages": "\(pages.count)"])
        }
        let pagePrefix = "page:"
        if let landing = defaults.string(forKey: ExploreSettings.legacyLandingKey), landing.hasPrefix(pagePrefix) {
            let id = UUID(uuidString: String(landing.dropFirst(pagePrefix.count))).map(HomeConfigurationID.init)
            if home.selected == nil, let id, home.configurations.contains(where: { $0.id == id }) { home.selected = id }
            defaults.removeObject(forKey: ExploreSettings.legacyLandingKey)
        }
    }

    // MARK: - File

    private struct Version: Decodable { var schemaVersion: Int }

    /// The part of a pre-5d-3f file that `HomeSectionBinding` no longer reads.
    private struct LegacyLatest: Decodable {
        struct Section: Decodable {
            struct Binding: Decodable {
                var type: String
                var excluded: [SourceInstanceKey]?
            }
            var binding: Binding
        }
        var sections: [Section]

        var excluded: [SourceInstanceKey] {
            var keys: [SourceInstanceKey] = []
            for section in sections where section.binding.type == "latest" {
                for key in section.binding.excluded ?? [] where !keys.contains(key) { keys.append(key) }
            }
            return keys
        }
    }

    /// A newer build's file: the sections that decode.
    private struct LenientPage: Decodable {
        var sections: [HomeSection]
        var skipped = 0

        private enum CodingKeys: String, CodingKey { case sections }
        private struct Skipped: Decodable {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var list = try container.nestedUnkeyedContainer(forKey: .sections)
            var decoded: [HomeSection] = []
            while !list.isAtEnd {
                // A failed decode leaves the container on the same element, so it can be
                // stepped over; the count is logged by `load`.
                do {
                    decoded.append(try list.decode(HomeSection.self))
                } catch {
                    _ = try list.decode(Skipped.self)
                    skipped += 1
                }
            }
            sections = decoded
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            AppLogger.cache("⟐ explore home could not be read; it will not be written over", error: error)
            isReadOnly = true
            return
        }
        do {
            let version = try JSONDecoder().decode(Version.self, from: data).schemaVersion
            if version > HomePage.currentSchemaVersion {
                let lenient = try JSONDecoder().decode(LenientPage.self, from: data)
                home = HomeConfigurations(sections: lenient.sections)
                isReadOnly = true
                AppLogger.cache("⟐ explore home comes from a newer build; reading it without writing", context: [
                    "schemaVersion": "\(version)", "sections": "\(lenient.sections.count)", "skipped": "\(lenient.skipped)",
                ])
                return
            }
            var read: HomeConfigurations
            if version < 2 {
                // Before 5d-4: the one home, which becomes 預設, and the custom pages move in.
                read = HomeConfigurations(sections: try JSONDecoder().decode(HomePage.self, from: data).sections)
                readLegacyLatestExcluded(data)
                moveCustomPages(into: &read)
                insertForYouOnce(into: &read)
                applyDefaultsRhythmOnce(to: &read)
                home = read
                write()
                return
            }
            read = try JSONDecoder().decode(HomeConfigurations.self, from: data)
            let inserted = insertsForYouOnce && !defaults.bool(forKey: Self.forYouInsertedKey)
            insertForYouOnce(into: &read)
            // After 為你推薦, so a 預設 from before it is recognised.
            let restyled = applyDefaultsRhythmOnce(to: &read)
            if read.customPagesPending {
                moveCustomPages(into: &read)
                home = read
                if !read.customPagesPending || inserted || restyled { write() }
                return
            }
            home = read
            if inserted || restyled { write() }
        } catch {
            AppLogger.cache("⟐ explore home could not be decoded", error: error)
            isReadOnly = !keepAside(data)
        }
    }

    private func readLegacyLatestExcluded(_ data: Data) {
        do {
            legacyLatestExcluded = try JSONDecoder().decode(LegacyLatest.self, from: data).excluded
        } catch {
            // The page itself decoded; only the old list is lost, and with it nothing to move.
            AppLogger.cache("⟐ explore home's old 排除的來源 could not be read", error: error)
        }
    }

    /// Copies an undecodable file next to itself, named after its modification time so a
    /// second launch finds the copy it already made. Returns whether the bytes are safe.
    private func keepAside(_ data: Data) -> Bool {
        let modified: Date
        do {
            modified = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date ?? Date()
        } catch {
            AppLogger.cache("⟐ explore home's modification date could not be read", error: error)
            modified = Date()
        }
        let copy = fileURL.deletingLastPathComponent()
            .appendingPathComponent("explore_home.corrupt-\(Int(modified.timeIntervalSince1970)).json")
        if FileManager.default.fileExists(atPath: copy.path) { return true }
        do {
            try data.write(to: copy, options: .withoutOverwriting)
            AppLogger.cache("⟐ explore home kept aside as \(copy.lastPathComponent)")
            return true
        } catch {
            AppLogger.cache("⟐ undecodable explore home could not be kept aside; it will not be written over", error: error)
            return false
        }
    }
}
