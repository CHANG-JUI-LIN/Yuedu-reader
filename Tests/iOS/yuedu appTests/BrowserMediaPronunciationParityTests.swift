import AVKit
import Testing
import UIKit
@testable import yuedu_app

@MainActor
struct BrowserMediaPronunciationParityTests {
    @Test func videoSourceChildProducesReplacedFragmentAndMediaIdentity() throws {
        let html = "<html><body><p>Before</p><video id='clip' width='240' height='135'><source src='../media/movie.mp4' type='video/mp4'/>Fallback</video><p>After</p></body></html>"
        let result = try BrowserLayoutDocument(html: html, cssTexts: [], config: BrowserLayoutConfig())
            .makeLayout(containerSize: CGSize(width: 320, height: 640))
        let attachment = try #require(result.mediaAttachments.first)
        #expect(attachment.value.sourceHref == "../media/movie.mp4")
        #expect(attachment.value.mediaType == "video/mp4")
        #expect(!result.sourceText.contains("Fallback"))
        let pages = PageFragmentation.fragment(box: result.rootBox, pageSize: CGSize(width: 320, height: 640), contentInsets: .zero)
        var matched: [ImageFragment] = []
        func walk(_ fragments: [Fragment]) {
            for fragment in fragments {
                if case .image(let image) = fragment, image.nodeID == attachment.key { matched.append(image) }
                if case .group(let children) = fragment { walk(children) }
            }
        }
        for page in pages { walk(page.fragments) }
        #expect(matched.count == 1)
        #expect(matched.first?.rect.width ?? 0 > 0)
        #expect(!BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: []).unsupportedFeatures.contains(.scriptedInteractive))
    }

    @Test func inlineVideoAndVideoOnlyChapterProduceBrowserPages() async throws {
        for html in [
            "<body><video src='movie.mp4'></video></body>",
            "<body><p>Before <video style='display:inline' src='movie.mp4'></video> After</p></body>"
        ] {
            let session = BrowserLayoutSession(html: html, cssTexts: [], config: BrowserLayoutConfig(), imageLoader: { _ in nil }, generation: 1)
            let page = try await session.layoutNextPage()
            #expect(page != nil)
            #expect(session.pipelineMediaAttachments.count == 1)
        }
    }

    @Test func publicationMediaURLUsesChapterRelativeResourceIdentity() async throws {
        let url = try await EPUBTestFixtures.makeArchive(entries: EPUBTestFixtures.georgia().entries)
        let session = try await PublicationSession.open(sourceURL: url)
        let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
        let media = EPUBMediaAttachment(kind: .video, sourceHref: "../media/movie.mp4")
        let resolved = adapter.resolveMediaAttachment(forChapter: 0, media: media)
        let chapterHref = try #require(adapter.chapterSourceHref(at: 0))
        let href = EPUBStyleResolver.resolveImageHref(media.sourceHref, chapterHref: chapterHref)
        #expect(resolved.sourceHref == session.resourceURL(for: href).absoluteString)
        #expect(URL(string: resolved.sourceHref)?.scheme == "reader-book")
    }

    @Test func rubyAndIPAUseCollapsedChapterUTF16Ranges() throws {
        let html = "<html><body><p>😀  <ruby>漢字<rt>かんじ</rt></ruby> <span ssml:ph='tɛst'>test</span> 漢字</p></body></html>"
        let result = try BrowserLayoutDocument(html: html, cssTexts: [], config: BrowserLayoutConfig())
            .makeLayout(containerSize: CGSize(width: 320, height: 640))
        let source = result.sourceText as NSString
        #expect(result.pronunciationHints.contains(TTSPronunciationHint(range: source.range(of: "漢字"), reading: "かんじ")))
        #expect(result.pronunciationHints.contains(TTSPronunciationHint(range: source.range(of: "test"), ipa: "tɛst")))
        #expect(!result.sourceText.contains("かんじ"))
        let speech = TTSPronunciationSpeechText(text: result.sourceText, hints: result.pronunciationHints)
        #expect(speech.text.contains("かんじ test 漢字"))
        #expect(speech.sourceOffset(forSpeechOffset: (speech.text as NSString).range(of: "test").location) == source.range(of: "test").location)
    }

