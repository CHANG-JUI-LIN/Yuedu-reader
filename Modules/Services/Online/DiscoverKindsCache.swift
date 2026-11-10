import CryptoKit
import Foundation

/// Disk cache for a source's parsed discover categories (`getExploreItems` output).
///
/// Mirrors Legado's `exploreKinds` cache: `@js:`-driven discover pages run a JS
/// (often with network requests) just to produce the category list, and that list
/// is stable for a given (source rule, discover runtime variables) pair. The key is
/// an MD5 over bookSourceUrl + exploreUrl + the discover-relevant runtime-variable
/// JSON, so editing the source's rule or switching a 發現頁 filter naturally maps to
/// a different entry — no explicit invalidation needed. Pull-to-refresh and the
/// toolbar refresh button bypass the cache and overwrite it (`forceRefresh`).
final class DiscoverKindsCache: Sendable {
    static let shared = DiscoverKindsCache()

    private struct Entry: Codable {
        var items: [ModernParserBridge.DiscoverItem]
        var timestamp: Date
    }

    private let queue = DispatchQueue(label: "com.yuedu.discoverKindsCache")

    private let directory: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiscoverKindsCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        directory = base
    }

    private func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    func items(forKey key: String) -> [ModernParserBridge.DiscoverItem]? {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL(forKey: key)),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  !entry.items.isEmpty
            else { return nil }
            return entry.items
        }
    }

    func store(_ items: [ModernParserBridge.DiscoverItem], forKey key: String) {
        guard !items.isEmpty else { return }
        let entry = Entry(items: items, timestamp: Date())
        queue.sync {
            guard let data = try? JSONEncoder().encode(entry) else { return }
            try? data.write(to: fileURL(forKey: key), options: .atomic)
        }
    }

    func removeAll() {
        queue.sync {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Legado `BookSource.clearExploreKindsCache`, which a source's `source.refreshExplore()`
    /// runs — 露西弗俱乐部's login button calls it so that 發現 lists 我的收藏 once signed in:
    /// every entry of `sourceUrl`, whatever its rule or variables.
    func removeAll(sourceUrl: String) {
        let prefix = Self.sourcePrefix(sourceUrl) + "-"
        queue.sync {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            } catch {
                AppLogger.network("⟐ discover kinds cache unreadable", context: ["error": "\(error)"])
                return
            }
            for name in names where name.hasPrefix(prefix) {
                do {
                    try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                } catch {
                    AppLogger.network("⟐ discover kinds entry not removed", context: [
                        "file": name, "error": "\(error)",
                    ])
                }
            }
        }
    }

    /// Stable cache key. `variableJSON` is the canonical JSON of the source's
    /// sanitized discover runtime variables (nil when the source has none).
    /// Bumped when reading a rule's kinds changes what the same rule yields, so a list parsed
    /// before the change is not served after it. 1: a line break inside a kind's JSON string
    /// (美女图站's POST kinds had lost their URLs). 2: a kinds script's completion value is
    /// Rhino's, so a valueless `if` after the list no longer replaces it.
    private static let parserRevision = "2"

    /// `<source digest>-<digest of every input>`: the first part lets `removeAll(sourceUrl:)`
    /// find a source's entries. A key before 11-07 was the second part alone; those files are
    /// never read again.
    static func key(sourceUrl: String, exploreUrl: String, variableJSON: String?) -> String {
        sourcePrefix(sourceUrl) + "-" + digest(sourceUrl: sourceUrl, exploreUrl: exploreUrl, variableJSON: variableJSON)
    }

    private static func sourcePrefix(_ sourceUrl: String) -> String {
        CryptoKit.Insecure.MD5.hash(data: Data(sourceUrl.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(sourceUrl: String, exploreUrl: String, variableJSON: String?) -> String {
        var hasher = CryptoKit.Insecure.MD5()
        func feed(_ s: String) {
            let bytes = Array(s.utf8)
            hasher.update(data: Data(bytes))
        }
        feed(parserRevision)
        feed("|")
        feed(sourceUrl)
        feed("|")
        feed(exploreUrl)
        feed("|")
        feed(variableJSON ?? "")
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
