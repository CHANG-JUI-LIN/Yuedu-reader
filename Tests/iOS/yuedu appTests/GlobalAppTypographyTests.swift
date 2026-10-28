import Foundation
import SwiftUI
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

    @Test("custom tab font keeps the caption2 base size")
    func customTabFontDoesNotScaleWithDynamicType() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf")
        let info = try UserFontStorageManager.shared.importFont(fileURL: fixtureURL)
        defer { UserFontStorageManager.shared.delete(info) }

        let font = try #require(
            GlobalAppTypographyUIKitBridge.tabBarFont(
                postScriptName: info.postScriptName
            )
        )

        #expect(font.fontName == info.postScriptName)
        #expect(abs(font.pointSize - 11) < 0.01)
    }

    /// Feedback #41: `ContentUnavailableView` sets its own system fonts on its title and
    /// description, so `UnavailableLabel` and the call sites set the global ones. With no
    /// custom font they must draw exactly as the view's own did — the styles differ by OS
    /// version, so run this on the oldest and newest supported runtimes — and with one, they
    /// must change.
    @Test("unavailable title and description match the system's and follow a custom font")
    func unavailableTextFollowsGlobalFont() throws {
        func render(title: Font?, description: Font?) throws -> Data {
            let renderer = ImageRenderer(
                content: ContentUnavailableView {
                    Label {
                        // `.font(nil)` would reset the view's own font, not leave it.
                        if let title {
                            Text("此分組暫無意見回報").font(title)
                        } else {
                            Text("此分組暫無意見回報")
                        }
                    } icon: {
                        Image(systemName: "tray")
                    }
                } description: {
                    if let description {
                        Text("換一個篩選條件或搜尋字詞試試。").font(description)
                    } else {
                        Text("換一個篩選條件或搜尋字詞試試。")
                    }
                }
                .frame(width: 320, height: 300)
            )
            renderer.scale = 2
            return try #require(renderer.uiImage?.pngData())
        }
        let saved = GlobalAppTypography.activePostScriptName
        defer { GlobalAppTypography.activePostScriptName = saved }

        GlobalAppTypography.activePostScriptName = nil
        let plain = try render(title: nil, description: nil)
        #expect(try render(title: DSFont.unavailableTitle, description: nil) == plain)
        #expect(try render(title: nil, description: DSFont.unavailableDescription) == plain)

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf")
        let info = try UserFontStorageManager.shared.importFont(fileURL: fixtureURL)
        defer { UserFontStorageManager.shared.delete(info) }
        GlobalAppTypography.activePostScriptName = info.postScriptName
        #expect(try render(title: DSFont.unavailableTitle, description: nil) != plain)
        #expect(try render(title: nil, description: DSFont.unavailableDescription) != plain)
    }
}
