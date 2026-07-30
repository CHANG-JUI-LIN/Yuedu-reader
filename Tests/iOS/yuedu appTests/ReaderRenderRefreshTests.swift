import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Reader render refresh", .serialized)
@MainActor
struct ReaderRenderRefreshTests {
    @Test("refresh requests preserve their rendering contract")
    func requestPreservesRenderingContract() {
        let position = CoreTextReadingPosition(spineIndex: 3, charOffset: 144)
        let request = ReaderRenderRefreshRequest(
            intent: .layout,
            mode: .scroll,
            settings: Self.makeSettings(fontSize: 18),
            position: position,
            viewportSize: CGSize(width: 390, height: 844)
        )

        #expect(request.mode == .scroll)
        #expect(request.position == position)
        #expect(request.intent == .layout)
    }

    @Test("only completed refresh results report completion")
    func onlyCompletedResultsReportCompletion() {
        #expect(ReaderRenderRefreshResult.completed(transactionID: 4).isCompleted)
        #expect(!ReaderRenderRefreshResult.superseded(transactionID: 5).isCompleted)
        #expect(
            !ReaderRenderRefreshResult.failed(
                transactionID: 6,
                failure: .engineUnavailable(.paged)
            ).isCompleted
        )
    }

    @Test("newer layout refresh supersedes older transaction")
    func newerRefreshSupersedesOlderTransaction() async {
        let renderer = EPUBPageRenderer()
        renderer.loadTXT(
            attributedBuilder: MutableReaderRefreshBuilder(body: "Body"),
            bookIdentifier: UUID().uuidString,
            renderSize: CGSize(width: 320, height: 480),
            settings: Self.makeSettings(fontSize: 18)
        )
        await waitUntilPagedReady(renderer)

        let first = Task {
            await renderer.refresh(Self.request(fontSize: 19))
        }
        let firstCommit = await waitForVisibleCommit(renderer)
        let second = Task {
            await renderer.refresh(Self.request(fontSize: 22))
        }
        let secondCommit = await waitForVisibleCommit(
            renderer,
            after: firstCommit.transactionID
        )
        renderer.finishVisibleRefresh(
            transactionID: secondCommit.transactionID,
            outcome: .applied
        )

        #expect(await first.value == .superseded(transactionID: 1))
        #expect(await second.value == .completed(transactionID: 2))
        #expect((renderer.engine as? CoreTextPageEngine)?.renderSettings.fontSize == 22)
        #expect(renderer.scrollEngine?.renderSettings.fontSize == 22)
    }

    @Test("chapter refresh invalidates shared document once")
    func chapterRefreshInvalidatesSharedDocumentOnce() async {
        let builder = MutableReaderRefreshBuilder(body: "Body")
        let renderer = EPUBPageRenderer()
        renderer.loadTXT(
            attributedBuilder: builder,
            bookIdentifier: UUID().uuidString,
            renderSize: CGSize(width: 320, height: 480),
            settings: Self.makeSettings(fontSize: 18)
        )
        await waitUntilPagedReady(renderer)
        #expect(builder.buildCount == 1)

        let task = Task {
            await renderer.refresh(
                ReaderRenderRefreshRequest(
                    intent: .chapterContent(0),
                    mode: .paged,
                    settings: Self.makeSettings(fontSize: 18),
                    position: .chapterStart(0),
                    viewportSize: CGSize(width: 320, height: 480)
                )
            )
        }
        let commit = await waitForVisibleCommit(renderer)
        renderer.finishVisibleRefresh(
            transactionID: commit.transactionID,
            outcome: .applied
        )

        #expect(await task.value == .completed(transactionID: 1))
        #expect(builder.buildCount == 2)
    }

    @Test("newer layout refresh rebuilds target while older prepare is in flight")
    func newerRefreshRebuildsTargetDuringOlderPrepare() async {
        let builder = MutableReaderRefreshBuilder(body: "Body")
        let renderer = EPUBPageRenderer()
        renderer.loadTXT(
            attributedBuilder: builder,
            bookIdentifier: UUID().uuidString,
            renderSize: CGSize(width: 320, height: 480),
            settings: Self.makeSettings(fontSize: 18)
        )
        await waitUntilPagedReady(renderer)
        let engine = renderer.engine as? CoreTextPageEngine
        let callbackProbe = ReaderRefreshCallbackProbe()
        engine?.onChapterReady = { _ in callbackProbe.chapterReadyCount += 1 }
        engine?.onNavigateToPage = { _ in callbackProbe.navigateCount += 1 }

        builder.gateBuild(fontSize: 19)
        let firstResultProbe = ReaderRefreshResultProbe()
        let first = Task {
            let result = await renderer.refresh(Self.request(fontSize: 19))
            firstResultProbe.result = result
            return result
        }
        await builder.waitUntilGatedBuildStarts()
        #expect(renderer.pendingVisibleRefreshCommit == nil)

        let second = Task {
            await renderer.refresh(Self.request(fontSize: 22))
        }
        await builder.waitUntilBuildStarts(fontSize: 22)
        await Task.yield()

        let firstReturnedBeforeGateRelease = firstResultProbe.result != nil
        #expect(firstResultProbe.result == .superseded(transactionID: 1))
        #expect(builder.hasPendingGatedBuild)
        if !firstReturnedBeforeGateRelease {
            builder.releaseGatedBuild()
        }

        let firstResult = await first.value
        let secondCommit = await waitForVisibleCommit(renderer)
        renderer.finishVisibleRefresh(
            transactionID: secondCommit.transactionID,
            outcome: .applied
        )
        let secondResult = await second.value
        let readyCountAfterSecond = callbackProbe.chapterReadyCount
        let navigateCountAfterSecond = callbackProbe.navigateCount
        let pageAfterSecond = engine?.currentPage
        let wasRelayingAfterSecond = engine?.isRelaying

        if builder.hasPendingGatedBuild {
            builder.releaseGatedBuild()
        }
        await builder.waitUntilGatedBuildReturns()
        while renderer.activeRefreshPreparationCount > 0 {
            await Task.yield()
        }

        #expect(firstResult == .superseded(transactionID: 1))
        #expect(secondResult == .completed(transactionID: 2))
        #expect(secondCommit.transactionID == 2)
        #expect(engine?.layouts[0] != nil)
        #expect(engine?.renderSettings.fontSize == 22)
        #expect(callbackProbe.chapterReadyCount == readyCountAfterSecond)
        #expect(callbackProbe.navigateCount == navigateCountAfterSecond)
        #expect(engine?.currentPage == pageAfterSecond)
        #expect(wasRelayingAfterSecond == false)
        #expect(engine?.isRelaying == false)
    }

    @Test("paged appearance does not mark stale content revision applied")
    func pagedAppearancePreservesStaleContentRevision() async {
        let builder = MutableReaderRefreshBuilder(body: "Old body")
        let renderer = EPUBPageRenderer()
        renderer.loadTXT(
            attributedBuilder: builder,
            bookIdentifier: UUID().uuidString,
            renderSize: CGSize(width: 320, height: 480),
            settings: Self.makeSettings(fontSize: 18)
        )
        await waitUntilPagedReady(renderer)
        builder.body = "New body"

        let scrollContent = Task {
            await renderer.refresh(
                Self.request(
                    intent: .chapterContent(0),
                    mode: .scroll,
                    fontSize: 18
                )
            )
        }
        let scrollCommit = await waitForVisibleCommit(renderer)
        _ = await renderer.scrollEngine?.reslice(
            restoreAt: 0,
            contentWidth: 288,
            restorePosition: .chapterStart(0)
        )
        renderer.finishVisibleRefresh(
            transactionID: scrollCommit.transactionID,
            outcome: .applied
        )
        #expect(await scrollContent.value == .completed(transactionID: 1))

        let appearance = Task {
            await renderer.refresh(
                Self.request(
                    intent: .appearance,
                    mode: .paged,
                    fontSize: 18
                )
            )
        }
        let appearanceCommit = await waitForVisibleCommit(
            renderer,
            after: scrollCommit.transactionID
        )
        renderer.finishVisibleRefresh(
            transactionID: appearanceCommit.transactionID,
            outcome: .applied
        )
        #expect(await appearance.value == .completed(transactionID: 2))
        #expect(
            (renderer.engine as? CoreTextPageEngine)?
                .layouts[0]?.attributedString.string == "Old body"
        )

        let activation = Task {
            await renderer.refresh(
                Self.request(
                    intent: .modeActivation,
                    mode: .paged,
                    fontSize: 18
                )
            )
        }
        let activationCommit = await waitForVisibleCommit(
            renderer,
            after: appearanceCommit.transactionID
        )
        #expect(
            (renderer.engine as? CoreTextPageEngine)?
                .layouts[0]?.attributedString.string == "New body"
        )
        renderer.finishVisibleRefresh(
            transactionID: activationCommit.transactionID,
            outcome: .applied
        )
        #expect(await activation.value == .completed(transactionID: 3))
    }

    @Test("fresh scroll mode activation completes without visible commit")
    func freshScrollActivationCompletesImmediately() async {
        let renderer = EPUBPageRenderer()
        renderer.loadTXT(
            attributedBuilder: MutableReaderRefreshBuilder(body: "Body"),
            bookIdentifier: UUID().uuidString,
            renderSize: CGSize(width: 320, height: 480),
            settings: Self.makeSettings(fontSize: 18)
        )
        await waitUntilPagedReady(renderer)
        let request = Self.request(
            intent: .modeActivation,
            mode: .scroll,
            fontSize: 18
        )

        let first = Task { await renderer.refresh(request) }
        let firstCommit = await waitForVisibleCommit(renderer)
        _ = await renderer.scrollEngine?.reslice(
            restoreAt: 0,
            contentWidth: 288,
            restorePosition: .chapterStart(0)
        )
        renderer.finishVisibleRefresh(
            transactionID: firstCommit.transactionID,
            outcome: .applied
        )
        #expect(await first.value == .completed(transactionID: 1))

        let second = Task { await renderer.refresh(request) }
        let unexpectedCommitFinisher = Task<ReaderVisibleRefreshCommit?, Never> {
            @MainActor in
            while !Task.isCancelled {
                if let commit = renderer.pendingVisibleRefreshCommit,
                   commit.transactionID > firstCommit.transactionID {
                    renderer.finishVisibleRefresh(
                        transactionID: commit.transactionID,
                        outcome: .applied
                    )
                    return commit
                }
                await Task.yield()
            }
            return nil
        }
        let secondResult = await second.value
        unexpectedCommitFinisher.cancel()
        let unexpectedCommit = await unexpectedCommitFinisher.value

        #expect(secondResult == .completed(transactionID: 2))
        #expect(unexpectedCommit == nil)
        #expect(renderer.pendingVisibleRefreshCommit == nil)
    }

    private static func makeSettings(fontSize: CGFloat) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "sepia",
            textColor: .black,
            backgroundColor: .white,
            fontSize: fontSize,
            lineHeightMultiple: 1.6,
            lineSpacing: 10,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 24,
            marginV: 16,
            footerHeight: 24,
            contentInsets: .zero
        )
    }

    private static func request(fontSize: CGFloat) -> ReaderRenderRefreshRequest {
        request(intent: .layout, mode: .paged, fontSize: fontSize)
    }

    private static func request(
        intent: ReaderRenderRefreshIntent,
        mode: ReaderDisplayMode,
        fontSize: CGFloat
    ) -> ReaderRenderRefreshRequest {
        ReaderRenderRefreshRequest(
            intent: intent,
            mode: mode,
            settings: makeSettings(fontSize: fontSize),
            position: .chapterStart(0),
            viewportSize: CGSize(width: 320, height: 480)
        )
    }
}

