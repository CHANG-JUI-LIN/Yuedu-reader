import Foundation
import Testing
@testable import yuedu_app

/// `GlobalSettings.snapshot` is what chapter building, search and network TTS read off the
/// main thread. Every field it mirrors has to refresh it, or those readers keep drawing and
/// requesting with the value from before the change.
@Suite("GlobalSettings snapshot for off-main readers", .serialized)
@MainActor
struct GlobalSettingsSnapshotTests {
    /// One row per mirrored property: change it, then read the snapshot.
    @Test("every mirrored setting refreshes the snapshot when it changes")
    func everyMirroredSettingRefreshesSnapshot() {
        let settings = GlobalSettings.shared
        let stores = ReadingSettingsStoresSnapshot()
        let old = (
            follows: settings.commentBubbleFollowsSourceSVG,
            mode: settings.commentBubblePresetMode,
            scale: settings.commentBubbleScale,
            font: settings.selectedReaderFontPostScript,
            cacheDays: settings.searchCacheDays,
            template: settings.httpTtsUrlTemplate,
            headers: settings.httpTtsHeaders,
            sources: settings.importedTTSSources
        )
        defer {
            settings.commentBubbleFollowsSourceSVG = old.follows
            settings.commentBubblePresetMode = old.mode
            settings.commentBubbleScale = old.scale
            settings.selectedReaderFontPostScript = old.font
            settings.searchCacheDays = old.cacheDays
            settings.httpTtsUrlTemplate = old.template
            settings.httpTtsHeaders = old.headers
            settings.importedTTSSources = old.sources
            stores.restore()
        }

        settings.commentBubbleFollowsSourceSVG.toggle()
        #expect(GlobalSettings.snapshot.commentBubbleFollowsSourceSVG == !old.follows)

        let mode: ReaderCommentBubblePresetMode = old.mode == .square ? .builtin : .square
        settings.commentBubblePresetMode = mode
        #expect(GlobalSettings.snapshot.commentBubblePresetMode == mode)

        let scale = old.scale == 1.5 ? 1.25 : 1.5
        settings.commentBubbleScale = scale
        #expect(GlobalSettings.snapshot.commentBubbleScale == scale)

        settings.selectedReaderFontPostScript = "Snapshot-Test-Font"
        #expect(GlobalSettings.snapshot.selectedReaderFontPostScript == "Snapshot-Test-Font")

        settings.searchCacheDays = old.cacheDays + 3
        #expect(GlobalSettings.snapshot.searchCacheDays == old.cacheDays + 3)

        let template = "https://snapshot-tts.example/speak?text={{speakText}}"
        settings.httpTtsUrlTemplate = template
        #expect(GlobalSettings.snapshot.httpTtsUrlTemplate == template)

        settings.httpTtsHeaders = ["X-Snapshot": "1"]
        #expect(GlobalSettings.snapshot.httpTtsHeaders == ["X-Snapshot": "1"])

        // The active source is derived from the template and the imported list, so adding the
        // matching source alone has to change it.
        #expect(GlobalSettings.snapshot.activeTTSSource == nil)
        let source = ImportedTTSSource(name: "snapshot voice", urlTemplate: template)
        settings.importedTTSSources = old.sources + [source]
        #expect(GlobalSettings.snapshot.activeTTSSource == source)
    }

    /// Editing the worn style keeps its ID and changes only its SVG; the bubble image cache
    /// keys on that SVG, so the snapshot has to carry the edit.
    @Test("selecting and editing the worn bubble style in place refreshes the snapshot")
    func bubbleStyleSelectionAndInPlaceEdit() {
        let settings = GlobalSettings.shared
        let stores = ReadingSettingsStoresSnapshot()
        let oldMode = settings.commentBubblePresetMode
        let oldSelectedID = settings.commentBubbleSelectedCustomStyleID
        var style = ReaderCommentBubbleCustomStyle(name: "snapshot test", svg: "<svg id=\"a\"/>")
        defer {
            settings.deleteCommentBubbleCustomStyle(id: style.id)
            if let oldSelectedID { settings.selectCommentBubbleCustomStyle(id: oldSelectedID) }
            settings.commentBubblePresetMode = oldMode
            stores.restore()
        }

        settings.upsertCommentBubbleCustomStyle(style)
        #expect(GlobalSettings.snapshot.commentBubbleSelectedCustomStyleID == style.id)
        #expect(GlobalSettings.snapshot.commentBubbleSelectedCustomStyle?.svg == "<svg id=\"a\"/>")
        #expect(GlobalSettings.snapshot.commentBubblePresetMode == .custom)

        // `store…` replaces the style without touching the selection: only the library's
        // `didSet` runs.
        style.svg = "<svg id=\"b\"/>"
        settings.storeCommentBubbleCustomStyle(style)
        #expect(GlobalSettings.snapshot.commentBubbleSelectedCustomStyleID == style.id)
        #expect(GlobalSettings.snapshot.commentBubbleSelectedCustomStyle?.svg == "<svg id=\"b\"/>")
    }

    @Test("a reader off the main thread sees the value main just wrote")
    func offMainReaderSeesMainWrite() async {
        let settings = GlobalSettings.shared
        let old = settings.searchCacheDays
        defer { settings.searchCacheDays = old }

        settings.searchCacheDays = old + 7
        let seen = await Task.detached { GlobalSettings.snapshot.searchCacheDays }.value
        #expect(seen == old + 7)
    }
}
