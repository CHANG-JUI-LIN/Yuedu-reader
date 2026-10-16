import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// A reading setup synced from another device names its pictures by their IDs in that
/// device's style asset store. Only the settings travelled, so a highlight pack imported on
/// one device painted nothing on the others, and its frame editor spun forever (2026-10-15).
@Suite("閱讀設定圖片同步", .serialized)
struct ReaderStylePictureSyncTests {
    @Test("sends the pictures the setup shows that this device has, and fetches the rest")
    func choosesPicturesToSendAndFetch() {
        let frame = UUID(), darkFrame = UUID(), skin = UUID()
        var rule = RegexHighlightRule.custom(name: "框", pattern: "“[^”]*”")
        rule.lightStyle.decoration.backgroundImage = ReaderStyleImagePresentation(assetID: frame)
        rule.darkStyle.decoration.backgroundImage = ReaderStyleImagePresentation(assetID: darkFrame)
        var highlights = AppearanceThemeReadingSettings()
        highlights.regexHighlights = RegexHighlightConfiguration(isEnabled: true, rules: [], customRules: [rule])
        var bubble = ReaderDialogueBubbleStyle(isEnabled: true)
        bubble.left.skin = ReaderDialogueBubbleSkin(assetID: skin)
        bubble.right.avatar = ReaderDialogueBubbleAvatar(assetID: frame)
        var bubbles = AppearanceThemeReadingSettings()
        bubbles.dialogueBubbleStyle = bubble
        let records = [
            ReadingSettingSyncRecord(item: "regexHighlights", values: highlights, editedAt: Date()),
            ReadingSettingSyncRecord(item: "dialogueBubble", values: bubbles, editedAt: Date()),
        ]

        let sync = ICloudSyncManager.readerStylePictureSync(
            referencedBy: records,
            stored: [Self.asset(frame), Self.asset(skin), Self.asset(UUID())]
        )

        #expect(sync.send.map(\.id) == [frame, skin])
        #expect(sync.fetch == [darkFrame])
        #expect(ICloudSyncManager.readerStylePictureIDs(referencedBy: records) == [frame, darkFrame, skin])
    }

    @Test("a picture that arrives is stored under the ID the settings name it by")
    func storesArrivingPictureUnderItsID() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)
        let id = UUID()
        let revision = await store.revision

        try await store.importSyncedImage(id: id, data: try Self.pngData(), name: "对话高亮 十字架")

        #expect(await store.revision > revision, "the reader redraws on the store's revision")
        let stored = try #require(await store.assets().first { $0.id == id })
        #expect(stored.name == "对话高亮 十字架")
        #expect(FileManager.default.fileExists(atPath: try await store.imageFileURL(for: id).path))
        // From disk, as the next launch reads it.
        let data = try await ReaderStyleAssetStore(rootURL: root).imageData(for: id)
        let image = try #require(UIImage(data: data))
        #expect(image.size == CGSize(width: 8, height: 8))
    }

    private static func asset(_ id: UUID) -> ReaderStyleAsset {
        ReaderStyleAsset(
            id: id, name: "picture", mimeType: "image/png", pixelWidth: 8, pixelHeight: 8,
            hasAlpha: true, sha256: "", fileName: "\(id).png", thumbnailFileName: "\(id)-thumb.png"
        )
    }

    private static func pngData() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return try #require(image.pngData())
    }
}
