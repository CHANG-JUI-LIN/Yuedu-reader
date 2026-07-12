import Foundation
import UIKit
import CryptoKit
import ReadiumZIPFoundation
import ReadiumShared
import ReadiumStreamer

enum EPUBWritingMode: String, Sendable {
    case horizontal
    case verticalRL
    case unspecified
}

enum EPUBLayoutMode: String, Codable, Equatable, Sendable {
    case reflowable
    case prePaginated
}

enum EPUBFlowMode: String, Codable, Equatable, Sendable {
    case paginated
    case scrolledContinuous
    case scrolledDoc
    case auto
}

enum EPUBPageProgressionDirection: String, Codable, Equatable, Sendable {
    case `default`
    case ltr
    case rtl
}

enum FixedLayoutSpread: String, Codable, Equatable, Sendable {
    case auto
    case landscape
    case portrait
    case both
    case none

    static func parse(_ raw: String?) -> FixedLayoutSpread {
        guard let raw else { return .auto }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("landscape") { return .landscape }
        if value.contains("portrait") { return .portrait }
        if value.contains("both") { return .both }
        if value.contains("none") { return .none }
        return .auto
    }
}

enum FixedLayoutOrientation: String, Codable, Equatable, Sendable {
    case auto
    case landscape
    case portrait

    static func parse(_ raw: String?) -> FixedLayoutOrientation {
        guard let raw else { return .auto }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("landscape") { return .landscape }
        if value.contains("portrait") { return .portrait }
        return .auto
    }
}

enum FixedLayoutSpreadSide: String, Codable, Equatable, Sendable {
    case auto
    case left
    case right
    case center
}

struct FixedLayoutSpreadPair: Equatable, Sendable {
    let leftPage: Int?
    let rightPage: Int?
    let isSinglePage: Bool

    var globalPageIndex: Int {
        pages.min() ?? 0
    }

    var pages: [Int] {
        [leftPage, rightPage].compactMap { $0 }
    }

    func contains(page: Int) -> Bool {
        leftPage == page || rightPage == page
    }
}

enum FixedLayoutSpreadPairingBuilder {
    static func build(
        chapters: [PublicationChapterDescriptor],
        isRTL: Bool
    ) -> [FixedLayoutSpreadPair] {
        guard !chapters.isEmpty else { return [] }

        let firstSide: FixedLayoutSpreadSide = isRTL ? .right : .left
        let secondSide: FixedLayoutSpreadSide = isRTL ? .left : .right
        var pairs: [FixedLayoutSpreadPair] = []
        var leftPage: Int?
        var rightPage: Int?

        func hasOpenPair() -> Bool {
            leftPage != nil || rightPage != nil
        }

        func set(_ page: Int, on side: FixedLayoutSpreadSide) {
            switch side {
            case .left:
                leftPage = page
            case .right:
                rightPage = page
            case .auto, .center:
                break
            }
        }

        func flushOpenPair() {
            guard hasOpenPair() else { return }
            pairs.append(FixedLayoutSpreadPair(leftPage: leftPage, rightPage: rightPage, isSinglePage: false))
            leftPage = nil
            rightPage = nil
        }

        for chapter in chapters.sorted(by: { $0.index < $1.index }) {
            let side = chapter.spreadSide
            if side == .center {
                flushOpenPair()
                pairs.append(FixedLayoutSpreadPair(leftPage: chapter.index, rightPage: nil, isSinglePage: true))
            } else if side == firstSide {
                if hasOpenPair() {
                    flushOpenPair()
                }
                set(chapter.index, on: firstSide)
            } else if side == secondSide {
                if hasOpenPair() {
                    set(chapter.index, on: secondSide)
                    flushOpenPair()
                } else {
                    set(chapter.index, on: secondSide)
                    flushOpenPair()
                }
            } else {
                if !hasOpenPair() {
                    set(chapter.index, on: firstSide)
                } else {
                    set(chapter.index, on: secondSide)
                    flushOpenPair()
                }
            }
        }

        flushOpenPair()
        return pairs
    }
}

@MainActor
protocol FixedLayoutSpreadPairingProviding: AnyObject {
    var fixedLayoutSpreadPairs: [FixedLayoutSpreadPair] { get }
    func fixedLayoutSpreadPair(containing page: Int) -> FixedLayoutSpreadPair?
    func nextFixedLayoutSpreadPage(after page: Int) -> Int?
    func previousFixedLayoutSpreadPage(before page: Int) -> Int?
}

extension FixedLayoutSpreadPairingProviding {
    func fixedLayoutSpreadPair(containing page: Int) -> FixedLayoutSpreadPair? {
        fixedLayoutSpreadPairs.first { $0.contains(page: page) }
    }

    func nextFixedLayoutSpreadPage(after page: Int) -> Int? {
        guard let index = fixedLayoutSpreadPairs.firstIndex(where: { $0.contains(page: page) }) else {
            return fixedLayoutSpreadPairs.first(where: { $0.globalPageIndex > page })?.globalPageIndex
        }
        let nextIndex = fixedLayoutSpreadPairs.index(after: index)
        guard fixedLayoutSpreadPairs.indices.contains(nextIndex) else { return nil }
        return fixedLayoutSpreadPairs[nextIndex].globalPageIndex
    }

    func previousFixedLayoutSpreadPage(before page: Int) -> Int? {
        guard let index = fixedLayoutSpreadPairs.firstIndex(where: { $0.contains(page: page) }) else {
            return fixedLayoutSpreadPairs.last(where: { $0.globalPageIndex < page })?.globalPageIndex
        }
        guard index > fixedLayoutSpreadPairs.startIndex else { return nil }
        return fixedLayoutSpreadPairs[fixedLayoutSpreadPairs.index(before: index)].globalPageIndex
    }
}

struct FixedLayoutViewport: Sendable {
    let defaultViewport: CGSize?
    let pageViewports: [Int: CGSize]
}

struct PublicationChapterDescriptor: Equatable {
    let index: Int
    let href: String
    let title: String
    let mediaType: String
    let spreadSide: FixedLayoutSpreadSide
    let fixedLayoutViewport: CGSize?
    let layoutModeOverride: EPUBLayoutMode?
    let spreadOverride: FixedLayoutSpread?
    let orientationOverride: FixedLayoutOrientation?

    init(
        index: Int,
        href: String,
        title: String,
        mediaType: String,
        spreadSide: FixedLayoutSpreadSide = .auto,
        fixedLayoutViewport: CGSize? = nil,
        layoutModeOverride: EPUBLayoutMode? = nil,
        spreadOverride: FixedLayoutSpread? = nil,
        orientationOverride: FixedLayoutOrientation? = nil
    ) {
        self.index = index
        self.href = href
        self.title = title
        self.mediaType = mediaType
        self.spreadSide = spreadSide
        self.fixedLayoutViewport = fixedLayoutViewport
        self.layoutModeOverride = layoutModeOverride
        self.spreadOverride = spreadOverride
        self.orientationOverride = orientationOverride
    }
}

struct PublicationResourceResponse {
    let data: Data
    let mimeType: String
    let textEncodingName: String?
}

struct BookResourceChapterDescriptor: Equatable {
    let index: Int
    let href: String
    let title: String
    let mediaType: String
}

protocol BookResourceProvider: AnyObject {
    var customScheme: String { get }
    var chapters: [BookResourceChapterDescriptor] { get }
    func cssResourceHrefs() -> [String]
    func resourceURL(for href: String) -> URL
    func chapterDataSize(at index: Int) async throws -> Int
    func chapterIndex(for href: String) -> Int?
    func chapterHTML(at index: Int) async throws -> String
    func response(for requestURL: URL) async throws -> PublicationResourceResponse
}

final class ReadiumBookResourceAdapter: BookResourceProvider {
    private let session: PublicationSession

    init(session: PublicationSession) {
        self.session = session
    }