@MainActor
private final class MutableReaderRefreshBuilder: AttributedStringBuilding {
    let chapterCount = 1
    var body: String
    private(set) var buildCount = 0
    private var gatedFontSize: CGFloat?
    private var gatedBuildStarted = false
    private var gatedBuildReturned = false
    private var gatedBuildContinuation: CheckedContinuation<Void, Never>?
    private var startedFontSizes: Set<CGFloat> = []

    var hasPendingGatedBuild: Bool {
        gatedBuildContinuation != nil
    }

    init(body: String) {
        self.body = body
    }

    func chapterTitle(at index: Int) -> String {
        "Chapter \(index)"
    }

    func chapterDataSize(at index: Int) async -> Int {
        body.utf8.count
    }

    func gateBuild(fontSize: CGFloat) {
        gatedFontSize = fontSize
        gatedBuildStarted = false
        gatedBuildReturned = false
    }

    func waitUntilGatedBuildStarts() async {
        while !gatedBuildStarted {
            await Task.yield()
        }
    }

    func waitUntilBuildStarts(fontSize: CGFloat) async {
        while !startedFontSizes.contains(fontSize) {
            await Task.yield()
        }
    }

    func waitUntilGatedBuildReturns() async {
        while !gatedBuildReturned {
            await Task.yield()
        }
    }

