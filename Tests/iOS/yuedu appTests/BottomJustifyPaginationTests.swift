import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 底部對齊 (legado `textBottomJustify`): on a page CoreText filled to the bottom, the
/// leftover space is spread evenly over every line gap so the last line sits on the
/// content bottom. The justified origins live in the page artifact, so drawing,
/// selection, TTS highlight and inline images all read the same geometry.
@Suite("Bottom justify pagination", .serialized)
struct BottomJustifyPaginationTests {
    private static let renderSize = CGSize(width: 320, height: 480)

    private static func chapter(paragraphs: Int = 120) -> NSAttributedString {
        NSAttributedString(
            string: String(repeating: "每一頁的最後一行都要貼齊內容區底邊。\n", count: paragraphs),
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
    }

    private static func lastLineBottom(_ artifact: PageLayoutArtifact) -> CGFloat {
        let lines = CTFrameGetLines(artifact.frame) as! [CTLine]
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(lines[lines.count - 1], nil, &descent, nil)
        // Origins are relative to the frame path's bounding box: its bottom edge is y = 0.
        return artifact.lineOrigins[lines.count - 1].y - descent
    }

    private static func frameOrigins(_ artifact: PageLayoutArtifact) -> [CGPoint] {
        let count = (CTFrameGetLines(artifact.frame) as! [CTLine]).count
        var origins = [CGPoint](repeating: .zero, count: count)
        CTFrameGetLineOrigins(artifact.frame, CFRangeMake(0, count), &origins)
        return origins
    }

    @Test("Filled pages put their last line on the content bottom, spreading the gap over every line")
    @MainActor
    func filledPagesReachTheBottom() async throws {
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: Self.chapter(),
            renderSize: Self.renderSize,
            fontSize: 18,
            bottomJustify: true,
            revision: ContentRevision()
        )
        try #require(layout.pageArtifacts.count > 2)

        for artifact in layout.pageArtifacts.dropLast() {
            let natural = Self.frameOrigins(artifact)
            try #require(natural.count > 2)
            #expect(Self.lastLineBottom(artifact) < 0.5)
            #expect(Self.lastLineBottom(artifact) > -0.5)
            // The first line keeps its place; every later gap grows by the same amount.
            #expect(artifact.lineOrigins[0] == natural[0])
            let firstStep = (natural[1].y - artifact.lineOrigins[1].y)
            #expect(firstStep > 0)
            for index in 2..<natural.count {
                let shift = natural[index].y - artifact.lineOrigins[index].y
                #expect(abs(shift - firstStep * CGFloat(index)) < 0.01)
            }
        }
    }

