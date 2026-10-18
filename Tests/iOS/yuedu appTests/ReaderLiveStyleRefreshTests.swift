import CoreText
import Foundation
import Testing
import UIKit
@testable import YueduCoreText
@testable import yuedu_app

@Suite("Reader live style refresh", .serialized)
@MainActor
struct ReaderLiveStyleRefreshTests {
    @Test(arguments: [ReaderDisplayMode.paged, .scroll])
    func boldCanTurnOffBeforeGlobalPersistence(mode: ReaderDisplayMode) async throws {
        let global = GlobalSettings.shared
        let oldBold = global.readerFontBold
        let oldFont = global.selectedReaderFontPostScript
        defer {
            global.readerFontBold = oldBold
            global.selectedReaderFontPostScript = oldFont
        }
        global.selectedReaderFontPostScript = nil
        // ReaderConfig has already changed, but its debounced persistence has not.
        global.readerFontBold = true
        let text = "正文 Bold toggle regression"
        let builder = TXTLazyAttributedStringBuilder(text: text, chapterIndexes: [
            TXTChapterIndex(index: 0, title: "", contentRange: NSRange(location: 0, length: (text as NSString).length))
        ])
        let renderer = try await load(builder, settings: settings(bold: true))
        for bold in [false, true, false] {
            try await refresh(renderer, intent: .layout, mode: mode, settings: settings(bold: bold))
            let content = try content(renderer, mode: mode)
            let offset = (content.string as NSString).range(of: "Bold").location
            #expect(offset != NSNotFound)
            let font = try #require(content.attribute(.font, at: offset, effectiveRange: nil) as? UIFont)
            #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold) == bold)
            if !bold {
                #expect(content.attribute(.strokeWidth, at: offset, effectiveRange: nil) == nil)
            }
        }
    }

    @Test(arguments: [ReaderDisplayMode.paged, .scroll])
    func bubbleStyleRebuildsVisibleAndInactiveModes(mode: ReaderDisplayMode) async throws {
        let global = GlobalSettings.shared
        let oldFollow = global.commentBubbleFollowsSourceSVG
        let oldPreset = global.commentBubblePresetMode
        let oldScale = global.commentBubbleScale
        defer {
            global.commentBubbleFollowsSourceSVG = oldFollow
            global.commentBubblePresetMode = oldPreset
            global.commentBubbleScale = oldScale
        }
        global.commentBubbleFollowsSourceSVG = false
        global.commentBubblePresetMode = .square
        global.commentBubbleScale = 1
        let renderer = try await load(LiveCommentBadgeBuilder(), settings: settings())
        let originalWidth = try badgeWidth(content(renderer, mode: .paged))
        let otherMode: ReaderDisplayMode = mode == .paged ? .scroll : .paged

        for scale in [1.5, 1.0] {
            global.commentBubbleScale = scale
            try await refresh(renderer, intent: .documentStyle, mode: mode, settings: settings())
            let updatedWidth = try badgeWidth(content(renderer, mode: mode))
            #expect(abs(updatedWidth - originalWidth * scale) < 1)
            // The other engine already exists; changing modes must not restore old geometry.
            try await refresh(renderer, intent: .modeActivation, mode: otherMode, settings: settings())
            #expect(try badgeWidth(content(renderer, mode: otherMode)) == updatedWidth)
        }
    }

    private func settings(bold: Bool = false) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "test", textColor: .black, backgroundColor: .white,
            fontSize: 20, lineHeightMultiple: 1.5, lineSpacing: 0,
            paragraphSpacing: 8, letterSpacing: 0, marginH: 0, marginV: 0,
            footerHeight: 0, contentInsets: .zero, isBold: bold
        )
    }

    private func load(_ builder: any AttributedStringBuilding, settings: ReaderRenderSettings) async throws -> EPUBPageRenderer {
        let renderer = EPUBPageRenderer()
        renderer.loadTXT(attributedBuilder: builder, bookIdentifier: UUID().uuidString,
                         renderSize: CGSize(width: 320, height: 480), settings: settings)
        let deadline = Date().addingTimeInterval(10)
        while !renderer.isCoreTextReady && Date() < deadline { await Task.yield() }
        try #require(renderer.isCoreTextReady)
        return renderer
    }

    private func refresh(_ renderer: EPUBPageRenderer, intent: ReaderRenderRefreshIntent,
                         mode: ReaderDisplayMode, settings: ReaderRenderSettings) async throws {
        let task = Task {
            await renderer.refresh(ReaderRenderRefreshRequest(
                intent: intent, mode: mode, settings: settings, position: .chapterStart(0),
                viewportSize: CGSize(width: 320, height: 480)
            ))
        }
        let deadline = Date().addingTimeInterval(10)
        while renderer.pendingVisibleRefreshCommit == nil && Date() < deadline { await Task.yield() }
        let commit = try #require(renderer.pendingVisibleRefreshCommit)
        #expect(commit.position == .chapterStart(0))
        if mode == .scroll {
            let success = await renderer.scrollEngine?.reslice(
                restoreAt: 0, contentWidth: 320, restorePosition: commit.position
            )
            #expect(success == true)
        }
        renderer.finishVisibleRefresh(transactionID: commit.transactionID, outcome: .applied)
        #expect(await task.value.isCompleted)
    }

    private func content(_ renderer: EPUBPageRenderer, mode: ReaderDisplayMode) throws -> NSAttributedString {
        switch mode {
        case .paged:
            return try #require((renderer.engine as? CoreTextPageEngine)?.layouts[0]?.attributedString)
        case .scroll:
            return try #require(renderer.scrollEngine?.chunks.first?.attributedString)
        }
    }

    private func badgeWidth(_ content: NSAttributedString) throws -> CGFloat {
        var width: CGFloat?
        content.enumerateAttribute(NSAttributedString.Key(kCTRunDelegateAttributeName as String),
                                   in: NSRange(location: 0, length: content.length)) { value, _, stop in
            guard let value else { return }
            let info = Unmanaged<ImageRunInfo>.fromOpaque(CTRunDelegateGetRefCon(value as! CTRunDelegate)).takeUnretainedValue()
            width = info.image?.size.width
            stop.pointee = true
        }
        return try #require(width)
    }
}

private struct LiveCommentBadgeBuilder: AttributedStringBuilding {
    let chapterCount = 1
    func chapterTitle(at index: Int) -> String { "" }
    func chapterDataSize(at index: Int) async -> Int { 128 }
    func buildChapter(at index: Int, settings: ReaderRenderSettings,
                      themeTextColor: UIColor, themeBackgroundColor: UIColor) async throws -> AttributedChapterBuildResult {
        let renderer = NodeAttributedStringRenderer(config: .init(
            from: settings, textColor: themeTextColor, renderWidth: 320
        ))
        let content = await renderer.render([
            .paragraph([.text("正文"), .commentBadge(count: "12", reviewURL: "ydreview://test", title: "")], style: .body)
        ])
        return AttributedChapterBuildResult(attributedString: content, imagePage: nil,
                                           pageBackgroundImage: nil, anchorOffsets: [:])
    }
}
