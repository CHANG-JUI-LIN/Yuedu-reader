import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Content revision pagination", .serialized)
struct ContentRevisionPaginationTests {
    @Test("A build result keeps one revision and separate results receive separate revisions")
    func buildResultRevisionIdentity() {
        let injectedRevision = ContentRevision()
        let first = makeBuildResult(revision: injectedRevision)
        let firstRevision = first.revision
        let second = makeBuildResult()

        #expect(first.revision == injectedRevision)
        #expect(first.revision == firstRevision)
        #expect(first.revision != second.revision)
    }

    @Test("Explicit revision skips fingerprinting for first-page and full pagination")
    @MainActor
    func explicitRevisionSkipsFingerprinting() async {
        var fingerprintCount = 0
        let paginator = CoreTextPaginator(layoutFingerprintProvider: { _ in
            fingerprintCount += 1
            return fingerprintCount
        })
        let attributedString = makeAttributedString()
        let revision = ContentRevision()

        _ = await paginator.paginateFirstPage(
            spineIndex: 0,
            attrStr: attributedString,
            renderSize: CGSize(width: 320, height: 480),
            fontSize: 18,
            revision: revision
        )
        _ = await paginator.paginate(
            spineIndex: 0,
            attrStr: attributedString,
            renderSize: CGSize(width: 320, height: 480),
            fontSize: 18,
            revision: revision
        )

        #expect(fingerprintCount == 0)
    }

    @Test("Legacy pagination without revision still fingerprints content")
    @MainActor
    func legacyPaginationStillFingerprintsContent() async {
        var fingerprintCount = 0
        let paginator = CoreTextPaginator(layoutFingerprintProvider: { _ in
            fingerprintCount += 1
            return 7
        })
        let attributedString = makeAttributedString()

        _ = await paginator.paginateFirstPage(
            spineIndex: 0,
            attrStr: attributedString,
            renderSize: CGSize(width: 320, height: 480),
            fontSize: 18
        )
        _ = await paginator.paginate(
            spineIndex: 0,
            attrStr: attributedString,
            renderSize: CGSize(width: 320, height: 480),
            fontSize: 18
        )

        #expect(fingerprintCount == 2)
    }

    @Test("Different explicit revisions prevent stale content cache hits")
    @MainActor
    func differentExplicitRevisionsUseDifferentLayouts() async {
        let paginator = CoreTextPaginator()
        let firstContent = makeAttributedString(text: "第一份內容")
        let secondContent = makeAttributedString(text: "第二份完全不同的內容")

        _ = await paginator.paginate(
            spineIndex: 7,
            attrStr: firstContent,
            renderSize: CGSize(width: 320, height: 480),
            fontSize: 18,
            revision: ContentRevision()
        )
        let secondLayout = await paginator.paginate(
            spineIndex: 7,
            attrStr: secondContent,
            renderSize: CGSize(width: 320, height: 480),
            fontSize: 18,
            revision: ContentRevision()
        )

        #expect(secondLayout.attributedString.string == secondContent.string)
    }

    @Test("Legacy fingerprints prevent stale content cache hits")
    @MainActor
    func differentLegacyFingerprintsUseDifferentLayouts() async {
        var fingerprintCount = 0
        let firstContent = makeAttributedString(text: "legacy first")
        let secondContent = makeAttributedString(text: "legacy second")
        let paginator = CoreTextPaginator(layoutFingerprintProvider: { attributedString in
            fingerprintCount += 1
            return attributedString.string == firstContent.string ? 101 : 202
        })

        _ = await paginator.paginate(
            spineIndex: 8,
            attrStr: firstContent,
            renderSize: CGSize(width: 320, height: 480),
            fontSize: 18
        )
        let secondLayout = await paginator.paginate(
            spineIndex: 8,
            attrStr: secondContent,
            renderSize: CGSize(width: 320, height: 480),
            fontSize: 18
        )

        #expect(fingerprintCount == 2)
        #expect(secondLayout.attributedString.string == secondContent.string)
    }

    @Test("A warm full request with the same revision returns the cached layout")
    @MainActor
    func sameRevisionWarmRequestHitsCache() async {
        let paginator = CoreTextPaginator()
        let attributedString = makeAttributedString()
        let revision = ContentRevision()

        let firstLayout = await paginator.paginate(
            spineIndex: 9,
            attrStr: attributedString,
            renderSize: CGSize(width: 320, height: 480),
            fontSize: 18,
            revision: revision
        )
        let warmLayout = await paginator.paginate(
            spineIndex: 9,
            attrStr: attributedString,
            renderSize: CGSize(width: 320, height: 480),
            fontSize: 18,
            revision: revision
        )

        #expect(firstLayout.framesetter === warmLayout.framesetter)
    }

    private func makeBuildResult(
        revision: ContentRevision = ContentRevision()
    ) -> AttributedChapterBuildResult {
        AttributedChapterBuildResult(
            attributedString: makeAttributedString(),
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:],
            revision: revision
        )
    }

    private func makeAttributedString(
        text: String = String(repeating: "內容修訂測試。", count: 40)
    ) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
    }
}
