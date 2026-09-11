import CryptoKit
import Foundation
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

    private struct CorpusShardSummary: Codable {
        let shardIndex: Int
        let shardCount: Int
        let bookCount: Int
        let chapterCount: Int
        let supportedCount: Int
        let fallbackCount: Int
        let affectedCount: Int
        let changedCount: Int
        let unsupportedCount: Int
        let unaffectedCount: Int
        let unaffectedExactCount: Int
        let attributedCount: Int
        let legacyOracleCount: Int
        let presentationalAttributeCount: Int
        let presentationalHintCount: Int
        let presentationalHintChangedCount: Int
        let noPresentationalAttributeCount: Int
        let noPresentationalAttributeVerifiedCount: Int
    }

    /// Phase-closure evidence is deliberately separate from the immutable
    /// Phase 4E0 PRE artifact. The PRE schema remains frozen; this row records
    /// the current production BrowserAuto decision plus structural evidence
    /// needed for a same-process deterministic replay and invariant gate.
    private struct ClosureCorpusRow: Codable, Equatable {
        let bookID: String
        let bookTitle: String
        let spineIndex: Int
        let chapterTitle: String
        let sourceLength: Int
        let scannerReasons: [String]
        let pageCount: Int?
        let pageRangeDigest: String?
        let logicalLineCount: Int?
        let fragmentCount: Int?
        let geometryDigest: String?
        let containsGeneratedFont: Bool
        let features: [String]
        let invariantFailures: [String]
    }

    private struct ClosureCorpusArtifact: Codable, Equatable {
        let schemaVersion: Int
        let shardIndex: Int?
        let shardCount: Int?
        let bookCount: Int
        let chapterCount: Int
        let browserSupportedChapterCount: Int
        let fallbackChapterCount: Int
        let fallbackReasonDistribution: [String: Int]
        let layoutFailureCount: Int
        let diagnosticFailureCount: Int
        let invariantViolationCount: Int
        let rows: [ClosureCorpusRow]
    }

    private struct ClosureChapterMetadata {
        let bookTitle: String
        let chapterTitle: String
    }

    private struct ClosureGeometry {
        let pageCount: Int
        let pageRangeDigest: String
        let logicalLineCount: Int
        let fragmentCount: Int
        let geometryDigest: String
        let containsGeneratedFont: Bool
        let features: [String]
        let invariantFailures: [String]
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
        let closure: ClosureGeometry
    }

    private struct RowKey: Hashable {
        let bookID: String
        let spineIndex: Int
    }

    private struct CorpusShard: Equatable {
        let index: Int
        let count: Int

        func includes(spineIndex: Int) -> Bool {
            spineIndex % count == index
        }

        var label: String {
            "\(index + 1)/\(count)"
        }
    }

    private enum TextIndentCorpusClass: Equatable {
        case unaffected
        case supportedNonZero
        case unsupported
    }

    private struct CorpusBuildResult {
        let artifact: CorpusArtifact
        let closureArtifact: ClosureCorpusArtifact
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
        let presentationalAttributeRows: Set<RowKey>
        let presentationalHintRows: Set<RowKey>
        let acceptedPresentationalHintRows: Set<RowKey>
        let presentationalHintChangedRows: Set<RowKey>
        let presentationalHintFailures: [String]
        let noPresentationalAttributeRows: Set<RowKey>
    }

    private struct PresentationalHintUsage {
        let hasRelevantAttribute: Bool
        let hasValidHint: Bool
    }

    private static let viewport = CGSize(width: 390, height: 844)
    private static let insets = UIEdgeInsets(top: 18, left: 16, bottom: 22, right: 16)

    @Test(
        "capture or compare Phase 4E0 inline-context corpus geometry",
        .enabled(if:
            ProcessInfo.processInfo.environment["YUEDU_RUN_INLINE_CONTEXT_CORPUS"] == "1"
            || ProcessInfo.processInfo.environment["YUEDU_CAPTURE_INLINE_CONTEXT_PRE"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/yuedu-run-inline-context-corpus")
            || FileManager.default.fileExists(
                atPath: "/tmp/yuedu-horizontal-closure-double-pass"
            )
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
        let shard = try corpusShardFromEnvironment()
        let closureDoublePass = FileManager.default.fileExists(
            atPath: "/tmp/yuedu-horizontal-closure-double-pass"
        )
        let capture = ProcessInfo.processInfo.environment["YUEDU_CAPTURE_INLINE_CONTEXT_PRE"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/yuedu-capture-inline-context-pre")
        #expect(!capture || shard == nil)
        guard !capture || shard == nil else { return }
        let expected: CorpusArtifact?
        if capture {
            expected = nil
        } else {
            let fullExpected = try JSONDecoder().decode(
                CorpusArtifact.self,
                from: Data(contentsOf: artifactURL)
            )
            expected = shard.map { filteredArtifact(fullExpected, for: $0) } ?? fullExpected
        }
        // The immutable Phase 4E0 artifact answers PRE-refactor attribution.
        // Horizontal closure instead compares the current production pipeline
        // with an immediate same-process replay; feeding old PRE rows into that
        // pass would mislabel already-approved later-phase geometry as a new
        // diagnostic failure.
        let buildExpected = closureDoublePass ? nil : expected
        let build = try await buildArtifact(inputs: inputs, expected: buildExpected, shard: shard)
        let actual = build.artifact

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var verifiedNoAttributeRows = Set<RowKey>()
        if capture {
            #expect(!FileManager.default.fileExists(atPath: artifactURL.path))
            try FileManager.default.createDirectory(
                at: artifactURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(actual).write(to: artifactURL, options: .withoutOverwriting)
        } else if let expected, !closureDoublePass {
            let matches = artifactsMatch(
                expected: expected,
                actual: actual,
                acceptedRows: build.legacyOracleVerifiedRows
                    .union(build.acceptedTextIndentRows)
                    .union(build.acceptedPresentationalHintRows)
            )
            let exactRows = identicalRowKeys(expected: expected, actual: actual)
            verifiedNoAttributeRows = build.noPresentationalAttributeRows.intersection(
                exactRows
                    .union(build.legacyOracleVerifiedRows)
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
            if !build.presentationalHintFailures.isEmpty {
                let failureSummary = Array(build.presentationalHintFailures.prefix(8))
                    .joined(separator: " | ")
                Issue.record("Phase 4F0 presentational-hint attribution failed: \(failureSummary)")
            }
            if verifiedNoAttributeRows != build.noPresentationalAttributeRows {
                let missing = build.noPresentationalAttributeRows
                    .subtracting(verifiedNoAttributeRows)
                    .prefix(8)
                    .map { "book=\($0.bookID) spine=\($0.spineIndex)" }
                    .joined(separator: " | ")
                Issue.record("Phase 4F0 no-attribute geometry parity failed: \(missing)")
            }
            if !matches {
                let firstDifference = firstDifference(
                    expected: expected,
                    actual: actual,
                    ignoring: build.legacyOracleVerifiedRows
                        .union(build.acceptedTextIndentRows)
                        .union(build.acceptedPresentationalHintRows)
                )
                Issue.record("Phase 4F0 corpus geometry changed without attribution: \(firstDifference)")
            }
            #expect(
                matches
                    && build.legacyOracleFailures.isEmpty
                    && build.textIndentFailures.isEmpty
                    && build.presentationalHintFailures.isEmpty
                    && verifiedNoAttributeRows == build.noPresentationalAttributeRows
            )
        }

        let phase4F0SummaryParts = [
            "PHASE4E1_TEXT_INDENT shard=\(shard?.label ?? "full")",
            "books=\(actual.bookCount)",
            "chapters=\(actual.chapterCount)",
            "affected=\(build.affectedRows.count)",
            "changed=\(build.changedRows.count)",
            "unsupported=\(build.unsupportedRows.count)",
            "unaffected=\(build.unaffectedRows.count)",
            "unaffectedExact=\(build.unaffectedExactRows.count)",
            "attributed=\(build.attributedRows.count)",
            "presentationalAttributes=\(build.presentationalAttributeRows.count)",
            "presentationalHints=\(build.presentationalHintRows.count)",
            "presentationalChanged=\(build.presentationalHintChangedRows.count)",
            "noPresentationalAttribute=\(build.noPresentationalAttributeRows.count)",
            "noPresentationalAttributeVerified=\(verifiedNoAttributeRows.count)",
            "legacyOracle=\(build.legacyOracleVerifiedRows.count)",
            "capture=\(capture)",
        ]
        print(phase4F0SummaryParts.joined(separator: " "))
        if let shard {
            try writeShardSummary(
                CorpusShardSummary(
                    shardIndex: shard.index,
                    shardCount: shard.count,
                    bookCount: actual.bookCount,
                    chapterCount: actual.chapterCount,
                    supportedCount: actual.browserSupportedChapterCount,
                    fallbackCount: actual.fallbackChapterCount,
                    affectedCount: build.affectedRows.count,
                    changedCount: build.changedRows.count,
                    unsupportedCount: build.unsupportedRows.count,
                    unaffectedCount: build.unaffectedRows.count,
                    unaffectedExactCount: build.unaffectedExactRows.count,
                    attributedCount: build.attributedRows.count,
                    legacyOracleCount: build.legacyOracleVerifiedRows.count,
                    presentationalAttributeCount: build.presentationalAttributeRows.count,
                    presentationalHintCount: build.presentationalHintRows.count,
                    presentationalHintChangedCount: build.presentationalHintChangedRows.count,
                    noPresentationalAttributeCount: build.noPresentationalAttributeRows.count,
                    noPresentationalAttributeVerifiedCount: verifiedNoAttributeRows.count
                )
            )
        }

        if closureDoublePass {
            let firstClosure = build.closureArtifact
            try writeClosureArtifact(firstClosure, pass: 1, shard: shard)

            // Run the same production inputs/settings again in this process.
            // Embedded subset fonts can receive process-generated identities;
            // keeping both passes in one process removes identity noise without
            // exempting page, source, line, fragment, or geometry differences.
            let repeatedBuild = try await buildArtifact(
                inputs: inputs,
                expected: nil,
                shard: shard
            )
            let secondClosure = repeatedBuild.closureArtifact
            try writeClosureArtifact(secondClosure, pass: 2, shard: shard)
            if firstClosure != secondClosure {
                let difference = firstClosureDifference(firstClosure, secondClosure)
                Issue.record("Horizontal closure deterministic replay failed: \(difference)")
            }
            #expect(firstClosure == secondClosure)
            #expect(firstClosure.layoutFailureCount == 0)
            #expect(firstClosure.diagnosticFailureCount == 0)
            #expect(firstClosure.invariantViolationCount == 0)
            print(
                "HORIZONTAL_CLOSURE shard=\(shard?.label ?? "full") "
                    + "chapters=\(firstClosure.chapterCount) "
                    + "supported=\(firstClosure.browserSupportedChapterCount) "
                    + "fallback=\(firstClosure.fallbackChapterCount) "
                    + "invariantViolations=\(firstClosure.invariantViolationCount) "
                    + "deterministic=\(firstClosure == secondClosure)"
            )
        }
    }

    @Test("same-process legacy oracle preserves exact unaffected geometry")
    func legacyOracleMatchesSyntheticChapter() throws {
        let html = """
        <html><head><style>
        body { margin: 0; padding: 0; text-align: center; }
        p { margin: 0; padding: 0; line-height: 23px; }
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
        expected: CorpusArtifact?,
        shard: CorpusShard? = nil
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
        var presentationalAttributeRows = Set<RowKey>()
        var presentationalHintRows = Set<RowKey>()
        var acceptedPresentationalHintRows = Set<RowKey>()
        var presentationalHintChangedRows = Set<RowKey>()
        var presentationalHintFailures: [String] = []
        var noPresentationalAttributeRows = Set<RowKey>()
        var closureMetadataByKey: [RowKey: ClosureChapterMetadata] = [:]
        var closureGeometryByKey: [RowKey: ClosureGeometry] = [:]
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
                if let shard, !shard.includes(spineIndex: spineIndex) {
                    continue
                }
                let chapter = (
                    html: try await adapter.chapterHTML(at: spineIndex),
                    css: await adapter.processedCSS(forChapter: spineIndex)
                )

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
                closureMetadataByKey[key] = ClosureChapterMetadata(
                    bookTitle: session.bookTitle,
                    chapterTitle: session.chapters[spineIndex].title
                )
                let presentationalUsage = try presentationalHintUsage(in: chapter.html)
                if presentationalUsage.hasRelevantAttribute {
                    presentationalAttributeRows.insert(key)
                } else {
                    noPresentationalAttributeRows.insert(key)
                }
                if presentationalUsage.hasValidHint {
                    presentationalHintRows.insert(key)
                }
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

                if presentationalUsage.hasValidHint {
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
                    closureGeometryByKey[key] = currentEvidence.closure

                    guard let expectedRow = expectedByKey[key] else { continue }
                    guard presentationalHintTransitionMatches(
                        expected: expectedRow,
                        actual: row
                    ) else {
                        presentationalHintFailures.append(
                            "book=\(bookID) spine=\(spineIndex) metadata/source changed"
                        )
                        continue
                    }
                    guard currentEvidence.rangesAreOrdered else {
                        presentationalHintFailures.append(
                            "book=\(bookID) spine=\(spineIndex) source ranges not monotonic"
                        )
                        continue
                    }
                    if row != expectedRow {
                        presentationalHintChangedRows.insert(key)
                        acceptedPresentationalHintRows.insert(key)
                    }
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
                    closureGeometryByKey[key] = currentEvidence.closure

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
                           zeroRow.pageCount == expectedRow.pageCount,
                           zeroRow.pageRangeDigest == expectedRow.pageRangeDigest,
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
                            let replayedZeroRow = corpusRow(
                                bookID: bookID,
                                spineIndex: spineIndex,
                                geometry: zeroGeometry
                            )
                            guard replayedZeroRow == zeroRow else {
                                textIndentFailures.append(
                                    "book=\(bookID) spine=\(spineIndex) oracle zero replay nondeterministic"
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
                            let repeatedZeroEvidence = try zeroTextIndentEvidence(
                                html: chapter.html,
                                css: chapter.css,
                                config: config,
                                images: images,
                                contentWidth: contentWidth,
                                contentHeight: contentHeight
                            )
                            let repeatedZeroRow = repeatedZeroEvidence.map {
                                corpusRow(
                                    bookID: bookID,
                                    spineIndex: spineIndex,
                                    evidence: $0
                                )
                            }
                            let oracleDescription: String
                            if metadataMatches(expected: expectedRow, actual: zeroRow),
                               !zeroEvidence.containsFloat,
                               let zeroGeometry = try zeroTextIndentGeometry(
                                   html: chapter.html,
                                   css: chapter.css,
                                   config: config,
                                   images: images,
                                   contentWidth: contentWidth,
                                   contentHeight: contentHeight
                               ) {
                                oracleDescription = try legacyOracleFailure(
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
                                ) ?? "match"
                            } else {
                                oracleDescription = "not-applicable"
                            }
                            textIndentFailures.append(
                                "book=\(bookID) spine=\(spineIndex) forced-zero differs from PRE "
                                    + "generatedFont=\(zeroEvidence.containsGeneratedFont) "
                                    + "float=\(zeroEvidence.containsFloat) "
                                    + "expected=\(expectedRow) zero=\(zeroRow) "
                                    + "repeatZero=\(String(describing: repeatedZeroRow)) "
                                    + "deterministic=\(repeatedZeroRow == Optional(zeroRow)) "
                                    + "legacyOracle=\(oracleDescription)"
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
                closureGeometryByKey[key] = closureGeometry(
                    rootBox: pipeline.rootBox,
                    sourceText: pipeline.sourceText,
                    pages: pages,
                    boxDigest: boxSnapshot.digest,
                    fragmentDigest: fragmentSnapshot.digest,
                    pageRangeDigest: row.pageRangeDigest ?? ""
                )

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
                "PHASE4E1_TEXT_INDENT_PROGRESS shard=\(shard?.label ?? "full") "
                    + "books=\(openedBookCount) "
                    + "chapters=\(rows.count - rowStart) cumulative=\(rows.count)"
            )
        }

        rows.sort {
            if $0.bookID != $1.bookID { return $0.bookID < $1.bookID }
            return $0.spineIndex < $1.spineIndex
        }
        let supported = rows.filter(\.scannerReasons.isEmpty).count
        let diagnosticFailureCount = legacyOracleFailures.count
            + textIndentFailures.count
            + presentationalHintFailures.count
        let fallbackReasonDistribution = rows.reduce(into: [String: Int]()) { result, row in
            for reason in row.scannerReasons {
                result[reason, default: 0] += 1
            }
        }
        let closureRows = rows.map { row -> ClosureCorpusRow in
            let key = RowKey(bookID: row.bookID, spineIndex: row.spineIndex)
            let metadata = closureMetadataByKey[key]
            let geometry = closureGeometryByKey[key]
            return ClosureCorpusRow(
                bookID: row.bookID,
                bookTitle: metadata?.bookTitle ?? "",
                spineIndex: row.spineIndex,
                chapterTitle: metadata?.chapterTitle ?? "",
                sourceLength: row.sourceLength,
                scannerReasons: row.scannerReasons,
                pageCount: geometry?.pageCount,
                pageRangeDigest: geometry?.pageRangeDigest,
                logicalLineCount: geometry?.logicalLineCount,
                fragmentCount: geometry?.fragmentCount,
                geometryDigest: geometry?.geometryDigest,
                containsGeneratedFont: geometry?.containsGeneratedFont ?? false,
                features: geometry?.features ?? [],
                invariantFailures: geometry?.invariantFailures ?? []
            )
        }
        let invariantViolationCount = closureRows.reduce(0) {
            $0 + $1.invariantFailures.count
        }
        return CorpusBuildResult(
            artifact: CorpusArtifact(
                schemaVersion: 1,
                bookCount: openedBookCount,
                chapterCount: rows.count,
                browserSupportedChapterCount: supported,
                fallbackChapterCount: rows.count - supported,
                rows: rows
            ),
            closureArtifact: ClosureCorpusArtifact(
                schemaVersion: 1,
                shardIndex: shard?.index,
                shardCount: shard?.count,
                bookCount: openedBookCount,
                chapterCount: rows.count,
                browserSupportedChapterCount: supported,
                fallbackChapterCount: rows.count - supported,
                fallbackReasonDistribution: fallbackReasonDistribution,
                layoutFailureCount: 0,
                diagnosticFailureCount: diagnosticFailureCount,
                invariantViolationCount: invariantViolationCount,
                rows: closureRows
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
            attributedRows: attributedRows,
            presentationalAttributeRows: presentationalAttributeRows,
            presentationalHintRows: presentationalHintRows,
            acceptedPresentationalHintRows: acceptedPresentationalHintRows,
            presentationalHintChangedRows: presentationalHintChangedRows,
            presentationalHintFailures: presentationalHintFailures,
            noPresentationalAttributeRows: noPresentationalAttributeRows
        )
    }

    private func presentationalHintUsage(in html: String) throws -> PresentationalHintUsage {
        let document = try SwiftSoup.parse(html)
        var hasRelevantAttribute = false
        var hasValidHint = false
        for image in try document.select("img").array() {
            if image.hasAttr("width") || image.hasAttr("height") {
                hasRelevantAttribute = true
            }
            if !HTMLPresentationalHintExtractor.extract(
                from: SwiftSoupHTMLSemanticAdapter.adapt(image)
            ).isEmpty {
                hasValidHint = true
            }
        }
        return PresentationalHintUsage(
            hasRelevantAttribute: hasRelevantAttribute,
            hasValidHint: hasValidHint
        )
    }

    private func identicalRowKeys(
        expected: CorpusArtifact,
        actual: CorpusArtifact
    ) -> Set<RowKey> {
        Set(zip(expected.rows, actual.rows).compactMap { expectedRow, actualRow in
            guard expectedRow == actualRow else { return nil }
            return RowKey(bookID: actualRow.bookID, spineIndex: actualRow.spineIndex)
        })
    }

    private func metadataMatches(expected: CorpusRow, actual: CorpusRow) -> Bool {
        expected.bookID == actual.bookID
            && expected.spineIndex == actual.spineIndex
            && expected.sourceLength == actual.sourceLength
            && expected.scannerReasons == actual.scannerReasons
    }

    private func presentationalHintTransitionMatches(
        expected: CorpusRow,
        actual: CorpusRow
    ) -> Bool {
        if metadataMatches(expected: expected, actual: actual) {
            return true
        }

        // A previously intrinsic-sized image can make an otherwise supported
        // float too tall for a fragmentainer. Applying its width/height hint
        // may remove precisely that post-layout fallback. Keep this allowance
        // exact: identity must match, PRE must contain no geometry, and the
        // current chapter must be fully supported with monotonic ranges (the
        // caller checks the latter). No scanner capability is relaxed.
        return expected.bookID == actual.bookID
            && expected.spineIndex == actual.spineIndex
            && expected.scannerReasons == ["layout-unsupported-float-fragmentation"]
            && expected.sourceLength == 0
            && expected.boxLineDigest == nil
            && expected.fragmentDigest == nil
            && expected.pageRangeDigest == nil
            && expected.pageCount == nil
            && actual.scannerReasons.isEmpty
            && actual.sourceLength > 0
            && actual.boxLineDigest != nil
            && actual.fragmentDigest != nil
            && actual.pageRangeDigest != nil
            && actual.pageCount != nil
    }

    private func corpusShardFromEnvironment() throws -> CorpusShard? {
        let environment = ProcessInfo.processInfo.environment
        var rawIndex = environment["YUEDU_INLINE_CONTEXT_CORPUS_SHARD"]
        var rawCount = environment["YUEDU_INLINE_CONTEXT_CORPUS_SHARD_COUNT"]
        if rawIndex == nil, rawCount == nil,
           let controlShard = try corpusShardFromControlFile() {
            rawIndex = String(controlShard.index)
            rawCount = String(controlShard.count)
        }
        guard rawIndex != nil || rawCount != nil else { return nil }
        guard let rawIndex,
              let rawCount,
              let index = Int(rawIndex),
              let count = Int(rawCount),
              count > 0,
              index >= 0,
              index < count else {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [NSLocalizedDescriptionKey:
                    "Invalid inline-context corpus shard; expected zero-based index and positive count"]
            )
        }
        return CorpusShard(index: index, count: count)
    }

    private func corpusShardFromControlFile() throws -> CorpusShard? {
        let prefix = "yuedu-inline-context-corpus-shard-"
        let matches = try FileManager.default.contentsOfDirectory(atPath: "/tmp")
            .filter { $0.hasPrefix(prefix) }
        let datedMatches = try matches.map { filename in
            let path = "/tmp/\(filename)"
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let modifiedAt = attributes[.modificationDate] as? Date ?? .distantPast
            return (filename: filename, modifiedAt: modifiedAt)
        }
        // Simulator test containers may retain a just-deleted /tmp sentinel
        // for one subsequent launch. The host guarantees one xcodebuild at a
        // time, so the most recently touched control file is authoritative.
        guard let filename = datedMatches.max(by: {
            $0.modifiedAt < $1.modifiedAt
        })?.filename else { return nil }
        let components = String(filename.dropFirst(prefix.count))
            .components(separatedBy: "-of-")
        guard components.count == 2,
              let index = Int(components[0]),
              let count = Int(components[1]),
              count > 0,
              index >= 0,
              index < count else {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [NSLocalizedDescriptionKey:
                    "Invalid inline-context corpus shard control file: \(filename)"]
            )
        }
        return CorpusShard(index: index, count: count)
    }

    private func filteredArtifact(
        _ artifact: CorpusArtifact,
        for shard: CorpusShard
    ) -> CorpusArtifact {
        let rows = artifact.rows.filter { shard.includes(spineIndex: $0.spineIndex) }
        let supported = rows.filter(\.scannerReasons.isEmpty).count
        return CorpusArtifact(
            schemaVersion: artifact.schemaVersion,
            bookCount: artifact.bookCount,
            chapterCount: rows.count,
            browserSupportedChapterCount: supported,
            fallbackChapterCount: rows.count - supported,
            rows: rows
        )
    }

    private func writeShardSummary(_ summary: CorpusShardSummary) throws {
        let url = URL(fileURLWithPath:
            "/tmp/yuedu-phase4e1-corpus-shard-\(summary.shardIndex)-of-\(summary.shardCount).json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(summary).write(to: url, options: .atomic)
    }

    private func writeClosureArtifact(
        _ artifact: ClosureCorpusArtifact,
        pass: Int,
        shard: CorpusShard?
    ) throws {
        let suffix = shard.map { "shard-\($0.index)-of-\($0.count)" } ?? "full"
        let url = URL(fileURLWithPath:
            "/tmp/yuedu-horizontal-closure-pass-\(pass)-\(suffix).json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(artifact).write(to: url, options: .atomic)
    }

    private func firstClosureDifference(
        _ first: ClosureCorpusArtifact,
        _ second: ClosureCorpusArtifact
    ) -> String {
        if first.schemaVersion != second.schemaVersion
            || first.shardIndex != second.shardIndex
            || first.shardCount != second.shardCount
            || first.bookCount != second.bookCount
            || first.chapterCount != second.chapterCount
            || first.browserSupportedChapterCount != second.browserSupportedChapterCount
            || first.fallbackChapterCount != second.fallbackChapterCount
            || first.fallbackReasonDistribution != second.fallbackReasonDistribution
            || first.layoutFailureCount != second.layoutFailureCount
            || first.diagnosticFailureCount != second.diagnosticFailureCount
            || first.invariantViolationCount != second.invariantViolationCount {
            return "artifact summary differs"
        }
        for (lhs, rhs) in zip(first.rows, second.rows) where lhs != rhs {
            return "book=\(lhs.bookID) spine=\(lhs.spineIndex) "
                + "decision=\(lhs.scannerReasons)->\(rhs.scannerReasons) "
                + "pages=\(String(describing: lhs.pageCount))->\(String(describing: rhs.pageCount)) "
                + "ranges=\(String(describing: lhs.pageRangeDigest))->"
                + "\(String(describing: rhs.pageRangeDigest)) "
                + "lines=\(String(describing: lhs.logicalLineCount))->"
                + "\(String(describing: rhs.logicalLineCount)) "
                + "fragments=\(String(describing: lhs.fragmentCount))->"
                + "\(String(describing: rhs.fragmentCount)) "
                + "geometry=\(String(describing: lhs.geometryDigest))->"
                + "\(String(describing: rhs.geometryDigest))"
        }
        return "row count differs: \(first.rows.count) -> \(second.rows.count)"
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
              original.semanticElement == zeroed.semanticElement,
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
        let closure = closureGeometry(
            rootBox: rootBox,
            sourceText: sourceText,
            pages: pages,
            boxDigest: boxDigest,
            fragmentDigest: fragmentDigest,
            pageRangeDigest: pageRangeDigest
        )
        return GeometryEvidence(
            sourceText: sourceText,
            visibleTextDigest: stableDigest(visible),
            rangesAreOrdered: BrowserLayoutTestSupport.rangesAreOrdered(pages),
            containsGeneratedFont: containsProcessGeneratedEmbeddedFont(in: rootBox),
            containsFloat: containsFloat(in: rootBox),
            boxDigest: boxDigest,
            fragmentDigest: fragmentDigest,
            pageRangeDigest: pageRangeDigest,
            pageCount: pages.count,
            closure: closure
        )
    }

    private func closureGeometry(
        rootBox: BlockBox,
        sourceText: String,
        pages: [PageFragments],
        boxDigest: String,
        fragmentDigest: String,
        pageRangeDigest: String
    ) -> ClosureGeometry {
        let logicalLineCount = countLogicalLines(in: rootBox)
        let fragmentCount = pages.reduce(0) { partial, page in
            partial + countLeafFragments(page.fragments)
        }
        let geometryDigest = stableDigest([
            boxDigest,
            fragmentDigest,
            pageRangeDigest,
            String(pages.count),
            String(logicalLineCount),
            String(fragmentCount),
        ].joined(separator: "|"))
        return ClosureGeometry(
            pageCount: pages.count,
            pageRangeDigest: pageRangeDigest,
            logicalLineCount: logicalLineCount,
            fragmentCount: fragmentCount,
            geometryDigest: geometryDigest,
            containsGeneratedFont: containsProcessGeneratedEmbeddedFont(in: rootBox),
            features: closureFeatures(rootBox: rootBox, pages: pages),
            invariantFailures: closureInvariantFailures(
                rootBox: rootBox,
                sourceText: sourceText,
                pages: pages
            )
        )
    }

    private func countLogicalLines(in box: BlockBox) -> Int {
        box.lines.count + box.children.reduce(0) { $0 + countLogicalLines(in: $1) }
    }

    private func countLeafFragments(_ fragments: [Fragment]) -> Int {
        fragments.reduce(0) { partial, fragment in
            switch fragment {
            case .group(let children):
                return partial + countLeafFragments(children)
            default:
                return partial + 1
            }
        }
    }

    private func closureFeatures(
        rootBox: BlockBox,
        pages: [PageFragments]
    ) -> [String] {
        var features = Set<String>()
        var maxDepth = 0
        var fillOccurrences: [Int: (count: Int, hasBorder: Bool)] = [:]

        func visitBox(_ box: BlockBox, depth: Int) {
            maxDepth = max(maxDepth, depth)
            if !box.lines.isEmpty { features.insert("ordinary-prose") }
            if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(box.debugTag) {
                features.insert("chapter-title")
            }
            if box.isFloated { features.insert("float") }
            if box.style.textIndent.hasPositiveSpecifiedValue {
                features.insert("text-indent")
            }
            if box.style.backgroundColor != nil || box.style.backgroundImage != nil {
                features.insert("background")
            }
            if box.imageAttachment != nil { features.insert("image") }
            for line in box.lines {
                for run in line.runs {
                    if run.atomic != nil { features.insert("image") }
                    if run.ruby != nil { features.insert("ruby") }
                }
            }
            for child in box.children { visitBox(child, depth: depth + 1) }
        }

        func visitFragments(_ fragments: [Fragment]) {
            for fragment in fragments {
                switch fragment {
                case .text:
                    break
                case .image(let image):
                    features.insert(image.isBackgroundPaint ? "background" : "image")
                case .fill(let fill):
                    let hasBorder = fill.borderTop.isVisible
                        || fill.borderRight.isVisible
                        || fill.borderBottom.isVisible
                        || fill.borderLeft.isVisible
                    let existing = fillOccurrences[fill.nodeID] ?? (0, false)
                    fillOccurrences[fill.nodeID] = (
                        existing.count + 1,
                        existing.hasBorder || hasBorder
                    )
                case .group(let children):
                    visitFragments(children)
                }
            }
        }

        visitBox(rootBox, depth: 0)
        pages.forEach { visitFragments($0.fragments) }
        if maxDepth >= 2 { features.insert("nested-block") }
        if fillOccurrences.contains(where: { entry in
            entry.key >= 0 && entry.value.count > 1 && entry.value.hasBorder
        }) {
            features.insert("bordered-fragmented-block")
        }
        return features.sorted()
    }

    private func closureInvariantFailures(
        rootBox: BlockBox,
        sourceText: String,
        pages: [PageFragments]
    ) -> [String] {
        var failures: [String] = []
        let ns = sourceText as NSString
        let epsilon: CGFloat = 0.5

        func record(_ value: String) {
            if failures.count < 32, !failures.contains(value) { failures.append(value) }
        }

        func isFinite(_ value: CGFloat) -> Bool { value.isFinite }
        func validSize(_ size: CGSize) -> Bool {
            isFinite(size.width) && isFinite(size.height)
                && size.width >= 0 && size.height >= 0
        }
        func validRect(_ rect: CGRect) -> Bool {
            isFinite(rect.minX) && isFinite(rect.minY)
                && isFinite(rect.width) && isFinite(rect.height)
                && rect.width >= 0 && rect.height >= 0
        }
        func validEdges(_ edges: EdgeSizes, allowNegative: Bool) -> Bool {
            let values = [edges.top, edges.right, edges.bottom, edges.left]
            return values.allSatisfy { isFinite($0) && (allowNegative || $0 >= 0) }
        }
        func validRange(_ range: NSRange) -> Bool {
            range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= ns.length
        }
        func onlyWhitespace(_ range: NSRange) -> Bool {
            guard validRange(range) else { return false }
            return ns.substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }

        func visitBox(_ box: BlockBox, path: String) {
            if !validRect(box.frame.rawValue) { record("box-rect:\(path)") }
            if !validSize(box.contentSize) { record("box-content-size:\(path)") }
            if !validEdges(box.margins, allowNegative: true) {
                record("box-margin:\(path)")
            }
            if !validEdges(box.padding, allowNegative: false) {
                record("box-padding:\(path)")
            }
            if !validEdges(box.borders, allowNegative: false) {
                record("box-border:\(path)")
            }
            if abs(box.frame.width - box.borderBoxWidth) > epsilon {
                record("box-inline-geometry:\(path)")
            }
            let expectedHeight = box.borders.vertical
                + box.padding.vertical
                + box.contentSize.height
            if abs(box.frame.height - expectedHeight) > epsilon {
                record("box-block-geometry:\(path)")
            }
            if !box.lines.isEmpty && box.contentSize.width <= 0 {
                record("inline-available-width:\(path)")
            }

            for (lineIndex, line) in box.lines.enumerated() {
                let linePath = "\(path).l\(lineIndex)"
                if ![line.top, line.baseline, line.height, line.ascent,
                     line.descent, line.contentX].allSatisfy(\.isFinite)
                    || line.height <= 0 || line.ascent < 0 || line.descent < 0 {
                    record("line-metrics:\(linePath)")
                }
                var lineCursor = -1
                for (runIndex, run) in line.runs.enumerated() {
                    if !validRange(run.sourceRange) {
                        record("line-source-range:\(linePath).r\(runIndex)")
                    }
                    if run.sourceRange.length > 0 && run.sourceRange.location < lineCursor {
                        record("line-source-order:\(linePath)")
                    }
                    lineCursor = max(lineCursor, NSMaxRange(run.sourceRange))
                    if !run.x.isFinite || !run.width.isFinite || run.width < 0 {
                        record("line-run-geometry:\(linePath).r\(runIndex)")
                    }
                    if let ruby = run.ruby {
                        if !validRange(ruby.unit.sourceRange)
                            || ruby.unit.sourceRange != run.sourceRange {
                            record("ruby-atomic-range:\(linePath).r\(runIndex)")
                        }
                        let baseStart = ruby.unit.base.first?.sourceRange.location
                        let baseEnd = ruby.unit.base.last.map { NSMaxRange($0.sourceRange) }
                        if baseStart != ruby.unit.sourceRange.location
                            || baseEnd != NSMaxRange(ruby.unit.sourceRange) {
                            record("ruby-base-mapping:\(linePath).r\(runIndex)")
                        }
                    }
                }
            }

            if case .block = box.boxType, box.style.textIndent.hasPositiveSpecifiedValue {
                let anonymousChildren = box.children.filter {
                    if case .anonymous = $0.boxType { return true }
                    return false
                }
                let ownedLineBoxes = ([box] + anonymousChildren)
                    .filter { !$0.lines.isEmpty && $0.ownsFirstFormattedLine }
                let formattedLineBoxes = ([box] + anonymousChildren)
                    .filter { !$0.lines.isEmpty }
                if !formattedLineBoxes.isEmpty && ownedLineBoxes.count != 1 {
                    record("text-indent-first-line-owner:\(path)")
                }
            }

            for (index, child) in box.children.enumerated() {
                if child.parentBox !== box { record("box-parent-link:\(path).\(index)") }
                visitBox(child, path: "\(path).\(index)")
            }
        }
        visitBox(rootBox, path: "0")

        var rubyRanges = Set<String>()
        func collectRubyRanges(_ box: BlockBox) {
            for line in box.lines {
                for run in line.runs where run.ruby != nil {
                    rubyRanges.insert("\(run.sourceRange.location):\(run.sourceRange.length)")
                }
            }
            box.children.forEach(collectRubyRanges)
        }
        collectRubyRanges(rootBox)

        let pageCanvas = CGRect(origin: .zero, size: Self.viewport)
        func validateFragment(_ fragment: Fragment, page: Int, path: String) {
            let rect: CGRect
            switch fragment {
            case .text(let text):
                rect = text.rect.rawValue
                if !validRange(text.sourceRange) {
                    record("fragment-source-range:p\(page).\(path)")
                }
                if case .wholeRange = text.sourceMapping,
                   !rubyRanges.contains("\(text.sourceRange.location):\(text.sourceRange.length)") {
                    record("ruby-fragment-mapping:p\(page).\(path)")
                }
                if !text.baselineY.isFinite { record("fragment-baseline:p\(page).\(path)") }
            case .fill(let fill):
                rect = fill.rect.rawValue
                switch fill.fragmentPosition {
                case .single:
                    break
                case .first:
                    if fill.borderBottom.isVisible {
                        record("fragmented-border-first:p\(page).\(path)")
                    }
                case .middle:
                    if fill.borderTop.isVisible || fill.borderBottom.isVisible {
                        record("fragmented-border-middle:p\(page).\(path)")
                    }
                case .last:
                    if fill.borderTop.isVisible {
                        record("fragmented-border-last:p\(page).\(path)")
                    }
                }
            case .image(let image):
                rect = image.rect.rawValue
                if image.isBackgroundPaint {
                    if rect != pageCanvas { record("background-page-canvas:p\(page).\(path)") }
                    return
                }
                if !validRange(image.sourceRange) {
                    record("image-source-range:p\(page).\(path)")
                }
            case .group(let children):
                for (index, child) in children.enumerated() {
                    validateFragment(child, page: page, path: "\(path).\(index)")
                }
                return
            }
            if !validRect(rect) { record("fragment-rect:p\(page).\(path)") }
            if rect.minY < -epsilon || rect.maxY > Self.viewport.height + epsilon {
                record("fragment-page-canvas:p\(page).\(path)")
            }
        }

        for (pageIndex, page) in pages.enumerated() {
            if page.index != pageIndex { record("page-index:p\(pageIndex)") }
            if page.pageRect.rawValue != pageCanvas { record("page-canvas:p\(pageIndex)") }
            for (index, fragment) in page.fragments.enumerated() {
                validateFragment(fragment, page: pageIndex, path: String(index))
            }
        }

        var sourceCursor = 0
        func validateLinearSource(_ fragments: [Fragment]) {
            for fragment in fragments {
                switch fragment {
                case .text(let text):
                    guard case .linear = text.sourceMapping,
                          text.sourceRange.length > 0 else { continue }
                    let range = text.sourceRange
                    guard validRange(range) else { continue }
                    if range.location < sourceCursor {
                        record("source-range-overlap")
                    } else if range.location > sourceCursor,
                              !onlyWhitespace(NSRange(
                                location: sourceCursor,
                                length: range.location - sourceCursor
                              )) {
                        record("source-range-gap")
                    }
                    sourceCursor = max(sourceCursor, NSMaxRange(range))
                case .group(let children):
                    validateLinearSource(children)
                default:
                    continue
                }
            }
        }
        pages.forEach { validateLinearSource($0.fragments) }
        if sourceCursor < ns.length,
           !onlyWhitespace(NSRange(location: sourceCursor, length: ns.length - sourceCursor)) {
            record("source-tail-gap")
        }

        let pageRanges = BrowserChapterLayout.buildPageRanges(pages, sourceText: sourceText)
        var previousEnd = 0
        for range in pageRanges where range.length > 0 {
            if !validRange(range) { record("page-source-range") }
            if range.location < previousEnd {
                record("page-source-overlap")
            } else if range.location > previousEnd,
                      !onlyWhitespace(NSRange(
                        location: previousEnd,
                        length: range.location - previousEnd
                      )) {
                record("page-source-gap")
            }
            previousEnd = max(previousEnd, NSMaxRange(range))
        }
        if previousEnd < ns.length,
           !onlyWhitespace(NSRange(location: previousEnd, length: ns.length - previousEnd)) {
            record("page-source-tail-gap")
        }

        return failures.sorted()
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

    /// Same-process differential oracle for PRE rows whose process-sensitive
    /// resource/font state cannot be reproduced across corpus shards. It
    /// recreates the old no-float ordering (shape all inline runs during tree
    /// construction, then place the preformatted lines) without exposing a
    /// legacy mode in production BlockLayout. Callers separately require PRE
    /// source/page-range parity and reject every floated chapter.
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

}
