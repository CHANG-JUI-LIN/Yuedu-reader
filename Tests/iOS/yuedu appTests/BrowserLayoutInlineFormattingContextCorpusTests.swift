import CryptoKit
import Foundation
import ReadiumZIPFoundation
import SwiftSoup
import Testing
import UIKit
@testable import yuedu_app

@MainActor
struct BrowserLayoutInlineFormattingContextCorpusTests {
    private struct CorpusRow: Codable, Equatable {
        let bookID: String
        let spineIndex: Int
        let sourceLength: Int
        let scannerReasons: [String]
        let boxLineDigest: String?
        let fragmentDigest: String?
        let pageRangeDigest: String?
        let pageCount: Int?
    }

    private struct CorpusArtifact: Codable, Equatable {
        let schemaVersion: Int
        let bookCount: Int
        let chapterCount: Int
        let browserSupportedChapterCount: Int
        let fallbackChapterCount: Int
        let rows: [CorpusRow]
    }

    private struct BookInput {
        let stableKey: String
        let url: URL
    }

    private struct GeometryBuild {
        let rootBox: BlockBox
        let sourceText: String
        let pages: [PageFragments]
        let boxSnapshot: BrowserLayoutGeometryFingerprint.Snapshot
        let fragmentSnapshot: BrowserLayoutGeometryFingerprint.Snapshot
        let pageRangeSnapshot: BrowserLayoutGeometryFingerprint.Snapshot
    }

    /// Compact per-pass evidence for affected chapters. Returning only digests,
    /// source identity and classification flags lets the current tree deallocate
    /// before the forced-zero tree is built — essential for very large EPUB
    /// chapters in the real corpus.
    private struct GeometryEvidence {
        let sourceText: String
        let visibleTextDigest: String
        let rangesAreOrdered: Bool
        let containsGeneratedFont: Bool
        let containsFloat: Bool
        let boxDigest: String
        let fragmentDigest: String
        let pageRangeDigest: String
        let pageCount: Int
    }

    private struct RowKey: Hashable {
        let bookID: String
        let spineIndex: Int
    }

    private enum TextIndentCorpusClass: Equatable {
        case unaffected
        case supportedNonZero
        case unsupported
    }

    private struct CorpusBuildResult {
        let artifact: CorpusArtifact
        let legacyOracleVerifiedRows: Set<RowKey>
        let legacyOracleFailures: [String]
        let acceptedTextIndentRows: Set<RowKey>
        let textIndentFailures: [String]
        let affectedRows: Set<RowKey>
        let changedRows: Set<RowKey>
        let unsupportedRows: Set<RowKey>
        let unaffectedRows: Set<RowKey>
        let unaffectedExactRows: Set<RowKey>
        let attributedRows: Set<RowKey>
    }

    private static let viewport = CGSize(width: 390, height: 844)
    private static let insets = UIEdgeInsets(top: 18, left: 16, bottom: 22, right: 16)

    @Test(
        "capture or compare Phase 4E0 inline-context corpus geometry",
        .enabled(if:
            ProcessInfo.processInfo.environment["YUEDU_RUN_INLINE_CONTEXT_CORPUS"] == "1"
            || ProcessInfo.processInfo.environment["YUEDU_CAPTURE_INLINE_CONTEXT_PRE"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/yuedu-run-inline-context-corpus")
        )
    )
    func corpusGeometryMatchesImmutablePRE() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let realDirectory = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["YUEDU_REAL_EPUB_DIR"]
                ?? "/Users/zhangruilin/Desktop/Test document/EPUB Format"
        )
        let artifactURL = repoRoot
            .appendingPathComponent("docs/browser-layout/phase4e0-inline-context-pre.json")
        let inputs = try await makeInputs(repoRoot: repoRoot, realDirectory: realDirectory)
        let capture = ProcessInfo.processInfo.environment["YUEDU_CAPTURE_INLINE_CONTEXT_PRE"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/yuedu-capture-inline-context-pre")
        let expected = capture ? nil : try JSONDecoder().decode(
            CorpusArtifact.self,
            from: Data(contentsOf: artifactURL)
        )
        let build = try await buildArtifact(inputs: inputs, expected: expected)
        let actual = build.artifact

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if capture {
            #expect(!FileManager.default.fileExists(atPath: artifactURL.path))
            try FileManager.default.createDirectory(
                at: artifactURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(actual).write(to: artifactURL, options: .withoutOverwriting)
        } else if let expected {
            let matches = artifactsMatch(
                expected: expected,
                actual: actual,
                acceptedRows: build.legacyOracleVerifiedRows
                    .union(build.acceptedTextIndentRows)
            )
            if !build.legacyOracleFailures.isEmpty {
                let failureSummary: String = Array(build.legacyOracleFailures.prefix(8))
                    .joined(separator: " | ")
                Issue.record("Phase 4E0 legacy oracle failed: \(failureSummary)")
            }
            if !build.textIndentFailures.isEmpty {
                let failureSummary = Array(build.textIndentFailures.prefix(8))
                    .joined(separator: " | ")
                Issue.record("Phase 4E1 text-indent attribution failed: \(failureSummary)")
            }
            if !matches {
                let firstDifference = firstDifference(
                    expected: expected,
                    actual: actual,
                    ignoring: build.legacyOracleVerifiedRows
                        .union(build.acceptedTextIndentRows)
                )
                Issue.record("Phase 4E1 corpus geometry changed without attribution: \(firstDifference)")
            }
            #expect(
                matches
                    && build.legacyOracleFailures.isEmpty
                    && build.textIndentFailures.isEmpty
            )
        }

        print(
            "PHASE4E1_TEXT_INDENT books=\(actual.bookCount) chapters=\(actual.chapterCount) "
                + "affected=\(build.affectedRows.count) changed=\(build.changedRows.count) "
                + "unsupported=\(build.unsupportedRows.count) "
                + "unaffected=\(build.unaffectedRows.count) "
                + "unaffectedExact=\(build.unaffectedExactRows.count) "
                + "attributed=\(build.attributedRows.count) "
                + "legacyOracle=\(build.legacyOracleVerifiedRows.count) capture=\(capture)"
        )
    }

