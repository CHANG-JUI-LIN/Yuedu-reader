import CryptoKit
import Foundation
import Testing
import UIKit
import WebKit
@testable import yuedu_app

enum IDPFEPUB3Corpus {
    struct Manifest: Decodable, Sendable {
        let schemaVersion: Int
        let samples: [Sample]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case samples
        }
    }

    struct Sample: Decodable, Sendable, CustomTestStringConvertible {
        let id: String
        let title: String
        let sourceURL: URL
        let catalogURL: URL
        let filename: String
        let sha256: String
        let license: String
        let features: [String]
        let smokeTargets: [SmokeTarget]
        let manual: Bool
        let manualCheckpoints: [String]

        var testDescription: String { id }

        enum CodingKeys: String, CodingKey {
            case id, title, filename, sha256, license, features, manual
            case sourceURL = "source_url"
            case catalogURL = "catalog_url"
            case smokeTargets = "smoke_targets"
            case manualCheckpoints = "manual_checkpoints"
        }
    }

    struct SmokeTarget: Decodable, Sendable {
        let spineHref: String?
        let chapterIndex: Int?
        let textProbes: [String]
        let expectsImagePage: Bool
        let expectsFallback: Bool

        enum CodingKeys: String, CodingKey {
            case spineHref = "spine_href"
            case chapterIndex = "chapter_index"
            case textProbes = "text_probes"
            case expectsImagePage = "expects_image_page"
            case expectsFallback = "expects_fallback"
        }
    }

    struct Configuration: Sendable {
        let rootURL: URL
        let samples: [Sample]
    }

    struct LoadState: Sendable {
        let configuration: Configuration?
        let errorDescription: String?
    }

    enum CorpusError: LocalizedError {
        case invalidConfiguration(String)
        case unresolvedTarget(sampleID: String, target: String)
        case invalidResource(sampleID: String, href: String)
        case fixedLayoutRenderFailed(sampleID: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration(let message):
                return message
            case .unresolvedTarget(let sampleID, let target):
                return "\(sampleID): cannot resolve smoke target \(target)"
            case .invalidResource(let sampleID, let href):
                return "\(sampleID): production resource is empty for \(href)"
            case .fixedLayoutRenderFailed(let sampleID, let reason):
                return "\(sampleID): fixed-layout production render failed: \(reason)"
            }
        }
    }

    static let isEnabled = ProcessInfo.processInfo.environment["YUEDU_RUN_EPUB3_CORPUS"] == "1"

    private static let loadState: LoadState = {
        guard isEnabled else { return LoadState(configuration: nil, errorDescription: nil) }
        do {
            return LoadState(configuration: try loadVerifiedConfiguration(), errorDescription: nil)
        } catch {
            return LoadState(configuration: nil, errorDescription: error.localizedDescription)
        }
    }()

    static func loadCasesFromEnvironment() -> [Sample] {
        guard isEnabled else { return [] }
        if let configuration = loadState.configuration {
            return configuration.samples
        }
        Issue.record("Invalid IDPF EPUB 3 corpus configuration: \(loadState.errorDescription ?? "unknown error")")
        return []
    }

    static func requireConfiguration() throws -> Configuration {
        guard isEnabled else {
            throw CorpusError.invalidConfiguration("Set YUEDU_RUN_EPUB3_CORPUS=1 to run the official corpus suite")
        }
        guard let configuration = loadState.configuration else {
            throw CorpusError.invalidConfiguration(
                "Invalid IDPF EPUB 3 corpus configuration: \(loadState.errorDescription ?? "unknown error")"
            )
        }
        return configuration
    }

    static func verifiedBookURL(for sample: Sample) throws -> URL {
        let configuration = try requireConfiguration()
        guard configuration.samples.contains(where: { $0.id == sample.id }) else {
            throw CorpusError.invalidConfiguration("\(sample.id): sample is not part of the verified manifest")
        }
        return configuration.rootURL.appendingPathComponent(sample.filename, isDirectory: false)
    }

    private static func loadVerifiedConfiguration() throws -> Configuration {
        guard let rootPath = ProcessInfo.processInfo.environment["YUEDU_EPUB3_CORPUS_DIR"],
              !rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CorpusError.invalidConfiguration(
                "YUEDU_EPUB3_CORPUS_DIR is required when YUEDU_RUN_EPUB3_CORPUS=1"
            )
        }

        let manifestURL = repositoryRoot
            .appendingPathComponent("docs/build-week/epub3/sample-manifest.json", isDirectory: false)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion == 1 else {
            throw CorpusError.invalidConfiguration("Expected manifest schema_version 1, got \(manifest.schemaVersion)")
        }
        guard manifest.samples.count == 42 else {
            throw CorpusError.invalidConfiguration("Expected 42 official samples, got \(manifest.samples.count)")
        }
        guard Set(manifest.samples.map(\.id)).count == manifest.samples.count,
              Set(manifest.samples.map(\.filename)).count == manifest.samples.count,
              manifest.samples.allSatisfy({ !$0.smokeTargets.isEmpty })
        else {
            throw CorpusError.invalidConfiguration(
                "Manifest coverage requires unique IDs, unique filenames, and at least one smoke target per sample"
            )
        }

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        for sample in manifest.samples {
            let bookURL = rootURL.appendingPathComponent(sample.filename, isDirectory: false)
            guard FileManager.default.fileExists(atPath: bookURL.path) else {
                throw CorpusError.invalidConfiguration("\(sample.id): missing \(bookURL.path)")
            }
            let actualHash = try sha256(of: bookURL)
            guard actualHash == sample.sha256.lowercased() else {
                throw CorpusError.invalidConfiguration(
                    "\(sample.id): SHA256 mismatch; expected \(sample.sha256), got \(actualHash)"
                )
            }
        }
        return Configuration(rootURL: rootURL, samples: manifest.samples)
    }

    private static var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath, isDirectory: false)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@Suite(
    "Official IDPF EPUB 3 corpus",
    .serialized,
    .enabled(
        if: IDPFEPUB3Corpus.isEnabled,
        "Set YUEDU_RUN_EPUB3_CORPUS=1 and YUEDU_EPUB3_CORPUS_DIR to run the external corpus"
    )
)
struct IDPFEPUB3SampleSmokeTests {
    typealias Corpus = IDPFEPUB3Corpus

