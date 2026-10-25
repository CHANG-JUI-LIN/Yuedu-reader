import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// `SVGPathParser.tokenize` walks UTF-8 bytes since Crashlytics dde5251b, where the regex
/// version's `Substring` → `Double` copies read a bridged `NSBigMutableString` one character at
/// a time for ≥6.4 s on the main thread. That regex is kept here as the oracle: a path must
/// tokenize exactly as it did before.
@Suite("SVG path tokenizer")
struct SVGPathTokenizerTests {

    private static func regexTokens(_ d: String) -> [SVGPathParser.Token] {
        let regex = try! NSRegularExpression(pattern: #"([MmLlHhVvCcSsQqTtAazZ])|(-?\d*\.?\d+(?:[eE][-+]?\d+)?)"#)
        var tokens: [SVGPathParser.Token] = []
        for match in regex.matches(in: d, range: NSRange(location: 0, length: (d as NSString).length)) {
            if let range = Range(match.range(at: 1), in: d), !range.isEmpty, let char = d[range].first {
                tokens.append(.command(char))
            } else if let range = Range(match.range(at: 2), in: d), !range.isEmpty, let value = Double(d[range]) {
                tokens.append(.number(CGFloat(value)))
            }
        }
        return tokens
    }

    @Test("tokenizes as the regex it replaced", arguments: [
        "M10 10 H86 V52 H58 L48 62 L38 52 H10 Z",
        "m-.5-.5l.5.5zM0,0c1,2,3,4,5,6s7 8 9 10",
        // One point per number: `1.5.5` is two numbers, a bare trailing point ends one.
        "0.5.5", "1.", "1.e5", ".e5", ".",
        // A sign begins a number only when it is `-`; `+` is a separator.
        "1-2", "--5", "-", "-.5", "+1", "1+2",
        // The exponent needs digits after the `e`.
        "1e", "1e-3", "1E+5x", "1e+", "M 1e 2",
        // Compact arc flags stay one number, as before.
        "a10 10 0 0110 10",
        // Bytes outside ASCII are separators.
        "評1.5字-2", "",
        "M1103.4 172.8C1024.6 93.9 919.5 50.5 807.7 50.5H492.3C380.5 50.5 275.4 93.9 196.6 172.8"
            + "S74.3 356.3 74.3 468.1v86.6c0 102.7 36.9 199.6 104.3 275.5l-26.9 145.9a39.4 39.4 0 0 0"
            + " 55.2 42.7l146.6-69.8c43.9 13.9 90.1 21.1 137.2 21.1h296.5c111.8 0 216.9-43.4 295.7-122.3"
    ])
    func matchesRegex(_ d: String) {
        #expect(SVGPathParser.tokenize(d) == Self.regexTokens(d))
    }

    @Test("bridged path data tokenizes the same as native")
    func bridgedInput() {
        let d = "M10 10 C20 20 40 20 50 10 a5 5 0 1 0 10 0 Z"
        let bridged = NSTextStorage(string: d).string
        #expect(!bridged.isContiguousUTF8)
        #expect(SVGPathParser.tokenize(bridged) == SVGPathParser.tokenize(d))
    }

    /// The parsed bubble is cached and drawn from every thread; its strings must not be the
    /// bridged storage the SVG arrived in.
    @Test("a bridged SVG is parsed into native strings")
    func bridgedSVGParsesNative() throws {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' data-case='\(UUID().uuidString)' width='96' height='72' viewBox='0 0 96 72'>"
            + "<path d='M10 10 H86 V52 H58 L48 62 L38 52 H10 Z' fill='#888888'/>"
            + "<text x='48' y='44' font-size='28' font-family='微軟正黑體, PingFang TC' fill='#FFFFFF'>12</text></svg>"
        let bridged = NSTextStorage(string: svg).string
        #expect(!bridged.isContiguousUTF8)
        let bubble = try #require(CommentBubbleSVGRecognizer.recognize(src: "svg:", svgContent: bridged))
        var sawPath = false
        for element in bubble.elements {
            switch element {
            case .path(let d, _, _, _, _):
                sawPath = true
                #expect(d.isContiguousUTF8)
            case .text(let text, _, _, _, let family, _, _, _, _, _):
                #expect(text.isContiguousUTF8)
                #expect(family?.isContiguousUTF8 ?? true)
            default:
                break
            }
        }
        #expect(sawPath)
    }
}