    @Test("same-process legacy oracle preserves exact no-float geometry")
    func legacyOracleMatchesSyntheticChapter() throws {
        let html = """
        <html><head><style>
        body { margin: 3%; padding: 4px; text-align: center; }
        p { margin: 7px 5%; line-height: 1.35; }
        </style></head><body><p>Architecture parity oracle text that wraps.</p></body></html>
        """
        let contentWidth = Self.viewport.width - Self.insets.left - Self.insets.right
        let contentHeight = Self.viewport.height - Self.insets.top - Self.insets.bottom
        let config = BrowserLayoutConfig(
            renderWidth: contentWidth,
            renderHeight: contentHeight,
            rootFontSize: 17,
            fontFamilies: ["PingFangSC-Regular"],
            textColor: .black,
            backgroundColor: .white,
            contentInsets: Self.insets
        )
        let document = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let current = try document.makeLayout(
            containerSize: Self.viewport,
            fragmentHeight: contentHeight
        )
        let pages = PageFragmentation.fragment(
            box: current.rootBox,
            pageSize: Self.viewport,
            contentInsets: Self.insets
        )
        let failure = try legacyOracleFailure(
            html: html,
            css: [],
            images: [:],
            config: config,
            contentWidth: contentWidth,
            contentHeight: contentHeight,
            currentSourceText: current.sourceText,
            currentPages: pages,
            currentBoxSnapshot: BrowserLayoutGeometryFingerprint.boxLineSnapshot(current.rootBox),
            currentFragmentSnapshot: BrowserLayoutGeometryFingerprint.fragmentSnapshot(pages)
        )
        #expect(failure == nil)
    }

    private func legacyShape(
        _ box: BlockBox,
        containingInlineSize: CGFloat,
        config: BrowserLayoutConfig,
        sourceText: String,
        savedRuns: inout [(box: BlockBox, runs: [InlineRun])]
    ) {
        for child in box.children {
            let childInlineSize: CGFloat
            switch child.boxType {
            case .anonymous:
                childInlineSize = containingInlineSize
            case .block:
                let resolved = CSSLengthResolver.resolve(
                    child.style.width,
                    emBase: child.style.fontSize,
                    remBase: config.rootFontSize,
                    percentBase: containingInlineSize
                )
                if case .auto = child.style.width, resolved == nil {
                    childInlineSize = containingInlineSize
                } else {
                    childInlineSize = min(
                        max(resolved ?? containingInlineSize, 0),
                        containingInlineSize
                    )
                }
            }
            legacyShape(
                child,
                containingInlineSize: childInlineSize,
                config: config,
                sourceText: sourceText,
                savedRuns: &savedRuns
            )
        }
        guard !box.inlineRuns.isEmpty else { return }
        box.lines = InlineLayout.layoutLines(
            runs: box.inlineRuns,
            context: InlineFormattingContext(
                containingInlineSize: containingInlineSize,
                rootFontSize: config.rootFontSize,
                lineHeight: box.style.lineHeight,
                writingMode: config.writingMode,
                sourceText: sourceText,
                fontResolver: config.fontResolver,
                floatContext: nil,
                blockOffsetY: 0
            )
        )
        savedRuns.append((box, box.inlineRuns))
        box.inlineRuns = []
    }

    private func makeInputs(repoRoot: URL, realDirectory: URL) async throws -> [BookInput] {
        var inputs: [BookInput] = []
        let repoDirectory = repoRoot.appendingPathComponent("docs/epub-regression/samples")
        for url in try epubFiles(in: repoDirectory) {
            inputs.append(BookInput(
                stableKey: "repo-regression/\(url.lastPathComponent)",
                url: url
            ))
        }
        for url in try epubFiles(in: realDirectory) {
            inputs.append(BookInput(
                stableKey: "real/\(url.lastPathComponent)",
                url: url
            ))
        }

        let generated: [(String, EPUBTestFixtures.Sample)] = [
            ("linear-algebra", EPUBTestFixtures.linearAlgebra()),
            ("israelsailing", EPUBTestFixtures.israelSailing()),
            ("georgia", EPUBTestFixtures.georgia()),
            ("quiz-bindings", EPUBTestFixtures.quizBindings()),
            ("prose-smoke", EPUBTestFixtures.proseSmoke()),
        ]
        for (name, sample) in generated {
            inputs.append(BookInput(
                stableKey: "repo-generated/\(name)",
                url: try await EPUBTestFixtures.makeArchive(entries: sample.entries)
            ))
        }
        return inputs.sorted { $0.stableKey < $1.stableKey }
    }

