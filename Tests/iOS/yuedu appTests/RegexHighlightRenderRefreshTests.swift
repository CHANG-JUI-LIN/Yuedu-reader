import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Regex highlight render refresh", .serialized)
struct RegexHighlightRenderRefreshTests {
    @Test("color and decoration redraw while typography and matching relayout")
    func refreshClassification() {
        let original = configuration()
        var recolor = original
        recolor.customRules[0].lightStyle.text.colorHex = 0x123456
        var decoration = original
        decoration.customRules[0].lightStyle.decoration.cornerRadius = 12
        var typography = original
        typography.customRules[0].lightStyle.text.fontSize = 24
        var matching = original
        matching.customRules[0].pattern = "different"
        var asset = original
        asset.customRules[0].lightStyle.decoration.backgroundImage = .init(
            assetID: readerStyleFixtureUUID(143),
            contentMode: .fit
        )
        var disabled = original
        disabled.isEnabled = false
        var twoRules = original
        twoRules.customRules.append(.custom(name: "Second", pattern: "world"))
        var reordered = twoRules
        reordered.customRules.reverse()

        #expect(RegexHighlightRefreshPolicy.classify(from: original, to: recolor) == .redraw)
        #expect(RegexHighlightRefreshPolicy.classify(from: original, to: decoration) == .redraw)
        #expect(RegexHighlightRefreshPolicy.classify(from: original, to: asset) == .redraw)
        #expect(RegexHighlightRefreshPolicy.classify(from: original, to: typography) == .relayout)
        #expect(RegexHighlightRefreshPolicy.classify(from: original, to: matching) == .relayout)
        #expect(RegexHighlightRefreshPolicy.classify(from: original, to: disabled) == .relayout)
        #expect(RegexHighlightRefreshPolicy.classify(from: twoRules, to: reordered) == .relayout)
    }

    @Test("render settings route regex refresh through the shared policy")
    func renderSettingsIntent() {
        let originalConfiguration = configuration()
        var recolorConfiguration = originalConfiguration
        recolorConfiguration.customRules[0].lightStyle.text.colorHex = 0x654321
        var typographyConfiguration = originalConfiguration
        typographyConfiguration.customRules[0].lightStyle.text.letterSpacing = 4

        let original = settings(configuration: originalConfiguration)
        let recolor = settings(configuration: recolorConfiguration)
        let typography = settings(configuration: typographyConfiguration)
        var revisedAsset = original
        revisedAsset.readerStyleAssetRevision += 1
        var darkAppearance = original
        darkAppearance.readerStyleAppearance = .dark

        #expect(recolor.refreshIntent(comparedTo: original) == .appearance)
        #expect(revisedAsset.refreshIntent(comparedTo: original) == .appearance)
        #expect(darkAppearance.refreshIntent(comparedTo: original) == .appearance)
        #expect(typography.refreshIntent(comparedTo: original) == .layout)
    }

    @Test("cold persisted background image is warmed for synchronous drawing")
    func coldCachePrewarm() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assetID = readerStyleFixtureUUID(141)
        let data = try #require(UIImage(systemName: "photo")?.pngData())
        let asset = ReaderStyleAsset(
            id: assetID,
            name: "Regex background",
            mimeType: "image/png",
            pixelWidth: 64,
            pixelHeight: 64,
            hasAlpha: true,
            sha256: String(repeating: "b", count: 64),
            fileName: "regex-background.png",
            thumbnailFileName: "regex-background-thumb.png"
        )
        try data.write(to: root.appendingPathComponent(asset.fileName))
        try data.write(to: root.appendingPathComponent(asset.thumbnailFileName))
        try JSONEncoder().encode(
            RegexAssetManifestFixture(version: 1, revision: 9, assets: [asset])
        ).write(to: root.appendingPathComponent("manifest.json"))

        var configuration = configuration()
        configuration.customRules[0].lightStyle.decoration.backgroundImage = .init(
            assetID: assetID,
            contentMode: .fit
        )
        configuration.customRules[0].darkStyle.decoration.backgroundImage = .init(
            assetID: readerStyleFixtureUUID(142),
            contentMode: .fill
        )
        let store = ReaderStyleAssetStore(rootURL: root)
        #expect(await store.cachedImage(for: assetID) == nil)

        await store.prewarmRegexHighlightAssets(
            configuration: configuration,
            appearance: .light
        )

        #expect(await store.cachedImage(for: assetID) != nil)
    }

    @Test("asset mutation publishes the committed revision")
    func assetMutationRevisionNotification() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)
        let data = try #require(UIImage(systemName: "photo.fill")?.pngData())

        try await confirmation("revision notification published") { confirmed in
            let observer = NotificationCenter.default.addObserver(
                forName: .readerStyleAssetsDidChange,
                object: nil,
                queue: nil
            ) { notification in
                let revision = notification.userInfo?[
                    ReaderStyleAssetStore.revisionUserInfoKey
                ] as? NSNumber
                if revision?.uint64Value == 1 {
                    confirmed()
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            _ = try await store.importImage(
                data: data,
                suggestedName: "Revision fixture"
            )
        }

        #expect(await store.revision == 1)
    }

    private func configuration() -> RegexHighlightConfiguration {
        var rule = RegexHighlightRule.custom(name: "Custom", pattern: "hello")
        rule.lightStyle.text.colorHex = 0xFF8A34
        rule.darkStyle.text.colorHex = 0xFFD099
        return RegexHighlightConfiguration(
            isEnabled: true,
            rules: [],
            customRules: [rule]
        )
    }

    private func settings(
        configuration: RegexHighlightConfiguration
    ) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "sepia",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 18,
            lineHeightMultiple: 1.6,
            lineSpacing: 10,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 24,
            marginV: 16,
            footerHeight: 24,
            contentInsets: .zero,
            regexHighlightConfiguration: configuration,
            readerStyleAppearance: .light,
            readerStyleAssetRevision: 3
        )
    }
}

private struct RegexAssetManifestFixture: Codable {
    let version: Int
    let revision: UInt64
    let assets: [ReaderStyleAsset]
}
