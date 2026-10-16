#if DEBUG
import SwiftUI
import UIKit
import YueduCoreText

/// Opt-in UI regression fixture. Uses the production viewport engine/controller;
/// XCTest supplies the touch events. Never selected in a normal launch.
struct ContinuousScrollGestureFixture: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> FixtureController { FixtureController() }
    func updateUIViewController(_ controller: FixtureController, context: Context) {}

    final class FixtureController: UIViewController {
        private let status = UILabel()
        private let resource = Resource()
        private let usesTXT = ProcessInfo.processInfo.arguments.contains("-continuous-scroll-txt-test")
        private var reader: CoreTextCollectionScrollViewController?
        private var started = false

        override func viewDidLoad() {
            super.viewDidLoad()
            status.accessibilityIdentifier = "viewport_gesture_status"
            status.text = "loading"
            status.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            status.numberOfLines = 0
            view.addSubview(status)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            status.frame = CGRect(x: 4, y: view.safeAreaInsets.top, width: view.bounds.width - 8, height: 60)
            guard !started, view.bounds.height > 0 else { return }
            started = true
            Task { await startReader() }
        }

        private func startReader() async {
            let settings = ReaderRenderSettings(theme: "paper", textColor: .black, backgroundColor: .white,
                fontSize: 20, lineHeightMultiple: 1.4, lineSpacing: 0, paragraphSpacing: 6,
                letterSpacing: 0, marginH: 12, marginV: 12, footerHeight: 0,
                contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
            let size = view.bounds.size
            let engine = CoreTextScrollEngine(builder: resource, renderSettings: settings)
            if !usesTXT {
                let delegate = CoreTextPageEngine(attributedBuilder: resource, renderSettings: settings,
                    offsetStore: CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("viewport-gesture-offsets")))
                let browser = BrowserLayoutPageEngine(resource: resource, delegate: delegate,
                                                      settings: settings, mode: .browserAuto)
                browser.usesViewportScrolling = true
                await browser.start(renderSize: size, bookId: "viewport-gesture-fixture")
                engine.browserAutoEngine = browser
            }
            await engine.start(initialChapter: 1, contentWidth: size.width - 24,
                               viewportExtent: size.height, loadAdjacentChapters: false)
            guard let offset = usesTXT ? 500 : engine.browserChapter(at: 1)?.facts?.anchorOffsets["p30"] else {
                status.text = "fixture failed"; return
            }
            let controller = CoreTextCollectionScrollViewController(engine: engine, axis: .vertical,
                horizontalInset: 12, verticalInset: 12, backgroundColor: .white)
            controller.setInitialPosition(chapter: 1, charOffset: offset)
            if usesTXT {
                controller.onDeceleratingScroll = { [weak self] in self?.resource.releasePreviousChapter() }
            }
            controller.onViewportDiagnostics = { [weak self] diagnostics in
                guard let self else { return }
                // Release the held chapter only after real momentum has crossed
                // a measured-height boundary. No timer and no injected offset.
                if diagnostics.decelerationCorrections > 0 { self.resource.releasePreviousChapter() }
                self.status.text = "ready corrections=\(diagnostics.decelerationCorrections) interrupted=\(diagnostics.interruptedDecelerations) continued=\(diagnostics.continuedDecelerations) counts=\(diagnostics.countChanges) insertions=\(diagnostics.insertions) decelInsertions=\(diagnostics.decelerationInsertions) progressInside=\(diagnostics.progressDuringGeometry) error=\(diagnostics.maximumScreenError) scale=\(self.traitCollection.displayScale) surfaces=\(self.reader?.fragmentHost.visibleSurfaces.count ?? 0) paints=\(self.reader?.fragmentHost.redrawCount ?? 0)"
            }
            reader = controller
            addChild(controller)
            controller.view.frame = view.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(controller.view, belowSubview: status)
            controller.didMove(toParent: self)
            controller.view.layoutIfNeeded()
            if status.text == "loading" { status.text = "ready" }
        }
    }

    @MainActor
    final class Resource: BrowserLayoutResourceProviding, AttributedStringBuilding {
        nonisolated let chapterCount = 2
        private var previousReleased = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private lazy var txtBuilder: TXTLazyAttributedStringBuilder = {
            let body = String(repeating: "這是連續捲動的真實手勢測試，前章完成時不能中斷減速或改變正在看的位置。\n", count: 200)
            let file = TXTMappedTextFile(data: Data(("第1章 前章\n" + body + "\n第2章 當前章\n" + body).utf8), encoding: .utf8)
            return TXTLazyAttributedStringBuilder(mappedTextFile: file,
                chapterIndexes: TXTChapterParser.parseMappedChapterIndexes(file, bookTitle: "Scroll gesture"))
        }()
        let html = "<body>" + (0..<90).map { index in
            "<p id='p\(index)' style='margin:24px 0'>Paragraph \(index) "
                + String(repeating: "中文 continuous geometry sample ", count: 3 + index % 9) + "</p>"
        }.joined() + "</body>"
        func releasePreviousChapter() {
            previousReleased = true
            let completions = waiting
            waiting.removeAll()
            completions.forEach { $0.resume() }
        }
        nonisolated func chapterTitle(at index: Int) -> String { "Chapter \(index)" }
        nonisolated func chapterSourceHref(at index: Int) -> String? { "\(index).xhtml" }
        func chapterHTML(at index: Int) async throws -> String {
            if index == 0 && !previousReleased {
                await withCheckedContinuation { waiting.append($0) }
            }
            return html
        }
        func chapterDataSize(at index: Int) async -> Int { html.utf8.count }
        func cssFrontendInput(forChapter index: Int, html: String) async -> CSSFrontendInput {
            .currentCompatibility(html: html, cssTexts: [])
        }
        func prefetchImages(forChapter index: Int, html: String, renderWidth: CGFloat) async -> [String: UIImage] { [:] }
        func loadImage(forChapter index: Int, source: String, renderWidth: CGFloat) async -> UIImage? { nil }
        func fontResolver() -> BrowserFontResolver? { nil }
        func buildChapter(at index: Int, settings: ReaderRenderSettings, themeTextColor: UIColor,
                          themeBackgroundColor: UIColor) async throws -> AttributedChapterBuildResult {
            if index == 0 && !previousReleased {
                await withCheckedContinuation { waiting.append($0) }
            }
            return try await txtBuilder.buildChapter(at: index, settings: settings,
                themeTextColor: themeTextColor, themeBackgroundColor: themeBackgroundColor)
        }
    }
}
#endif