    private func buildArtifact(
        inputs: [BookInput],
        expected: CorpusArtifact?
    ) async throws -> CorpusBuildResult {
        var rows: [CorpusRow] = []
        var legacyOracleVerifiedRows = Set<RowKey>()
        var legacyOracleFailures: [String] = []
        var acceptedTextIndentRows = Set<RowKey>()
        var textIndentFailures: [String] = []
        var affectedRows = Set<RowKey>()
        var changedRows = Set<RowKey>()
        var unsupportedRows = Set<RowKey>()
        var unaffectedRows = Set<RowKey>()
        var unaffectedExactRows = Set<RowKey>()
        var attributedRows = Set<RowKey>()
        var openedBookCount = 0
        let contentWidth = Self.viewport.width - Self.insets.left - Self.insets.right
        let contentHeight = Self.viewport.height - Self.insets.top - Self.insets.bottom
        let expectedByKey = Dictionary(
            uniqueKeysWithValues: (expected?.rows ?? []).map {
                (RowKey(bookID: $0.bookID, spineIndex: $0.spineIndex), $0)
            }
        )

        for input in inputs {
            let session = try await PublicationSession.open(sourceURL: input.url)
            openedBookCount += 1
            let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
            let bookID = stableID(input.stableKey)
            let rowStart = rows.count

            for spineIndex in session.chapters.indices {
                let chapter: (html: String, css: [String], usedArchiveFallback: Bool)
                do {
                    let html = try await adapter.chapterHTML(at: spineIndex)
                    chapter = (
                        html,
                        await adapter.processedCSS(forChapter: spineIndex),
                        false
                    )
                } catch {
                    let html = try await rawArchiveChapterHTML(
                        sourceURL: input.url,
                        encodedHref: session.chapters[spineIndex].href
                    )
                    chapter = (
                        html,
                        try await rawArchiveStylesheets(
                            sourceURL: input.url,
                            encodedChapterHref: session.chapters[spineIndex].href,
                            html: html
                        ),
                        true
                    )
                }

                let scan = BrowserLayoutCapabilityScanner.scan(
                    html: chapter.html,
                    cssTexts: chapter.css
                )
                var reasons = scan.unsupportedFeatures.map(\.description)
                if session.epubWritingMode == .verticalRL {
                    reasons.append("metadata-vertical-writing-mode")
                }
                if session.layoutMode == .prePaginated {
                    reasons.append("metadata-fixed-layout")
                }
                reasons = Array(Set(reasons)).sorted()
                let key = RowKey(bookID: bookID, spineIndex: spineIndex)
                let scannerRejectedTextIndent = scan.unsupportedFeatures.contains(.textIndent)

                guard reasons.isEmpty else {
                    let row = CorpusRow(
                        bookID: bookID,
                        spineIndex: spineIndex,
                        sourceLength: 0,
                        scannerReasons: reasons,
                        boxLineDigest: nil,
                        fragmentDigest: nil,
                        pageRangeDigest: nil,
                        pageCount: nil
                    )
                    rows.append(row)

                    if scannerRejectedTextIndent {
                        unsupportedRows.insert(key)
                        if let expectedRow = expectedByKey[key] {
                            var expectedReasons = Set(expectedRow.scannerReasons)
                            expectedReasons.insert(UnsupportedFeature.textIndent.description)
                            let reasonsMatch = row.scannerReasons == expectedReasons.sorted()
                            let geometryWasNotAttempted = row.boxLineDigest == nil
                                && row.fragmentDigest == nil
                                && row.pageRangeDigest == nil
                                && row.pageCount == nil
                            if reasonsMatch && geometryWasNotAttempted {
                                acceptedTextIndentRows.insert(key)
                            } else {
                                textIndentFailures.append(
                                    "book=\(bookID) spine=\(spineIndex) unsupported reason drift"
                                )
                            }
                        }
                    } else {
                        unaffectedRows.insert(key)
                        if let expectedRow = expectedByKey[key] {
                            if expectedRow == row {
                                unaffectedExactRows.insert(key)
                            } else {
                                textIndentFailures.append(
                                    "book=\(bookID) spine=\(spineIndex) unaffected fallback changed"
                                )
                            }
                        }
                    }
                    continue
                }

                guard !chapter.usedArchiveFallback else {
                    throw CocoaError(
                        .fileReadUnknown,
                        userInfo: [NSLocalizedDescriptionKey:
                            "A scanner-supported chapter required the raw ZIP fallback"]
                    )
                }
                let images = await adapter.prefetchImages(
                    forChapter: spineIndex,
                    html: chapter.html,
                    renderWidth: contentWidth
                )
                let config = BrowserLayoutConfig(
                    renderWidth: contentWidth,
                    renderHeight: contentHeight,
                    rootFontSize: 17,
                    fontFamilies: [],
                    textColor: .black,
                    backgroundColor: .white,
                    contentInsets: Self.insets,
                    fontResolver: adapter.fontResolver()
                )
                let textIndentClass: TextIndentCorpusClass
                switch scan.textIndentUsage {
                case .none:
                    textIndentClass = .unaffected
                    unaffectedRows.insert(key)
                case .supportedNonZero:
                    textIndentClass = .supportedNonZero
                    affectedRows.insert(key)
                case .unsupported:
                    textIndentClass = .unsupported
                    unsupportedRows.insert(key)
                    textIndentFailures.append(
                        "book=\(bookID) spine=\(spineIndex) scanner admitted unsupported indent"
                    )
                }

                if textIndentClass == .unsupported {
                    rows.append(CorpusRow(
                        bookID: bookID,
                        spineIndex: spineIndex,
                        sourceLength: 0,
                        scannerReasons: [UnsupportedFeature.textIndent.description],
                        boxLineDigest: nil,
                        fragmentDigest: nil,
                        pageRangeDigest: nil,
                        pageCount: nil
                    ))
                    continue
                }

                if textIndentClass == .supportedNonZero {
                    let currentEvidence: GeometryEvidence
                    do {
                        currentEvidence = try documentEvidence(
                            html: chapter.html,
                            css: chapter.css,
                            config: config,
                            images: images,
                            contentHeight: contentHeight
                        )
                    } catch BrowserLayoutDocument.BrowserLayoutError.unsupportedFloatFragmentation {
                        rows.append(CorpusRow(
                            bookID: bookID,
                            spineIndex: spineIndex,
                            sourceLength: 0,
                            scannerReasons: ["layout-unsupported-float-fragmentation"],
                            boxLineDigest: nil,
                            fragmentDigest: nil,
                            pageRangeDigest: nil,
                            pageCount: nil
                        ))
                        continue
                    }
                    let row = corpusRow(
                        bookID: bookID,
                        spineIndex: spineIndex,
                        evidence: currentEvidence
                    )
                    rows.append(row)

                    guard let expectedRow = expectedByKey[key] else { continue }
                    let textFailuresBefore = textIndentFailures.count
                    let legacyFailuresBefore = legacyOracleFailures.count
                    guard let zeroEvidence = try zeroTextIndentEvidence(
                        html: chapter.html,
                        css: chapter.css,
                        config: config,
                        images: images,
                        contentWidth: contentWidth,
                        contentHeight: contentHeight
                    ) else {
                        textIndentFailures.append(
                            "book=\(bookID) spine=\(spineIndex) zero clone changed another style"
                        )
                        continue
                    }
                    let zeroRow = corpusRow(
                        bookID: bookID,
                        spineIndex: spineIndex,
                        evidence: zeroEvidence
                    )

                    guard zeroEvidence.sourceText == currentEvidence.sourceText else {
                        textIndentFailures.append(
                            "book=\(bookID) spine=\(spineIndex) forced-zero source changed"
                        )
                        continue
                    }
                    if currentEvidence.visibleTextDigest != zeroEvidence.visibleTextDigest
                        || !currentEvidence.rangesAreOrdered
                        || !zeroEvidence.rangesAreOrdered {
                        textIndentFailures.append(
                            "book=\(bookID) spine=\(spineIndex) source/fragment attribution failed"
                        )
                    }

                    if zeroRow != expectedRow {
                        if metadataMatches(expected: expectedRow, actual: zeroRow),
                           zeroEvidence.containsGeneratedFont,
                           !zeroEvidence.containsFloat {
                            guard let zeroGeometry = try zeroTextIndentGeometry(
                                html: chapter.html,
                                css: chapter.css,
                                config: config,
                                images: images,
                                contentWidth: contentWidth,
                                contentHeight: contentHeight
                            ) else {
                                textIndentFailures.append(
                                    "book=\(bookID) spine=\(spineIndex) oracle zero clone drift"
                                )
                                continue
                            }
                            let oracleFailure = try legacyOracleFailure(
                                html: chapter.html,
                                css: chapter.css,
                                images: images,
                                config: config,
                                contentWidth: contentWidth,
                                contentHeight: contentHeight,
                                currentSourceText: zeroGeometry.sourceText,
                                currentPages: zeroGeometry.pages,
                                currentBoxSnapshot: zeroGeometry.boxSnapshot,
                                currentFragmentSnapshot: zeroGeometry.fragmentSnapshot
                            )
                            if let oracleFailure {
                                legacyOracleFailures.append(
                                    "book=\(bookID) spine=\(spineIndex) forced-zero \(oracleFailure)"
                                )
                            } else {
                                legacyOracleVerifiedRows.insert(key)
                            }
                        } else {
                            textIndentFailures.append(
                                "book=\(bookID) spine=\(spineIndex) forced-zero differs from PRE"
                            )
                        }
                    }

                    if row != expectedRow {
                        changedRows.insert(key)
                        if row == zeroRow {
                            textIndentFailures.append(
                                "book=\(bookID) spine=\(spineIndex) changed without indent geometry"
                            )
                        }
                    }
                    if textIndentFailures.count == textFailuresBefore,
                       legacyOracleFailures.count == legacyFailuresBefore {
                        attributedRows.insert(key)
                        if row != expectedRow {
                            acceptedTextIndentRows.insert(key)
                        }
                    }
                    continue
                }

                let document = BrowserLayoutDocument(
                    html: chapter.html,
                    cssTexts: chapter.css,
                    config: config,
                    imageLoader: { images[$0] }
                )
                let pipeline: BrowserLayoutDocument.BrowserLayoutPipelineResult
                do {
                    pipeline = try document.makeLayout(
                        containerSize: Self.viewport,
                        fragmentHeight: contentHeight
                    )
                } catch BrowserLayoutDocument.BrowserLayoutError.unsupportedFloatFragmentation {
                    rows.append(CorpusRow(
                        bookID: bookID,
                        spineIndex: spineIndex,
                        sourceLength: 0,
                        scannerReasons: ["layout-unsupported-float-fragmentation"],
                        boxLineDigest: nil,
                        fragmentDigest: nil,
                        pageRangeDigest: nil,
                        pageCount: nil
                    ))
                    continue
                }
                let pages = PageFragmentation.fragment(
                    box: pipeline.rootBox,
                    pageSize: Self.viewport,
                    contentInsets: Self.insets
                )
                let boxSnapshot = BrowserLayoutGeometryFingerprint
                    .boxLineSnapshot(pipeline.rootBox)
                let fragmentSnapshot = BrowserLayoutGeometryFingerprint
                    .fragmentSnapshot(pages)
                let row = CorpusRow(
                    bookID: bookID,
                    spineIndex: spineIndex,
                    sourceLength: (pipeline.sourceText as NSString).length,
                    scannerReasons: [],
                    boxLineDigest: boxSnapshot.digest,
                    fragmentDigest: fragmentSnapshot.digest,
                    pageRangeDigest: BrowserLayoutGeometryFingerprint
                        .pageRangeSnapshot(pages, sourceText: pipeline.sourceText).digest,
                    pageCount: pages.count
                )
                rows.append(row)

                guard let expectedRow = expectedByKey[key] else { continue }
                if expectedRow == row {
                    unaffectedExactRows.insert(key)
                } else if metadataMatches(expected: expectedRow, actual: row),
                          containsProcessGeneratedEmbeddedFont(in: pipeline.rootBox) {
                    // Some malformed/subset EPUB fonts expose a process-generated
                    // PostScript name and EPUBStyleResolver can choose a different
                    // duplicate face in a fresh process. The immutable PRE digest
                    // therefore cannot be replayed for these rows: both glyph
                    // widths and the fontName field vary before Phase 4E0 code runs.
                    // Keep the exception exact and test-only. A no-float chapter
                    // must instead match a same-process pre-refactor shaping oracle;
                    // delete this branch when font-face selection is deterministic.
                    if containsFloat(in: pipeline.rootBox) {
                        legacyOracleFailures.append(
                            "book=\(bookID) spine=\(spineIndex) has generated font and float"
                        )
                    } else {
                        let oracleFailure = try legacyOracleFailure(
                            html: chapter.html,
                            css: chapter.css,
                            images: images,
                            config: config,
                            contentWidth: contentWidth,
                            contentHeight: contentHeight,
                            currentSourceText: pipeline.sourceText,
                            currentPages: pages,
                            currentBoxSnapshot: boxSnapshot,
                            currentFragmentSnapshot: fragmentSnapshot
                        )
                        if let oracleFailure {
                            legacyOracleFailures.append(
                                "book=\(bookID) spine=\(spineIndex) \(oracleFailure)"
                            )
                        } else {
                            legacyOracleVerifiedRows.insert(key)
                        }
                    }
                } else {
                    textIndentFailures.append(
                        "book=\(bookID) spine=\(spineIndex) unaffected geometry changed"
                    )
                }
            }
            print(
                "PHASE4E1_TEXT_INDENT_PROGRESS books=\(openedBookCount) "
                    + "chapters=\(rows.count - rowStart) cumulative=\(rows.count)"
            )
        }

        rows.sort {
            if $0.bookID != $1.bookID { return $0.bookID < $1.bookID }
            return $0.spineIndex < $1.spineIndex
        }
        let supported = rows.filter(\.scannerReasons.isEmpty).count
        return CorpusBuildResult(
            artifact: CorpusArtifact(
                schemaVersion: 1,
                bookCount: openedBookCount,
                chapterCount: rows.count,
                browserSupportedChapterCount: supported,
                fallbackChapterCount: rows.count - supported,
                rows: rows
            ),
            legacyOracleVerifiedRows: legacyOracleVerifiedRows,
            legacyOracleFailures: legacyOracleFailures,
            acceptedTextIndentRows: acceptedTextIndentRows,
            textIndentFailures: textIndentFailures,
            affectedRows: affectedRows,
            changedRows: changedRows,
            unsupportedRows: unsupportedRows,
            unaffectedRows: unaffectedRows,
            unaffectedExactRows: unaffectedExactRows,
            attributedRows: attributedRows
        )
    }

