import CryptoKit
import Foundation
import ReadiumShared

/// One disk namespace for automatic remote-file and byte-range caches. Explicit
/// offline copies and reading records are deliberately outside this directory.
final class RemoteLibraryCache: @unchecked Sendable {
    static let shared = RemoteLibraryCache(root: StorageLocations.remoteLibraryCache)
    let root: URL
    private let lock = NSLock()
    private var activeBooks: [UUID: Int] = [:]

    init(root: URL) { self.root = root }

    func retain(_ id: UUID) { lock.withLock { activeBooks[id, default: 0] += 1 } }
    func release(_ id: UUID) {
        lock.withLock {
            let count = activeBooks[id, default: 0] - 1
            if count <= 0 { activeBooks.removeValue(forKey: id) }
            else { activeBooks[id] = count }
        }
    }

    static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func directory(bookID: UUID, version: String) throws -> URL {
        let url = root.appendingPathComponent(bookID.uuidString).appendingPathComponent(Self.key(version))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func clearInactive() throws {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: root.path) else { return }
            for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                if let id = UUID(uuidString: url.lastPathComponent), activeBooks[id] != nil { continue }
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// Readium reads ZIP directory/entries through the same transport as the catalog.
/// Bytes are published to Readium only after the response's version is checked.
final class RemoteLibraryResourceClient: HTTPClient {
    private let transport: any HTTPClient
    private let url: HTTPURL
    private let length: Int64
    private let entityTag: String?
    private let lastModified: String?
    private let directory: URL
    private let onFailure: (@Sendable (HTTPError) -> Void)?

    init(transport: any HTTPClient, url: HTTPURL, length: Int64,
         entityTag: String?, lastModified: String?, directory: URL,
         onFailure: (@Sendable (HTTPError) -> Void)? = nil) {
        self.transport = transport; self.url = url; self.length = length
        self.entityTag = entityTag; self.lastModified = lastModified; self.directory = directory
        self.onFailure = onFailure
    }

    func stream(request convertible: HTTPRequestConvertible,
                consume: @escaping (Data, Double?) -> HTTPResult<Void>) async -> HTTPResult<HTTPResponse> {
        let result = await loadRequest(convertible, consume: consume)
        if case .failure(let error) = result {
            if case .cancelled = error { return result }
            onFailure?(error)
        }
        return result
    }

    private func loadRequest(_ convertible: HTTPRequestConvertible,
                             consume: @escaping (Data, Double?) -> HTTPResult<Void>) async -> HTTPResult<HTTPResponse> {
        do {
            var request = try convertible.httpRequest().get()
            guard request.url.isEquivalentTo(url) else {
                return .failure(.malformedRequest(url: request.url.string))
            }
            if Task.isCancelled { return .failure(.cancelled) }
            if request.method == .head {
                return .success(HTTPResponse(request: request, url: url, status: .ok,
                    headers: responseHeaders(contentLength: length), mediaType: .epub, body: nil))
            }
            guard request.method == .get,
                  let requestedRange = request.headers.first(where: { $0.key.lowercased() == "range" })?.value,
                  let range = Self.byteRange(requestedRange, length: length) else {
                return .failure(.malformedRequest(url: request.url.string))
            }
            let expectedLength = range.upperBound - range.lowerBound
            let canonicalRange = "bytes=\(range.lowerBound)-\(range.upperBound - 1)"
            let file = directory.appendingPathComponent(RemoteLibraryCache.key(canonicalRange) + ".range")
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                // An incomplete cache file is corruption, not a valid short ZIP read.
                guard Int64(data.count) == expectedLength else { return .failure(.malformedResponse(nil)) }
                try Task.checkCancellation()
                switch consume(data, 1) {
                case .failure(let error): return .failure(error)
                case .success:
                    return .success(HTTPResponse(request: request, url: url, status: .partialContent,
                        headers: responseHeaders(contentLength: expectedLength, range: range),
                        mediaType: .epub, body: nil))
                }
            }
            request.headers = request.headers.filter { $0.key.lowercased() != "range" }
            request.headers["Range"] = canonicalRange
            if let entityTag, !entityTag.hasPrefix("W/") { request.headers["If-Match"] = entityTag }
            else if let lastModified { request.headers["If-Unmodified-Since"] = lastModified }
            request.headers["Accept-Encoding"] = "identity"
            let response = try await transport.fetch(request).get()
            if let entityTag, let received = response.valueForHeader("ETag"), received != entityTag {
                return .failure(.other(RemoteLibraryError.contentChanged))
            }
            if let lastModified, let received = response.valueForHeader("Last-Modified"), received != lastModified {
                return .failure(.other(RemoteLibraryError.contentChanged))
            }
            guard response.status == .partialContent,
                  Self.responseRange(response.valueForHeader("Content-Range"), matches: range, length: length),
                  response.valueForHeader("Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true,
                  let data = response.body,
                  Int64(data.count) == expectedLength,
                  response.contentLength.map({ $0 == expectedLength }) ?? true else {
                return .failure(.malformedResponse(nil))
            }
            try Task.checkCancellation()
            try data.write(to: file, options: .atomic)
            switch consume(data, 1) {
            case .failure(let error): return .failure(error)
            case .success: return .success(response)
            }
        } catch let error as HTTPError {
            if case .errorResponse(let response) = error, response.status.rawValue == 412 {
                return .failure(.other(RemoteLibraryError.contentChanged))
            }
            return .failure(error)
        } catch is CancellationError { return .failure(.cancelled) }
        catch { return .failure(.other(error)) }
    }

    private func responseHeaders(contentLength: Int64, range: Range<Int64>? = nil) -> [String: String] {
        var headers = ["Content-Length": String(contentLength), "Content-Type": "application/epub+zip", "Accept-Ranges": "bytes"]
        if let range { headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(length)" }
        if let entityTag { headers["ETag"] = entityTag }
        if let lastModified { headers["Last-Modified"] = lastModified }
        return headers
    }

    private static func byteRange(_ header: String, length: Int64) -> Range<Int64>? {
        guard length > 0, header.hasPrefix("bytes=") else { return nil }
        let bounds = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let lower = Int64(bounds[0]), let inclusiveUpper = Int64(bounds[1]),
              lower >= 0, lower < length, inclusiveUpper >= lower else { return nil }
        // Readium's buffer may request beyond EOF; HTTP's final range is shorter.
        return lower..<(min(inclusiveUpper, length - 1) + 1)
    }

    private static func responseRange(_ header: String?, matches expected: Range<Int64>, length: Int64) -> Bool {
        guard let header, header.lowercased().hasPrefix("bytes ") else { return false }
        let parts = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, Int64(parts[1]) == length else { return false }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        return bounds.count == 2 && Int64(bounds[0]) == expected.lowerBound && Int64(bounds[1]) == expected.upperBound - 1
    }
}
