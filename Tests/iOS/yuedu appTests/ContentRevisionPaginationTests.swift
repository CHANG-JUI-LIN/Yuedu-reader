import Foundation
import os
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
        let fingerprintCount = OSAllocatedUnfairLock(initialState: 0)
        let paginator = CoreTextPaginator(layoutFingerprintProvider: { _ in
            fingerprintCount.withLock { count in
                count += 1
                return count
            }
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

        #expect(fingerprintCount.withLock { $0 } == 0)
    }

    @Test("Legacy pagination without revision still fingerprints content")
    @MainActor
    func legacyPaginationStillFingerprintsContent() async {
        let fingerprintCount = OSAllocatedUnfairLock(initialState: 0)
        let paginator = CoreTextPaginator(layoutFingerprintProvider: { _ in
            fingerprintCount.withLock { $0 += 1 }
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

        #expect(fingerprintCount.withLock { $0 } == 2)
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
        let fingerprintCount = OSAllocatedUnfairLock(initialState: 0)
        let firstContent = makeAttributedString(text: "legacy first")
        let secondContent = makeAttributedString(text: "legacy second")
        let firstText = firstContent.string
        let paginator = CoreTextPaginator(layoutFingerprintProvider: { attributedString in
            fingerprintCount.withLock { $0 += 1 }
            return attributedString.string == firstText ? 101 : 202
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

        #expect(fingerprintCount.withLock { $0 } == 2)
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

    /// A window whose side safe areas differ (a folded iPhone Duo's status bar runs down one side)
    /// can swap its two margins at the same size. The cache once keyed on the left margin alone
    /// and would hand back pages laid out for the other side.
    @Test("Swapping the left and right margins at the same size lays the chapter out again")
    @MainActor
    func swappedSideMarginsMissCache() async {
        let paginator = CoreTextPaginator()
        let attributedString = makeAttributedString()
        let revision = ContentRevision()

        let firstLayout = await paginator.paginate(
            spineIndex: 10,
            attrStr: attributedString,
            renderSize: CGSize(width: 320, height: 480),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 70),
            revision: revision
        )
        let swappedLayout = await paginator.paginate(
            spineIndex: 10,
            attrStr: attributedString,
            renderSize: CGSize(width: 320, height: 480),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 0, left: 70, bottom: 0, right: 8),
            revision: revision
        )

        #expect(firstLayout.framesetter !== swappedLayout.framesetter)
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
