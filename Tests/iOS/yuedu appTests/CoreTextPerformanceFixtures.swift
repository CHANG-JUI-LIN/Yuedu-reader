import Foundation
import SwiftSoup
import Testing
@testable import yuedu_app

enum CoreTextPerformanceFixtures {
    struct Fixture {
        let id: String
        let html: String
        let minimumTextCharacters: Int
        let minimumElementCount: Int
        let expectedCSSRuleCount: Int
        let expectedImageCount: Int
        let simulatedResourceLatencyMilliseconds: Int
    }

    static let plain10K = Fixture(
        id: "plain-10k",
        html: document(
            title: "Plain 10K",
            body: paragraphs(
                minimumCharacters: 10_240,
                unit: "天地玄黃，宇宙洪荒。日月盈昃，辰宿列張。"
            )
        ),
        minimumTextCharacters: 10_240,
        minimumElementCount: 40,
        expectedCSSRuleCount: 0,
        expectedImageCount: 0,
        simulatedResourceLatencyMilliseconds: 0
    )

    static let plain100K = Fixture(
        id: "plain-100k",
        html: document(
            title: "Plain 100K",
            body: paragraphs(
                minimumCharacters: 102_400,
                unit: "讀書使人充實，思考使人深邃，交談使人清醒。"
            )
        ),
        minimumTextCharacters: 102_400,
        minimumElementCount: 400,
        expectedCSSRuleCount: 0,
        expectedImageCount: 0,
        simulatedResourceLatencyMilliseconds: 0
    )

    static let cssHeavy50K: Fixture = {
        let ruleCount = 300
        let elementCount = 1_000
        let rules = (0..<ruleCount).map { index in
            """
            .c\(index) {
              color: rgb(\(index % 255), \((index * 3) % 255), \((index * 7) % 255));
              margin-left: \(index % 8)px;
              line-height: \(120 + index % 40)%;
            }
            """
        }.joined(separator: "\n")
        let payload = String(
            repeating: "層疊樣式應只匹配候選規則並保持來源順序。",
            count: 3
        )
        let body = (0..<elementCount).map { index in
            #"<p id="e\#(index)" class="c\#(index % ruleCount)">\#(payload)</p>"#
        }.joined(separator: "\n")
        return Fixture(
            id: "css-heavy-50k",
            html: document(
                title: "CSS Heavy 50K",
                head: "<style>\(rules)</style>",
                body: body
            ),
            minimumTextCharacters: 50_000,
            minimumElementCount: elementCount,
            expectedCSSRuleCount: ruleCount,
            expectedImageCount: 0,
            simulatedResourceLatencyMilliseconds: 0
        )
    }()

    static let image40: Fixture = {
        let body = (0..<40).map { index in
            """
            <figure>
              <img src="fixture-image-\(index).png"
                   width="\(160 + index % 4 * 40)"
                   height="\(120 + index % 5 * 30)"
                   alt="Fixture image \(index)"/>
              <figcaption>Image fixture \(index)</figcaption>
            </figure>
            """
        }.joined(separator: "\n")
        return Fixture(
            id: "image-40",
            html: document(title: "Image 40", body: body),
            minimumTextCharacters: 600,
            minimumElementCount: 120,
            expectedCSSRuleCount: 0,
            expectedImageCount: 40,
            simulatedResourceLatencyMilliseconds: 0
        )
    }()

    static let verticalCJK50K: Fixture = {
        let paragraph = """
        <p>「直排標點，應維持禁則。」Latin 2026
        <ruby>漢<rt>hàn</rt></ruby><ruby>字<rt>zì</rt></ruby>
        旁註與英文數字共同排版。</p>
        """
        let body = String(repeating: paragraph, count: 1_300)
        return Fixture(
            id: "vertical-cjk-50k",
            html: document(
                title: "Vertical CJK 50K",
                head: "<style>html, body { writing-mode: vertical-rl; }</style>",
                body: body
            ),
            minimumTextCharacters: 50_000,
            minimumElementCount: 5_000,
            expectedCSSRuleCount: 2,
            expectedImageCount: 0,
            simulatedResourceLatencyMilliseconds: 0
        )
    }()

