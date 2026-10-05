import Foundation
import Testing
@testable import yuedu_app

@Suite("Aozora source map")
struct AozoraSourceMapTests {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/TXTEncodings/aozora-neko-jijo.txt")

    @Test("the displayed text is the header, body and colophon blocks joined by line breaks")
    func displayedTextIsTheBlocks() throws {
        for text in [try TXTFileReader.readTextFile(url: Self.fixture), Self.sample] {
            let document = AozoraDocumentParser.parse(text)
            let blocks = document.headerBlocks + document.body + document.colophon
            #expect(document.displayedText == blocks.map(\.displayedText).joined(separator: "\n"))
            #expect(document.sourceMap.displayedLength == document.displayedText.utf16.count)
            #expect(document.sourceMap.sourceLength == text.utf16.count)
        }
    }

    @Test("every token boundary of the public-domain download round-trips")
    func fixtureRoundTrip() throws {
        let text = try TXTFileReader.readTextFile(url: Self.fixture)
        let document = AozoraDocumentParser.parse(text)
        let map = document.sourceMap
        let units = Array(text.utf16)
        let displayed = Array(document.displayedText.utf16)
        let tokens = AozoraTokenizer.tokenize(text)
        for boundary in tokens.map(\.range.lowerBound) + [units.count] {
            let shown = map.displayedOffset(forSource: boundary)
            #expect(map.displayedOffset(forSource: map.sourceOffset(forDisplayed: shown)) == shown)
        }
        // Text in the body comes back to exactly where it was, offset by offset.
        let body = AozoraSource(text).range(ofLines: document.structure.body)
        for token in tokens where token.kind == .text && body.contains(token.range.lowerBound) {
            for offset in token.range {
                let shown = map.displayedOffset(forSource: offset)
                #expect(map.sourceOffset(forDisplayed: shown) == offset)
                #expect(displayed[shown] == units[offset])
            }
        }
        // Copied runs really are copies.
        for run in map.runs where run.isIdentity {
            #expect(displayed[run.displayedStart..<(run.displayedStart + run.displayedLength)]
                .elementsEqual(units[run.sourceStart..<(run.sourceStart + run.sourceLength)]))
        }
    }

    @Test("both directions are monotonic")
    func monotonic() throws {
        for text in [try TXTFileReader.readTextFile(url: Self.fixture), Self.sample] {
            let map = AozoraDocumentParser.parse(text).sourceMap
            var previous = 0
            for offset in 0...map.sourceLength {
                let shown = map.displayedOffset(forSource: offset)
                #expect(shown >= previous)
                previous = shown
            }
            previous = 0
            for offset in 0...map.displayedLength {
                let origin = map.sourceOffset(forDisplayed: offset)
                #expect(origin >= previous)
                previous = origin
            }
        }
    }

    @Test("a gaiji outside the BMP replaces its annotation")
    func wideGaiji() {
        let text = "題\n\n前※［＃「てへん＋劣」、第4水準2-1-1］後"
        let document = AozoraDocumentParser.parse(text)
        #expect(document.displayedText == "題\n\n前\u{20089}後")
        let map = document.sourceMap
        let gaiji = (text as NSString).range(of: "※").location
        let after = (text as NSString).range(of: "後").location
        #expect(map.displayedOffset(forSource: gaiji) == 4)
        #expect(map.displayedOffset(forSource: gaiji + 3) == 4)
        #expect(map.displayedOffset(forSource: after) == 6)
        #expect(map.sourceOffset(forDisplayed: 4) == gaiji)
        #expect(map.sourceOffset(forDisplayed: 5) == gaiji)
        #expect(map.sourceOffset(forDisplayed: 6) == after)
    }

    @Test("a run that grows: one character becomes a pair outside the BMP")
    func growingRun() throws {
        let text = "題\n\n前Ａ［＃「Ａ」は試験、第4水準2-1-1］後"
        let document = AozoraDocumentParser.parse(text)
        #expect(document.displayedText == "題\n\n前\u{20089}後")
        let map = document.sourceMap
        let letter = (text as NSString).range(of: "Ａ").location
        let after = (text as NSString).range(of: "後").location
        let grown = try #require(map.runs.first { $0.sourceStart == letter })
        #expect(grown.sourceLength == 1)
        #expect(grown.displayedLength == 2)
        #expect(map.sourceOffset(forDisplayed: 5) == letter)
        #expect(map.displayedOffset(forSource: letter + 1) == 6)
        #expect(map.displayedOffset(forSource: after) == 6)
    }

    @Test("deleted markup maps to where the next shown text begins")
    func deletions() {
        let text = "題\r\n\r\n前｜漢字《かんじ》［＃「漢字」に傍点］後"
        let document = AozoraDocumentParser.parse(text)
        #expect(document.displayedText == "題\n\n前漢字後")
        let map = document.sourceMap
        let units = text as NSString
        #expect(map.displayedOffset(forSource: units.range(of: "｜").location) == 4)
        #expect(map.displayedOffset(forSource: units.range(of: "《").location) == 6)
        #expect(map.displayedOffset(forSource: units.range(of: "［").location) == 6)
        #expect(map.displayedOffset(forSource: units.range(of: "後").location) == 6)
        // \r\n shows as \n: both of its units map to the one displayed unit.
        #expect(map.displayedOffset(forSource: 1) == 1)
        #expect(map.displayedOffset(forSource: 2) == 1)
        #expect(map.sourceOffset(forDisplayed: 1) == 1)
    }

    @Test("the notation block and the trailing line breaks are deleted")
    func droppedSections() throws {
        let text = try TXTFileReader.readTextFile(url: Self.fixture)
        let document = AozoraDocumentParser.parse(text)
        let source = AozoraSource(text)
        let notation = try #require(document.structure.notationBlock)
        let blockStart = source.lines[notation.lowerBound].lowerBound
        let bodyStart = source.lines[document.structure.body.lowerBound].lowerBound
        // Everything from the end of the header to the body shows at one place.
        let shown = document.sourceMap.displayedOffset(forSource: blockStart)
        #expect(document.sourceMap.displayedOffset(forSource: bodyStart - 1) == shown)
        #expect(!document.displayedText.contains("テキスト中に現れる記号について"))
        #expect(document.displayedText.hasPrefix("『吾輩は猫である』中篇自序\n夏目漱石\n"))
    }

    @Test("a line split at 地付き maps its line break to the annotation")
    func splitLine() {
        let text = "題\n\n文。［＃地付き］（未完）"
        let document = AozoraDocumentParser.parse(text)
        #expect(document.displayedText == "題\n\n文。\n（未完）")
        let annotation = (text as NSString).range(of: "［＃地付き］")
        #expect(document.sourceMap.sourceOffset(forDisplayed: 5) == annotation.location)
        #expect(document.sourceMap.displayedOffset(forSource: NSMaxRange(annotation)) == 6)
    }

    private static let sample = """
        山の話\r
        山田太郎\r
        \r
        -------------------------------------------------------\r
        【テキスト中に現れる記号について】\r
        \r
        《》：ルビ\r
        -------------------------------------------------------\r
        \r
        ［＃５字下げ］一［＃「一」は中見出し］\r
        　｜彼地《かのち》で※［＃「口＋世」、ページ数-行数］を見た。〔cafe'〕に入る。かわる／＼。\r
        　本文［＃割り注］注［＃割り注終わり］と［＃傍点］強調［＃傍点終わり］。［＃地付き］（了）\r
        ［＃改ページ］\r
        ［＃ここから中見出し］\r
        二\r
        \r
        副題\r
        ［＃ここで中見出し終わり］\r
        　最後の行※［＃コト、1-2-24］《こと》。\r
        \r
        \r
        底本：「山の話」架空書房\r
        　　　1999年1月1日発行\r
        入力：誰か\r

        """
}
