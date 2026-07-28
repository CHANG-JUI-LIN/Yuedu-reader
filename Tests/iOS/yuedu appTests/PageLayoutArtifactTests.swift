import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Page layout artifacts", .serialized)
struct PageLayoutArtifactTests {
    @Test("Pagination creates one final frame artifact for every page range")
    @MainActor
    func paginationCreatesArtifactsForEveryPage() async {
        let attributedString = NSAttributedString(
            string: String(repeating: "每一頁只建立一次最終 CoreText frame。\n", count: 180),
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: attributedString,
            renderSize: CGSize(width: 320, height: 480),
            fontSize: 18,
            revision: ContentRevision()
        )

        #expect(layout.pageArtifacts.count == layout.pageRanges.count)
        for (artifact, range) in zip(layout.pageArtifacts, layout.pageRanges) {
            #expect(artifact.range.location == range.location)
            #expect(artifact.range.length == range.length)
            #expect(artifact.lineOrigins.count == (CTFrameGetLines(artifact.frame) as! [CTLine]).count)
        }
    }

    @Test("Page rendering returns the exact frame retained by the artifact")
    @MainActor
    func renderingReusesArtifactFrameIdentity() async throws {
        let attributedString = NSAttributedString(
            string: String(repeating: "artifact identity ", count: 120),
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: attributedString,
            renderSize: CGSize(width: 320, height: 480),
            fontSize: 18,
            revision: ContentRevision()
        )
        let artifact = try #require(layout.pageArtifacts.first)

        let renderingFrame = CoreTextPageView.frameForRendering(
            layout: layout,
            pageIndex: 0
        )

        #expect(renderingFrame === artifact.frame)
    }
}
