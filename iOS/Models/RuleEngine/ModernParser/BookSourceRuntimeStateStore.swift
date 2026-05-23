import CryptoKit
import Foundation

/// Persistent runtime state owned by an imported Legado book source.
///
/// Source variables are intentionally kept outside `BookSource`: imported rule
/// JSON remains immutable, while settings changed by `source.setVariable(...)`
/// survive search/detail/toc/content sessions and app relaunches.
final class BookSourceRuntimeStateStore {
    static let shared = BookSourceRuntimeStateStore()

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.yuedu.bookSourceRuntimeState")

    private init() {
        defaults = UserDefaults(suiteName: "com.yuedu.bookSourceRuntimeState") ?? .standard
    }

    func sourceVariableJSON(for sourceUrl: String) -> String? {
        queue.sync {
            defaults.string(forKey: key(sourceUrl: sourceUrl, suffix: "sourceVariableJSON"))
        }
    }

    func setSourceVariableJSON(_ json: String?, for sourceUrl: String) {
        queue.sync {
            let storageKey = key(sourceUrl: sourceUrl, suffix: "sourceVariableJSON")
            guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                defaults.removeObject(forKey: storageKey)
                return
            }
            defaults.set(json, forKey: storageKey)
        }
    }

    private func key(sourceUrl: String, suffix: String) -> String {
        let data = Data(sourceUrl.utf8)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "bookSourceRuntime.\(digest).\(suffix)"
    }
}