    private func metadataMatches(expected: CorpusRow, actual: CorpusRow) -> Bool {
        expected.bookID == actual.bookID
            && expected.spineIndex == actual.spineIndex
            && expected.sourceLength == actual.sourceLength
            && expected.scannerReasons == actual.scannerReasons
    }

    private func cloneWithZeroTextIndent(_ node: ComputedStyleNode) -> ComputedStyleNode {
        var style = node.style
        style.textIndent = .initial
        let children = node.children.map { child -> StyleTreeChild in
            switch child {
            case .text(let text):
                return .text(text)
            case .element(let element):
                return .element(cloneWithZeroTextIndent(element))
            }
        }
        return ComputedStyleNode(
            tag: node.tag,
            element: node.element,
            style: style,
            children: children,
            nodeID: node.nodeID,
            linkTarget: node.linkTarget,
            anchorID: node.anchorID
        )
    }

    private func stylesDifferOnlyByTextIndent(
        original: ComputedStyleNode,
        zeroed: ComputedStyleNode
    ) -> Bool {
        var normalized = original.style
        normalized.textIndent = .initial
        guard normalized == zeroed.style,
              original.tag == zeroed.tag,
              original.element === zeroed.element,
              original.nodeID == zeroed.nodeID,
              original.linkTarget == zeroed.linkTarget,
              original.anchorID == zeroed.anchorID,
              original.children.count == zeroed.children.count else {
            return false
        }
        for (originalChild, zeroedChild) in zip(original.children, zeroed.children) {
            switch (originalChild, zeroedChild) {
            case (.text(let lhs), .text(let rhs)):
                guard lhs == rhs else { return false }
            case (.element(let lhs), .element(let rhs)):
                guard stylesDifferOnlyByTextIndent(original: lhs, zeroed: rhs) else {
                    return false
                }
            default:
                return false
            }
        }
        return true
    }