    @Test func orthographicSpeechRebasesIPAAndResumeOffsets() {
        let hints = [
            TTSPronunciationHint(range: NSRange(location: 2, length: 2), reading: "かんじ"),
            TTSPronunciationHint(range: NSRange(location: 5, length: 4), ipa: "tɛst")
        ]
        let speech = TTSPronunciationSpeechText(text: "😀漢字 test", hints: hints)
        #expect(speech.text == "😀かんじ test")
        #expect(speech.sourceOffset(forSpeechOffset: 3) == 2)
        #expect(speech.sourceOffset(forSpeechOffset: 6) == 5)
        #expect(speech.ipaHints.first?.range == NSRange(location: 6, length: 4))
        let utterance = SystemTTSEngine.makeUtterance(text: "😀漢字 test", rate: 0.5, pronunciationHints: hints)
        #expect(utterance.speechString == "😀かんじ test")
    }

    @Test func browserEnginePublishesRubyHintsAndVideoPlayAction() async throws {
        let resource = MockBrowserLayoutResource(chapters: [
            .init(title: "Media", href: "chapter.xhtml", html: "<body><p>😀<ruby>漢字<rt>かんじ</rt></ruby></p><video src='movie.mp4'></video></body>", css: [])
        ])
        let settings = EPUBTestFixtures.renderSettings()
        let store = CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let delegate = CoreTextPageEngine(attributedBuilder: MockAttributedStringBuilder(texts: ["legacy"]), renderSettings: settings, offsetStore: store)
        let engine = BrowserLayoutPageEngine(resource: resource, delegate: delegate, settings: settings, mode: .browserAuto, showDebugOverlay: false)
        await engine.start(renderSize: CGSize(width: 320, height: 640), bookId: "media-parity")
        #expect(engine.choice(for: 0)?.isBrowser == true)
        // The delegate retains startup chapter zero; browser metadata must
        // remain the narration owner even while this legacy entry exists.
        #expect(engine.layouts[0] != nil)
        let provider: any PageRenderingProvider = engine
        let text = try #require(provider.chapterText(forSpine: 0))
        #expect(provider.chapterPronunciationHints(forSpine: 0) == [
            TTSPronunciationHint(range: (text as NSString).range(of: "漢字"), reading: "かんじ")
        ])
        let controller = try #require(engine.pageViewController(at: 0) as? BrowserLayoutPageViewController)
        controller.loadViewIfNeeded()
        #expect(controller.pageView.accessibilityCustomActions?.contains { $0.name == localized("播放") } == true)
        controller.viewDidLayoutSubviews()
        #expect(controller.pageView.accessibilityCustomActions?.filter { $0.name == localized("播放") }.count == 1)
    }

    @Test func authoredRubyReadingWinsOverLexicon() {
        let authored = TTSPronunciationHint(range: NSRange(location: 0, length: 2), reading: "かんじ")
        let lexicon = PLSLexicon(href: "test.pls", language: nil, alphabet: "ipa", lexemes: [
            PLSLexicon.Lexeme(grapheme: "漢字", phoneme: "lexicon")
        ])
        let hints = TTSPronunciationAnnotator.hints(in: "漢字 漢字", authoredHints: [authored], lexicons: [lexicon], bookLanguage: nil)
        #expect(hints == [authored, TTSPronunciationHint(range: NSRange(location: 3, length: 2), ipa: "lexicon")])
    }

    @Test func httpSpeechUsesRubyReadingWhilePublishingOriginalText() async {
        let oldTemplate = GlobalSettings.shared.httpTtsUrlTemplate
        GlobalSettings.shared.httpTtsUrlTemplate = "https://unused.invalid/{{text}}"
        defer { GlobalSettings.shared.httpTtsUrlTemplate = oldTemplate }
        let (requests, continuation) = AsyncStream<String>.makeStream()
        var iterator = requests.makeAsyncIterator()
        let provider = CapturingRubySpeechProvider { continuation.yield($0) }
        let engine = HTTPTTSEngine(audioProvider: provider)
        defer { engine.stop() }
        var publishedText: String?
        engine.onSegmentChanged = { _, _, text in publishedText = text }
        engine.speak(text: "漢字 test", title: "", rate: 0.5, pronunciationHints: [
            TTSPronunciationHint(range: NSRange(location: 0, length: 2), reading: "かんじ")
        ])
        let requested = await iterator.next()
        #expect(requested == "かんじ test")
        #expect(publishedText == "漢字 test")
    }

    @Test func rubyBaseStaysAtomicAcrossSpeechChunkBoundary() {
        let text = "a漢字語b"
        let hint = TTSPronunciationHint(range: NSRange(location: 1, length: 3), reading: "かんじご")
        let chunks = TTSPronunciationProjector.chunks(text, targetLength: 2, hints: [hint])
        let projected = chunks.flatMap { TTSPronunciationProjector.project([hint], into: $0.sourceRange) }
        #expect(projected.count == 1)
        #expect(projected.first?.reading == "かんじご")
    }

    @Test func rubyWhitespaceTrimKeepsTheCompleteAuthoredBaseRange() {
        let hint = TTSPronunciationHint(range: NSRange(location: 0, length: 4), reading: "かんじ")
        let chunks = TTSPronunciationProjector.chunks(" 漢字 ", targetLength: 2, hints: [hint])
        #expect(chunks.count == 1)
        #expect(chunks.first?.sourceRange == hint.range)
        #expect(TTSPronunciationSpeechText(text: chunks[0].text, hints: [hint]).text == "かんじ")
    }

    @Test func videoOnlyPageHasAnAccessiblePlaybackLabel() {
        let image = DisplayImageItem(source: "placeholder", image: nil, sourceRange: NSRange(location: 0, length: 0), nodeID: 1, linkTarget: nil, writingMode: .horizontal, rect: PageLocalRect(rawValue: CGRect(x: 0, y: 0, width: 200, height: 120)), alt: nil)
        let controller = BrowserLayoutPageViewController(globalPageIndex: 0, readingPosition: nil, displayList: DisplayList(items: [.image(image)]), mediaAttachments: [1: EPUBMediaAttachment(kind: .video, sourceHref: "movie.mp4")], backgroundColor: .white, onLinkActivate: nil)
        controller.loadViewIfNeeded()
        #expect(controller.pageView.accessibilityLabel == localized("播放"))
        #expect(controller.pageView.accessibilityCustomActions?.contains { $0.name == localized("播放") } == true)
    }

    @Test func pendingVideoProviderDoesNotRetainThePageCoordinator() async {
        let owner = UIViewController()
        owner.loadViewIfNeeded()
        let (started, startContinuation) = AsyncStream<Void>.makeStream()
        var startIterator = started.makeAsyncIterator()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        var coordinator: BrowserInlineVideoCoordinator? = BrowserInlineVideoCoordinator(owner: owner, playerProvider: { _ in
            startContinuation.yield(())
            var releaseIterator = release.makeAsyncIterator()
            _ = await releaseIterator.next()
            return AVPlayer()
        }, isActive: { _ in false })
        weak var releasedCoordinator = coordinator
        coordinator?.sync([BrowserInlineVideoPlacement(nodeID: 1, media: EPUBMediaAttachment(kind: .video, sourceHref: "pending.mp4"), rect: CGRect(x: 0, y: 0, width: 200, height: 120))])
        #expect(coordinator?.start(nodeID: 1) == true)
        _ = await startIterator.next()
        coordinator = nil
        #expect(releasedCoordinator == nil)
        releaseContinuation.yield(())
        releaseContinuation.finish()
    }

    @Test func inlineVideoDetachesViewAndReusesPlayerOnReturn() async {
        let owner = UIViewController()
        owner.loadViewIfNeeded()
        let player = AVPlayer()
        var active = false
        let (bindings, bindingContinuation) = AsyncStream<Void>.makeStream()
        var bindingIterator = bindings.makeAsyncIterator()
        let coordinator = BrowserInlineVideoCoordinator(owner: owner, playerProvider: { _ in
            active = true
            bindingContinuation.yield(())
            return player
        }, isActive: { _ in active })
        let media = EPUBMediaAttachment(kind: .video, sourceHref: "file:///unused.mp4")
        let placement = BrowserInlineVideoPlacement(nodeID: 4, media: media, rect: CGRect(x: 10, y: 20, width: 200, height: 120))
        coordinator.sync([placement])
        #expect(owner.children.isEmpty)
        #expect(coordinator.start(nodeID: 4))
        _ = await bindingIterator.next()
        #expect(coordinator.embeddedNodeIDs == [4])
        #expect((owner.children.first as? AVPlayerViewController)?.player === player)
        coordinator.sync([])
        #expect(owner.children.isEmpty)
        #expect(active)
        coordinator.sync([placement])
        #expect(coordinator.embeddedNodeIDs == [4])
        coordinator.detachAll()
        #expect(owner.children.isEmpty)
    }
}

private final class CapturingRubySpeechProvider: TTSAudioProvider {
    let displayName = "Ruby test"
    private let record: (String) -> Void
    init(record: @escaping (String) -> Void) { self.record = record }
    func audioData(for text: String, title: String, rate: Float) async throws -> Data {
        record(text)
        throw CancellationError()
    }
}
