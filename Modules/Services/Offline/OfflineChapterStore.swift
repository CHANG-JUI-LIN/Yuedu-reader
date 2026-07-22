import Foundation

struct OfflineStorageRoots: Sendable, Equatable {
    var textRoot: URL
    var mangaRoot: URL

    static var live: OfflineStorageRoots {
        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return OfflineStorageRoots(
            textRoot: documents.appendingPathComponent("online_cache", isDirectory: true),
            mangaRoot: applicationSupport.appendingPathComponent("manga", isDirectory: true)
        )
    }

    func textBookDirectory(bookId: UUID) -> URL {
        textRoot.appendingPathComponent(bookId.uuidString, isDirectory: true)
    }

    func mangaBookDirectory(bookId: UUID) -> URL {
        mangaRoot.appendingPathComponent(bookId.uuidString, isDirectory: true)
    }

    func mangaChapterDirectory(bookId: UUID, chapterIndex: Int) -> URL {
        mangaBookDirectory(bookId: bookId)
            .appendingPathComponent(String(chapterIndex), isDirectory: true)
    }
}

struct MangaChapterManifest: Codable, Equatable, Sendable {
    struct Page: Codable, Equatable, Sendable {
        var sourceURL: String
        var filename: String
        var byteCount: Int64
    }

    var sourceURL: String
    var tocTitle: String
    var pages: [Page]
    var completedAt: Date
}

struct OfflineMangaImageRequest: Equatable, Sendable {
    var sourceURL: String
    var headers: [String: String]
}

struct OfflineMangaChapterRequest: Equatable, Sendable {
    var bookId: UUID
    var chapterIndex: Int
    var chapterSourceURL: String
    var tocTitle: String
    var images: [OfflineMangaImageRequest]
}

struct OfflineImageResponse: Sendable {
    var data: Data
    var statusCode: Int
    var mimeType: String? = nil
}

protocol OfflineImageDownloading: Sendable {
    func response(for request: URLRequest) async throws -> OfflineImageResponse
}

struct URLSessionOfflineImageDownloader: OfflineImageDownloading {
    func response(for request: URLRequest) async throws -> OfflineImageResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return OfflineImageResponse(
            data: data,
            statusCode: statusCode,
            mimeType: response.mimeType
        )
    }
}

enum OfflineChapterValidation: Equatable, Sendable {
    case complete
    case incomplete
    case stale
}

enum OfflineChapterStoreError: LocalizedError, Equatable {
    case noImages
    case invalidImageURL(String)
    case imageResponse(index: Int, statusCode: Int)
    case emptyImage(index: Int)
    case invalidImageData(index: Int)
    case imageWrite(index: Int, message: String)
    case manifestWrite(String)
    case manifestValidation
    case commit(String)
    case remove(String)

    var errorDescription: String? {
        switch self {
        case .noImages:
            return "Manga chapter contains no images"
        case .invalidImageURL(let url):
            return "Invalid manga image URL: \(url)"
        case .imageResponse(let index, let statusCode):
            return "Manga page \(index) returned HTTP \(statusCode)"
        case .emptyImage(let index):
            return "Manga page \(index) returned no data"
        case .invalidImageData(let index):
            return "Manga page \(index) did not contain a supported image"
        case .imageWrite(let index, let message):
            return "Unable to write manga page \(index): \(message)"
        case .manifestWrite(let message):
            return "Unable to write manga manifest: \(message)"
        case .manifestValidation:
            return "Manga manifest validation failed"
        case .commit(let message):
            return "Unable to commit manga chapter: \(message)"
        case .remove(let message):
            return "Unable to remove offline artifacts: \(message)"
        }
    }
}

protocol OfflineChapterStoring: Sendable {
    func validationState(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?,
        requiresManga: Bool
    ) async -> OfflineChapterValidation
    func persistMangaImages(_ request: OfflineMangaChapterRequest) async throws
    func removeBook(bookId: UUID) async throws
    func reconcileBook(
        bookId: UUID,
        oldRefs: [OnlineChapterRef],
        newRefs: [OnlineChapterRef]
    ) async throws
    func storageByteCount(bookId: UUID?) async -> Int64
}

