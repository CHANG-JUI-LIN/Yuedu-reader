import Foundation
import UIKit

/// Immutable output of one chapter content build.
///
/// Page and scroll layout consume the same document instance. Layout-specific
/// preparation stays outside this type because it depends on the viewport.
struct ChapterDocument {
    let spineIndex: Int
    let attributedString: NSAttributedString
    let imagePage: HTMLAttributedStringBuilder.ImagePage?
    let pageBackgroundImage: UIImage?
    let pageBackgroundColor: UIColor?
    /// Dark `@media (prefers-color-scheme: dark)` variant of `pageBackgroundColor`.
    let darkPageBackgroundColor: UIColor?
    let anchorOffsets: [String: Int]
    let revision: ContentRevision

    init(spineIndex: Int, buildResult: AttributedChapterBuildResult) {
        self.spineIndex = spineIndex
        attributedString = buildResult.attributedString
        imagePage = buildResult.imagePage
        pageBackgroundImage = buildResult.pageBackgroundImage
        pageBackgroundColor = buildResult.pageBackgroundColor
        darkPageBackgroundColor = buildResult.darkPageBackgroundColor
        anchorOffsets = buildResult.anchorOffsets
        revision = buildResult.revision
    }
}

/// Full identity of a builder invocation.
///
/// Colors remain in the request until the builder output is split into
/// layout-only and paint-only layers. Keeping them here prevents stale
/// attributed colors while still de-duplicating page/scroll work today.
struct ChapterDocumentRequest: Equatable {
    let spineIndex: Int
    let settings: ReaderRenderSettings
    let themeTextColor: UIColor
    let themeBackgroundColor: UIColor
}

/// The single owner of built chapter documents for a reader session.
///
/// Main-actor isolation matches the current builder contract. Individual
/// builders may perform their parsing and resource work on their own executors.
/// Equal concurrent requests share one task; failures are surfaced unchanged
/// and are never retried on an alternate path.
@MainActor
final class ChapterDocumentStore {
    private struct CacheEntry {
        let request: ChapterDocumentRequest
        let document: ChapterDocument
        var accessOrder: UInt64
    }

    private struct InFlightEntry {
        let id: UUID
        let request: ChapterDocumentRequest
        let generation: UInt64
        let task: Task<ChapterDocument, Error>
    }

    private let builder: any AttributedStringBuilding
    private let capacity: Int
    private var cache: [CacheEntry] = []
    private var inFlight: [InFlightEntry] = []
    private var accessOrder: UInt64 = 0
    private var generation: UInt64 = 0

    init(builder: any AttributedStringBuilding, capacity: Int = 8) {
        self.builder = builder
        self.capacity = max(1, capacity)
    }

    func document(for request: ChapterDocumentRequest) async throws -> ChapterDocument {
        if let index = cache.firstIndex(where: { $0.request == request }) {
            accessOrder &+= 1
            cache[index].accessOrder = accessOrder
            return cache[index].document
        }

        if let entry = inFlight.first(where: { $0.request == request }) {
            return try await entry.task.value
        }

        let entryID = UUID()
        let requestGeneration = generation
        let task = Task { @MainActor [builder] in
            // Binds the spine index for the `⏱ coreText.document.*` lines emitted deep inside
            // the chapter-agnostic HTML/CSS builders. See `ReaderDocumentTrace`.
            try await ReaderDocumentTrace.$spineIndex.withValue(request.spineIndex) {
                let result = try await builder.buildChapter(
                    at: request.spineIndex,
                    settings: request.settings,
                    themeTextColor: request.themeTextColor,
                    themeBackgroundColor: request.themeBackgroundColor
                )
                return ChapterDocument(spineIndex: request.spineIndex, buildResult: result)
            }
        }
        inFlight.append(
            InFlightEntry(
                id: entryID,
                request: request,
                generation: requestGeneration,
                task: task
            )
        )

        do {
            let document = try await task.value
            let stillOwnsEntry = inFlight.contains { $0.id == entryID }
            inFlight.removeAll { $0.id == entryID }
            guard stillOwnsEntry, generation == requestGeneration else { return document }
            insert(document, for: request)
            return document
        } catch {
            inFlight.removeAll { $0.id == entryID }
            throw error
        }
    }

    func invalidateAll() {
        generation &+= 1
        cache.removeAll(keepingCapacity: true)
        inFlight.forEach { $0.task.cancel() }
        inFlight.removeAll(keepingCapacity: true)
    }

    func invalidate(spineIndex: Int) {
        cache.removeAll { $0.request.spineIndex == spineIndex }
        let invalidatedTasks = inFlight
            .filter { $0.request.spineIndex == spineIndex }
            .map(\.task)
        inFlight.removeAll { $0.request.spineIndex == spineIndex }
        invalidatedTasks.forEach { $0.cancel() }
    }

    private func insert(_ document: ChapterDocument, for request: ChapterDocumentRequest) {
        accessOrder &+= 1
        cache.removeAll { $0.request == request }
        cache.append(
            CacheEntry(
                request: request,
                document: document,
                accessOrder: accessOrder
            )
        )

        if cache.count > capacity,
           let leastRecentIndex = cache.indices.min(by: {
               cache[$0].accessOrder < cache[$1].accessOrder
           }) {
            cache.remove(at: leastRecentIndex)
        }
    }
}