    @Test("With 下邊距 0 the last line sits on the footer band, not a line-grid step above it")
    @MainActor
    func lastLineReachesTheFooterBand() async throws {
        // The reader's real geometry: the bottom inset is exactly the footer band. The
        // column used to be cut down to a multiple of fontSize + lineSpacing, and the
        // remainder — up to a whole line — sat between the last line and the footer,
        // where 底部對齊 could not reach it. The path must keep the inset it was given.
        let insets = UIEdgeInsets(top: 104, left: 24, bottom: 58, right: 24)
        let size = CGSize(width: 440, height: 956)
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: Self.chapter(paragraphs: 200),
            renderSize: size,
            fontSize: 18,
            contentInsets: insets,
            bottomJustify: true,
            revision: ContentRevision()
        )
        try #require(layout.pageArtifacts.count > 2)
        #expect(layout.contentInsets.bottom == insets.bottom)
        for artifact in layout.pageArtifacts.dropLast() {
            let pathRect = CTFrameGetPath(artifact.frame).boundingBoxOfPath
            #expect(pathRect.minY == insets.bottom)
            #expect(abs(Self.lastLineBottom(artifact)) < 0.5)
        }
    }

    @Test("The chapter's last page keeps its natural line positions")
    @MainActor
    func chapterEndIsNotStretched() async throws {
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: Self.chapter(),
            renderSize: Self.renderSize,
            fontSize: 18,
            bottomJustify: true,
            revision: ContentRevision()
        )
        let last = try #require(layout.pageArtifacts.last)
        #expect(last.lineOrigins == Self.frameOrigins(last))
    }

    @Test("A page cut short by a forced page break keeps its natural line positions")
    @MainActor
    func forcedBreakPageIsNotStretched() async throws {
        let text = NSMutableAttributedString(attributedString: Self.chapter(paragraphs: 4))
        text.append(NSAttributedString(
            string: "\n",
            attributes: [
                .font: UIFont.systemFont(ofSize: 18),
                HTMLAttributedStringBuilder.pageBreakAttribute: true,
            ]
        ))
        text.append(Self.chapter(paragraphs: 60))
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: text,
            renderSize: Self.renderSize,
            fontSize: 18,
            bottomJustify: true,
            revision: ContentRevision()
        )
        let first = try #require(layout.pageArtifacts.first)
        #expect(first.lineOrigins == Self.frameOrigins(first))
        #expect(Self.lastLineBottom(first) > 100)
    }

    @Test("A page that ends because a block image moved to the next page keeps its natural line positions")
    @MainActor
    func pageBeforeBlockImageIsNotStretched() async throws {
        let font = UIFont.systemFont(ofSize: 18)
        let text = NSMutableAttributedString(attributedString: Self.chapter(paragraphs: 30))
        let imageLocation = text.length
        text.append(RunDelegateProvider.makeImagePlaceholder(
            image: UIImage(), font: font, textColor: .black,
            totalWidth: 280, drawWidth: 280, drawHeight: 460,
            ascent: 460, descent: 0, paddingLeft: 0, paddingRight: 0,
            imageSource: "image.png", displayMode: .block, opacity: 1
        ))
        text.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        text.append(Self.chapter(paragraphs: 40))
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: text,
            renderSize: Self.renderSize,
            fontSize: 18,
            bottomJustify: true,
            revision: ContentRevision()
        )
        let imagePage = try #require(layout.pageRanges.firstIndex {
            $0.location <= imageLocation && imageLocation < $0.location + $0.length
        })
        // The image opens its page: the page before it ended for the image.
        try #require(layout.pageRanges[imagePage].location == imageLocation, "image did not open a page")
        let before = layout.pageArtifacts[imagePage - 1]
        #expect(before.lineOrigins == Self.frameOrigins(before))
        #expect(Self.lastLineBottom(before) > 50)
        // Text pages on either side that ended for text still justify.
        let earlier = layout.pageArtifacts[imagePage - 2]
        #expect(abs(Self.lastLineBottom(earlier)) < 0.5)
        let after = layout.pageArtifacts[imagePage + 1]
        #expect(abs(Self.lastLineBottom(after)) < 0.5)
    }

    @Test("A paragraph background box still encloses its lines after they move")
    @MainActor
    func backgroundBoxesFollowJustifiedLines() async throws {
        let paragraph = "<p style=\"background-color:#eee\">每一段都有底色，底色要跟著自己的行一起往下移動。</p>"
        let attributed = await EPUBTestFixtures.renderIR(
            html: "<html><body>\(String(repeating: paragraph, count: 30))</body></html>",
            config: HTMLAttributedStringBuilder.Config(
                fontSize: 18, lineHeightMultiple: 1.5, lineSpacing: 0, paragraphSpacing: 8,
                firstLineIndent: 0, textColor: .black, backgroundColor: .white,
                fontFamilyName: nil, renderWidth: Self.renderSize.width
            )
        )
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: LayoutShared(attributed).wrappedValue,
            renderSize: Self.renderSize,
            fontSize: 18,
            bottomJustify: true,
            revision: ContentRevision()
        )
        try #require(layout.pageArtifacts.count > 2)

        for (pageIndex, artifact) in layout.pageArtifacts.enumerated().dropLast() {
            #expect(abs(Self.lastLineBottom(artifact)) < 0.5)
            let boxes = try #require(layout.blockRenderables[pageIndex]).map(\.rect)
            let pathRect = CTFrameGetPath(artifact.frame).boundingBoxOfPath
            let lines = CTFrameGetLines(artifact.frame) as! [CTLine]
            for (index, line) in lines.enumerated() {
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                // Boxes are in UIKit canvas space; origins are relative to the path's bottom.
                let top = Self.renderSize.height - (artifact.lineOrigins[index].y + pathRect.minY + ascent)
                let bottom = top + ascent + descent
                #expect(
                    boxes.contains { $0.minY <= top + 0.5 && bottom <= $0.maxY + 0.5 },
                    "page \(pageIndex) line \(index) left its background box"
                )
            }
        }
    }

    @Test("The first page laid out on its own matches the same page in the full layout")
    @MainActor
    func firstPageLayoutMatchesFullLayout() async throws {
        let forcedBreak = NSMutableAttributedString(attributedString: Self.chapter(paragraphs: 4))
        forcedBreak.append(NSAttributedString(
            string: "\n",
            attributes: [.font: UIFont.systemFont(ofSize: 18), HTMLAttributedStringBuilder.pageBreakAttribute: true]
        ))
        forcedBreak.append(Self.chapter(paragraphs: 60))

        // Opening a book shows the partial layout first; when the full one replaces
        // it, the visible page must not move.
        for (chapter, firstPageJustifies) in [(Self.chapter(), true), (forcedBreak as NSAttributedString, false)] {
            let revision = ContentRevision()
            let partial = try #require(await CoreTextPaginator().paginateFirstPage(
                spineIndex: 0, attrStr: chapter, renderSize: Self.renderSize, fontSize: 18,
                bottomJustify: true, revision: revision
            ))
            let full = await CoreTextPaginator().paginate(
                spineIndex: 0, attrStr: chapter, renderSize: Self.renderSize, fontSize: 18,
                bottomJustify: true, revision: revision
            )
            let partialFirst = try #require(partial.pageArtifacts.first)
            let fullFirst = try #require(full.pageArtifacts.first)
            #expect(partialFirst.lineOrigins == fullFirst.lineOrigins)
            #expect(partial.bottomJustifiedPages.contains(0) == full.bottomJustifiedPages.contains(0))
            #expect(full.bottomJustifiedPages.contains(0) == firstPageJustifies)
        }
    }

    @Test("Turning the setting off lays out with CoreText's own origins, and is a separate cache entry")
    @MainActor
    func offKeepsNaturalOrigins() async throws {
        let paginator = CoreTextPaginator()
        let chapter = Self.chapter()
        let revision = ContentRevision()
        let justified = await paginator.paginate(
            spineIndex: 0, attrStr: chapter, renderSize: Self.renderSize, fontSize: 18,
            bottomJustify: true, revision: revision
        )
        let natural = await paginator.paginate(
            spineIndex: 0, attrStr: chapter, renderSize: Self.renderSize, fontSize: 18,
            bottomJustify: false, revision: revision
        )
        let justifiedFirst = try #require(justified.pageArtifacts.first)
        let naturalFirst = try #require(natural.pageArtifacts.first)
        #expect(naturalFirst.lineOrigins == Self.frameOrigins(naturalFirst))
        #expect(justifiedFirst.lineOrigins != naturalFirst.lineOrigins)
    }

    @Test("Recoloring a layout keeps its justified origins")
    @MainActor
    func appearanceUpdateKeepsJustifiedOrigins() async throws {
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: Self.chapter(),
            renderSize: Self.renderSize,
            fontSize: 18,
            bottomJustify: true,
            revision: ContentRevision()
        )
        let recolored = layout.withUpdatedColors(textColor: .red, backgroundColor: .black)
        let before = try #require(layout.pageArtifacts.first)
        let after = try #require(recolored.pageArtifacts.first)
        #expect(after.lineOrigins == before.lineOrigins)
    }
}
