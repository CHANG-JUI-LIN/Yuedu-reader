import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Global app typography", .serialized)
@MainActor
struct GlobalAppTypographyTests {
    @Test("custom semantic font resolves the selected PostScript name")
    func customSemanticFontResolvesSelectedName() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf")
        let info = try UserFontStorageManager.shared.importFont(fileURL: fixtureURL)
        defer { UserFontStorageManager.shared.delete(info) }

        let font = GlobalAppTypography.uiFont(
            .body,
            postScriptName: info.postScriptName,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        )

        #expect(font.fontName == info.postScriptName)
    }

    @Test("invalid custom font falls back to the matching system style")
    func invalidFontFallsBackToSystemStyle() {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let font = GlobalAppTypography.uiFont(
            .body,
            postScriptName: "Missing-Yuedu-Font",
            compatibleWith: traits
        )
        let expected = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont.systemFont(ofSize: 17),
            compatibleWith: traits
        )

        #expect(font.fontName == expected.fontName)
        #expect(abs(font.pointSize - expected.pointSize) < 0.01)
    }

    @Test("custom semantic font grows at accessibility sizes")
    func customSemanticFontScalesForDynamicType() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf")
        let info = try UserFontStorageManager.shared.importFont(fileURL: fixtureURL)
        defer { UserFontStorageManager.shared.delete(info) }

        let normal = GlobalAppTypography.uiFont(
            .body,
            postScriptName: info.postScriptName,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        )
        let accessibility = GlobalAppTypography.uiFont(
            .body,
            postScriptName: info.postScriptName,
            compatibleWith: UITraitCollection(
                preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
            )
        )

        #expect(accessibility.pointSize > normal.pointSize)
    }
}