    var customScheme: String { PublicationSession.scheme }

    var chapters: [BookResourceChapterDescriptor] {
        session.chapters.map {
            BookResourceChapterDescriptor(
                index: $0.index,
                href: $0.href,
                title: $0.title,
                mediaType: $0.mediaType
            )
        }
    }

    func cssResourceHrefs() -> [String] {
        session.publication.readingOrder.compactMap { link -> String? in
            let mimeType = link.mediaType?.string.lowercased()
            guard mimeType == "text/css" else { return nil }
            let href = link.href.trimmingCharacters(in: .whitespacesAndNewlines)
            return href.isEmpty ? nil : href
        }
    }

    func resourceURL(for href: String) -> URL {
        session.resourceURL(for: href)
    }

    func chapterDataSize(at index: Int) async throws -> Int {
        try await session.chapterDataSize(at: index)
    }

    func cachedChapterByteSizes() -> [Int]? {
        session.cachedChapterByteSizes
    }

    func saveChapterByteSizes(_ sizes: [Int]) {
        session.saveChapterByteSizes(sizes)
    }

    func chapterIndex(for href: String) -> Int? {
        session.chapterIndex(for: href)
    }

    func chapterHTML(at index: Int) async throws -> String {
        try await session.chapterHTML(at: index)
    }

    func response(for requestURL: URL) async throws -> PublicationResourceResponse {
        try await session.response(for: requestURL)
    }
}

enum PublicationSessionError: LocalizedError {
    case fileNotFound
    case parsingFailed(String)
    case resourceNotFound(String)
    case resourceReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "EPUB file not found"
        case .parsingFailed(let reason):
            return "EPUB parsing failed: \(reason)"
        case .resourceNotFound(let href):
            return "Resource not found: \(href)"
        case .resourceReadFailed(let reason):
            return "Resource read failed: \(reason)"
        }
    }
}

final class PublicationSessionRegistry {
    static let shared = PublicationSessionRegistry()

    private let lock = NSLock()
    private var sessions: [String: PublicationSession] = [:]

    private init() {}

    func register(_ session: PublicationSession) {
        lock.lock()
        sessions[session.id] = session
        lock.unlock()
    }

    func unregister(id: String) {
        lock.lock()
        sessions.removeValue(forKey: id)
        lock.unlock()
    }

    func session(for id: String) -> PublicationSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }
}


struct SpinesCache: Codable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int? = SpinesCache.currentSchemaVersion
    let bookTitle: String
    let author: String
    let chapters: [PublicationChapterDescriptorCache]
    var chapterByteSizes: [Int]?             // nil = not yet scanned (backwards compatible)
    // encryptionAlgorithms != nil means encryption metadata is cached.
    // encryptionIdentifier may be nil even when cached (book has no unique-id).
    var encryptionIdentifier: String?
    var encryptionAlgorithms: [String: String]?

    struct PublicationChapterDescriptorCache: Codable {
        let index: Int
        let href: String
        let title: String
        let mediaType: String
        let spreadSide: FixedLayoutSpreadSide?
        let fixedLayoutViewport: CGSize?
        let layoutModeOverride: EPUBLayoutMode?
        let spreadOverride: FixedLayoutSpread?
        let orientationOverride: FixedLayoutOrientation?

        init(
            index: Int,
            href: String,
            title: String,
            mediaType: String,
            spreadSide: FixedLayoutSpreadSide? = nil,
            fixedLayoutViewport: CGSize? = nil,
            layoutModeOverride: EPUBLayoutMode? = nil,
            spreadOverride: FixedLayoutSpread? = nil,
            orientationOverride: FixedLayoutOrientation? = nil
        ) {
            self.index = index
            self.href = href
            self.title = title
            self.mediaType = mediaType
            self.spreadSide = spreadSide
            self.fixedLayoutViewport = fixedLayoutViewport
            self.layoutModeOverride = layoutModeOverride
            self.spreadOverride = spreadOverride
            self.orientationOverride = orientationOverride
        }
    }
}

// Helper to find cache path
private func getCacheURL(for sourceURL: URL) -> URL {
    let cachesPaths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
    let bookId = sourceURL.lastPathComponent.replacingOccurrences(of: ".epub", with: "")
    return cachesPaths[0].appendingPathComponent("spine_cache_\(bookId).json")
}

final class PublicationSession {
    static let scheme = "reader-book"

    let id: String
    let sourceURL: URL
    let publication: Publication
    let bookTitle: String
    let author: String
    let language: String?
    let chapters: [PublicationChapterDescriptor]
    let tocEntries: [EPUBTocEntry]
    let epubWritingMode: EPUBWritingMode
    let pageProgressionDirection: EPUBPageProgressionDirection
    let layoutMode: EPUBLayoutMode
    let flowMode: EPUBFlowMode
    let fixedLayoutSpread: FixedLayoutSpread
    let fixedLayoutOrientation: FixedLayoutOrientation
    let fixedLayoutViewport: FixedLayoutViewport?
    let opfManifestItemsByID: [String: EPUBManifestReference]
    let opfSpineReferences: [EPUBSpineReference]
    let pronunciationLexicons: [PLSLexicon]
    let mediaOverlaysByChapter: [Int: EPUBMediaOverlay]
    /// Pre-scanned chapter byte sizes loaded from SpinesCache. nil = not yet available.
    let cachedChapterByteSizes: [Int]?
    private let obfuscationIdentifier: String?
    private let encryptionAlgorithmsByHref: [String: String]
    private let resourceLock = NSLock()
    private var transformedResourceCache: [String: Data] = [:]
    private let cacheURL: URL

    private init(
        id: String,
        sourceURL: URL,
        publication: Publication,
        bookTitle: String,
        author: String,
        language: String?,
        chapters: [PublicationChapterDescriptor],
        tocEntries: [EPUBTocEntry],
        epubWritingMode: EPUBWritingMode,
        pageProgressionDirection: EPUBPageProgressionDirection,
        layoutMode: EPUBLayoutMode,
        flowMode: EPUBFlowMode,
        fixedLayoutSpread: FixedLayoutSpread,
        fixedLayoutOrientation: FixedLayoutOrientation,
        fixedLayoutViewport: FixedLayoutViewport?,
        opfManifestItemsByID: [String: EPUBManifestReference],
        opfSpineReferences: [EPUBSpineReference],
        pronunciationLexicons: [PLSLexicon],
        mediaOverlaysByChapter: [Int: EPUBMediaOverlay],
        cachedChapterByteSizes: [Int]?,
        obfuscationIdentifier: String?,
        encryptionAlgorithmsByHref: [String: String],
        cacheURL: URL
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.publication = publication
        self.bookTitle = bookTitle
        self.author = author
        self.language = language
        self.chapters = chapters
        self.tocEntries = tocEntries
        self.epubWritingMode = epubWritingMode
        self.pageProgressionDirection = pageProgressionDirection
        self.layoutMode = layoutMode
        self.flowMode = flowMode
        self.fixedLayoutSpread = fixedLayoutSpread
        self.fixedLayoutOrientation = fixedLayoutOrientation
        self.fixedLayoutViewport = fixedLayoutViewport
        self.opfManifestItemsByID = opfManifestItemsByID
        self.opfSpineReferences = opfSpineReferences
        self.pronunciationLexicons = pronunciationLexicons
        self.mediaOverlaysByChapter = mediaOverlaysByChapter
        self.cachedChapterByteSizes = cachedChapterByteSizes
        self.obfuscationIdentifier = obfuscationIdentifier
        self.encryptionAlgorithmsByHref = encryptionAlgorithmsByHref
        self.cacheURL = cacheURL
    }

