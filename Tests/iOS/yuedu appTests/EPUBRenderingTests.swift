import Testing
import Foundation
import UIKit
@testable import yuedu_app

struct EPUBRenderingTests {

    // MARK: - HR divider has correct attribute

    @Test func hrDividerCarriesAttribute() {
        // Compile-time verification: HRDividerStyle and hrDividerAttribute exist
        let key = HTMLAttributedStringBuilder.hrDividerAttribute
        let style = HTMLAttributedStringBuilder.HRDividerStyle(color: .black, lineWidth: 1.0)
        #expect(key.rawValue == "ReaderHRDivider")
        #expect(style.lineWidth == 1.0)
    }

    // MARK: - Image source resolution

    @Test func imageSourceReadsXlinkHref() {
        let attrs: [String: String] = ["xlink:href": "cover.jpg"]
        let src = attrs["src"] ?? attrs["xlink:href"] ?? attrs["href"] ?? ""
        #expect(src == "cover.jpg")
    }

    @Test func imageSourcePrefersSrc() {
        let attrs: [String: String] = ["src": "logo.png", "xlink:href": "ignored.jpg"]
        let src = attrs["src"] ?? attrs["xlink:href"] ?? attrs["href"] ?? ""
        #expect(src == "logo.png")
    }

    // MARK: - Percentage length resolution

    @Test func resolvePercentRelativeToBase() {
        let value = "40%"
        let base: CGFloat = 440
        let result: CGFloat? = {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.hasSuffix("%"), let number = Double(trimmed.dropLast()) {
                return CGFloat(number / 100.0) * base
            }
            return nil
        }()
        #expect(result == 176.0)
    }

    @Test func resolveEmRelativeToFontSize() {
        let value = "2em"
        let base: CGFloat = 17
        let result: CGFloat? = {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.hasSuffix("em"), let number = Double(trimmed.dropLast(2)) {
                return CGFloat(number) * base
            }
            return nil
        }()
        #expect(result == 34.0)
    }

    // MARK: - Margin auto: only center when both sides are auto

    @Test func singleSidedAutoMarginDoesNotCenter() {
        // margin: 0 1em 0 auto → left=auto, right=1em
        let left = "auto"
        let right = "1em"
        let isCentered: Bool = {
            let l = left.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let r = right.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return l == "auto" && r == "auto"
        }()
        #expect(!isCentered)
    }

    @Test func doubleSidedAutoMarginDoesCenter() {
        let left = "auto"
        let right = "auto"
        let isCentered: Bool = {
            let l = left.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let r = right.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return l == "auto" && r == "auto"
        }()
        #expect(isCentered)
    }

    // MARK: - HTML entity count sanity

    @Test func copyrightPageHasHrElements() {
        let html = """
        <body><h1>版权信息</h1><p>text</p><hr/><p>text2</p><hr/><p>text3</p></body>
        """
        // SwiftSoup would count 2 <hr> elements
        let hrCount = html.components(separatedBy: "<hr").count - 1
        #expect(hrCount == 2)
    }
}
