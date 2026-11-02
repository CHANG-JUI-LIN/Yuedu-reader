import Combine
import Foundation
import SwiftUI
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// Paged mode lays each chapter of a publisher EPUB out in its own writing mode (`BookWritingModes`),
/// in both engines, while pages keep turning in the book's direction. The case that started it: the
/// table of contents a Calibre conversion appends to a vertical book (`c0004.xhtml`, spine 3) declares
/// no writing mode, and was laid out vertically.
@Suite("Chapter writing modes in paged mode", .serialized)
@MainActor
struct ChapterWritingModeEngineTests {
    private static let size = CGSize(width: 320, height: 480)

    private static func convertedVerticalBook() async throws -> PublicationSession {
        try await PublicationSession.open(sourceURL: try await BookWritingModesTests.converted("vertical-zh.azw3"))
    }

    /// The settings the reader hands a publisher EPUB's engines: its principal mode.
    private static func settings(_ modes: BookWritingModes) -> ReaderRenderSettings {
        EPUBTestFixtures.renderSettings(writingMode: modes.direction.principalMode)
    }

    private static func textModes(_ fragments: [Fragment]) -> [ReaderWritingMode] {
        fragments.flatMap { fragment -> [ReaderWritingMode] in
            switch fragment {
            case .text(let text): [text.writingMode]
            case .group(let children): textModes(children)
            case .fill, .image: []
            }
        }
    }

    /// The mode spine `spine` was laid out in, by whichever engine owns it.
    private static func layoutMode(_ engine: BrowserLayoutPageEngine, spine: Int) -> ReaderWritingMode? {
        if engine.choice(for: spine)?.isBrowser == true {
            let modes = Set(engine.testLayout(for: spine)?.pages.flatMap { textModes($0.fragments) } ?? [])
            return modes.count == 1 ? modes.first : nil
        }
        return engine.layouts[spine]?.writingMode
    }

    @Test("the legacy engine alone lays each chapter of the converted book out in its own mode")
    func legacyEngine() async throws {
        let session = try await Self.convertedVerticalBook()
        let modes = await EPUBPageRenderer().resolveWritingModes(for: session)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = CoreTextPageEngine(
            attributedBuilder: EPUBAttributedStringBuilder(session: session, renderSize: Self.size),
            renderSettings: Self.settings(modes), offsetStore: CharOffsetStore(directoryURL: directory)
        )
        engine.writingModes = modes
        await engine.start(renderSize: Self.size, bookId: UUID().uuidString)
        #expect(await engine.preloadChapter(at: 1).isReady)
        #expect(await engine.preloadChapter(at: 3).isReady)
        #expect(engine.layouts[1]?.writingMode == .verticalRTL)
        #expect(engine.layouts[3]?.writingMode == .horizontal)
    }