    private let renderSize = CGSize(width: 390, height: 844)
    private let contentInsets = UIEdgeInsets(top: 40, left: 20, bottom: 40, right: 20)

    @Test("corpus configuration")
    func corpusConfiguration() throws {
        let configuration = try Corpus.requireConfiguration()
        #expect(configuration.samples.count == 42)
        #expect(configuration.samples.reduce(0) { $0 + $1.smokeTargets.count } == 43)
    }

    @Test(
        "sample opens, renders, paginates, and slices",
        arguments: Corpus.loadCasesFromEnvironment()
    )
    @MainActor
    func smoke(sample: Corpus.Sample) async throws {
        let bookURL = try Corpus.verifiedBookURL(for: sample)
        let session = try await PublicationSession.open(sourceURL: bookURL)
        #expect(!session.chapters.isEmpty, "\(sample.id): publication has no reading order")

        for target in sample.smokeTargets {
            let chapterIndex = try resolve(target: target, sample: sample, session: session)
            let chapter = session.chapters[chapterIndex]
            // Per-spine rendition metadata wins over the package default in mixed-layout books.
            let targetLayoutMode = chapter.layoutModeOverride ?? session.layoutMode
            let fixedCapability = targetLayoutMode == .prePaginated
            let writingMode: ReaderWritingMode = session.epubWritingMode == .verticalRL
                ? .verticalRTL
                : .horizontal
            let settings = makeRenderSettings(writingMode: writingMode)

            if target.expectsImagePage {
                #expect(fixedCapability, "\(sample.id): expected fixed-layout capability for \(chapter.href)")
            }

            if fixedCapability {
                let renderer = EPUBPageRenderer()
                renderer.load(
                    publicationSession: session,
                    bookIdentifier: "idpf-corpus-\(sample.id)-\(chapterIndex)",
                    renderSize: renderSize,
                    settings: settings
                )
                guard let engine = renderer.engine else {
                    Issue.record(
                        "\(sample.id): production EPUBPageRenderer created no engine for fixed target \(chapter.href)"
                    )
                    continue
                }
                for _ in 0..<400 {
                    if renderer.isCoreTextReady { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(
                    renderer.isCoreTextReady,
                    "\(sample.id): production EPUBPageRenderer did not finish mixed-layout startup"
                )
                try await assertFixedLayoutSmoke(
                    target: target,
                    sample: sample,
                    chapterIndex: chapterIndex,
                    chapter: chapter,
                    session: session,
                    engine: engine
                )
                continue
            }

            if session.layoutMode == .prePaginated {
                Issue.record(
                    "\(sample.id): production EPUBPageRenderer cannot route reflowable item override \(chapter.href) inside a pre-paginated package"
                )
                continue
            }

            let result = try await EPUBAttributedStringBuilder(
                session: session,
                renderSize: renderSize
            ).buildChapter(
                at: chapterIndex,
                settings: settings,
                themeTextColor: .black,
                themeBackgroundColor: .white
            )

            assertVisibleOutput(result, target: target, sample: sample)
            await assertPagedAndScrollSmoke(
                result,
                chapterIndex: chapterIndex,
                writingMode: writingMode,
                sample: sample
            )
        }
    }
}

private extension IDPFEPUB3SampleSmokeTests {
    func makeRenderSettings(writingMode: ReaderWritingMode) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "test",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 17,
            lineHeightMultiple: 1.5,
            lineSpacing: 0,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 0,
            marginV: 0,
            footerHeight: 0,
            contentInsets: .zero,
            writingMode: writingMode
        )
    }

