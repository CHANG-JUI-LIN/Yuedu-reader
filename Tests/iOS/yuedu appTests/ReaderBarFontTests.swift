import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// The 頁眉／頁腳 typeface option (FB-126): 系統字體 stays exactly what the bars always
/// drew, 跟隨正文 and an installed reading font go through the chapter-title font path,
/// and every layout written before the option still reads.
struct ReaderBarFontTests {

    // MARK: - Coding

    @Test("A style saved before the option decodes as the system font")
    func legacyStyleDecodesAsSystem() throws {
        let json = #"{"fontSize":12,"weight":"bold","color":{"source":"readerText"},"opacity":0.6}"#
        let style = try JSONDecoder().decode(ReaderBarStyle.self, from: Data(json.utf8))
        #expect(style.font == .system)
        #expect(style.fontSize == 12)
        #expect(style.weight == .bold)
    }

    @Test("A whole layout from before the option, as presets and 主題包 carry it, still decodes")
    func legacyLayoutDecodes() throws {
        var layout = ReaderBarLayout.default
        layout.style.fontSize = 13
        let data = try JSONEncoder().encode(layout)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let style = try #require(object["style"] as? [String: Any])
        #expect(style["font"] == nil)

        let decoded = try JSONDecoder().decode(ReaderBarLayout.self, from: data)
        #expect(decoded == layout)
        #expect(decoded.style.font == .system)
    }

    @Test("The system font is left out of the encoding; the other choices round-trip")
    func encodingRoundTrips() throws {
        let plain = try JSONEncoder().encode(ReaderBarStyle())
        let plainObject = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(Set(plainObject.keys) == ["fontSize", "weight", "color", "opacity"])

        for font in [ReaderBarFontReference.followsBody, .custom("Georgia")] {
            let style = ReaderBarStyle(font: font)
            let decoded = try JSONDecoder().decode(ReaderBarStyle.self, from: JSONEncoder().encode(style))
            #expect(decoded.font == font)
        }
    }

    @Test("A source this version does not know reads as the system font")
    func unknownSourceReadsAsSystem() throws {
        let json = #"{"fontSize":11,"font":{"source":"somethingNewer","postScriptName":"X"}}"#
        let style = try JSONDecoder().decode(ReaderBarStyle.self, from: Data(json.utf8))
        #expect(style.font.normalized == .system)
    }

    @Test("Saving normalizes the layout without dropping the choice")
    func normalizationKeepsTheChoice() {
        var layout = ReaderBarLayout.default
        layout.style.font = .followsBody
        #expect(layout.normalized().style.font == .followsBody)
        layout.style.font = .custom("Georgia")
        #expect(layout.normalized().style.font == .custom("Georgia"))
        layout.style.font = ReaderBarFontReference(source: .custom, postScriptName: "")
        #expect(layout.normalized().style.font == .system)
    }

    // MARK: - Resolution

    @Test("系統字體 is exactly the font the bars drew before", arguments: ReaderBarFieldNaming.weights)
    @MainActor func systemChoiceIsUnchanged(weight: ReaderOverlayFontWeight) {
        let style = ReaderBarStyle(fontSize: 11, weight: weight)
        let resolved = ReaderBarStyleResolver.resolve(
            style, readerTextColor: .black, userInterfaceStyle: .light, bodyFontPostScriptName: "Georgia"
        )
        let expected = UIFont.systemFont(ofSize: 11, weight: Self.uiWeight(weight))
        #expect(resolved.font == expected)
        #expect(resolved.syntheticBoldOffset == 0)
    }

    @Test("跟隨正文 draws in the reading font, and in the system font when there is none")
    @MainActor func followsBodyUsesTheReadingFont() {
        let style = ReaderBarStyle(fontSize: 11, font: .followsBody)
        let georgia = ReaderBarStyleResolver.resolve(
            style, readerTextColor: .black, userInterfaceStyle: .light, bodyFontPostScriptName: "Georgia"
        )
        #expect(georgia.font.familyName == "Georgia")
        #expect(georgia.font.pointSize == 11)

        let none = ReaderBarStyleResolver.resolve(
            style, readerTextColor: .black, userInterfaceStyle: .light, bodyFontPostScriptName: nil
        )
        #expect(none.font.familyName == UIFont.systemFont(ofSize: 11).familyName)
    }

