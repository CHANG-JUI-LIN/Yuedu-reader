import Foundation

struct ReaderStyleAsset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let mimeType: String
    let pixelWidth: Int
    let pixelHeight: Int
    let hasAlpha: Bool
    let sha256: String
    let fileName: String
    let thumbnailFileName: String
}

enum ReaderStyleAssetReference: Codable, Equatable, Hashable, Sendable {
    case chapterLayer(String)
    case regexRule(String)
}

enum ReaderStyleAssetStoreError: Error, Equatable, Sendable {
    case inputTooLarge(actual: Int, maximum: Int)
    case decodedImageTooLarge(actualPixels: Int, maximumPixels: Int)
    case invalidImage
    case assetNotFound(UUID)
    case assetInUse(assetID: UUID, references: [ReaderStyleAssetReference])
    case writeFailed
}