actor OfflineChapterStore: OfflineChapterStoring {
    private static let manifestFilename = "manifest.json"

    nonisolated let roots: OfflineStorageRoots
    private let imageDownloader: any OfflineImageDownloading
    private let fileManager: FileManager

    init(
        roots: OfflineStorageRoots = .live,
        imageDownloader: any OfflineImageDownloading = URLSessionOfflineImageDownloader(),
        fileManager: FileManager = .default
    ) {
        self.roots = roots
        self.imageDownloader = imageDownloader
        self.fileManager = fileManager
    }

    func validationState(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?,
        requiresManga: Bool = false
    ) -> OfflineChapterValidation {
        let repository = ChapterCacheRepository(rootDirectory: roots.textRoot)
        guard let package = repository.loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        ) else {
            return .incomplete
        }
        guard requiresManga else { return .complete }
        let mangaRequest = OfflineMangaChapterRequest(
            bookId: bookId,
            chapterIndex: chapterIndex,
            chapterSourceURL: expectedSourceURL ?? package.sourceURL ?? "",
            tocTitle: expectedTOCTitle ?? package.tocTitle ?? "",
            images: MangaChapterParser.parsedImages(from: package.content).map {
                OfflineMangaImageRequest(sourceURL: $0.url, headers: $0.headers)
            }
        )
        return mangaValidationState(for: mangaRequest)
    }

    func mangaValidationState(for request: OfflineMangaChapterRequest) -> OfflineChapterValidation {
        guard let manifest = Self.validatedMangaManifest(
            bookId: request.bookId,
            chapterIndex: request.chapterIndex,
            roots: roots,
            fileManager: fileManager
        ) else {
            return .incomplete
        }

        let expectedURLs = request.images.map(\.sourceURL)
        guard
            manifest.sourceURL == request.chapterSourceURL,
            normalizedTitle(manifest.tocTitle) == normalizedTitle(request.tocTitle),
            manifest.pages.map(\.sourceURL) == expectedURLs
        else {
            return .stale
        }
        return .complete
    }

    func persistMangaImages(_ request: OfflineMangaChapterRequest) async throws {
        guard !request.images.isEmpty else { throw OfflineChapterStoreError.noImages }

        let bookDirectory = roots.mangaBookDirectory(bookId: request.bookId)
        do {
            try fileManager.createDirectory(at: bookDirectory, withIntermediateDirectories: true)
        } catch {
            throw OfflineChapterStoreError.commit(error.localizedDescription)
        }

        let temporaryDirectory = bookDirectory.appendingPathComponent(
            ".\(request.chapterIndex).\(UUID().uuidString).tmp",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        var manifestPages: [MangaChapterManifest.Page] = []
        for batchStart in stride(from: 0, to: request.images.count, by: 4) {
            let batchEnd = min(batchStart + 4, request.images.count)
            let batch = Array(request.images[batchStart..<batchEnd].enumerated()).map {
                (index: batchStart + $0.offset, image: $0.element)
            }
            let downloaded = try await withThrowingTaskGroup(
                of: (Int, MangaChapterManifest.Page).self,
                returning: [(Int, MangaChapterManifest.Page)].self
            ) { group in
                for item in batch {
                    let downloader = imageDownloader
                    let directory = temporaryDirectory
                    group.addTask {
                        guard let url = URL(string: item.image.sourceURL) else {
                            throw OfflineChapterStoreError.invalidImageURL(item.image.sourceURL)
                        }
                        var urlRequest = URLRequest(url: url, timeoutInterval: 60)
                        for (key, value) in item.image.headers {
                            urlRequest.setValue(value, forHTTPHeaderField: key)
                        }
                        let response = try await downloader.response(for: urlRequest)
                        guard (200...299).contains(response.statusCode) else {
                            throw OfflineChapterStoreError.imageResponse(
                                index: item.index,
                                statusCode: response.statusCode
                            )
                        }
                        guard !response.data.isEmpty else {
                            throw OfflineChapterStoreError.emptyImage(index: item.index)
                        }
                        guard Self.isSupportedImageData(
                            response.data,
                            mimeType: response.mimeType
                        ) else {
                            throw OfflineChapterStoreError.invalidImageData(index: item.index)
                        }
                        let filename = Self.imageFilename(index: item.index, sourceURL: url)
                        do {
                            try response.data.write(
                                to: directory.appendingPathComponent(filename),
                                options: .atomic
                            )
                        } catch {
                            throw OfflineChapterStoreError.imageWrite(
                                index: item.index,
                                message: error.localizedDescription
                            )
                        }
                        return (
                            item.index,
                            MangaChapterManifest.Page(
                                sourceURL: item.image.sourceURL,
                                filename: filename,
                                byteCount: Int64(response.data.count)
                            )
                        )
                    }
                }

                var values: [(Int, MangaChapterManifest.Page)] = []
                for try await value in group {
                    values.append(value)
                }
                return values
            }
            manifestPages.append(contentsOf: downloaded.sorted { $0.0 < $1.0 }.map(\.1))
        }

        let manifest = MangaChapterManifest(
            sourceURL: request.chapterSourceURL,
            tocTitle: request.tocTitle,
            pages: manifestPages,
            completedAt: Date()
        )
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(
                to: temporaryDirectory.appendingPathComponent(Self.manifestFilename),
                options: .atomic
            )
        } catch {
            throw OfflineChapterStoreError.manifestWrite(error.localizedDescription)
        }

        guard Self.validatedManifest(in: temporaryDirectory, fileManager: fileManager) == manifest else {
            throw OfflineChapterStoreError.manifestValidation
        }

        let committedDirectory = roots.mangaChapterDirectory(
            bookId: request.bookId,
            chapterIndex: request.chapterIndex
        )
        do {
            if fileManager.fileExists(atPath: committedDirectory.path) {
                _ = try fileManager.replaceItemAt(
                    committedDirectory,
                    withItemAt: temporaryDirectory,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryDirectory, to: committedDirectory)
            }
        } catch {
            throw OfflineChapterStoreError.commit(error.localizedDescription)
        }

        guard mangaValidationState(for: request) == .complete else {
            try? fileManager.removeItem(at: committedDirectory)
            throw OfflineChapterStoreError.manifestValidation
        }
    }

    func removeBook(bookId: UUID) async throws {
        for directory in [
            roots.textBookDirectory(bookId: bookId),
            roots.mangaBookDirectory(bookId: bookId),
        ] where fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                throw OfflineChapterStoreError.remove(error.localizedDescription)
            }
        }
    }

    func reconcileBook(
        bookId: UUID,
        oldRefs: [OnlineChapterRef],
        newRefs: [OnlineChapterRef]
    ) async throws {
        let maximumCount = max(oldRefs.count, newRefs.count)
        guard maximumCount > 0 else { return }
        for index in 0..<maximumCount {
            let oldRef = oldRefs.indices.contains(index) ? oldRefs[index] : nil
            let newRef = newRefs.indices.contains(index) ? newRefs[index] : nil
            let matches = oldRef.map { old in
                newRef.map { new in
                    normalizedURL(old.url) == normalizedURL(new.url)
                        && normalizedTitle(old.title) == normalizedTitle(new.title)
                } ?? false
            } ?? true
            guard !matches else { continue }
            do {
                for suffix in ["txt", "meta.json", "package.json", "raw.html", "normalized.xhtml"] {
                    let file = roots.textBookDirectory(bookId: bookId)
                        .appendingPathComponent("\(index).\(suffix)")
                    if fileManager.fileExists(atPath: file.path) {
                        try fileManager.removeItem(at: file)
                    }
                }
                let mangaDirectory = roots.mangaChapterDirectory(
                    bookId: bookId,
                    chapterIndex: index
                )
                if fileManager.fileExists(atPath: mangaDirectory.path) {
                    try fileManager.removeItem(at: mangaDirectory)
                }
            } catch {
                throw OfflineChapterStoreError.remove(error.localizedDescription)
            }
        }
    }

    nonisolated func storageByteCount(bookId: UUID? = nil) async -> Int64 {
        let fileManager = FileManager.default
        let directories: [URL]
        if let bookId {
            directories = [
                roots.textBookDirectory(bookId: bookId),
                roots.mangaBookDirectory(bookId: bookId),
            ]
        } else {
            directories = [roots.textRoot, roots.mangaRoot]
        }
        return directories.reduce(into: 0) { total, directory in
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            ) else { return }
            for case let fileURL as URL in enumerator {
                guard
                    let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                    values.isRegularFile == true
                else { continue }
                total += Int64(values.fileSize ?? 0)
            }
        }
    }

    nonisolated static func validatedMangaManifest(
        bookId: UUID,
        chapterIndex: Int,
        roots: OfflineStorageRoots = .live,
        fileManager: FileManager = .default
    ) -> MangaChapterManifest? {
        validatedManifest(
            in: roots.mangaChapterDirectory(bookId: bookId, chapterIndex: chapterIndex),
            fileManager: fileManager
        )
    }

    nonisolated static func validatedMangaManifest(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> MangaChapterManifest? {
        validatedManifest(in: directory, fileManager: fileManager)
    }

    private nonisolated static func validatedManifest(
        in directory: URL,
        fileManager: FileManager
    ) -> MangaChapterManifest? {
        let manifestURL = directory.appendingPathComponent(manifestFilename)
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(MangaChapterManifest.self, from: data),
            !manifest.pages.isEmpty
        else { return nil }

        for page in manifest.pages {
            let fileURL = directory.appendingPathComponent(page.filename)
            guard
                page.byteCount > 0,
                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                values.isRegularFile == true,
                Int64(values.fileSize ?? 0) == page.byteCount
            else { return nil }
        }
        return manifest
    }

    private nonisolated static func imageFilename(index: Int, sourceURL: URL) -> String {
        let rawExtension = sourceURL.pathExtension.lowercased()
        let allowed = rawExtension.count <= 8
            && !rawExtension.isEmpty
            && rawExtension.allSatisfy { $0.isLetter || $0.isNumber }
        let pathExtension = allowed ? rawExtension : "jpg"
        return String(format: "%03d", index) + "." + pathExtension
    }

    private nonisolated static func isSupportedImageData(
        _ data: Data,
        mimeType: String?
    ) -> Bool {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        if bytes.starts(with: Array("GIF8".utf8)) { return true }
        if bytes.starts(with: Array("BM".utf8)) { return true }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00])
            || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return true
        }
        if bytes.count >= 12,
           String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" {
            return true
        }
        if bytes.count >= 12,
           String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" {
            return true  // HEIF / HEIC / AVIF family
        }
        if mimeType?.lowercased() == "image/svg+xml",
           let prefix = String(data: data.prefix(256), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           prefix.hasPrefix("<svg") || prefix.hasPrefix("<?xml") {
            return true
        }
        return false
    }

    private func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw.lowercased() }
        components.fragment = nil
        components.queryItems = components.queryItems?.sorted { lhs, rhs in
            lhs.name == rhs.name ? (lhs.value ?? "") < (rhs.value ?? "") : lhs.name < rhs.name
        }
        return (components.string ?? raw).lowercased()
    }
}