    private func verifiedZeroTextIndentStyleRoot(
        html: String,
        css: [String],
        config: BrowserLayoutConfig
    ) throws -> ComputedStyleNode? {
        var metrics = LayoutMetrics()
        let original = try LegacyCSSFrontend().buildStyleTree(
            html: html,
            cssTexts: css,
            config: config,
            metrics: &metrics
        ).rootNode
        let zeroed = cloneWithZeroTextIndent(original)
        guard stylesDifferOnlyByTextIndent(original: original, zeroed: zeroed) else {
            return nil
        }
        return zeroed
    }

    private func zeroTextIndentEvidence(
        html: String,
        css: [String],
        config: BrowserLayoutConfig,
        images: [String: UIImage],
        contentWidth: CGFloat,
        contentHeight: CGFloat
    ) throws -> GeometryEvidence? {
        guard let zeroRoot = try verifiedZeroTextIndentStyleRoot(
            html: html,
            css: css,
            config: config
        ) else {
            return nil
        }
        return styleTreeEvidence(
            styleRoot: zeroRoot,
            config: config,
            images: images,
            contentWidth: contentWidth,
            contentHeight: contentHeight
        )
    }

    private func zeroTextIndentGeometry(
        html: String,
        css: [String],
        config: BrowserLayoutConfig,
        images: [String: UIImage],
        contentWidth: CGFloat,
        contentHeight: CGFloat
    ) throws -> GeometryBuild? {
        guard let zeroRoot = try verifiedZeroTextIndentStyleRoot(
            html: html,
            css: css,
            config: config
        ) else {
            return nil
        }
        return makeGeometry(
            styleRoot: zeroRoot,
            config: config,
            images: images,
            contentWidth: contentWidth,
            contentHeight: contentHeight
        )
    }