    @Test("An installed font is used by name; one that is gone draws in the system font")
    @MainActor func customFontResolvesByName() {
        let installed = ReaderBarStyleResolver.resolve(
            ReaderBarStyle(fontSize: 11, font: .custom("Georgia")),
            readerTextColor: .black, userInterfaceStyle: .light, bodyFontPostScriptName: nil
        )
        #expect(installed.font.familyName == "Georgia")

        let missing = ReaderBarStyleResolver.resolve(
            ReaderBarStyle(fontSize: 11, font: .custom("NoSuchFont-Regular")),
            readerTextColor: .black, userInterfaceStyle: .light, bodyFontPostScriptName: nil
        )
        #expect(missing.font.familyName == UIFont.systemFont(ofSize: 11).familyName)
    }

    @Test("A face other than 系統字體 asks for tabular figures where it has them")
    @MainActor func nonSystemFacesGetTabularDigits() {
        // The system font has proportional digits by default and supports the tabular
        // feature, so it shows both sides: 系統字體 keeps its digits, 跟隨正文 with no
        // reading font picked gets the same face with tabular ones.
        let system = ReaderBarStyleResolver.resolve(
            ReaderBarStyle(fontSize: 11), readerTextColor: .black, userInterfaceStyle: .light
        ).font
        let following = ReaderBarStyleResolver.resolve(
            ReaderBarStyle(fontSize: 11, font: .followsBody),
            readerTextColor: .black, userInterfaceStyle: .light, bodyFontPostScriptName: nil
        ).font
        #expect(Self.width("1111", system) != Self.width("0000", system))
        #expect(abs(Self.width("1111", following) - Self.width("0000", following)) < 0.01)
    }

    @Test("Weight picks the family's own bold face, and fakes one the family lacks")
    @MainActor func weightKeepsWorking() {
        let georgia = ReaderBarStyleResolver.resolve(
            ReaderBarStyle(fontSize: 11, weight: .bold, font: .custom("Georgia")),
            readerTextColor: .black, userInterfaceStyle: .light, bodyFontPostScriptName: nil
        )
        #expect(georgia.font.familyName == "Georgia")
        #expect(georgia.font.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(georgia.syntheticBoldOffset == 0)

        // Chalkduster has one face and no weight axis, like most imported CJK fonts.
        let bold = ReaderBarStyleResolver.resolve(
            ReaderBarStyle(fontSize: 11, weight: .bold, font: .followsBody),
            readerTextColor: .black, userInterfaceStyle: .light, bodyFontPostScriptName: "Chalkduster"
        )
        #expect(bold.font.familyName == "Chalkduster")
        #expect(bold.syntheticBoldOffset > 0)

        let regular = ReaderBarStyleResolver.resolve(
            ReaderBarStyle(fontSize: 11, weight: .regular, font: .followsBody),
            readerTextColor: .black, userInterfaceStyle: .light, bodyFontPostScriptName: "Chalkduster"
        )
        #expect(regular.syntheticBoldOffset == 0)

        // The system face has a weight axis, so 跟隨正文 without a reading font never fakes.
        let systemBold = ReaderBarStyleResolver.resolve(
            ReaderBarStyle(fontSize: 11, weight: .bold, font: .followsBody),
            readerTextColor: .black, userInterfaceStyle: .light, bodyFontPostScriptName: nil
        )
        #expect(systemBold.syntheticBoldOffset == 0)
    }

    @Test("A synthetic bold run is measured with its offset")
    @MainActor func syntheticBoldWidensTheRun() throws {
        let builder = ReaderBarRenderModelBuilder()
        var layout = ReaderBarLayout(fields: [.init(kind: .customText, slot: .footerLeft,
                                                    configuration: .init(customText: "Page 12"))])
        layout.style.font = .followsBody
        layout.style.weight = .bold
        let model = builder.model(
            for: .footer, layout: layout, content: Self.snapshot, readerTextColor: .black,
            horizontalPadding: 0, svgAssetStore: nil, userInterfaceStyle: .light, displayScale: 1,
            bodyFontPostScriptName: "Chalkduster"
        )
        #expect(model.syntheticBoldOffset > 0)
        #expect(model.font.familyName == "Chalkduster")
    }