    /// Update the on-disk SpinesCache with scanned chapter byte sizes.
    func saveChapterByteSizes(_ sizes: [Int]) {
        guard let data = try? Data(contentsOf: cacheURL),
              var cache = try? JSONDecoder().decode(SpinesCache.self, from: data) else { return }
        cache.chapterByteSizes = sizes
        if let encoded = try? JSONEncoder().encode(cache) {
            try? encoded.write(to: cacheURL)
        }
    }

    deinit {
        PublicationSessionRegistry.shared.unregister(id: id)
    }

    static func open(sourceURL: URL) async throws -> PublicationSession {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw PublicationSessionError.fileNotFound
        }

        let publication = try await openPublication(sourceURL: sourceURL)
        let opfMetadata = await parseOPFMetadata(from: sourceURL)
        let epubWritingMode = opfMetadata.writingMode
        let rtlBidiVerify = "[RTLVerify] file=\(sourceURL.lastPathComponent) lang=\(opfMetadata.language ?? "nil") pageProgression=\(opfMetadata.pageProgressionDirection.rawValue) writingMode=\(epubWritingMode.rawValue) → \(epubWritingMode == .verticalRL ? "VERTICAL" : "HORIZONTAL")"
        print(rtlBidiVerify)
        NSLog("%@", rtlBidiVerify)
        let tocEntries = flattenTableOfContents(publication.manifest.tableOfContents)

        let cacheURL = getCacheURL(for: sourceURL)
        let chapters: [PublicationChapterDescriptor]
        let cachedTitle: String?
        let cachedAuthor: String?
        var cachedByteSizes: [Int]? = nil
        var cachedEncryptionIdentifier: String? = nil
        var cachedEncryptionAlgorithms: [String: String]? = nil
        var encryptionIsCached = false

        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(SpinesCache.self, from: data),
           cache.schemaVersion == SpinesCache.currentSchemaVersion {
            // Cache hit, O(1) read, bypassing O(N^2) XML matching
            chapters = cache.chapters.map {
                PublicationChapterDescriptor(
                    index: $0.index,
                    href: $0.href,
                    title: $0.title,
                    mediaType: $0.mediaType,
                    spreadSide: $0.spreadSide ?? .auto,
                    fixedLayoutViewport: $0.fixedLayoutViewport,
                    layoutModeOverride: $0.layoutModeOverride,
                    spreadOverride: $0.spreadOverride,
                    orientationOverride: $0.orientationOverride
                )
            }
            cachedTitle = cache.bookTitle
            cachedAuthor = cache.author
            cachedByteSizes = cache.chapterByteSizes
            if let algorithms = cache.encryptionAlgorithms {
                cachedEncryptionIdentifier = cache.encryptionIdentifier
                cachedEncryptionAlgorithms = algorithms
                encryptionIsCached = true
            }
        } else {
            // Cache miss, do O(N^2) matching
            let chapterTitleMap = Dictionary(
                tocEntries.map { (normalizedHREF($0.href), $0.title) },
                uniquingKeysWith: { first, _ in first }
            )
            let readingOrder = chapterLinks(from: publication)
            var lastResolvedTOCTitle: String?
            chapters = readingOrder.enumerated().map { (index, link) in
                let href = normalizedHREF(link.href)
                let matchedTOCTitle = chapterTitleMap[href] ?? chapterTitleMap.first(where: {
                    href.hasSuffix($0.key) || $0.key.hasSuffix(href)
                })?.value
                if let matchedTOCTitle, !matchedTOCTitle.isEmpty {
                    lastResolvedTOCTitle = matchedTOCTitle
                }
                let spineMetadata = opfMetadata.spineMetadataByHref[href]
                return PublicationChapterDescriptor(
                    index: index,
                    href: href,
                    title: sanitizedTitle(
                        link.title ?? matchedTOCTitle ?? lastResolvedTOCTitle,
                        fallbackHref: href,
                        chapterIndex: index
                    ),
                    mediaType: link.mediaType?.string ?? "application/xhtml+xml",
                    spreadSide: spineMetadata?.spreadSide ?? .auto,
                    fixedLayoutViewport: spineMetadata?.viewport,
                    layoutModeOverride: spineMetadata?.layoutModeOverride,
                    spreadOverride: spineMetadata?.spreadOverride,
                    orientationOverride: spineMetadata?.orientationOverride
                )
            }

            // Save Cache (encryption will be added after resolving below)
            let cTitle = publication.metadata.title ?? "Unknown"
            let cAuthor = publication.metadata.authors.map { $0.name }.joined(separator: ", ")
            let cacheChapters = chapters.map {
                SpinesCache.PublicationChapterDescriptorCache(
                    index: $0.index,
                    href: $0.href,
                    title: $0.title,
                    mediaType: $0.mediaType,
                    spreadSide: $0.spreadSide,
                    fixedLayoutViewport: $0.fixedLayoutViewport,
                    layoutModeOverride: $0.layoutModeOverride,
                    spreadOverride: $0.spreadOverride,
                    orientationOverride: $0.orientationOverride
                )
            }
            let cacheObj = SpinesCache(bookTitle: cTitle, author: cAuthor, chapters: cacheChapters)
            if let cacheData = try? JSONEncoder().encode(cacheObj) {
                try? cacheData.write(to: cacheURL)
            }
            cachedTitle = nil
            cachedAuthor = nil
        }

        let finalTitle: String
        let finalAuthor: String
        if let cachedTitle = cachedTitle, let cachedAuthor = cachedAuthor {
            finalTitle = cachedTitle
            finalAuthor = cachedAuthor
        } else {
            let titleText = publication.metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let authorText = publication.metadata.authors
                .map(\.name)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            finalTitle = titleText?.isEmpty == false ? titleText! : sourceURL.deletingPathExtension().lastPathComponent
            finalAuthor = authorText
        }

        let fixedLayoutPageViewports: [Int: CGSize] = Dictionary(
            uniqueKeysWithValues: chapters.compactMap { chapter in
                guard let viewport = chapter.fixedLayoutViewport else { return nil }
                return (chapter.index, viewport)
            }
        )
        let mediaOverlaysByChapter = await parseMediaOverlays(
            from: sourceURL,
            chapters: chapters
        )
        let pronunciationLexicons = await parsePronunciationLexicons(
            from: sourceURL,
            manifestItemsByID: opfMetadata.manifestItemsByID
        )

        let obfuscationIdentifier: String?
        let encryptionAlgorithmsByHref: [String: String]
        if encryptionIsCached {
            // Use cached encryption metadata — skip ZIP I/O entirely
            obfuscationIdentifier = cachedEncryptionIdentifier
            encryptionAlgorithmsByHref = cachedEncryptionAlgorithms ?? [:]
        } else {
            let (parsedIdentifier, parsedAlgorithms) = await epubEncryptionMetadata(from: sourceURL)
            obfuscationIdentifier = parsedIdentifier
            encryptionAlgorithmsByHref = parsedAlgorithms
            // Persist encryption metadata into SpinesCache
            if let data = try? Data(contentsOf: cacheURL),
               var cache = try? JSONDecoder().decode(SpinesCache.self, from: data) {
                cache.encryptionIdentifier = parsedIdentifier
                cache.encryptionAlgorithms = parsedAlgorithms
                if let encoded = try? JSONEncoder().encode(cache) {
                    try? encoded.write(to: cacheURL)
                }
            }
        }