    private func makeGeometry(
        styleRoot: ComputedStyleNode,
        config: BrowserLayoutConfig,
        images: [String: UIImage],
        contentWidth: CGFloat,
        contentHeight: CGFloat
    ) -> GeometryBuild {
        var sourceText = SourceTextBuilder()
        var anchors: [String: Int] = [:]
        let rootBox = BoxTreeBuilder.buildBlock(
            for: styleRoot,
            config: config,
            sourceText: &sourceText,
            anchors: &anchors,
            imageLoader: { images[$0] }
        )
        _ = BlockLayout.layOut(
            root: rootBox,
            containerWidth: contentWidth,
            inlineContainingSize: config.renderWidth,
            rootFontSize: config.rootFontSize,
            writingMode: config.writingMode,
            sourceText: sourceText.text,
            fontResolver: config.fontResolver,
            fragmentHeight: contentHeight
        )
        let pages = PageFragmentation.fragment(
            box: rootBox,
            pageSize: Self.viewport,
            contentInsets: Self.insets
        )
        return GeometryBuild(
            rootBox: rootBox,
            sourceText: sourceText.text,
            pages: pages,
            boxSnapshot: BrowserLayoutGeometryFingerprint.boxLineSnapshot(rootBox),
            fragmentSnapshot: BrowserLayoutGeometryFingerprint.fragmentSnapshot(pages),
            pageRangeSnapshot: BrowserLayoutGeometryFingerprint.pageRangeSnapshot(
                pages,
                sourceText: sourceText.text
            )
        )
    }

    private func corpusRow(
        bookID: String,
        spineIndex: Int,
        geometry: GeometryBuild
    ) -> CorpusRow {
        CorpusRow(
            bookID: bookID,
            spineIndex: spineIndex,
            sourceLength: (geometry.sourceText as NSString).length,
            scannerReasons: [],
            boxLineDigest: geometry.boxSnapshot.digest,
            fragmentDigest: geometry.fragmentSnapshot.digest,
            pageRangeDigest: geometry.pageRangeSnapshot.digest,
            pageCount: geometry.pages.count
        )
    }

    private func corpusRow(
        bookID: String,
        spineIndex: Int,
        evidence: GeometryEvidence
    ) -> CorpusRow {
        CorpusRow(
            bookID: bookID,
            spineIndex: spineIndex,
            sourceLength: (evidence.sourceText as NSString).length,
            scannerReasons: [],
            boxLineDigest: evidence.boxDigest,
            fragmentDigest: evidence.fragmentDigest,
            pageRangeDigest: evidence.pageRangeDigest,
            pageCount: evidence.pageCount
        )
    }

    private func documentEvidence(
        html: String,
        css: [String],
        config: BrowserLayoutConfig,
        images: [String: UIImage],
        contentHeight: CGFloat
    ) throws -> GeometryEvidence {
        let document = BrowserLayoutDocument(
            html: html,
            cssTexts: css,
            config: config,
            imageLoader: { images[$0] }
        )
        let pipeline = try document.makeLayout(
            containerSize: Self.viewport,
            fragmentHeight: contentHeight
        )
        let pages = PageFragmentation.fragment(
            box: pipeline.rootBox,
            pageSize: Self.viewport,
            contentInsets: Self.insets
        )
        return geometryEvidence(
            rootBox: pipeline.rootBox,
            sourceText: pipeline.sourceText,
            pages: pages
        )
    }