    @Test("Synthetic bold keeps the bar's opacity where its two passes overlap")
    @MainActor func syntheticBoldKeepsTheOpacity() throws {
        let font = try #require(UIFont(name: "Chalkduster", size: 16))
        let model = ReaderBarRenderModel(
            bar: .footer, slots: [[.text("MMMM 12:34")], [], []], font: font, color: .black, opacity: 0.5,
            horizontalPadding: 0, showsDivider: false, accessibilityValue: "", syntheticBoldOffset: 1
        )
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 30)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            ReaderBarRenderer.draw(model, in: bounds, canvasHeight: bounds.height, context: context.cgContext)
        }
        let cgImage = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 200 * 30 * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: 200, height: 30, bitsPerComponent: 8,
                bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(cgImage, in: bounds)
        }
        let maxAlpha = stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }.max() ?? 0
        // Drawn twice at 0.5 the overlap would reach 0.75 (191).
        #expect(maxAlpha >= 120)
        #expect(maxAlpha <= 132)
    }

    // MARK: - Alignment

    @Test("The battery and progress track keep their size in any face")
    func iconMetricsDoNotFollowTheFace() throws {
        let system = UIFont.systemFont(ofSize: 11)
        let georgia = try #require(UIFont(name: "Georgia", size: 11))
        let chalk = try #require(UIFont(name: "Chalkduster", size: 11))
        for face in [georgia, chalk] {
            #expect(ReaderBarRenderer.imageSize(font: face) == ReaderBarRenderer.imageSize(font: system))
            #expect(ReaderBarRenderer.progressWidth(font: face) == ReaderBarRenderer.progressWidth(font: system))
        }
    }

    /// The battery used to be sized from the bar font's own line height. The new
    /// metric reads the regular system font; this pins that every weight of the system
    /// font measures the same, so a 系統字體 bar's battery is the size it always was.
    @Test("System-font line height does not vary with weight", arguments: ReaderBarFieldNaming.weights)
    func systemLineHeightIsWeightInvariant(weight: ReaderOverlayFontWeight) {
        for size in stride(from: 8.0, through: 16.0, by: 1.0) {
            #expect(
                UIFont.systemFont(ofSize: size, weight: Self.uiWeight(weight)).lineHeight
                    == UIFont.systemFont(ofSize: size).lineHeight
            )
        }
    }

    // MARK: - Refresh

    @Test("Changing the reading font rebuilds a 跟隨正文 bar")
    @MainActor func environmentCarriesTheReadingFont() {
        var layout = ReaderBarLayout.default
        layout.style.font = .followsBody
        var environment = ReaderPageBarsEnvironment(
            layout: layout, headerEnabled: true, footerEnabled: true, readerTextColor: .black,
            headerHorizontalPadding: 16, footerHorizontalPadding: 16,
            headerTopOffset: 20, footerBottomOffset: 20, bookTitle: "Book",
            now: Self.snapshot.now, batteryLevel: 0.7, isCharging: false,
            readingDuration: 60, userInterfaceStyle: .light, displayScale: 1,
            bodyFontPostScriptName: "Georgia"
        )
        let controller = ReaderPageBarsController()
        controller.update(environment: environment, svgAssetStore: nil) { _ in nil }
        #expect(controller.model(for: .footer, snapshot: Self.snapshot, environment: environment)
            .font.familyName == "Georgia")

        let before = environment
        environment.bodyFontPostScriptName = "Chalkduster"
        // The reader rebuilds page-baked bars on any change to this value.
        #expect(environment != before)
        controller.update(environment: environment, svgAssetStore: nil) { _ in nil }
        #expect(controller.model(for: .footer, snapshot: Self.snapshot, environment: environment)
            .font.familyName == "Chalkduster")
    }

    // MARK: - Helpers

    private static let snapshot = ReaderOverlayContentSnapshot(
        bookTitle: "Book", chapterTitle: "Chapter", chapterPage: 2, chapterPageCount: 10,
        pageScope: .chapterBody, totalProgress: 0.2, now: Date(timeIntervalSince1970: 0), batteryLevel: 0.7,
        isCharging: false, readingDuration: 60, estimatedRemainingTime: 240
    )

    private static func uiWeight(_ weight: ReaderOverlayFontWeight) -> UIFont.Weight {
        switch weight {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    private static func width(_ text: String, _ font: UIFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}
