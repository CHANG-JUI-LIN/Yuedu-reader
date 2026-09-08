import CoreText
import Testing
import UIKit
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct BrowserTextInteractionTests {
    private func fixture(_ text: String = "甲乙😀丙丁") -> (BrowserLayoutPageView, CTLine) {
        let font = UIFont.systemFont(ofSize: 24)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let page = BrowserLayoutPageView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        page.pageSourceText = text
        page.pageSourceRange = NSRange(location: 0, length: (text as NSString).length)
        page.displayList = DisplayList(items: [.text(DisplayTextItem(
            sourceRange: page.pageSourceRange, nodeID: 1, linkTarget: nil, writingMode: .horizontal,
            rect: .init(rawValue: CGRect(x: 24, y: 80, width: width, height: 30)),
            baselineY: 105, font: font, color: .black, text: text, ctLine: line
        ))])
        page.configureTextInteraction(sourceText: text, spineIndex: 2, annotations: [])
        return (page, line)
    }

    @Test func precisePartialSelectionAndEmojiHitUseShapedOffsets() throws {
        let (page, line) = fixture()
        let range = NSRange(location: 2, length: 2)
        let rect = try #require(BrowserTextGeometry.rects(in: page.displayList, range: range).first)
        let start = CTLineGetOffsetForStringIndex(line, 2, nil)
        let end = CTLineGetOffsetForStringIndex(line, 4, nil)
        #expect(abs(rect.minX - (24 + start)) < 0.01)
        #expect(abs(rect.width - (end - start)) < 0.01)
        let hit = try #require(page.sourceRange(at: CGPoint(x: rect.midX, y: rect.midY)))
        #expect(hit == range)
        #expect(page.sourceRange(at: CGPoint(x: 280, y: 350)) == nil)
    }

    @Test func rtlSelectionStaysInsidePhysicalFragment() throws {
        let (page, _) = fixture("אבגד")
        let rect = try #require(BrowserTextGeometry.rects(in: page.displayList, range: page.pageSourceRange).first)
        #expect(abs(rect.minX - 24) < 0.01)
        let right = try #require(page.sourceRange(at: CGPoint(x: rect.maxX - 2, y: rect.midY)))
        let left = try #require(page.sourceRange(at: CGPoint(x: rect.minX + 2, y: rect.midY)))
        #expect(right.location == 0)
        #expect(left.location == 3)
        let start = try #require(BrowserTextGeometry.caret(at: 0, isEnd: false, in: page.displayList))
        #expect(abs(start.x - rect.maxX) < 0.01)
    }

    @Test func selectionUsesFullChapterOffsetsAndAnnotationRequest() throws {
        let (page, _) = fixture()
        let interaction = try #require(page.textInteraction)
        interaction.begin(at: CGPoint(x: 30, y: 90))
        #expect(page.hasActiveSelection)
        #expect(interaction.selection.selectedTextForCopy == "甲乙😀丙丁")
        let capture = RequestCapture()
        let observer = NotificationCenter.default.addObserver(forName: .coreTextUnderlineSelectionRequested, object: nil, queue: nil) {
            capture.request = $0.userInfo?["request"] as? CoreTextUnderlineSelectionRequest
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        interaction.requestAnnotation(style: .highlight, color: .green)
        let request = try #require(capture.request)
        #expect(request.position.spineIndex == 2)
        #expect(request.position.charOffset == 0)
        #expect(request.length == 6)
        #expect(request.excerpt == "甲乙😀丙丁")
        #expect(request.style == .highlight)
        #expect(request.color == .green)
        #expect(!page.hasActiveSelection)
    }

    @Test func annotationLayersAndNoteMarkerAppearAndClear() throws {
        let (page, _) = fixture()
        let interaction = try #require(page.textInteraction)
        interaction.annotations = [.init(spineIndex: 2, range: NSRange(location: 2, length: 2), style: .highlight, color: .pink, note: "筆記")]
        let note = try #require(page.subviews.compactMap { $0 as? NoteMarkerOverlayView }.first)
        #expect(note.markers.count == 1)
        let layers = page.subviews.compactMap { $0 as? InteractionOverlayView }.filter { !$0.showsHandles }
        #expect(layers.count == 1)
        #expect(layers[0].selectionRects.count == 1)
        let noteCenter = CGPoint(x: note.markers[0].badgeRect.midX, y: note.markers[0].badgeRect.midY)
        #expect(interaction.ownsTap(at: noteCenter))
        interaction.annotations = []
        #expect(note.markers.isEmpty)
        #expect(!page.subviews.compactMap { $0 as? InteractionOverlayView }.contains { !$0.showsHandles })
    }

    @Test func annotationContinuationDoesNotDuplicateNoteMarker() throws {
        let (page, _) = fixture()
        page.pageSourceRange = NSRange(location: 2, length: 4)
        page.textInteraction?.annotations = [.init(spineIndex: 2, range: NSRange(location: 0, length: 6), note: "跨頁筆記")]
        let note = try #require(page.subviews.compactMap { $0 as? NoteMarkerOverlayView }.first)
        #expect(note.markers.isEmpty)
        #expect(page.subviews.compactMap { $0 as? InteractionOverlayView }.contains { !$0.showsHandles && !$0.underlineRects.isEmpty })
    }
}

private final class RequestCapture: @unchecked Sendable {
    // Notification posting and observation both run synchronously on main.
    var request: CoreTextUnderlineSelectionRequest?
}