    @Test("BrowserAuto lays each chapter out in its own mode, reusing every admission's evaluation")
    func browserAuto() async throws {
        let session = try await Self.convertedVerticalBook()
        let renderer = EPUBPageRenderer()
        let modes = await renderer.resolveWritingModes(for: session)
        renderer.load(publicationSession: session, bookIdentifier: UUID().uuidString,
                      renderSize: Self.size, settings: Self.settings(modes))
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
        for spine in 0..<4 { #expect(await engine.preloadChapter(at: spine).isReady) }
        #expect(Self.layoutMode(engine, spine: 1) == .verticalRTL)
        #expect(Self.layoutMode(engine, spine: 2) == .verticalRTL)
        #expect(Self.layoutMode(engine, spine: 3) == .horizontal)
        #expect(engine.choice(for: 3)?.isBrowser == true)
        #expect(engine.testStaleAdmissionSpines.isEmpty, "\(engine.testStaleAdmissionSpines)")
    }

    @Test("pages step from the last vertical page into the horizontal TOC still turning right to left")
    func steppingIntoTheTOC() async throws {
        let session = try await Self.convertedVerticalBook()
        let renderer = EPUBPageRenderer()
        let modes = await renderer.resolveWritingModes(for: session)
        renderer.load(publicationSession: session, bookIdentifier: UUID().uuidString,
                      renderSize: Self.size, settings: Self.settings(modes))
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        let engine = try #require(renderer.engine)
        for spine in 0..<4 { _ = await engine.preloadChapter(at: spine) }
        let direction = try #require(renderer.bookDirection)
        #expect(direction.isRTL)

        let reader = CoreTextPageEngineView(
            engine: engine, pageTurnStyle: .slide, theme: .white, playbackHighlight: nil,
            isRTL: direction.isRTL, isDoublePageSpread: false, spreadGutter: 0,
            sessionCoordinator: nil, externalTargetVersion: 0, externalTargetPosition: nil,
            pageTurnCommand: nil, clearExternalTargetPosition: {}, currentPage: .constant(0),
            onPageChanged: { _, _ in }, onTapZone: { _ in }
        )
        let coordinator = reader.makeCoordinator()
        let pvc = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        let last = try #require(engine.lastPageIndex(ofChapter: 2))
        // Right to left: the next page is the one UIKit asks for "before".
        let next = try #require(coordinator.pageViewController(pvc, viewControllerBefore: engine.pageViewController(at: last)))
        let index = try #require((next as? PageIndexProviding)?.globalPageIndex)
        #expect(engine.localPosition(for: index).spineIndex == 3)
        #expect(engine.localPosition(for: index).localPage == 0)
        #expect(Self.layoutMode(try #require(engine as? BrowserLayoutPageEngine), spine: 3) == .horizontal)
    }

    @Test("a CSS-only vertical book without a page progression reads right to left before its first layout")
    func directionBeforeFirstLayout() async throws {
        let url = try await BookWritingModesTests.epub(
            language: "zh-Hant", css: "html { writing-mode: vertical-rl }", chapters: ["<p>一</p>", "<p>二</p>"]
        )
        let session = try await PublicationSession.open(sourceURL: url)
        let renderer = EPUBPageRenderer()
        await renderer.resolveWritingModes(for: session)
        #expect(renderer.bookDirection == BookDirection(isRTL: true, principalMode: .verticalRTL))
        #expect(renderer.engine == nil)
        renderer.load(publicationSession: session, bookIdentifier: UUID().uuidString,
                      renderSize: Self.size, settings: EPUBTestFixtures.renderSettings(writingMode: .verticalRTL))
        #expect(renderer.bookDirection?.isRTL == true)
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        #expect(renderer.bookDirection?.isRTL == true)
    }

    @Test("a book the reader did not resolve, and a TXT book, carry no direction of their own")
    func unresolvedBooksFollowTheSetting() async throws {
        let first = try await PublicationSession.open(sourceURL: try await BookWritingModesTests.epub(
            language: "ja", css: "html { writing-mode: vertical-rl }", chapters: ["<p>一</p>"]))
        let second = try await PublicationSession.open(sourceURL: try await BookWritingModesTests.epub(
            language: "en", chapters: ["<p>One</p>"]))
        let renderer = EPUBPageRenderer()
        await renderer.resolveWritingModes(for: first)
        // Another session's modes are never handed to this one's engines.
        renderer.load(publicationSession: second, bookIdentifier: UUID().uuidString,
                      renderSize: Self.size, settings: EPUBTestFixtures.renderSettings())
        #expect(renderer.bookDirection == nil)
        #expect((renderer.engine as? BrowserLayoutPageEngine)?.writingModes == nil)
        await renderer.resolveWritingModes(for: first)
        renderer.loadTXT(text: "第一章\n一\n", title: "TXT", bookIdentifier: UUID().uuidString,
                         renderSize: Self.size, settings: EPUBTestFixtures.renderSettings())
        #expect(renderer.bookDirection == nil)
    }

    @Test("turning 排版方向 gives the page view a new identity, so its controller is rebuilt")
    func directionIsInThePageViewIdentity() {
        func identity(_ mode: ReaderWritingMode) -> String {
            ReaderView.pageViewIdentity(pageTurnStyle: .slide, spreadMode: .singlePage,
                                        size: Self.size, direction: BookDirection(uniform: mode))
        }
        #expect(identity(.verticalRTL) != identity(.horizontal))
        #expect(identity(.horizontal) == identity(.horizontal))
    }
}
