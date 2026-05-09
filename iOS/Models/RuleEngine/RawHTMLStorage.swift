import Foundation

struct RawHTMLStorage {
    @discardableResult
    func persistRawHTML(_ rawHTML: String?, at path: URL) -> String? {
        if let rawHTML, !rawHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? rawHTML.write(to: path, atomically: true, encoding: .utf8)
            return path.lastPathComponent
        }
        try? FileManager.default.removeItem(at: path)
        return nil
    }

    func persistNormalizedHTML(_ normalizedHTML: String, at path: URL) {
        try? normalizedHTML.write(to: path, atomically: true, encoding: .utf8)
    }
}
