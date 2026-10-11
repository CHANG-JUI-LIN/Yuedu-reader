import Combine
import Foundation

/// Unified library 5a: the Explore home, `explore_home.json` beside the custom pages
/// (Phase 5 plan, decision 2).
///
/// - It is read once, when the store is made. `page` is nil until something saves one; the
///   home decides when to save `HomePageDefaults` (5c).
/// - Writes replace the file atomically on one serial queue.
/// - A file of this version that does not decode is copied aside
///   (`explore_home.corrupt-<mtime>.json`) before anything is written over it.
/// - A file that cannot be read, or cannot be copied aside, is never written over.
/// - A file from a newer build is read section by section, skipping what does not decode, and
///   never written over: writing it back would drop what this build cannot name.
@MainActor
final class HomePageStore: ObservableObject {
    /// The app's home; the editor (5d) changes the same one the home draws.
    static let shared = HomePageStore()

    @Published private(set) var page: HomePage?

    /// Whether saves stay in memory this launch, because the file could not be read or comes
    /// from a newer build.
    private(set) var isReadOnly = false

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.yuedu.explore.home")

    init(fileURL: URL = StorageLocations.applicationSupportRoot.appendingPathComponent("explore_home.json")) {
        self.fileURL = fileURL
        load()
    }

    /// The saved home, or the defaults for this reader, saved now so they never change under
    /// them (5a step 3).
    ///
    /// Call it only once the book-source library is read (`ExploreTabModel.isLoaded`): before
    /// that `mode` cannot tell a reader with sources from a new install, and the wrong order
    /// would be saved for good. The region is taken as it stands: a public-library section
    /// saved before the region is known has no row in China, where its provider is hidden.
    func pageOrDefaults(mode: ExploreMode, publicLibrariesAvailable: Bool) -> HomePage {
        if let page { return page }
        let defaults = HomePageDefaults.page(mode: mode, publicLibrariesAvailable: publicLibrariesAvailable)
        save(defaults)
        AppLogger.cache("⟐ explore home starts from its defaults", context: [
            "mode": mode.rawValue, "publicLibraries": "\(publicLibrariesAvailable)", "sections": "\(defaults.sections.count)",
        ])
        return defaults
    }

    /// 編輯首頁 and a section's long press (5d-2): changes the saved page. Nothing to change
    /// before the home has read or made one.
    func edit(_ change: (inout HomePage) -> Void) {
        guard var page else { return }
        change(&page)
        save(page)
    }

    func save(_ page: HomePage) {
        self.page = page
        guard !isReadOnly else {
            AppLogger.cache("⟐ explore home not saved: the file is read-only this launch",
                            context: ["sections": "\(page.sections.count)"])
            return
        }
        let url = fileURL
        queue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(page)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                AppLogger.cache("⟐ explore home could not be saved", error: error,
                                context: ["sections": "\(page.sections.count)"])
            }
        }
    }

    #if DEBUG
    /// Drains queued writes, for tests.
    nonisolated func waitForPendingWritesForTesting() {
        queue.sync {}
    }
    #endif

    // MARK: - File

    private struct Version: Decodable { var schemaVersion: Int }

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
                page = HomePage(sections: lenient.sections)
                isReadOnly = true
                AppLogger.cache("⟐ explore home comes from a newer build; reading it without writing", context: [
                    "schemaVersion": "\(version)", "sections": "\(lenient.sections.count)", "skipped": "\(lenient.skipped)",
                ])
                return
            }
            page = try JSONDecoder().decode(HomePage.self, from: data)
        } catch {
            AppLogger.cache("⟐ explore home could not be decoded", error: error)
            isReadOnly = !keepAside(data)
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