    func resolve(
        target: Corpus.SmokeTarget,
        sample: Corpus.Sample,
        session: PublicationSession
    ) throws -> Int {
        if let rawHref = target.spineHref,
           let index = resolveSpineHref(rawHref, in: session)
        {
            return index
        }
        if let index = target.chapterIndex, session.chapters.indices.contains(index) {
            return index
        }
        let description = target.spineHref ?? target.chapterIndex.map { String($0) } ?? "<missing>"
        throw Corpus.CorpusError.unresolvedTarget(sampleID: sample.id, target: description)
    }

    func resolveSpineHref(_ rawHref: String, in session: PublicationSession) -> Int? {
        let withoutFragment = rawHref.split(separator: "#", maxSplits: 1).first.map(String.init) ?? rawHref
        let normalized = withoutFragment
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let decoded = normalized.removingPercentEncoding ?? normalized
        let candidates = [rawHref, withoutFragment, normalized, decoded]
        for candidate in candidates where !candidate.isEmpty {
            if let index = session.chapterIndex(for: candidate) { return index }
        }
        return session.chapters.firstIndex { chapter in
            let chapterHref = chapter.href.removingPercentEncoding ?? chapter.href
            return chapterHref == decoded
                || chapterHref.hasSuffix("/\(decoded)")
                || decoded.hasSuffix("/\(chapterHref)")
        }
    }

