import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("CoreText large EPUB benchmarks", .serialized)
struct CoreTextLargeEPUBBenchmarkTests {
    private static let renderSize = CGSize(width: 390, height: 844)
    private static let settings = EPUBTestFixtures.renderSettings(
        fontSize: 18,
        lineHeightMultiple: 1.5,
        paragraphSpacing: 8
    )

    @Test("160 MiB corpus opens, builds, and paginates")
    @MainActor
    func benchmark160MiBBook() async throws {
        try await benchmark(CoreTextLargeEPUBCorpus.books[0])
    }

    @Test("224 MiB corpus opens, builds, and paginates")
    @MainActor
    func benchmark224MiBBook() async throws {
        try await benchmark(CoreTextLargeEPUBCorpus.books[1])
    }

    @MainActor
    private func benchmark(_ book: CoreTextLargeEPUBCorpus.Book) async throws {
        guard let sourceURL = CoreTextLargeEPUBCorpus.configuredURL(for: book) else {
            return
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            Issue.record("Missing configured corpus file for \(book.id)")
            return
        }
        guard try CoreTextLargeEPUBCorpus.isMaterialized(sourceURL) else {
            Issue.record("Corpus file is not downloaded for \(book.id)")
            return
        }

        let byteSize = try #require(
            sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        #expect(book.expectedByteRange.contains(Int64(byteSize)))

        let openStart = ProcessInfo.processInfo.systemUptime
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let openMilliseconds = elapsedMilliseconds(since: openStart)
        #expect(!session.chapters.isEmpty)

        let chapter = session.chapters[session.chapters.count / 2]
        let builder = EPUBAttributedStringBuilder(
            session: session,
            renderSize: Self.renderSize
        )

        let buildStart = ProcessInfo.processInfo.systemUptime
        let result = try await builder.buildChapter(
            at: chapter.index,
            settings: Self.settings,
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        let buildMilliseconds = elapsedMilliseconds(since: buildStart)
        #expect(result.attributedString.length > 0)

        let paginator = CoreTextPaginator()
        let firstPageStart = ProcessInfo.processInfo.systemUptime
        let firstPage = await paginator.paginateFirstPage(
            spineIndex: chapter.index,
            attrStr: result.attributedString,
            imagePage: result.imagePage,
            pageBackgroundImage: result.pageBackgroundImage,
            pageBackgroundColor: result.pageBackgroundColor,
            anchorOffsets: result.anchorOffsets,
            renderSize: Self.renderSize,
            fontSize: Self.settings.fontSize,
            lineSpacing: Self.settings.lineSpacing,
            paragraphSpacing: Self.settings.paragraphSpacing,
            letterSpacing: Self.settings.letterSpacing,
            contentInsets: Self.settings.contentInsets,
            writingMode: Self.settings.writingMode,
            revision: result.revision
        )
        let firstPageMilliseconds = elapsedMilliseconds(since: firstPageStart)

        let fullLayoutStart = ProcessInfo.processInfo.systemUptime
        let fullLayout = await paginator.paginate(
            spineIndex: chapter.index,
            attrStr: result.attributedString,
            imagePage: result.imagePage,
            pageBackgroundImage: result.pageBackgroundImage,
            pageBackgroundColor: result.pageBackgroundColor,
            anchorOffsets: result.anchorOffsets,
            renderSize: Self.renderSize,
            fontSize: Self.settings.fontSize,
            lineSpacing: Self.settings.lineSpacing,
            paragraphSpacing: Self.settings.paragraphSpacing,
            letterSpacing: Self.settings.letterSpacing,
            contentInsets: Self.settings.contentInsets,
            writingMode: Self.settings.writingMode,
            revision: result.revision
        )
        let fullLayoutMilliseconds = elapsedMilliseconds(since: fullLayoutStart)
        #expect(!fullLayout.pageRanges.isEmpty)

        let warmLayoutStart = ProcessInfo.processInfo.systemUptime
        let warmLayout = await paginator.paginate(
            spineIndex: chapter.index,
            attrStr: result.attributedString,
            imagePage: result.imagePage,
            pageBackgroundImage: result.pageBackgroundImage,
            pageBackgroundColor: result.pageBackgroundColor,
            anchorOffsets: result.anchorOffsets,
            renderSize: Self.renderSize,
            fontSize: Self.settings.fontSize,
            lineSpacing: Self.settings.lineSpacing,
            paragraphSpacing: Self.settings.paragraphSpacing,
            letterSpacing: Self.settings.letterSpacing,
            contentInsets: Self.settings.contentInsets,
            writingMode: Self.settings.writingMode,
            revision: result.revision
        )
        let warmLayoutMilliseconds = elapsedMilliseconds(since: warmLayoutStart)
        #expect(warmLayout.pageRanges.count == fullLayout.pageRanges.count)
        for (warmRange, fullRange) in zip(
            warmLayout.pageRanges,
            fullLayout.pageRanges
        ) {
            #expect(warmRange.location == fullRange.location)
            #expect(warmRange.length == fullRange.length)
        }

        print(
            String(
                format: """
                CORETEXT_BENCHMARK \
                id=%@ bytes=%d chapters=%d spine=%d chars=%d \
                firstPages=%d fullPages=%d \
                openMs=%.2f buildMs=%.2f firstPageMs=%.2f \
                fullLayoutMs=%.2f warmLayoutMs=%.2f
                """,
                book.id,
                byteSize,
                session.chapters.count,
                chapter.index,
                result.attributedString.length,
                firstPage?.pageRanges.count ?? 0,
                fullLayout.pageRanges.count,
                openMilliseconds,
                buildMilliseconds,
                firstPageMilliseconds,
                fullLayoutMilliseconds,
                warmLayoutMilliseconds
            )
        )
    }

    private func elapsedMilliseconds(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }
}