        let session = PublicationSession(
            id: UUID().uuidString.lowercased(),
            sourceURL: sourceURL,
            publication: publication,
            bookTitle: finalTitle,
            author: finalAuthor,
            language: opfMetadata.language,
            chapters: chapters,
            tocEntries: tocEntries,
            epubWritingMode: epubWritingMode,
            pageProgressionDirection: opfMetadata.pageProgressionDirection,
            layoutMode: opfMetadata.layoutMode,
            flowMode: opfMetadata.flowMode,
            fixedLayoutSpread: opfMetadata.fixedLayoutSpread,
            fixedLayoutOrientation: opfMetadata.fixedLayoutOrientation,
            fixedLayoutViewport: FixedLayoutViewport(
                defaultViewport: opfMetadata.defaultViewport,
                pageViewports: fixedLayoutPageViewports
            ),
            opfManifestItemsByID: opfMetadata.manifestItemsByID,
            opfSpineReferences: opfMetadata.spineReferences,
            pronunciationLexicons: pronunciationLexicons,
            mediaOverlaysByChapter: mediaOverlaysByChapter,
            cachedChapterByteSizes: cachedByteSizes,
            obfuscationIdentifier: obfuscationIdentifier,
            encryptionAlgorithmsByHref: encryptionAlgorithmsByHref,
            cacheURL: cacheURL
        )
        PublicationSessionRegistry.shared.register(session)
        return session
    }

    static func extractCoverImage(sourceURL: URL) async -> UIImage? {
        let startUptime = ProcessInfo.processInfo.systemUptime
        func coverTrace(_ message: String) {
            let line = "[ImportTrace][PublicationSession.cover] \(message)"
            print(line)
            NSLog("%@", line)
        }
        coverTrace("begin file=\(sourceURL.lastPathComponent)")
        guard let publication = try? await openPublication(sourceURL: sourceURL) else {
            coverTrace("openPublication failed")
            return nil
        }
        coverTrace(
            "openPublication done elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - startUptime) * 1000))"
        )
        switch await publication.cover() {
        case .success(let image):
            coverTrace(
                "cover success elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - startUptime) * 1000))"
            )
            return image
        case .failure:
            coverTrace(
                "cover missing elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - startUptime) * 1000))"
            )
            return nil
        }
    }

    func resourceURL(for href: String) -> URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = id
        let normalized = href.hasPrefix("/") ? href : "/\(href)"
        components.percentEncodedPath = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalized
        return components.url ?? URL(string: "\(Self.scheme)://\(id)\(normalized)")!
    }

    func chapterBaseURL(at index: Int) -> URL {
        resourceURL(for: chapters[index].href)
    }

    func chapterDataSize(at index: Int) async throws -> Int {
        let descriptor = chapters[index]
        guard let resource = resource(for: descriptor.href) else {
            throw PublicationSessionError.resourceNotFound(descriptor.href)
        }
        // estimatedLength() reads ZIP central directory uncompressedSize — no decompression needed
        if case .success(let length) = await resource.estimatedLength(), let length {
            return Int(length)
        }
        // fallback for non-ZIP resources or if metadata unavailable
        switch await resource.read() {
        case .success(let data): return data.count
        case .failure: return 0
        }
    }

    func chapterIndex(for href: String) -> Int? {
        let normalized = Self.normalizedHREF(href)
        if let index = chapters.firstIndex(where: {
            $0.href == normalized || normalized.hasSuffix($0.href) || $0.href.hasSuffix(normalized)
        }) {
            return index
        }
        // Obfuscated-filename EPUBs (`Text/_*:*….html`) can reach us in mixed encodings: a
        // tapped `<a href>` is the author's raw string while the stored spine href may be
        // percent-encoded (or the reverse, e.g. through an older spine cache). Retry on the
        // percent-decoded forms of both sides before giving up.
        let decodedTarget = normalized.removingPercentEncoding ?? normalized
        return chapters.firstIndex(where: {
            let decoded = $0.href.removingPercentEncoding ?? $0.href
            return decoded == decodedTarget
                || decodedTarget.hasSuffix(decoded)
                || decoded.hasSuffix(decodedTarget)
        })
    }

    func chapterHTML(at index: Int) async throws -> String {
        let descriptor = chapters[index]
        guard let resource = resource(for: descriptor.href) else {
            throw PublicationSessionError.resourceReadFailed(descriptor.href)
        }

        let data: Data
        switch await resource.read() {
        case .success(let value):
            data = value
        case .failure:
            throw PublicationSessionError.resourceReadFailed(descriptor.href)
        }

        let mediaType = link(for: descriptor.href)?.mediaType
        if let encoding = mediaType?.encoding,
           let html = String(data: data, encoding: encoding)
        {
            return html
        }

        for encoding in [String.Encoding.utf8, .unicode, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1] {
            if let html = String(data: data, encoding: encoding) {
                return html
            }
        }

        throw PublicationSessionError.resourceReadFailed(descriptor.href)
    }

    func response(for requestURL: URL) async throws -> PublicationResourceResponse {
        guard requestURL.scheme == Self.scheme, requestURL.host == id else {
            throw PublicationSessionError.resourceNotFound(requestURL.absoluteString)
        }
        let href = Self.normalizedHREF(resolvedHREF(from: requestURL))
        guard let resource = resource(for: href) else {
            throw PublicationSessionError.resourceNotFound(href)
        }

        let properties = try? await resource.properties().get()
        let data: Data
        let encryptionAlgorithm = link(for: href)?.properties.encryption?.algorithm
            ?? encryptionAlgorithmsByHref[href]
            ?? algorithmForHref(href)
        switch await resource.read() {
        case .success(let value):
            let rawData = await rawArchiveData(for: href) ?? value
            data = transformedDataIfNeeded(
                rawData,
                href: href,
                algorithm: encryptionAlgorithm
            )
        case .failure:
            throw PublicationSessionError.resourceNotFound(href)
        }

        let mimeType =
            link(for: href)?.mediaType?.string
            ?? properties?.mediaType?.string
            ?? fallbackMimeType(for: href)
        let isText =
            mimeType.contains("html")
            || mimeType.contains("xml")
            || mimeType.contains("css")
            || mimeType.contains("javascript")
            || mimeType.hasPrefix("text/")

        return PublicationResourceResponse(
            data: data,
            mimeType: mimeType,
            textEncodingName: isText ? "utf-8" : nil
        )
    }

    func readerLocator(
        chapterIndex: Int,
        pageInChapter: Int,
        totalPagesInChapter: Int,
        globalPage: Int,
        totalPages: Int,
        generationId: Int
    ) async -> ReaderLocator {
        let chapterProgression = totalPagesInChapter > 1
            ? Double(pageInChapter) / Double(max(totalPagesInChapter - 1, 1))
            : 0
        let totalProgression = totalPages > 1
            ? Double(globalPage) / Double(max(totalPages - 1, 1))
            : chapterProgression

        return ReaderLocator(
            spineHref: chapters[chapterIndex].href,
            chapterIndex: chapterIndex,
            pageInChapter: pageInChapter,
            totalPagesInChapter: totalPagesInChapter,
            globalPage: globalPage,
            progression: totalProgression,
            generationId: generationId,
            title: chapters[chapterIndex].title,
            chapterProgression: chapterProgression,
            totalProgression: totalProgression
        )
    }

    func resolve(locator: ReaderLocator) async -> (chapterIndex: Int, chapterProgression: Double)? {
        let chapterIndex = chapterIndex(for: locator.spineHref)
            ?? (chapters.indices.contains(locator.chapterIndex) ? locator.chapterIndex : nil)
        guard let chapterIndex else { return nil }
        return (chapterIndex, locator.chapterProgression ?? locator.progression)
    }

    // MARK: - Internal

    private func resolvedHREF(from url: URL) -> String {
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let decodedPath = path.removingPercentEncoding ?? path
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        if let query, !query.isEmpty {
            return "\(decodedPath)?\(query)"
        }
        return decodedPath
    }

    private func resource(for href: String) -> Resource? {
        readiumURLs(for: href).lazy
            .compactMap { [self] href in
                if let link = self.publication.linkWithHREF(href) {
                    return self.publication.get(link) ?? self.publication.get(href)
                }
                return self.publication.get(href)
            }
            .first
    }

    private func link(for href: String) -> Link? {
        readiumURLs(for: href).lazy
            .compactMap(publication.linkWithHREF(_:))
            .first
    }

    private func readiumURLs(for href: String) -> [AnyURL] {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let basePath = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        let candidates = [trimmed, basePath, "/\(basePath)"]
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard let url = AnyURL(legacyHREF: candidate) else {
                return nil
            }
            let normalized = url.normalized
            guard seen.insert(normalized.string).inserted else {
                return nil
            }
            return normalized
        }
    }

    private func fallbackMimeType(for href: String) -> String {
        switch URL(fileURLWithPath: href).pathExtension.lowercased() {
        case "html", "htm":
            return "text/html"
        case "xhtml":
            return "application/xhtml+xml"
        case "css":
            return "text/css"
        case "js":
            return "text/javascript"
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "woff":
            return "font/woff"
        case "woff2":
            return "font/woff2"
        case "ttf":
            return "font/ttf"
        case "otf":
            return "font/otf"
        default:
            return "application/octet-stream"
        }
    }

    private func transformedDataIfNeeded(_ data: Data, href: String, algorithm: String?) -> Data {
        guard let effectiveAlgorithm = algorithm ?? algorithmForHref(href) else {
            return data
        }

        resourceLock.lock()
        if let cached = transformedResourceCache[href] {
            resourceLock.unlock()
            return cached
        }
        resourceLock.unlock()

        let transformed = deobfuscate(data: data, algorithm: effectiveAlgorithm) ?? data

        resourceLock.lock()
        transformedResourceCache[href] = transformed
        resourceLock.unlock()
        return transformed
    }

    private func deobfuscate(data: Data, algorithm: String) -> Data? {
        guard
            let key = obfuscationKey(for: algorithm),
            let obfuscatedLength = obfuscatedLength(for: algorithm),
            !key.isEmpty
        else {
            return nil
        }

        var bytes = [UInt8](data)
        let limit = min(obfuscatedLength, bytes.count)
        for index in 0..<limit {
            bytes[index] ^= key[index % key.count]
        }
        return Data(bytes)
    }

    private func obfuscationKey(for algorithm: String) -> [UInt8]? {
        let publicationId = (obfuscationIdentifier ?? publication.metadata.identifier ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard !publicationId.isEmpty, publicationId != "urn:uuid:" else {
            return nil
        }

        switch algorithm {
        case "http://www.idpf.org/2008/embedding":
            return Array(Insecure.SHA1.hash(data: Data(publicationId.utf8)))
        case "http://ns.adobe.com/pdf/enc#RC":
            return Self.hexBytes(
                from: publicationId
                    .replacingOccurrences(of: "urn:uuid:", with: "")
                    .replacingOccurrences(of: "-", with: "")
            )
        default:
            return nil
        }
    }

    private func obfuscatedLength(for algorithm: String) -> Int? {
        switch algorithm {
        case "http://www.idpf.org/2008/embedding":
            return 1040
        case "http://ns.adobe.com/pdf/enc#RC":
            return 1024
        default:
            return nil
        }
    }

    private static func hexBytes(from string: String) -> [UInt8] {
        var position = string.startIndex
        return (0..<(string.count / 2)).compactMap { _ in
            defer { position = string.index(position, offsetBy: 2) }
            let end = string.index(position, offsetBy: 2)
            return UInt8(string[position..<end], radix: 16)
        }
    }

    private static func epubEncryptionMetadata(from sourceURL: URL) async -> (String?, [String: String]) {
        guard let archive = try? await Archive(url: sourceURL, accessMode: .read) else {
            return (nil, [:])
        }
        guard
            let containerXML = await readArchiveEntry("META-INF/container.xml", archive: archive),
            let opfPath = firstMatch(
                in: containerXML,
                pattern: #"full-path\s*=\s*"([^"]+)""#
            ),
            let opfXML = await readArchiveEntry(opfPath, archive: archive)
        else {
            return (nil, [:])
        }

        let uniqueID = firstMatch(in: opfXML, pattern: #"unique-identifier\s*=\s*"([^"]+)""#)
        var identifier: String?
        if let uniqueID {
            let escapedID = NSRegularExpression.escapedPattern(for: uniqueID)
            let patterns = [
                #"<dc:identifier[^>]*\sid\s*=\s*""# + escapedID + #""[^>]*>(.*?)</dc:identifier>"#,
                #"<identifier[^>]*\sid\s*=\s*""# + escapedID + #""[^>]*>(.*?)</identifier>"#,
            ]

            for pattern in patterns {
                if let matchedIdentifier = firstMatch(in: opfXML, pattern: pattern, dotMatchesLineSeparators: true)?
                    .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !matchedIdentifier.isEmpty {
                    identifier = matchedIdentifier
                    break
                }
            }
        }

        let basePath = (opfPath as NSString).deletingLastPathComponent
        var algorithmsByHref: [String: String] = [:]
        if let encryptionXML = await readArchiveEntry("META-INF/encryption.xml", archive: archive),
           let regex = try? NSRegularExpression(
                pattern: #"<enc:EncryptionMethod[^>]*Algorithm="([^"]+)"[\s\S]*?<enc:CipherReference[^>]*URI="([^"]+)""#,
                options: [.caseInsensitive]
           ) {
            let nsXML = encryptionXML as NSString
            for match in regex.matches(in: encryptionXML, range: NSRange(location: 0, length: nsXML.length)) {
                guard match.numberOfRanges > 2 else { continue }
                let algorithm = nsXML.substring(with: match.range(at: 1))
                let href = nsXML.substring(with: match.range(at: 2))
                let normalizedHref = normalizedResourcePath(href, relativeTo: basePath)
                algorithmsByHref[normalizedHref] = algorithm
            }
        }
        return (identifier, algorithmsByHref)
    }

    private struct OPFMetadataResult {
        let language: String?
        let writingMode: EPUBWritingMode
        let pageProgressionDirection: EPUBPageProgressionDirection
        let layoutMode: EPUBLayoutMode
        let flowMode: EPUBFlowMode
        let fixedLayoutSpread: FixedLayoutSpread
        let fixedLayoutOrientation: FixedLayoutOrientation
        let defaultViewport: CGSize?
        let spineMetadataByHref: [String: OPFSpineItemMetadata]
        let manifestItemsByID: [String: EPUBManifestReference]
        let spineReferences: [EPUBSpineReference]
    }

    private struct OPFSpineItemMetadata {
        var spreadSide: FixedLayoutSpreadSide = .auto
        var viewport: CGSize?
        var layoutModeOverride: EPUBLayoutMode?
        var spreadOverride: FixedLayoutSpread?
        var orientationOverride: FixedLayoutOrientation?
    }

    private static func firstMetaPropertyValue(in xml: String, property: String) -> String? {
        if let value = metaElements(in: xml).first(where: { $0.property == property.lowercased() })?.value,
           !value.isEmpty {
            return value
        }

        let escapedProperty = NSRegularExpression.escapedPattern(for: property)
        // Form 1: content="value" attribute
        let attrPattern = #"<meta[^>]*property\s*=\s*""# + escapedProperty + #""[^>]*content\s*=\s*"([^"]*)"[^>]*>"#
        if let value = firstMatch(in: xml, pattern: attrPattern) { return value }
        // Form 2: text content >value</meta>
        let textPattern = #"<meta[^>]*property\s*=\s*""# + escapedProperty + #""[^>]*>\s*([^<]+)\s*</meta>"#
        return firstMatch(in: xml, pattern: textPattern)
    }

    private static func parseOPFMetadata(from sourceURL: URL) async -> OPFMetadataResult {
        let fallback = OPFMetadataResult(
            language: nil,
            writingMode: .unspecified,
            pageProgressionDirection: .default,
            layoutMode: .reflowable,
            flowMode: .auto,
            fixedLayoutSpread: .auto,
            fixedLayoutOrientation: .auto,
            defaultViewport: nil,
            spineMetadataByHref: [:],
            manifestItemsByID: [:],
            spineReferences: []
        )
        guard let archive = try? await Archive(url: sourceURL, accessMode: .read) else { return fallback }
        guard
            let containerXML = await readArchiveEntry("META-INF/container.xml", archive: archive),
            let opfPath = firstMatch(in: containerXML, pattern: #"full-path\s*=\s*"([^"]+)""#),
            let opfXML = await readArchiveEntry(opfPath, archive: archive)
        else { return fallback }

        return parseOPFMetadataXML(opfXML, opfPath: opfPath)
    }

    private static func parseOPFMetadataXML(_ opfXML: String, opfPath: String) -> OPFMetadataResult {
        var writingMode: EPUBWritingMode = .unspecified
        let language = firstLanguageValue(in: opfXML)

        // <meta name="primary-writing-mode" content="vertical-rl"/>
        if let wm = firstMatch(in: opfXML, pattern: #"<meta[^>]*name\s*=\s*"primary-writing-mode"[^>]*content\s*=\s*"([^"]+)"[^>]*>"#)?.lowercased() {
            if wm.contains("vertical") { writingMode = .verticalRL }
            if wm.contains("horizontal") { writingMode = .horizontal }
        }

        // EPUB3 rendition:layout
        let layoutMode: EPUBLayoutMode
        if let layout = firstMetaPropertyValue(in: opfXML, property: "rendition:layout")?.lowercased() {
            layoutMode = layout.contains("pre-paginated") ? .prePaginated : .reflowable
        } else {
            layoutMode = .reflowable
        }

        // EPUB3 rendition:flow
        let flowMode: EPUBFlowMode
        if let flow = firstMetaPropertyValue(in: opfXML, property: "rendition:flow")?.lowercased() {
            if flow.contains("scrolled-doc") {
                flowMode = .scrolledDoc
            } else if flow.contains("scrolled-continuous") {
                flowMode = .scrolledContinuous
            } else if flow.contains("pre-paginated") {
                flowMode = .paginated
            } else {
                flowMode = .auto
            }
        } else {
            flowMode = .auto
        }

        let fixedLayoutSpread = FixedLayoutSpread.parse(firstMetaPropertyValue(in: opfXML, property: "rendition:spread"))
        let fixedLayoutOrientation = FixedLayoutOrientation.parse(firstMetaPropertyValue(in: opfXML, property: "rendition:orientation"))

        // spine page-progression-direction controls page-turn flow only (rtl = pages
        // advance right-to-left). It is independent of writing mode. Historically `rtl`
        // also implied CJK vertical-rl, but RTL bidi scripts (Hebrew, Arabic, …) are
        // horizontal RTL and must never be forced vertical. Gate the vertical fallback
        // on language, and only apply it when no explicit writing mode was declared.
        let pageProgressionDirection: EPUBPageProgressionDirection
        if let ppd = firstMatch(in: opfXML, pattern: #"<spine[^>]*page-progression-direction\s*=\s*"([^"]+)"[^>]*>"#)?.lowercased() {
            if ppd == "rtl" {
                pageProgressionDirection = .rtl
                let isRTLScript = HTMLWritingDirectionResolver.defaultDirection(forLanguage: language) == .rightToLeft
                if writingMode == .unspecified && !isRTLScript {
                    writingMode = .verticalRL
                }
            } else if ppd == "ltr" {
                pageProgressionDirection = .ltr
            } else {
                pageProgressionDirection = .default
            }
        } else {
            pageProgressionDirection = .default
        }

        // EPUB3 rendition:viewport
        let defaultViewport: CGSize?
        if let vp = firstMetaPropertyValue(in: opfXML, property: "rendition:viewport") {
            defaultViewport = parseViewportString(vp)
        } else {
            defaultViewport = nil
        }

        return OPFMetadataResult(
            language: language,
            writingMode: writingMode,
            pageProgressionDirection: pageProgressionDirection,
            layoutMode: layoutMode,
            flowMode: flowMode,
            fixedLayoutSpread: fixedLayoutSpread,
            fixedLayoutOrientation: fixedLayoutOrientation,
            defaultViewport: defaultViewport,
            spineMetadataByHref: parseSpineMetadata(in: opfXML, opfPath: opfPath),
            manifestItemsByID: parseManifestReferences(in: opfXML, opfPath: opfPath),
            spineReferences: parseSpineReferences(in: opfXML, opfPath: opfPath)
        )
    }

    private static func firstLanguageValue(in opfXML: String) -> String? {
        if let value = firstMatch(
            in: opfXML,
            pattern: #"<(?:[A-Za-z0-9_-]+:)?language\b[^>]*>\s*([^<]+?)\s*</(?:[A-Za-z0-9_-]+:)?language>"#,
            dotMatchesLineSeparators: true
        )?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        if let value = firstMetaPropertyValue(in: opfXML, property: "dcterms:language")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return nil
    }

    private static func parseSpineMetadata(in opfXML: String, opfPath: String) -> [String: OPFSpineItemMetadata] {
        let basePath = (opfPath as NSString).deletingLastPathComponent
        let manifestItems = manifestItemsByID(in: opfXML, relativeTo: basePath)
        let refinedViewports = refinedViewportByID(in: opfXML)
        let itemrefPattern = #"<itemref\b([^>]*)>"#
        guard let regex = try? NSRegularExpression(pattern: itemrefPattern, options: [.caseInsensitive]) else {
            return [:]
        }

        var metadataByHref: [String: OPFSpineItemMetadata] = [:]
        let nsXML = opfXML as NSString
        for match in regex.matches(in: opfXML, range: NSRange(location: 0, length: nsXML.length)) {
            guard match.numberOfRanges > 1 else { continue }
            let tag = nsXML.substring(with: match.range(at: 1))
            let attrs = attributes(in: tag)
            guard let idref = attrs["idref"], let item = manifestItems[idref] else { continue }

            var metadata = OPFSpineItemMetadata()
            let tokens = propertyTokens(attrs["properties"])
            metadata.spreadSide = spreadSide(from: tokens)
            metadata.layoutModeOverride = layoutModeOverride(from: tokens)
            metadata.spreadOverride = spreadOverride(from: tokens)
            metadata.orientationOverride = orientationOverride(from: tokens)
            metadata.viewport = refinedViewports[attrs["id"] ?? ""] ?? refinedViewports[idref]

            let href = normalizedResourcePath(item.href, relativeTo: basePath)
            metadataByHref[href] = metadata
        }

        for (id, viewport) in refinedViewports {
            guard let item = manifestItems[id] else { continue }
            let href = normalizedResourcePath(item.href, relativeTo: basePath)
            var metadata = metadataByHref[href] ?? OPFSpineItemMetadata()
            metadata.viewport = viewport
            metadataByHref[href] = metadata
        }

        return metadataByHref
    }

    private static func parseManifestReferences(in opfXML: String, opfPath: String) -> [String: EPUBManifestReference] {
        let basePath = (opfPath as NSString).deletingLastPathComponent
        return manifestItemsByID(in: opfXML, relativeTo: basePath).reduce(into: [:]) { result, entry in
            result[entry.key] = EPUBManifestReference(
                id: entry.key,
                href: normalizedResourcePath(entry.value.href, relativeTo: basePath),
                mediaType: entry.value.mediaType
            )
        }
    }

    private static func parseSpineReferences(in opfXML: String, opfPath: String) -> [EPUBSpineReference] {
        let basePath = (opfPath as NSString).deletingLastPathComponent
        let manifestItems = manifestItemsByID(in: opfXML, relativeTo: basePath)
        let itemrefPattern = #"<itemref\b([^>]*)>"#
        guard let regex = try? NSRegularExpression(pattern: itemrefPattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsXML = opfXML as NSString
        var references: [EPUBSpineReference] = []
        for match in regex.matches(in: opfXML, range: NSRange(location: 0, length: nsXML.length)) {
            guard match.numberOfRanges > 1 else { continue }
            let attrs = attributes(in: nsXML.substring(with: match.range(at: 1)))
            guard let idref = attrs["idref"], let item = manifestItems[idref] else { continue }
            references.append(EPUBSpineReference(
                index: references.count,
                idref: idref,
                itemrefID: attrs["id"],
                href: normalizedResourcePath(item.href, relativeTo: basePath),
                linear: attrs["linear"]?.lowercased() != "no"
            ))
        }
        return references
    }

    private static func parsePronunciationLexicons(
        from sourceURL: URL,
        manifestItemsByID: [String: EPUBManifestReference]
    ) async -> [PLSLexicon] {
        guard let archive = try? await Archive(url: sourceURL, accessMode: .read) else { return [] }
        var lexicons: [PLSLexicon] = []
        for item in manifestItemsByID.values
        where item.mediaType?.lowercased() == "application/pls+xml" {
            guard let xml = await readArchiveEntry(item.href, archive: archive),
                  let lexicon = PLSLexicon.parse(data: Data(xml.utf8), href: item.href)
            else { continue }
            lexicons.append(lexicon)
        }
        return lexicons
    }

    private static func parseMediaOverlays(
        from sourceURL: URL,
        chapters: [PublicationChapterDescriptor]
    ) async -> [Int: EPUBMediaOverlay] {
        guard let archive = try? await Archive(url: sourceURL, accessMode: .read),
              let containerXML = await readArchiveEntry("META-INF/container.xml", archive: archive),
              let opfPath = firstMatch(in: containerXML, pattern: #"full-path\s*=\s*"([^"]+)""#),
              let opfXML = await readArchiveEntry(opfPath, archive: archive)
        else { return [:] }

        let basePath = (opfPath as NSString).deletingLastPathComponent
        let manifestItems = manifestItemsByID(in: opfXML, relativeTo: basePath)
        let manifestItemsByHref = Dictionary(
            manifestItems.values.map { item in
                (normalizedResourcePath(item.href, relativeTo: basePath), item)
            },
            uniquingKeysWith: { first, _ in first }
        )

        var overlays: [Int: EPUBMediaOverlay] = [:]
        for chapter in chapters {
            guard let chapterItem = manifestItemsByHref[chapter.href],
                  let smilID = chapterItem.mediaOverlayID,
                  let smilItem = manifestItems[smilID]
            else { continue }
            let smilHref = normalizedResourcePath(smilItem.href, relativeTo: basePath)
            guard let smilXML = await readArchiveEntry(smilHref, archive: archive) else { continue }
            let parsed = SMILMediaOverlayParser.parse(
                xml: smilXML,
                smilHref: smilHref,
                chapterHref: chapter.href
            )
            let normalized = normalizeMediaOverlay(parsed, chapterHref: chapter.href)
            guard !normalized.fragments.isEmpty else { continue }
            overlays[chapter.index] = normalized
        }
        return overlays
    }

    private static func normalizeMediaOverlay(
        _ overlay: EPUBMediaOverlay,
        chapterHref: String
    ) -> EPUBMediaOverlay {
        let smilBase = (overlay.smilHref as NSString).deletingLastPathComponent
        let fragments = overlay.fragments.map { fragment in
            let textHref = fragment.textHref.map {
                normalizedResourcePath($0, relativeTo: smilBase)
            } ?? chapterHref
            return EPUBMediaOverlayFragment(
                id: fragment.id,
                textHref: textHref,
                textFragmentID: fragment.textFragmentID,
                audioHref: normalizedResourcePath(fragment.audioHref, relativeTo: smilBase),
                clipBegin: fragment.clipBegin,
                clipEnd: fragment.clipEnd
            )
        }
        return EPUBMediaOverlay(
            chapterHref: chapterHref,
            smilHref: overlay.smilHref,
            fragments: fragments
        )
    }

    private struct OPFManifestItem {
        let href: String
        let mediaType: String?
        let mediaOverlayID: String?
    }

    private static func manifestItemsByID(in opfXML: String, relativeTo basePath: String) -> [String: OPFManifestItem] {
        let pattern = #"<item\b([^>]*)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return [:]
        }
        let nsXML = opfXML as NSString
        var items: [String: OPFManifestItem] = [:]
        for match in regex.matches(in: opfXML, range: NSRange(location: 0, length: nsXML.length)) {
            guard match.numberOfRanges > 1 else { continue }
            let attrs = attributes(in: nsXML.substring(with: match.range(at: 1)))
            guard let id = attrs["id"], let href = attrs["href"] else { continue }
            items[id] = OPFManifestItem(
                href: href,
                mediaType: attrs["media-type"],
                mediaOverlayID: attrs["media-overlay"]
            )
        }
        return items
    }

    private static func refinedViewportByID(in opfXML: String) -> [String: CGSize] {
        metaElements(in: opfXML).reduce(into: [:]) { result, meta in
            guard meta.property == "rendition:viewport",
                  let refines = meta.refines?.trimmingCharacters(in: CharacterSet(charactersIn: "#")),
                  let viewport = parseViewportString(meta.value)
            else { return }
            result[refines] = viewport
        }
    }

    private struct OPFMetaElement {
        let property: String?
        let refines: String?
        let value: String
    }

    private static func metaElements(in opfXML: String) -> [OPFMetaElement] {
        let pattern = #"<meta\b([^>]*)>([\s\S]*?)</meta>|<meta\b([^>]*)/?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let nsXML = opfXML as NSString
        return regex.matches(in: opfXML, range: NSRange(location: 0, length: nsXML.length)).compactMap { match in
            let attrsRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 3)
            guard attrsRange.location != NSNotFound else { return nil }
            let attrs = attributes(in: nsXML.substring(with: attrsRange))
            let text: String
            if match.range(at: 2).location != NSNotFound {
                text = nsXML.substring(with: match.range(at: 2))
                    .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                text = ""
            }
            let value = attrs["content"] ?? text
            return OPFMetaElement(
                property: attrs["property"]?.lowercased(),
                refines: attrs["refines"],
                value: value
            )
        }
    }

    private static func attributes(in tag: String) -> [String: String] {
        let pattern = #"([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*(['"])(.*?)\2"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [:]
        }
        let nsTag = tag as NSString
        var attrs: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(location: 0, length: nsTag.length)) {
            guard match.numberOfRanges > 3 else { continue }
            let key = nsTag.substring(with: match.range(at: 1)).lowercased()
            let value = nsTag.substring(with: match.range(at: 3))
            attrs[key] = value
        }
        return attrs
    }

    private static func propertyTokens(_ raw: String?) -> Set<String> {
        Set(
            (raw ?? "")
                .split { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    private static func spreadSide(from tokens: Set<String>) -> FixedLayoutSpreadSide {
        if tokens.contains("page-spread-left") || tokens.contains("rendition:page-spread-left") {
            return .left
        }
        if tokens.contains("page-spread-right") || tokens.contains("rendition:page-spread-right") {
            return .right
        }
        if tokens.contains("page-spread-center") || tokens.contains("rendition:page-spread-center") {
            return .center
        }
        return .auto
    }

    private static func layoutModeOverride(from tokens: Set<String>) -> EPUBLayoutMode? {
        if tokens.contains("rendition:layout-pre-paginated") || tokens.contains("layout-pre-paginated") {
            return .prePaginated
        }
        if tokens.contains("rendition:layout-reflowable") || tokens.contains("layout-reflowable") {
            return .reflowable
        }
        return nil
    }

    private static func spreadOverride(from tokens: Set<String>) -> FixedLayoutSpread? {
        for token in tokens {
            guard token.hasPrefix("rendition:spread-") || token.hasPrefix("spread-") else { continue }
            return FixedLayoutSpread.parse(token.replacingOccurrences(of: "rendition:spread-", with: "").replacingOccurrences(of: "spread-", with: ""))
        }
        return nil
    }

    private static func orientationOverride(from tokens: Set<String>) -> FixedLayoutOrientation? {
        for token in tokens {
            guard token.hasPrefix("rendition:orientation-") || token.hasPrefix("orientation-") else { continue }
            return FixedLayoutOrientation.parse(token.replacingOccurrences(of: "rendition:orientation-", with: "").replacingOccurrences(of: "orientation-", with: ""))
        }
        return nil
    }

    private static func parseViewportString(_ raw: String) -> CGSize? {
        let parts = raw.components(separatedBy: CharacterSet(charactersIn: ",; "))
        var w: CGFloat?
        var h: CGFloat?
        for part in parts {
            let kv = part.components(separatedBy: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0].lowercased() {
            case "width": w = CGFloat(Double(kv[1]) ?? 0)
            case "height": h = CGFloat(Double(kv[1]) ?? 0)
            default: break
            }
        }
        guard let w, let h, w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    private static func readArchiveEntry(_ path: String, archive: Archive) async -> String? {
        guard let entry = try? await archive.get(path) else { return nil }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        _ = try? await archive.extract(entry, to: tempURL, skipCRC32: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let data = try? Data(contentsOf: tempURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func firstMatch(
        in string: String,
        pattern: String,
        dotMatchesLineSeparators: Bool = false
    ) -> String? {
        let options: NSRegularExpression.Options = dotMatchesLineSeparators ? [.caseInsensitive, .dotMatchesLineSeparators] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let nsString = string as NSString
        guard let match = regex.firstMatch(in: string, range: NSRange(location: 0, length: nsString.length)),
              match.numberOfRanges > 1
        else {
            return nil
        }
        return nsString.substring(with: match.range(at: 1))
    }

    private static func normalizedResourcePath(_ href: String, relativeTo basePath: String) -> String {
        guard !href.hasPrefix("/") else { return String(href.dropFirst()) }
        let combined = basePath.isEmpty ? href : basePath + "/" + href
        var stack: [String] = []
        for segment in combined.components(separatedBy: "/") {
            switch segment {
            case "", ".":
                break
            case "..":
                if !stack.isEmpty { stack.removeLast() }
            default:
                stack.append(segment)
            }
        }
        return stack.joined(separator: "/")
    }

    private func algorithmForHref(_ href: String) -> String? {
        let normalized = Self.normalizedHREF(href)
        if let exact = encryptionAlgorithmsByHref[normalized] {
            return exact
        }

        let basename = (normalized as NSString).lastPathComponent
        if let basenameMatch = encryptionAlgorithmsByHref[basename] {
            return basenameMatch
        }

        if let suffixMatch = encryptionAlgorithmsByHref.first(where: {
            normalized.hasSuffix($0.key) || $0.key.hasSuffix(normalized)
        })?.value {
            return suffixMatch
        }

        return nil
    }

    private func rawArchiveData(for href: String) async -> Data? {
        guard let archive = try? await Archive(url: sourceURL, accessMode: .read) else {
            return nil
        }

        let normalized = Self.normalizedHREF(href)
        let basename = (normalized as NSString).lastPathComponent

        let entry: Entry?
        if let exact = try? await archive.get(normalized) {
            entry = exact
        } else if let base = try? await archive.get(basename) {
            entry = base
        } else if let entries = try? await archive.entries() {
            entry = entries.first(where: { $0.path == normalized || $0.path.hasSuffix("/" + basename) || normalized.hasSuffix($0.path) || $0.path.hasSuffix(normalized) })
        } else {
            entry = nil
        }

        guard let entry else { return nil }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        _ = try? await archive.extract(entry, to: tempURL, skipCRC32: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try? Data(contentsOf: tempURL)
    }

    private static func openPublication(sourceURL: URL) async throws -> Publication {
        guard let fileURL = FileURL(url: sourceURL) else {
            throw PublicationSessionError.parsingFailed("Invalid file URL")
        }

        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let asset: Asset
        switch await assetRetriever.retrieve(url: fileURL, hints: FormatHints(mediaType: .epub)) {
        case .success(let value):
            asset = value
        case .failure(let error):
            throw PublicationSessionError.parsingFailed(error.localizedDescription)
        }

        let opener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )
        switch await opener.open(asset: asset, allowUserInteraction: false) {
        case .success(let publication):
            return publication
        case .failure(let error):
            throw PublicationSessionError.parsingFailed(error.localizedDescription)
        }
    }

    private static func chapterLinks(from publication: Publication) -> [Link] {
        let htmlLinks = publication.readingOrder.filter {
            if let mediaType = $0.mediaType {
                return mediaType.isHTML
            }
            let ext = URL(fileURLWithPath: $0.href).pathExtension.lowercased()
            return ext == "html" || ext == "htm" || ext == "xhtml"
        }
        return htmlLinks.isEmpty ? publication.readingOrder : htmlLinks
    }

    private static func flattenTableOfContents(_ links: [Link], level: Int = 0) -> [EPUBTocEntry] {
        links.flatMap { link in
            let href = normalizedTOCHREF(link.href)
            let ownEntry: [EPUBTocEntry]
            if !href.isEmpty {
                ownEntry = [
                    EPUBTocEntry(
                        href: href,
                        title: sanitizedTitle(link.title, fallbackHref: href),
                        level: level
                    )
                ]
            } else {
                ownEntry = []
            }
            return ownEntry + flattenTableOfContents(link.children, level: level + 1)
        }
    }

    static func normalizedTOCHREF(_ href: String) -> String {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let pathPart = parts.first.map(String.init) ?? ""
        let fragmentPart = parts.count > 1 ? String(parts[1]) : nil

        let normalizedPath: String
        if let url = URL(string: pathPart), url.scheme != nil {
            normalizedPath = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        } else {
            normalizedPath = pathPart.hasPrefix("/") ? String(pathPart.dropFirst()) : pathPart
        }

        if let fragmentPart {
            return "\(normalizedPath)#\(fragmentPart)"
        }
        return normalizedPath
    }

    private static func normalizedHREF(_ href: String) -> String {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let noFragment = trimmed.components(separatedBy: "#").first ?? trimmed
        if let url = URL(string: noFragment), url.scheme != nil {
            return (url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path)
        }
        return noFragment.hasPrefix("/") ? String(noFragment.dropFirst()) : noFragment
    }

    private static func sanitizedTitle(
        _ rawTitle: String?,
        fallbackHref: String,
        chapterIndex: Int? = nil
    ) -> String {
        let fallback = fallbackTitle(for: fallbackHref, chapterIndex: chapterIndex)
        guard var title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return fallback
        }

        title = title.replacingOccurrences(
            of: #"<\?xml[\s\S]*?\?>"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"<!DOCTYPE[\s\S]*?>"#,
            with: " ",
            options: .regularExpression
        )

        if title.contains("<") || title.contains("&") {
            if
                let data = title.data(using: .utf8),
                let decoded = try? NSAttributedString(
                    data: data,
                    options: [
                        .documentType: NSAttributedString.DocumentType.html,
                        .characterEncoding: String.Encoding.utf8.rawValue
                    ],
                    documentAttributes: nil
                ).string
            {
                title = decoded
            }
        }

        title = title.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty, !looksLikeMarkup(title) else {
            return fallback
        }

        if title.count > 240 {
            return fallback
        }

        return title
    }

    private static func fallbackTitle(for href: String, chapterIndex: Int?) -> String {
        let normalized = normalizedHREF(href)
        let filename = URL(fileURLWithPath: normalized).deletingPathExtension().lastPathComponent
        if !filename.isEmpty {
            return filename
        }
        if let chapterIndex {
            return "Chapter \(chapterIndex + 1)"
        }
        return "Untitled"
    }

    private static func looksLikeMarkup(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("<?xml")
            || lowercased.contains("<html")
            || lowercased.contains("<body")
            || lowercased.contains("<svg")
    }
}