    func releaseGatedBuild() {
        gatedBuildContinuation?.resume()
        gatedBuildContinuation = nil
        gatedFontSize = nil
    }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        buildCount += 1
        startedFontSizes.insert(settings.fontSize)
        if settings.fontSize == gatedFontSize {
            gatedBuildStarted = true
            await withCheckedContinuation { continuation in
                gatedBuildContinuation = continuation
            }
            gatedBuildReturned = true
        }
        return AttributedChapterBuildResult(
            attributedString: NSAttributedString(
                string: body,
                attributes: [
                    .font: UIFont.systemFont(ofSize: settings.fontSize),
                    .foregroundColor: themeTextColor,
                ]
            ),
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }
}

@MainActor
private final class ReaderRefreshResultProbe {
    var result: ReaderRenderRefreshResult?
}

@MainActor
private final class ReaderRefreshCallbackProbe {
    var chapterReadyCount = 0
    var navigateCount = 0
}

@MainActor
private func waitForVisibleCommit(
    _ renderer: EPUBPageRenderer,
    after transactionID: UInt64 = 0
) async -> ReaderVisibleRefreshCommit {
    while true {
        if let commit = renderer.pendingVisibleRefreshCommit,
           commit.transactionID > transactionID {
            return commit
        }
        await Task.yield()
    }
}

@MainActor
private func waitUntilPagedReady(_ renderer: EPUBPageRenderer) async {
    while !renderer.isCoreTextReady {
        await Task.yield()
    }
}
