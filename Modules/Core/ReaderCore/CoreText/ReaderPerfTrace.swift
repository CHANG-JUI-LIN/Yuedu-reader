import Foundation
import os

/// Stable reader-pipeline stage names shared by Instruments captures and
/// `XCTOSSignpostMetric` performance tests.
enum ReaderPerfStage: String, CaseIterable, Sendable {
    case chapterLoad = "chapter.load"
    case htmlParse = "html.parse"
    case cssCollect = "css.collect"
    case cssParse = "css.parse"
    case cssMatch = "css.match"
    case astBuild = "ast.build"
    case irConvert = "ir.convert"
    case attributedRender = "attributed.render"
    case imageLoad = "resource.image.load"
    case imageDecode = "resource.image.decode"
    case layoutFingerprint = "layout.fingerprint"
    case layoutVerticalPrepare = "layout.vertical.prepare"
    case layoutFramesetterCreate = "layout.framesetter.create"
    case layoutPageRanges = "layout.pageRanges"
    case layoutDisplayList = "layout.displayList"
    case layoutFirstPagePublish = "layout.firstPage.publish"
    case renderPage = "render.page"
    case renderChunk = "render.chunk"
    case renderTile = "render.tile"
    case cacheDocument = "cache.document"
    case cacheLayout = "cache.layout"
    case cacheRaster = "cache.raster"

    /// `OSSignposter` requires a `StaticString` interval name. Keep this mapping
    /// aligned with `rawValue`; tests guard the names because Instruments metrics
    /// use them as a long-lived compatibility contract.
    var signpostName: StaticString {
        switch self {
        case .chapterLoad: "chapter.load"
        case .htmlParse: "html.parse"
        case .cssCollect: "css.collect"
        case .cssParse: "css.parse"
        case .cssMatch: "css.match"
        case .astBuild: "ast.build"
        case .irConvert: "ir.convert"
        case .attributedRender: "attributed.render"
        case .imageLoad: "resource.image.load"
        case .imageDecode: "resource.image.decode"
        case .layoutFingerprint: "layout.fingerprint"
        case .layoutVerticalPrepare: "layout.vertical.prepare"
        case .layoutFramesetterCreate: "layout.framesetter.create"
        case .layoutPageRanges: "layout.pageRanges"
        case .layoutDisplayList: "layout.displayList"
        case .layoutFirstPagePublish: "layout.firstPage.publish"
        case .renderPage: "render.page"
        case .renderChunk: "render.chunk"
        case .renderTile: "render.tile"
        case .cacheDocument: "cache.document"
        case .cacheLayout: "cache.layout"
        case .cacheRaster: "cache.raster"
        }
    }
}

/// Bounded, content-free metadata for reader performance traces. Do not place
/// book titles, chapter text, URLs, or other user content in these fields.
struct ReaderPerfMetadata: Sendable {
    var resourceID: String?
    var spineIndex: Int?
    var characterCount: Int?
    var elementCount: Int?
    var ruleCount: Int?
    var pageCount: Int?
    var chunkCount: Int?
    var writingMode: String?
    var cacheResult: String?
    var executor: String?
    var generation: Int?

    init(
        resourceID: String? = nil,
        spineIndex: Int? = nil,
        characterCount: Int? = nil,
        elementCount: Int? = nil,
        ruleCount: Int? = nil,
        pageCount: Int? = nil,
        chunkCount: Int? = nil,
        writingMode: String? = nil,
        cacheResult: String? = nil,
        executor: String? = nil,
        generation: Int? = nil
    ) {
        self.resourceID = resourceID
        self.spineIndex = spineIndex
        self.characterCount = characterCount
        self.elementCount = elementCount
        self.ruleCount = ruleCount
        self.pageCount = pageCount
        self.chunkCount = chunkCount
        self.writingMode = writingMode
        self.cacheResult = cacheResult
        self.executor = executor
        self.generation = generation
    }

    var logDescription: String {
        var fields: [String] = []
        if let resourceID { fields.append("resource=\(resourceID)") }
        if let spineIndex { fields.append("spine=\(spineIndex)") }
        if let characterCount { fields.append("chars=\(characterCount)") }
        if let elementCount { fields.append("elements=\(elementCount)") }
        if let ruleCount { fields.append("rules=\(ruleCount)") }
        if let pageCount { fields.append("pages=\(pageCount)") }
        if let chunkCount { fields.append("chunks=\(chunkCount)") }
        if let writingMode { fields.append("writing=\(writingMode)") }
        if let cacheResult { fields.append("cache=\(cacheResult)") }
        if let executor { fields.append("executor=\(executor)") }
        if let generation { fields.append("generation=\(generation)") }
        return fields.joined(separator: " ")
    }
}

/// Points-of-Interest instrumentation for the CoreText reader pipeline.
///
/// Signposts are disabled cheaply when the system is not collecting them. The
/// type deliberately depends only on Foundation + os so it can move into the
/// future standalone YueduCoreText package without pulling in app logging.
enum ReaderPerfTrace {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.zhangruilin.yuedureader"
    static let category = "ReaderPerformance"

    private static let signposter = OSSignposter(
        subsystem: subsystem,
        category: category
    )

    struct Interval: Sendable {
        fileprivate let stage: ReaderPerfStage
        fileprivate let state: OSSignpostIntervalState
    }

    static func begin(
        _ stage: ReaderPerfStage,
        metadata: @autoclosure () -> ReaderPerfMetadata = ReaderPerfMetadata()
    ) -> Interval? {
        guard signposter.isEnabled else { return nil }
        let logDescription = metadata().logDescription
        let state = signposter.beginInterval(
            stage.signpostName,
            id: signposter.makeSignpostID(),
            "\(logDescription, privacy: .public)"
        )
        return Interval(stage: stage, state: state)
    }

    static func end(
        _ interval: Interval?,
        metadata: @autoclosure () -> ReaderPerfMetadata? = nil
    ) {
        guard let interval else { return }
        if let metadata = metadata() {
            signposter.endInterval(
                interval.stage.signpostName,
                interval.state,
                "\(metadata.logDescription, privacy: .public)"
            )
        } else {
            signposter.endInterval(interval.stage.signpostName, interval.state)
        }
    }

    @discardableResult
    static func span<T>(
        _ stage: ReaderPerfStage,
        metadata: @autoclosure () -> ReaderPerfMetadata = ReaderPerfMetadata(),
        _ body: () throws -> T
    ) rethrows -> T {
        guard signposter.isEnabled else { return try body() }
        let interval = begin(stage, metadata: metadata())
        defer { end(interval) }
        return try body()
    }

    @discardableResult
    static func spanAsync<T>(
        _ stage: ReaderPerfStage,
        metadata: @autoclosure () -> ReaderPerfMetadata = ReaderPerfMetadata(),
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        guard signposter.isEnabled else { return try await body() }
        let interval = begin(stage, metadata: metadata())
        defer { end(interval) }
        return try await body()
    }
}