    static let mixedEPUB = Fixture(
        id: "mixed-epub",
        html: document(
            title: "Mixed EPUB",
            head: """
            <style>
              .float { float: left; width: 35%; margin: 8px; }
              .panel { border: 2px solid #555; background: #eee; padding: 12px; }
              table { width: 100%; }
            </style>
            """,
            body: """
            <section class="panel">
              <h1>Mixed layout fixture</h1>
              <img class="float" src="fixture-float.png" alt="Float"/>
              <p>Text wraps around a floated illustration and continues across several lines.</p>
              <p><ruby>閱讀<rt>yuè dú</rt></ruby> includes ruby annotations.</p>
              <table>
                <tr><th>Column A</th><th>Column B</th></tr>
                <tr><td>Alpha</td><td>Beta</td></tr>
              </table>
              <math xmlns="http://www.w3.org/1998/Math/MathML">
                <mrow><mi>x</mi><mo>=</mo><mn>42</mn></mrow>
              </math>
              <svg xmlns="http://www.w3.org/2000/svg" width="120" height="60">
                <rect width="120" height="60" fill="#888"/>
              </svg>
              <aside epub:type="footnote" id="note-1"><p>A synthetic footnote.</p></aside>
            </section>
            """
        ),
        minimumTextCharacters: 140,
        minimumElementCount: 23,
        expectedCSSRuleCount: 3,
        expectedImageCount: 1,
        simulatedResourceLatencyMilliseconds: 0
    )

    static let onlineLatency = Fixture(
        id: "online-latency",
        html: document(
            title: "Online Latency",
            body: (0..<8).map { index in
                """
                <article>
                  <h2>Remote section \(index)</h2>
                  <img src="fixture-remote-\(index).png" alt="Remote \(index)"/>
                  <p>Resource loading is deterministic while the fake loader applies latency.</p>
                </article>
                """
            }.joined(separator: "\n")
        ),
        minimumTextCharacters: 600,
        minimumElementCount: 32,
        expectedCSSRuleCount: 0,
        expectedImageCount: 8,
        simulatedResourceLatencyMilliseconds: 50
    )

    static let all: [Fixture] = [
        plain10K,
        plain100K,
        cssHeavy50K,
        image40,
        verticalCJK50K,
        mixedEPUB,
        onlineLatency,
    ]

    private static func document(
        title: String,
        head: String = "",
        body: String
    ) -> String {
        """
        <!doctype html>
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops">
          <head>
            <meta charset="utf-8"/>
            <title>\(title)</title>
            \(head)
          </head>
          <body>\(body)</body>
        </html>
        """
    }

    private static func paragraphs(
        minimumCharacters: Int,
        unit: String,
        paragraphCharacters: Int = 256
    ) -> String {
        precondition(minimumCharacters > 0)
        precondition(!unit.isEmpty)
        let repetitions = max(1, (paragraphCharacters + unit.count - 1) / unit.count)
        let paragraph = String(String(repeating: unit, count: repetitions).prefix(paragraphCharacters))
        let paragraphCount = (minimumCharacters + paragraph.count - 1) / paragraph.count
        return String(repeating: "<p>\(paragraph)</p>\n", count: paragraphCount)
    }
}

enum CoreTextLargeEPUBCorpus {
    struct Book {
        let id: String
        let expectedSizeMiB: Int
        let environmentKey: String
        let expectedByteRange: ClosedRange<Int64>
    }

    static let books: [Book] = [
        Book(
            id: "large-epub-160m",
            expectedSizeMiB: 161,
            environmentKey: "YUEDU_PERF_EPUB_160_PATH",
            expectedByteRange: bytes(150)...bytes(175)
        ),
        Book(
            id: "large-epub-224m",
            expectedSizeMiB: 224,
            environmentKey: "YUEDU_PERF_EPUB_224_PATH",
            expectedByteRange: bytes(210)...bytes(240)
        ),
    ]

    static func configuredURL(
        for book: Book,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let path = environment[book.environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func isMaterialized(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
        ])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            return false
        }
        let allocatedSize = values.totalFileAllocatedSize
            ?? values.fileAllocatedSize
            ?? 0
        return allocatedSize > 0
    }

    private static func bytes(_ mebibytes: Int) -> Int64 {
        Int64(mebibytes) * 1_048_576
    }
}

@Suite("CoreText performance fixtures")
struct CoreTextPerformanceFixtureTests {

    @Test("fixture identifiers are stable and unique")
    func fixtureIdentifiersAreStableAndUnique() {
        let expected = Set([
            "plain-10k",
            "plain-100k",
            "css-heavy-50k",
            "image-40",
            "vertical-cjk-50k",
            "mixed-epub",
            "online-latency",
        ])

        #expect(Set(CoreTextPerformanceFixtures.all.map(\.id)) == expected)
    }

