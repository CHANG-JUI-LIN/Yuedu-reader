import Testing
import UIKit
@testable import yuedu_app

@Suite("Regex highlight rule editor")
@MainActor
struct RegexHighlightRuleEditorModelTests {
    @Test("invalid regex blocks save and preserves the original")
    func invalidRegex() {
        var saved: [RegexHighlightRule] = []
        let original = RegexHighlightRule.custom(name: "Rule", pattern: "ok")
        let model = RegexHighlightRuleEditorModel(rule: original) { saved.append($0) }
        model.pattern = "["

        #expect(model.save() == false)
        #expect(saved.isEmpty)
        #expect(model.regexError != nil)
        #expect(model.original == original)
    }

    @Test("built in name and pattern stay fixed while style saves")
    func builtInProtection() throws {
        var saved: [RegexHighlightRule] = []
        let original = try #require(RegexHighlightRule.builtIns.first)
        let model = RegexHighlightRuleEditorModel(rule: original) { saved.append($0) }
        model.name = "Changed"
        model.pattern = "different"
        model.lightStyle.text.colorHex = 0x123456

        #expect(model.save())
        #expect(saved[0].name == original.name)
        #expect(saved[0].pattern == original.pattern)
        #expect(saved[0].lightStyle.text.colorHex == 0x123456)
    }

    @Test("each rule editor persists its own enabled state")
    func enabledState() throws {
        var saved: [RegexHighlightRule] = []
        let original = try #require(RegexHighlightRule.builtIns.first)
        let model = RegexHighlightRuleEditorModel(rule: original) { saved.append($0) }
        model.isEnabled = false

        #expect(model.save())
        #expect(saved.count == 1)
        #expect(saved[0].id == original.id)
        #expect(saved[0].isEnabled == false)
    }

    @Test("CSS parsing is atomic and updates the structured style")
    func cssApply() {
        let model = RegexHighlightRuleEditorModel(
            rule: .custom(name: "Rule", pattern: "x")
        ) { _ in }
        let original = model.lightStyle

        #expect(model.applyCSS("display:grid", appearance: .light) == false)
        #expect(model.lightStyle == original)
        #expect(model.applyCSS("color:#112233; padding:4px", appearance: .light))
        #expect(model.lightStyle.text.colorHex == 0x112233)
        #expect(model.lightStyle.decoration.padding?.top == 4)
    }

    @Test("asset removal clears both appearances")
    func removeAssetReferences() {
        let assetID = readerStyleFixtureUUID(72)
        var rule = RegexHighlightRule.custom(name: "Rule", pattern: "x")
        rule.lightStyle.decoration.backgroundImage = .init(assetID: assetID)
        rule.darkStyle.decoration.backgroundImage = .init(assetID: assetID)
        let model = RegexHighlightRuleEditorModel(rule: rule) { _ in }

        #expect(model.removeAssetReferences(assetID: assetID))
        #expect(model.lightStyle.decoration.backgroundImage == nil)
        #expect(model.darkStyle.decoration.backgroundImage == nil)
    }

    @Test("live preview applies the current draft text and gradient style")
    func livePreviewUsesDraftStyle() throws {
        let model = RegexHighlightRuleEditorModel(
            rule: .custom(name: "Rule", pattern: "Sample"),
            testText: "Sample text"
        ) { _ in }
        model.lightStyle.text.colorHex = 0x123456
        model.lightStyle.text.fontSize = 31
        model.lightStyle.decoration.backgroundGradient = ReaderStyleGradient(
            angleDegrees: 90,
            stops: [
                .init(colorHex: 0xFFE1C7, location: 0),
                .init(colorHex: 0xD8E8FF, location: 1),
            ]
        )

        let preview = try model.previewAttributedString(appearance: .light, baseTextColor: .label)
        let color = try #require(preview.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        let font = try #require(preview.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let decoration = try #require(
            preview.attribute(RegexHighlightDecoration.attributeKey, at: 0, effectiveRange: nil)
                as? RegexHighlightDecoration
        )

        #expect(color == UIColor(readerStyleHex: 0x123456))
        #expect(font.pointSize == 31)
        #expect(decoration.style.backgroundGradient == model.lightStyle.decoration.backgroundGradient)
    }

    @Test("default gradients remain visible across their full range")
    func visibleDefaultGradient() {
        let light = RegexHighlightGradientDefaults.visible(for: .light)
        let dark = RegexHighlightGradientDefaults.visible(for: .dark)

        #expect(light.stops.first?.colorHex != 0xFFFFFF)
        #expect(dark.stops.first?.colorHex != 0x1C1C1E)
        #expect(light.stops.count >= 2)
        #expect(dark.stops.count >= 2)
    }

    @Test("forced asset deletion persists reference cleanup and removes the file")
    func forcedAssetDeletion() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)
        let data = try #require(UIImage(systemName: "photo")?.pngData())
        let asset = try await store.importImage(data: data, suggestedName: "photo.png")
        var rule = RegexHighlightRule.custom(name: "Rule", pattern: "x")
        rule.lightStyle.decoration.backgroundImage = .init(assetID: asset.id)
        rule.darkStyle.decoration.backgroundImage = .init(assetID: asset.id)
        var saved: [RegexHighlightRule] = []
        let model = RegexHighlightRuleEditorModel(rule: rule) { saved.append($0) }

        #expect(await model.deleteAsset(id: asset.id, store: store))
        #expect(saved.last?.lightStyle.decoration.backgroundImage == nil)
        #expect(saved.last?.darkStyle.decoration.backgroundImage == nil)
        #expect(await store.assets().isEmpty)
    }
}
