import SwiftSoup
import Testing
import UIKit
@testable import yuedu_app

@MainActor
struct BrowserLayoutRubyCorpusTests {
    private struct ExpectedBook {
        let fileName: String
        let rubyChapterCount: Int
        let rubyUnitCount: Int
    }

    private let expected = [
        ExpectedBook(
            fileName: "《全知读者视角01》sing N song(싱숑)著[Hooshaun制作].epub",
            rubyChapterCount: 12,
            rubyUnitCount: 14
        ),
        ExpectedBook(
            fileName: "《全职高手3》作者：蝴蝶蓝.epub",
            rubyChapterCount: 2,
            rubyUnitCount: 2
        ),
        ExpectedBook(
            fileName: "《全能游戏设计师1》作者：冷陌 & 青衫取醉.epub",
            rubyChapterCount: 21,
            rubyUnitCount: 45
        ),
        ExpectedBook(
            fileName: "《诡秘之主4》作者：爱潜水的乌贼.epub",
            rubyChapterCount: 40,
            rubyUnitCount: 552
        ),
    ]

    @Test(
        "validate Phase 4D horizontal Ruby corpus",
        .enabled(if:
            ProcessInfo.processInfo.environment["YUEDU_RUN_RUBY_CORPUS"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/yuedu-run-ruby-corpus")
        )
    )
    func validateHorizontalRubyCorpus() async throws {
        let root = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["YUEDU_REAL_EPUB_DIR"]
                ?? "/Users/zhangruilin/Desktop/Test document/EPUB Format"
        )
        var aggregateChapters = 0
        var aggregateUnits = 0

        for book in expected {
            let session = try await PublicationSession.open(
                sourceURL: root.appendingPathComponent(book.fileName)
            )
            #expect(session.epubWritingMode != .verticalRL)
            let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
            var chapterCount = 0
            var domUnitCount = 0
            var fragmentUnitCount = 0

            for index in session.chapters.indices {
                let html = try await adapter.chapterHTML(at: index)
                let dom = try SwiftSoup.parse(html)
                let domRubies = try dom.select("ruby").array()
                guard !domRubies.isEmpty else { continue }

                chapterCount += 1
                domUnitCount += domRubies.count
                let css = await adapter.processedCSS(forChapter: index)
                let config = BrowserLayoutConfig(
                    renderWidth: 320,
                    renderHeight: 480,
                    rootFontSize: 17,
                    fontFamilies: ["PingFangSC-Regular"],
                    textColor: .black,
                    backgroundColor: .white
                )
                let scan = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: css)
                guard !scan.unsupportedFeatures.contains(.ruby) else {
                    var metrics = LayoutMetrics()
                    let styleTree = try LegacyCSSFrontend().buildStyleTree(
                        html: html,
                        cssTexts: css,
                        config: config,
                        metrics: &metrics
                    ).rootNode
                    let diagnostic = rubyDiagnostics(in: styleTree)
                    Issue.record(
                        "Unsupported Ruby in \(book.fileName), chapter \(index) (\(session.chapters[index].href)): \(diagnostic)"
                    )
                    return
                }
                let document = BrowserLayoutDocument(html: html, cssTexts: css, config: config)
                let pipeline = try document.makeLayout(
                    containerSize: CGSize(width: 320, height: 480),
                    fragmentHeight: 480
                )
                let modelUnits = BrowserLayoutRubyTestProbe.rubyBoxes(in: pipeline.rootBox)
                #expect(modelUnits.count == domRubies.count)

                let pages = PageFragmentation.fragment(
                    box: pipeline.rootBox,
                    pageSize: CGSize(width: 320, height: 480)
                )
                let annotationFragments = BrowserLayoutTestSupport.allTextFragments(pages).filter {
                    $0.sourceMapping == .wholeRange
                }
                #expect(annotationFragments.count == domRubies.count)
                #expect(annotationFragments.allSatisfy { fragment in
                    fragment.rect.width.isFinite && fragment.rect.height.isFinite
                        && fragment.rect.width > 0 && fragment.rect.height > 0
                        && fragment.renderedTextOverride?.isEmpty == false
                })
                fragmentUnitCount += annotationFragments.count
            }

            #expect(chapterCount == book.rubyChapterCount)
            #expect(domUnitCount == book.rubyUnitCount)
            #expect(fragmentUnitCount == book.rubyUnitCount)
            aggregateChapters += chapterCount
            aggregateUnits += fragmentUnitCount
        }

        #expect(expected.count == 4)
        #expect(aggregateChapters == 75)
        #expect(aggregateUnits == 613)
    }

    private func rubyDiagnostics(in root: ComputedStyleNode) -> String {
        var rubies: [ComputedStyleNode] = []
        func collect(_ node: ComputedStyleNode) {
            if node.tag == "ruby" { rubies.append(node) }
            for child in node.children {
                guard case .element(let element) = child else { continue }
                collect(element)
            }
        }
        collect(root)

        func describe(_ node: ComputedStyleNode, depth: Int) -> [String] {
            let indent = String(repeating: "  ", count: depth)
            let markup: String
            if let element = node.element {
                markup = (try? element.outerHtml()) ?? "<unavailable>"
            } else {
                markup = "<synthetic>"
            }
            var result = [
                "\(indent)<\(node.tag)> display=\(node.style.display) "
                    + "float=\(node.style.isFloated) align=\(node.style.rubyAlign) "
                    + "position=\(node.style.rubyPosition) merge=\(node.style.rubyMerge) "
                    + "markup=\(markup)",
            ]
            for child in node.children {
                switch child {
                case .text(let text):
                    result.append("\(indent)  #text=\(text.debugDescription)")
                case .element(let element):
                    result.append(contentsOf: describe(element, depth: depth + 1))
                }
            }
            return result
        }

        return rubies.flatMap { describe($0, depth: 0) }.joined(separator: " | ")
    }
}