    private func styleTreeEvidence(
        styleRoot: ComputedStyleNode,
        config: BrowserLayoutConfig,
        images: [String: UIImage],
        contentWidth: CGFloat,
        contentHeight: CGFloat
    ) -> GeometryEvidence {
        var sourceText = SourceTextBuilder()
        var anchors: [String: Int] = [:]
        let rootBox = BoxTreeBuilder.buildBlock(
            for: styleRoot,
            config: config,
            sourceText: &sourceText,
            anchors: &anchors,
            imageLoader: { images[$0] }
        )
        _ = BlockLayout.layOut(
            root: rootBox,
            containerWidth: contentWidth,
            inlineContainingSize: config.renderWidth,
            rootFontSize: config.rootFontSize,
            writingMode: config.writingMode,
            sourceText: sourceText.text,
            fontResolver: config.fontResolver,
            fragmentHeight: contentHeight
        )
        let pages = PageFragmentation.fragment(
            box: rootBox,
            pageSize: Self.viewport,
            contentInsets: Self.insets
        )
        return geometryEvidence(
            rootBox: rootBox,
            sourceText: sourceText.text,
            pages: pages
        )
    }

    private func geometryEvidence(
        rootBox: BlockBox,
        sourceText: String,
        pages: [PageFragments]
    ) -> GeometryEvidence {
        let visible = BrowserLayoutTestSupport.visibleText(
            pages,
            sourceText: sourceText
        )
        // Each canonical row array is released after its digest expression,
        // before the next snapshot is created. Retaining all three snapshots
        // doubled the peak for the corpus's largest single-chapter EPUB.
        let boxDigest = BrowserLayoutGeometryFingerprint.boxLineSnapshot(rootBox).digest
        let fragmentDigest = BrowserLayoutGeometryFingerprint.fragmentSnapshot(pages).digest
        let pageRangeDigest = BrowserLayoutGeometryFingerprint.pageRangeSnapshot(
            pages,
            sourceText: sourceText
        ).digest
        return GeometryEvidence(
            sourceText: sourceText,
            visibleTextDigest: stableDigest(visible),
            rangesAreOrdered: BrowserLayoutTestSupport.rangesAreOrdered(pages),
            containsGeneratedFont: containsProcessGeneratedEmbeddedFont(in: rootBox),
            containsFloat: containsFloat(in: rootBox),
            boxDigest: boxDigest,
            fragmentDigest: fragmentDigest,
            pageRangeDigest: pageRangeDigest,
            pageCount: pages.count
        )
    }

    private func stableDigest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func containsProcessGeneratedEmbeddedFont(in box: BlockBox) -> Bool {
        if box.lines.contains(where: { line in
            line.runs.contains { $0.font.fontName.hasPrefix("font00000000") }
        }) {
            return true
        }
        return box.children.contains { containsProcessGeneratedEmbeddedFont(in: $0) }
    }

    private func containsFloat(in box: BlockBox) -> Bool {
        box.isFloated || box.children.contains { containsFloat(in: $0) }
    }

    /// Same-process differential oracle for PRE rows whose embedded-font face
    /// cannot be reproduced across test-host processes. It recreates the old
    /// no-float ordering (shape all inline runs during tree construction, then
    /// place the preformatted lines) without exposing a legacy mode in
    /// production BlockLayout. The caller rejects every floated chapter.
    private func legacyOracleFailure(
        html: String,
        css: [String],
        images: [String: UIImage],
        config: BrowserLayoutConfig,
        contentWidth: CGFloat,
        contentHeight: CGFloat,
        currentSourceText: String,
        currentPages: [PageFragments],
        currentBoxSnapshot: BrowserLayoutGeometryFingerprint.Snapshot,
        currentFragmentSnapshot: BrowserLayoutGeometryFingerprint.Snapshot
    ) throws -> String? {
        var metrics = LayoutMetrics()
        let styleRoot = try LegacyCSSFrontend().buildStyleTree(
            html: html,
            cssTexts: css,
            config: config,
            metrics: &metrics
        ).rootNode
        var sourceText = SourceTextBuilder()
        var anchors: [String: Int] = [:]
        let root = BoxTreeBuilder.buildBlock(
            for: styleRoot,
            config: config,
            sourceText: &sourceText,
            anchors: &anchors,
            imageLoader: { images[$0] }
        )
        guard !containsFloat(in: root) else {
            return "legacy oracle unexpectedly received a float"
        }

        var savedRuns: [(box: BlockBox, runs: [InlineRun])] = []
        legacyShape(
            root,
            containingInlineSize: config.renderWidth,
            config: config,
            sourceText: sourceText.text,
            savedRuns: &savedRuns
        )
        _ = BlockLayout.layOut(
            root: root,
            containerWidth: contentWidth,
            inlineContainingSize: config.renderWidth,
            rootFontSize: config.rootFontSize,
            writingMode: config.writingMode,
            sourceText: sourceText.text,
            fontResolver: config.fontResolver,
            fragmentHeight: contentHeight
        )
        for saved in savedRuns {
            saved.box.inlineRuns = saved.runs
        }
        let pages = PageFragmentation.fragment(
            box: root,
            pageSize: Self.viewport,
            contentInsets: Self.insets
        )

        guard sourceText.text == currentSourceText else {
            return "source text differs"
        }
        let boxSnapshot = BrowserLayoutGeometryFingerprint.boxLineSnapshot(root)
        if boxSnapshot != currentBoxSnapshot {
            return "box " + snapshotDifference(
                expected: boxSnapshot,
                actual: currentBoxSnapshot
            )
        }
        let fragmentSnapshot = BrowserLayoutGeometryFingerprint.fragmentSnapshot(pages)
        if fragmentSnapshot != currentFragmentSnapshot {
            return "fragment " + snapshotDifference(
                expected: fragmentSnapshot,
                actual: currentFragmentSnapshot
            )
        }
        let legacyPageRanges = BrowserLayoutGeometryFingerprint.pageRangeSnapshot(
            pages,
            sourceText: sourceText.text
        )
        let currentPageRanges = BrowserLayoutGeometryFingerprint.pageRangeSnapshot(
            currentPages,
            sourceText: currentSourceText
        )
        guard legacyPageRanges == currentPageRanges else {
            return "page ranges " + snapshotDifference(
                expected: legacyPageRanges,
                actual: currentPageRanges
            )
        }
        return nil
    }