    @MainActor
    func assertFixedLayoutSmoke(
        target: Corpus.SmokeTarget,
        sample: Corpus.Sample,
        chapterIndex: Int,
        chapter: PublicationChapterDescriptor,
        session: PublicationSession,
        engine: any PageRenderingProvider
    ) async throws {
        #expect(engine.totalPages >= session.chapters.count, "\(sample.id): engine lost spine pages")
        let globalPage = try #require(
            engine.pageIndex(for: .chapterStart(chapterIndex))
                ?? engine.estimatedGlobalPage(for: .chapterStart(chapterIndex)),
            "\(sample.id): engine cannot map fixed spine to a global page"
        )
        #expect(
            engine.readingPosition(forPage: globalPage)?.spineIndex == chapterIndex,
            "\(sample.id): fixed engine cannot address target page"
        )
        await engine.preloadChapter(at: chapterIndex)

        let pageViewController = engine.pageViewController(at: globalPage)
        #expect(
            pageViewController is FixedLayoutPageViewController,
            "\(sample.id): fixed target was not vended by FixedLayoutPageViewController"
        )
        pageViewController.loadViewIfNeeded()
        pageViewController.view.frame = CGRect(origin: .zero, size: renderSize)
        pageViewController.view.layoutIfNeeded()
        guard let webView = findWebView(in: pageViewController.view) else {
            throw Corpus.CorpusError.fixedLayoutRenderFailed(
                sampleID: sample.id,
                reason: "FixedLayoutPageViewController contains no WKWebView"
            )
        }
        try await waitForFixedLayoutVisualEvidence(
            webView: webView,
            target: target,
            sample: sample
        )

        let response = try await session.response(for: session.resourceURL(for: chapter.href))
        guard !response.data.isEmpty else {
            throw Corpus.CorpusError.invalidResource(sampleID: sample.id, href: chapter.href)
        }
        #expect(!response.mimeType.isEmpty, "\(sample.id): fixed spine resource has no MIME type")

        let mediaType = response.mimeType.lowercased()
        if mediaType.hasPrefix("image/") && mediaType != "image/svg+xml" {
            #expect(
                UIImage(data: response.data) != nil,
                "\(sample.id): fixed spine image cannot be decoded by the production image stack"
            )
        } else {
            if mediaType.contains("xml") || mediaType.contains("svg") {
                #expect(XMLParser(data: response.data).parse(), "\(sample.id): authored fixed XML is malformed")
            }
            let authoredSource: String
            if mediaType.contains("html") || mediaType.contains("xml") || mediaType.contains("svg") {
                authoredSource = try await session.chapterHTML(at: chapterIndex)
                #expect(!authoredSource.isEmpty, "\(sample.id): fixed engine resource path returned empty authored content")
            } else {
                authoredSource = String(decoding: response.data, as: UTF8.self)
            }
            for probe in target.textProbes {
                #expect(authoredSource.contains(probe), "\(sample.id): authored fixed source lost probe '\(probe)'")
            }
        }
    }

    @MainActor
    func findWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let webView = findWebView(in: subview) { return webView }
        }
        return nil
    }

    @MainActor
    func waitForFixedLayoutVisualEvidence(
        webView: WKWebView,
        target: Corpus.SmokeTarget,
        sample: Corpus.Sample
    ) async throws {
        let script = #"""
        (() => {
          const body = document.body;
          const visible = element => {
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';
          };
          const images = Array.from(document.images).filter(image =>
            visible(image) && image.complete && image.naturalWidth > 0 && image.naturalHeight > 0
          ).length;
          const svgs = Array.from(document.querySelectorAll('svg')).filter(visible).length;
          const canvases = Array.from(document.querySelectorAll('canvas')).filter(canvas =>
            visible(canvas) && canvas.width > 0 && canvas.height > 0
          ).length;
          const backgrounds = Array.from(document.querySelectorAll('body *')).filter(element =>
            visible(element) && getComputedStyle(element).backgroundImage !== 'none'
          ).length;
          const visibleElements = body
            ? Array.from(body.children).filter(visible).length
            : 0;
          return {
            ready: document.readyState,
            images: images,
            svgs: svgs,
            canvases: canvases,
            backgrounds: backgrounds,
            visibleElements: visibleElements,
            textLength: body ? body.innerText.trim().length : 0,
            layoutWidth: Math.max(document.documentElement?.scrollWidth || 0, body?.scrollWidth || 0),
            layoutHeight: Math.max(document.documentElement?.scrollHeight || 0, body?.scrollHeight || 0)
          };
        })()
        """#
        let deadline = ContinuousClock.now + .seconds(3)
        var lastObservation = "no JavaScript result"

        while ContinuousClock.now < deadline {
            do {
                let value = try await webView.evaluateJavaScript(script)
                if let result = value as? [String: Any] {
                    let ready = result["ready"] as? String ?? "unknown"
                    let images = integerValue(result["images"])
                    let svgs = integerValue(result["svgs"])
                    let canvases = integerValue(result["canvases"])
                    let backgrounds = integerValue(result["backgrounds"])
                    let visibleElements = integerValue(result["visibleElements"])
                    let textLength = integerValue(result["textLength"])
                    let layoutWidth = integerValue(result["layoutWidth"])
                    let layoutHeight = integerValue(result["layoutHeight"])
                    let mediaCount = images + svgs + canvases + backgrounds
                    let requiresMedia = target.expectsImagePage
                    let hasContentEvidence = requiresMedia
                        ? mediaCount > 0
                        : mediaCount > 0 || visibleElements > 0 || textLength > 0
                    let hasLayout = layoutWidth > 0 && layoutHeight > 0
                    lastObservation = "ready=\(ready) layout=\(layoutWidth)x\(layoutHeight) media=\(mediaCount) elements=\(visibleElements) text=\(textLength)"
                    if ready == "complete", hasLayout, hasContentEvidence { return }
                }
            } catch {
                lastObservation = error.localizedDescription
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw Corpus.CorpusError.fixedLayoutRenderFailed(
            sampleID: sample.id,
            reason: "no observable WebKit visual evidence within 3 seconds (\(lastObservation))"
        )
    }

    func integerValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let integer = value as? Int { return integer }
        return 0
    }

    func assertVisibleOutput(
        _ result: AttributedChapterBuildResult,
        target: Corpus.SmokeTarget,
        sample: Corpus.Sample
    ) {
        let visibleText = result.attributedString.string
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            !visibleText.isEmpty || result.imagePage?.image != nil,
            "\(sample.id): rendered output contains no visible text or image page"
        )
        for probe in target.textProbes {
            #expect(
                result.attributedString.string.contains(probe),
                "\(sample.id): rendered output lost probe '\(probe)'"
            )
        }
        if target.expectsFallback {
            #expect(
                !target.textProbes.isEmpty,
                "\(sample.id): reflow fallback target requires an observable rendered text probe"
            )
        }
    }

    func assertPagedAndScrollSmoke(
        _ result: AttributedChapterBuildResult,
        chapterIndex: Int,
        writingMode: ReaderWritingMode,
        sample: Corpus.Sample
    ) async {
        let length = result.attributedString.length
        let layout = await CoreTextPaginator().paginate(
            spineIndex: chapterIndex,
            attrStr: result.attributedString,
            imagePage: result.imagePage,
            pageBackgroundImage: result.pageBackgroundImage,
            pageBackgroundColor: result.pageBackgroundColor,
            anchorOffsets: result.anchorOffsets,
            renderSize: renderSize,
            fontSize: 17,
            contentInsets: contentInsets,
            writingMode: writingMode
        )
        #expect(!layout.pageRanges.isEmpty, "\(sample.id): pagination produced no pages")
        for range in layout.pageRanges {
            #expect(range.location >= 0, "\(sample.id): page range starts below zero")
            #expect(range.length > 0, "\(sample.id): page range must consume attributed content")
            #expect(
                range.location + range.length <= length,
                "\(sample.id): page range exceeds attributed-string bounds"
            )
        }
        assertPaginationCoverage(
            layout.pageRanges,
            attributedString: result.attributedString,
            sample: sample
        )

        let output = CoreTextChunkSlicer.slice(
            attributedString: result.attributedString,
            chapterIndex: chapterIndex,
            contentWidth: renderSize.width - contentInsets.left - contentInsets.right,
            heightCap: renderSize.height,
            writingMode: writingMode,
            pageBackgroundColor: result.pageBackgroundColor,
            pageBackgroundImage: result.pageBackgroundImage
        )
        #expect(!output.chunks.isEmpty, "\(sample.id): scroll slicing produced no chunks")
        #expect(output.chunks.first?.charRange.location == 0, "\(sample.id): first chunk does not start at zero")
        for pair in zip(output.chunks, output.chunks.dropFirst()) {
            #expect(
                pair.0.charRange.location + pair.0.charRange.length == pair.1.charRange.location,
                "\(sample.id): scroll chunk ranges are not continuous"
            )
        }
        if let last = output.chunks.last {
            #expect(
                last.charRange.location + last.charRange.length == length,
                "\(sample.id): scroll chunks do not cover the attributed string"
            )
        }
    }

    func assertPaginationCoverage(
        _ ranges: [CFRange],
        attributedString: NSAttributedString,
        sample: Corpus.Sample
    ) {
        let length = attributedString.length
        guard !ranges.isEmpty,
              ranges.allSatisfy({
                  $0.location >= 0
                      && $0.length > 0
                      && $0.location + $0.length <= length
              })
        else { return }

        var coveredEnd = 0
        for range in ranges {
            if range.location < coveredEnd {
                Issue.record(
                    "\(sample.id): page ranges overlap at UTF-16 offset \(range.location)"
                )
                coveredEnd = max(coveredEnd, range.location + range.length)
                continue
            }

            if range.location > coveredEnd {
                assertForcedPageBreakGap(
                    NSRange(location: coveredEnd, length: range.location - coveredEnd),
                    attributedString: attributedString,
                    sample: sample
                )
            }
            coveredEnd = range.location + range.length
        }

        if coveredEnd < length {
            assertForcedPageBreakGap(
                NSRange(location: coveredEnd, length: length - coveredEnd),
                attributedString: attributedString,
                sample: sample
            )
        }
    }

    func assertForcedPageBreakGap(
        _ gap: NSRange,
        attributedString: NSAttributedString,
        sample: Corpus.Sample
    ) {
        let gapEnd = gap.location + gap.length
        let isEntirelyForcedPageBreak = gap.length > 0
            && gap.location >= 0
            && gapEnd <= attributedString.length
            && (gap.location..<gapEnd).allSatisfy { location in
                attributedString.attribute(
                    HTMLAttributedStringBuilder.pageBreakAttribute,
                    at: location,
                    effectiveRange: nil
                ) as? Bool == true
            }

        #expect(
            isEntirelyForcedPageBreak,
            "\(sample.id): pagination gap \(gap.location)..<\(gapEnd) is not fully marked by ReaderForcedPageBreak"
        )
    }
}
