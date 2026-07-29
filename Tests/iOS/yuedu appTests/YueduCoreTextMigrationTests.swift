import Foundation
import Testing
import YueduCoreText

@Suite("YueduCoreText 0.2 migration contract")
struct YueduCoreTextMigrationTests {
    @Test("Standalone core product exposes the app's three migrated API areas")
    func standaloneCoreProductExposesMigratedAPIs() {
        let optionalMap = ReaderContentUnitMap(chapterUnitCounts: [100, 200])
        #expect(optionalMap != nil)
        guard let map = optionalMap else { return }
        let optionalMetrics = map.metrics(
            spineIndex: 1,
            localCharacterOffset: 50,
            currentChapterCharacterCount: 100
        )
        #expect(optionalMetrics != nil)
        guard let metrics = optionalMetrics else { return }
        let selection = TextSelectionManager()
        selection.setSelection(range: NSRange(location: 2, length: 3), maxLength: 10)
        let startEndpoint = selection.endpoint(for: .start)
        #expect(startEndpoint == .anchor)
        if let startEndpoint {
            selection.updateSelection(startEndpoint, to: 6, maxLength: 10)
        }
        let metadata = ReaderPerfMetadata(spineIndex: 1)

        #expect(metrics.currentUnitOffset == 200)
        #expect(selection.selectedRange == NSRange(location: 4, length: 3))
        #expect(selection.endpoint(for: .end) == .anchor)
        #expect(metadata.spineIndex == 1)
    }

    @Test("App no longer owns duplicate core implementations")
    func appNoLongerOwnsDuplicateCoreImplementations() {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let duplicatePaths = [
            "Modules/Core/ReaderCore/CoreText/ReaderContentMetrics.swift",
            "Modules/Core/ReaderCore/CoreText/TextSelectionManager.swift",
            "Modules/Core/ReaderCore/CoreText/ReaderPerfTrace.swift",
        ]

        for relativePath in duplicatePaths {
            #expect(
                !FileManager.default.fileExists(
                    atPath: packageRoot.appendingPathComponent(relativePath).path
                ),
                "Duplicate core implementation remains at \(relativePath)"
            )
        }
    }
}
