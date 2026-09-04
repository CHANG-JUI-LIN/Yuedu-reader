import Foundation
import Testing
@testable import yuedu_app

@MainActor
struct BrowserLayoutVisualAcceptanceCorpusTests {
    private struct Candidate: Codable {
        let bookTitle: String
        let fileName: String
        let spineIndex: Int
        let chapterTitle: String
        let href: String
        let computedTextIndent: [String]
        let containsFloat: Bool
        let containsRuby: Bool
        let browserLayoutSupported: Bool
        let unsupportedFeatures: [String]
    }

    @Test(
        "validate Phase 4E1 visual acceptance chapters with production computed style",
        .enabled(if: FileManager.default.fileExists(
            atPath: "/tmp/yuedu-run-phase4e1-visual-census"
        ))
    )
    func validateVisualAcceptanceChapters() async throws {
        let directory = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["YUEDU_REAL_EPUB_DIR"]
                ?? "/Users/zhangruilin/Desktop/Test document/EPUB Format"
        )
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expected: [(
            url: URL, fileName: String, spineIndex: Int,
            bookTitle: String, chapterTitle: String, href: String,
            indents: [String], hasFloat: Bool, hasRuby: Bool
        )] = [
            (
                directory.appendingPathComponent(
                    "《全知读者视角01》sing N song(싱숑)著[Hooshaun制作].epub"
                ),
                "《全知读者视角01》sing N song(싱숑)著[Hooshaun制作].epub",
                3, "全知读者视角01", "样式介绍", "OEBPS/Text/intro.xhtml",
                ["2em"], false, false
            ),
            (
                directory.appendingPathComponent("《诡秘之主4》作者：爱潜水的乌贼.epub"),
                "《诡秘之主4》作者：爱潜水的乌贼.epub",
                68, "诡秘之主", "非凡物品 封印物品", "OEBPS/Text/ffwp001.xhtml",
                ["1em", "2em"], true, false
            ),
            (
                directory.appendingPathComponent(
                    "《全能游戏设计师1》作者：冷陌 & 青衫取醉.epub"
                ),
                "《全能游戏设计师1》作者：冷陌 & 青衫取醉.epub",
                58, "全能游戏设计师", "第50章 赌得太大了！",
                "OEBPS/Text/_****:**:*::*::*:*:*:::::***:***::*:*:*:*:*:::::*:*::::*::***:*:.xhtml",
                ["2em"], false, true
            ),
            (
                repoRoot.appendingPathComponent(
                    "docs/epub-regression/samples/nav-xhtml-basic.epub"
                ),
                "nav-xhtml-basic.epub",
                0, "Nav XHTML Basic", "Chapter One", "EPUB/Text/chapter-1.xhtml",
                [], false, false
            ),
        ]

        var selected: [Candidate] = []
        for item in expected {
            let result = try await candidate(
                url: item.url,
                fileName: item.fileName,
                spineIndex: item.spineIndex
            )
            #expect(result.bookTitle == item.bookTitle)
            #expect(result.chapterTitle == item.chapterTitle)
            #expect(result.href == item.href)
            #expect(result.computedTextIndent == item.indents)
            #expect(result.containsFloat == item.hasFloat)
            #expect(result.containsRuby == item.hasRuby)
            #expect(result.browserLayoutSupported)
            #expect(result.unsupportedFeatures.isEmpty)
            selected.append(result)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(selected)
        print("PHASE4E1_VISUAL_ACCEPTANCE\n\(String(decoding: data, as: UTF8.self))")
    }

    private func candidate(
        url: URL,
        fileName: String,
        spineIndex: Int
    ) async throws -> Candidate {
        let session = try await PublicationSession.open(sourceURL: url)
        let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
        let html = try await adapter.chapterHTML(at: spineIndex)
        let css = await adapter.processedCSS(forChapter: spineIndex)
        let scan = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: css)
        var metrics = LayoutMetrics()
        let root = try LegacyCSSFrontend().buildStyleTree(
            html: html,
            cssTexts: css,
            config: BrowserLayoutConfig(),
            metrics: &metrics
        ).rootNode
        return Candidate(
            bookTitle: session.bookTitle,
            fileName: fileName,
            spineIndex: spineIndex,
            chapterTitle: session.chapters[spineIndex].title,
            href: session.chapters[spineIndex].href,
            computedTextIndent: computedTextIndents(in: root),
            containsFloat: containsFloat(in: root),
            containsRuby: containsRuby(in: root),
            browserLayoutSupported: scan.supported,
            unsupportedFeatures: scan.unsupportedFeatures.map(\.description).sorted()
        )
    }

    private func computedTextIndents(in root: ComputedStyleNode) -> [String] {
        var values = Set<String>()
        walk(root) { node in
            guard node.style.display == .block,
                  ownsInlineFormattingContent(node) else { return }
            if case .length(let length) = node.style.textIndent,
               let description = positiveDescription(length) {
                values.insert(description)
            }
        }
        return values.sorted()
    }

    private func ownsInlineFormattingContent(_ node: ComputedStyleNode) -> Bool {
        node.children.contains { child in
            switch child {
            case .text(let text):
                return text.contains { !$0.isWhitespace }
            case .element(let element):
                guard element.style.display != .none,
                      element.style.display != .block,
                      !element.style.isFloated else { return false }
                if ["br", "img", "svg", "ruby"].contains(element.tag) {
                    return true
                }
                return ownsInlineFormattingContent(element)
            }
        }
    }

    private func positiveDescription(_ length: CSSLength) -> String? {
        switch length {
        case .px(let value) where value > 0: return "\(compact(value))px"
        case .pt(let value) where value > 0: return "\(compact(value))pt"
        case .em(let value) where value > 0: return "\(compact(value))em"
        case .rem(let value) where value > 0: return "\(compact(value))rem"
        case .percent(let value) where value > 0: return "\(compact(value * 100))%"
        default: return nil
        }
    }

    private func compact(_ value: CGFloat) -> String {
        value.rounded() == value ? String(Int(value)) : String(Double(value))
    }

    private func containsFloat(in root: ComputedStyleNode) -> Bool {
        var result = false
        walk(root) { result = result || $0.style.isFloated }
        return result
    }

    private func containsRuby(in root: ComputedStyleNode) -> Bool {
        var result = false
        walk(root) { result = result || $0.tag == "ruby" }
        return result
    }

    private func walk(
        _ node: ComputedStyleNode,
        visit: (ComputedStyleNode) -> Void
    ) {
        visit(node)
        for child in node.children {
            guard case .element(let element) = child else { continue }
            walk(element, visit: visit)
        }
    }
}