    private func snapshotDifference(
        expected: BrowserLayoutGeometryFingerprint.Snapshot,
        actual: BrowserLayoutGeometryFingerprint.Snapshot
    ) -> String {
        for index in 0..<min(expected.canonicalRows.count, actual.canonicalRows.count) {
            if expected.canonicalRows[index] != actual.canonicalRows[index] {
                return "row=\(index) expected=\(expected.canonicalRows[index]) "
                    + "actual=\(actual.canonicalRows[index])"
            }
        }
        return "rowCount expected=\(expected.canonicalRows.count) "
            + "actual=\(actual.canonicalRows.count)"
    }

    private func artifactsMatch(
        expected: CorpusArtifact,
        actual: CorpusArtifact,
        acceptedRows: Set<RowKey>
    ) -> Bool {
        let actualSupported = actual.rows.filter(\.scannerReasons.isEmpty).count
        guard expected.schemaVersion == actual.schemaVersion,
              expected.bookCount == actual.bookCount,
              expected.chapterCount == actual.chapterCount,
              actual.browserSupportedChapterCount == actualSupported,
              actual.fallbackChapterCount == actual.rows.count - actualSupported,
              expected.rows.count == actual.rows.count else {
            return false
        }
        for (expectedRow, actualRow) in zip(expected.rows, actual.rows) {
            guard expectedRow != actualRow else { continue }
            let key = RowKey(bookID: actualRow.bookID, spineIndex: actualRow.spineIndex)
            guard acceptedRows.contains(key) else { return false }
        }
        return true
    }

    private func firstDifference(
        expected: CorpusArtifact,
        actual: CorpusArtifact,
        ignoring legacyOracleVerifiedRows: Set<RowKey> = []
    ) -> String {
        if expected.schemaVersion != actual.schemaVersion {
            return "schemaVersion expected=\(expected.schemaVersion) actual=\(actual.schemaVersion)"
        }
        if expected.bookCount != actual.bookCount || expected.chapterCount != actual.chapterCount {
            return "corpus size expected=\(expected.bookCount)/\(expected.chapterCount) "
                + "actual=\(actual.bookCount)/\(actual.chapterCount)"
        }
        for index in 0..<min(expected.rows.count, actual.rows.count) {
            let row = actual.rows[index]
            let key = RowKey(bookID: row.bookID, spineIndex: row.spineIndex)
            if expected.rows[index] != row, !legacyOracleVerifiedRows.contains(key) {
                return "row=\(index) expected=\(expected.rows[index]) actual=\(actual.rows[index])"
            }
        }
        return "row count expected=\(expected.rows.count) actual=\(actual.rows.count)"
    }

    private func stableID(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "book-\(digest)"
    }

    private func epubFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "epub" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func rawArchiveChapterHTML(
        sourceURL: URL,
        encodedHref: String
    ) async throws -> String {
        let decodedHref = encodedHref.removingPercentEncoding ?? encodedHref
        guard decodedHref != encodedHref else { throw CocoaError(.fileReadNoSuchFile) }
        return try await rawArchiveText(sourceURL: sourceURL, entryPath: decodedHref)
    }

    private func rawArchiveStylesheets(
        sourceURL: URL,
        encodedChapterHref: String,
        html: String
    ) async throws -> [String] {
        let decodedChapterHref = encodedChapterHref.removingPercentEncoding ?? encodedChapterHref
        let document = try SwiftSoup.parse(html)
        guard let head = document.head() else { return [] }
        var stylesheets: [String] = []

        for style in try head.select("style").array() {
            let css = try style.html()
            if !css.isEmpty { stylesheets.append(css) }
        }
        for link in try head.select("link[rel=stylesheet][href]").array() {
            let href = try link.attr("href")
            guard !href.isEmpty, URL(string: href)?.scheme == nil else { continue }
            let pathWithoutFragment = String(href.split(separator: "#", maxSplits: 1)[0])
            let pathWithoutQuery = String(pathWithoutFragment.split(separator: "?", maxSplits: 1)[0])
            let chapterDirectory = (decodedChapterHref as NSString).deletingLastPathComponent
            let relativePath = (chapterDirectory as NSString).appendingPathComponent(pathWithoutQuery)
            let normalizedPath = URL(fileURLWithPath: "/\(relativePath)")
                .standardizedFileURL.path.drop(while: { $0 == "/" })
            stylesheets.append(try await rawArchiveText(
                sourceURL: sourceURL,
                entryPath: String(normalizedPath)
            ))
        }
        var seen = Set<String>()
        return stylesheets.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func rawArchiveText(sourceURL: URL, entryPath: String) async throws -> String {
        let archive = try await Archive(url: sourceURL, accessMode: .read)
        guard let entry = try await archive.get(entryPath) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        _ = try await archive.extract(entry, to: temporaryURL, skipCRC32: true)
        let data = try Data(contentsOf: temporaryURL)
        for encoding in [
            String.Encoding.utf8, .unicode, .utf16, .utf16LittleEndian,
            .utf16BigEndian, .isoLatin1,
        ] {
            if let value = String(data: data, encoding: encoding) { return value }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}