    @Test("fixtures meet their declared text element image and CSS scale")
    func fixturesMeetDeclaredScale() throws {
        for fixture in CoreTextPerformanceFixtures.all {
            let document = try SwiftSoup.parse(fixture.html)
            let body = try #require(document.body())
            let textCount = try body.text().utf16.count
            let elementCount = try body.select("*").array().count
            let imageCount = try body.select("img").array().count
            let styleText = try document.select("style").array()
                .map { try $0.html() }
                .joined(separator: "\n")
            let parsedRules = CSSParser.parseWithFirstLetter(css: styleText)

            #expect(
                textCount >= fixture.minimumTextCharacters,
                "\(fixture.id) text count \(textCount)"
            )
            #expect(
                elementCount >= fixture.minimumElementCount,
                "\(fixture.id) element count \(elementCount)"
            )
            #expect(
                imageCount == fixture.expectedImageCount,
                "\(fixture.id) image count \(imageCount)"
            )
            #expect(
                parsedRules.regular.count + parsedRules.firstLetter.count
                    == fixture.expectedCSSRuleCount,
                "\(fixture.id) CSS rule count"
            )
        }
    }

    @Test("fixtures are self-contained and never fetch public network URLs")
    func fixturesAreSelfContained() throws {
        for fixture in CoreTextPerformanceFixtures.all {
            let document = try SwiftSoup.parse(fixture.html)
            let resources = try document.select("[src], [href]").array()
            for element in resources {
                let source = try element.hasAttr("src")
                    ? element.attr("src")
                    : element.attr("href")
                #expect(!source.hasPrefix("http://"))
                #expect(!source.hasPrefix("https://"))
            }
        }
    }
}

@Suite("CoreText large EPUB performance corpus")
struct CoreTextLargeEPUBCorpusTests {

    @Test("corpus descriptors use stable content-free identifiers")
    func descriptorsUseStableIdentifiers() {
        #expect(
            CoreTextLargeEPUBCorpus.books.map(\.id)
                == ["large-epub-160m", "large-epub-224m"]
        )
        #expect(
            CoreTextLargeEPUBCorpus.books.map(\.expectedSizeMiB)
                == [161, 224]
        )
        #expect(
            CoreTextLargeEPUBCorpus.books.map(\.environmentKey)
                == ["YUEDU_PERF_EPUB_160_PATH", "YUEDU_PERF_EPUB_224_PATH"]
        )
    }

    @Test("corpus paths resolve only from explicit environment configuration")
    func pathsResolveFromEnvironment() {
        let environment = [
            "YUEDU_PERF_EPUB_160_PATH": "/tmp/large-160.epub",
            "YUEDU_PERF_EPUB_224_PATH": "/tmp/large-224.epub",
        ]

        #expect(
            CoreTextLargeEPUBCorpus.configuredURL(
                for: CoreTextLargeEPUBCorpus.books[0],
                environment: environment
            )?.path == "/tmp/large-160.epub"
        )
        #expect(
            CoreTextLargeEPUBCorpus.configuredURL(
                for: CoreTextLargeEPUBCorpus.books[1],
                environment: environment
            )?.path == "/tmp/large-224.epub"
        )
        #expect(
            CoreTextLargeEPUBCorpus.configuredURL(
                for: CoreTextLargeEPUBCorpus.books[0],
                environment: [:]
            ) == nil
        )
    }

    @Test("configured local books match their registered size bands")
    func configuredBooksMatchSizeBands() throws {
        var configuredBookCount = 0
        for book in CoreTextLargeEPUBCorpus.books {
            guard let url = CoreTextLargeEPUBCorpus.configuredURL(for: book) else {
                continue
            }
            configuredBookCount += 1
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            let byteSize = try #require(values.fileSize)
            #expect(
                book.expectedByteRange.contains(Int64(byteSize)),
                "\(book.id) measured \(byteSize) bytes"
            )
            #expect(
                try CoreTextLargeEPUBCorpus.isMaterialized(url),
                "\(book.id) must be downloaded before benchmarking"
            )
        }
        if ProcessInfo.processInfo.environment["YUEDU_REQUIRE_LARGE_EPUB_CORPUS"] == "1" {
            #expect(configuredBookCount == CoreTextLargeEPUBCorpus.books.count)
        }
    }
}
