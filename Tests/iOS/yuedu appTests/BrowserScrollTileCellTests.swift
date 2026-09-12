@testable import YueduCoreText
import CoreText
import Testing
import UIKit
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct BrowserScrollTileCellTests {
    private func chapter(spineIndex: Int = 4, usesReaderBackground: Bool = false, source: String = "甲乙丙丁") -> BrowserScrollChapter {
        let font = UIFont.systemFont(ofSize: 24)
        let items: [DisplayItem] = [(String(source.prefix(2)), 0, CGFloat(80)), (String(source.suffix(2)), 2, CGFloat(120))].map { text, start, y in
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            return .text(DisplayTextItem(
                sourceRange: NSRange(location: start, length: 2), nodeID: start + 1, linkTarget: "#target",
                writingMode: .horizontal,
                rect: .init(rawValue: CGRect(x: 24, y: y, width: 60, height: 30)),
                baselineY: y + 25, font: font, color: .black, text: text, ctLine: line,
                sourceMapping: .linear(shapedRange: NSRange(location: 0, length: 2))
            ))
        }
        let document = BrowserScrollDocument(displayList: .init(items: items), contentHeight: 200,
            sourceText: source, anchorOffsets: ["target": 2], linkAnchors: [:])
        return BrowserScrollChapter(spineIndex: spineIndex, document: document,
            backgroundColor: .white, usesReaderBackground: usesReaderBackground)
    }

    private func secondTile(_ chapter: BrowserScrollChapter) -> BrowserScrollTile {
        BrowserScrollTile(chapter: chapter, documentRect: CGRect(x: 0, y: 110, width: 200, height: 90),
            charRange: CFRange(location: 2, length: 2))
    }

    @Test func boundedTileSharesTranslatedLinkAndSelectionGeometry() throws {
        let cell = BrowserScrollTileCell(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
        let tile = secondTile(chapter())
        cell.configure(tile: tile, horizontalInset: 20, leadingSpacing: 10)
        let view = cell.interactiveView
        #expect(view.frame == CGRect(x: 20, y: 10, width: 200, height: 90))
        #expect(view.clipsToBounds)
        #expect(view.displayList.items.count == 1)
        #expect(view.pageSourceText == "丙丁")
        let hit = try #require(view.sourceRange(at: CGPoint(x: 30, y: 20)))
        #expect(hit.location >= 2)
        let region = try #require(view.interactionRegions.regions.first)
        #expect(region.pageLocalRect.minY == 10)
        #expect(region.spineIndex == 4)
        #expect(cell.ownsTap(at: CGPoint(x: 50, y: 30)))
        #expect(!cell.ownsTap(at: CGPoint(x: 10, y: 30)))
        var activated: LinkInteractionRegion?
        cell.onLinkActivate = { activated = $0 }
        view.beginLinkPress(at: CGPoint(x: 30, y: 20))
        view.endLinkPress(at: CGPoint(x: 30, y: 20))
        #expect(activated?.href == "#target")
    }

    @Test func rebindReplacesSourceOwnerAndNeverStacksInteractions() throws {
        let cell = BrowserScrollTileCell(frame: CGRect(x: 0, y: 0, width: 200, height: 90))
        let first = secondTile(chapter())
        cell.configure(tile: first, horizontalInset: 0, leadingSpacing: 0)
        let oldView = cell.interactiveView
        let oldInteraction = try #require(oldView.textInteraction)
        oldInteraction.begin(at: CGPoint(x: 30, y: 20))
        #expect(oldView.hasActiveSelection)
        let gestureCount = oldView.gestureRecognizers?.count
        let interactionCount = oldView.interactions.count
        cell.configure(tile: first, horizontalInset: 10, leadingSpacing: 0)
        #expect(cell.interactiveView === oldView)
        #expect(cell.interactiveView.hasActiveSelection)
        cell.configure(tile: secondTile(chapter(spineIndex: 9, source: "戊己庚辛")), horizontalInset: 0, leadingSpacing: 0)
        #expect(cell.interactiveView !== oldView)
        #expect(oldView.superview == nil)
        #expect(!oldView.hasActiveSelection)
        #expect(cell.interactiveView.textInteraction?.spineIndex == 9)
        #expect(cell.interactiveView.pageSourceText == "庚辛")
        cell.interactiveView.textInteraction?.begin(at: CGPoint(x: 30, y: 20))
        let copiedText = try #require(cell.interactiveView.textInteraction?.selection.selectedTextForCopy)
        #expect(copiedText.contains("庚"))
        #expect(!copiedText.contains("丙"))
        #expect(cell.interactiveView.gestureRecognizers?.count == gestureCount)
        #expect(cell.interactiveView.interactions.count == interactionCount)
        cell.prepareForReuse()
        #expect(cell.currentTile == nil)
        #expect(cell.interactiveView.textInteraction == nil)
        #expect(cell.interactiveView.displayList.items.isEmpty)
    }

    @Test func annotationsAndCrossTilePlaybackUseChapterOffsets() throws {
        let cell = BrowserScrollTileCell(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
        cell.configure(tile: secondTile(chapter()), horizontalInset: 20, leadingSpacing: 10)
        cell.applyAnnotations([.init(spineIndex: 4, range: NSRange(location: 2, length: 2), style: .highlight, color: .pink)])
        let overlays = cell.interactiveView.subviews.compactMap { $0 as? InteractionOverlayView }
            .filter { !$0.showsHandles }
        #expect(overlays.count == 1)
        #expect(overlays.first?.selectionRects.first?.minY == 10)
        // The spoken sentence begins in the previous tile. Its visible suffix
        // still has to be highlighted here using the chapter's range.
        cell.applyPlaybackHighlight(text: "甲乙丙丁")
        let bounds = try #require(cell.playbackHighlightBounds(in: cell))
        #expect(bounds.minY >= 10)
        #expect(bounds.maxY <= 100)
        #expect(bounds.minX >= 20)
        cell.applyPlaybackHighlight(text: nil)
        #expect(cell.playbackHighlightBounds(in: cell) == nil)
        cell.applyAnnotations([])
        #expect(!cell.interactiveView.subviews.compactMap { $0 as? InteractionOverlayView }.contains { !$0.showsHandles })
    }

    @Test func readerArtworkAndVoiceOverBelongToContinuousHost() {
        let cell = BrowserScrollTileCell(frame: CGRect(x: 0, y: 0, width: 200, height: 90))
        cell.configure(tile: secondTile(chapter(usesReaderBackground: true)), horizontalInset: 0, leadingSpacing: 0)
        let view = cell.interactiveView
        #expect(view.skipAuthoredBackgroundPaint)
        #expect(view.backgroundColorFill == .clear)
        #expect(!view.isOpaque)
        #expect(view.readerBackgroundImage == nil)
        #expect(view.pageBars == nil)
        #expect(view.accessibilityLabel == "丙丁")
        #expect(view.accessibilityHint == localized("點兩下展開閱讀工具"))
        #expect(!view.accessibilityScroll(.down))
        #expect(view.accessibilityCustomActions?.contains { $0.name == localized("選取文字") } == true)
        #expect(view.accessibilityCustomActions?.contains { $0.name == localized("下一頁") } == false)
        var menuCount = 0
        cell.onAccessibilityMenu = { menuCount += 1 }
        #expect(view.accessibilityActivate())
        #expect(menuCount == 1)
    }
    @Test func paragraphSelectionUsesDOMRangesAndImageOnlyPositionIsChapterStart() throws {
        let pipeline = try BrowserLayoutDocument(html: "<body><p>First paragraph.</p><p>Second paragraph.</p></body>",
            cssTexts: [], config: BrowserLayoutConfig()).makeLayout(containerSize: CGSize(width: 320, height: 480))
        let document = BrowserScrollDocument.make(pipeline: pipeline, contentWidth: 320, contentInsets: .zero)
        let chapter = BrowserScrollChapter(spineIndex: 3, document: document, backgroundColor: .white,
            usesReaderBackground: false, paragraphRanges: BrowserLayoutSemanticContent.paragraphRanges(in: pipeline.rootBox))
        guard case .browser(let tile) = try #require(chapter.tiles(width: 320).first) else { return }
        let cell = BrowserScrollTileCell(frame: tile.documentRect)
        cell.configure(tile: tile, horizontalInset: 0, leadingSpacing: 0)
        let target = try #require(cell.interactiveView.displayList.items.compactMap { item -> DisplayTextItem? in
            if case .text(let text) = item, text.text.contains("Second") { return text }; return nil
        }.first)
        cell.interactiveView.textInteraction?.begin(at: CGPoint(x: target.rect.minX + 4, y: target.rect.midY))
        let copy = try #require(cell.interactiveView.textInteraction?.selection.selectedTextForCopy)
        #expect(copy.contains("Second"))
        #expect(!copy.contains("First"))

        let image = DisplayImageItem(source: "cover.png", image: nil, sourceRange: NSRange(location: 0, length: 0),
            nodeID: 1, linkTarget: nil, writingMode: .horizontal,
            rect: .init(rawValue: CGRect(x: 0, y: 50, width: 320, height: 2600)), alt: "Cover")
        let mediaDocument = BrowserScrollDocument(displayList: .init(items: [.image(image)]), contentHeight: 2650,
            sourceText: "", anchorOffsets: [:], linkAnchors: [:])
        let mediaChapter = BrowserScrollChapter(spineIndex: 7, document: mediaDocument,
            backgroundColor: .white, usesReaderBackground: false)
        let tiles = mediaChapter.tiles(width: 320)
        #expect(tiles.count == 2)
        #expect(tiles[1].stringIndex(atLocalPoint: CGPoint(x: 100, y: 100)) == 0)
        #expect(mediaDocument.documentY(forCharOffset: 0) == 50)
    }

}
