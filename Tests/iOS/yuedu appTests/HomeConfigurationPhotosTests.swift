import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 首頁配置's photos (maintainer, 2026-10-22): one square JPEG each, beside `explore_home.json`.
@MainActor
@Suite("Home configuration photos")
struct HomeConfigurationPhotosTests {
    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-photos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A `width`×`height` PNG, one pixel a point.
    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func pixelSize(of data: Data) -> CGSize? {
        guard let image = UIImage(data: data)?.cgImage else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    @Test("the middle square, at most the side asked for, never larger than the image")
    func squareJPEG() throws {
        let wide = try #require(HomeConfigurationPhotos.squareJPEG(from: png(width: 1200, height: 600), side: 288))
        #expect(pixelSize(of: wide) == CGSize(width: 288, height: 288))
        let small = try #require(HomeConfigurationPhotos.squareJPEG(from: png(width: 100, height: 50), side: 288))
        #expect(pixelSize(of: small) == CGSize(width: 50, height: 50))
        #expect(HomeConfigurationPhotos.squareJPEG(from: Data("not an image".utf8), side: 288) == nil)
    }

    @Test("a photo is saved, read again by a later launch, and removed")
    func saveReadRemove() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("HomeConfigurationPhotos")
        let id = HomeConfigurationID(UUID())

        let photos = HomeConfigurationPhotos(directory: directory)
        photos.loadIfNeeded()
        #expect(photos.images.isEmpty)
        try await photos.setPhoto(png(width: 400, height: 900), for: id)
        try await photos.setPhoto(png(width: 400, height: 900), for: .defaults)
        #expect(photos.images[id] != nil)
        let file = directory.appendingPathComponent("\(id.rawValue).jpg")
        #expect(pixelSize(of: try Data(contentsOf: file)) == CGSize(width: 288, height: 288))

        let later = HomeConfigurationPhotos(directory: directory)
        later.loadIfNeeded()
        #expect(Set(later.images.keys) == [id, .defaults])

        later.removePhoto(for: id)
        #expect(later.images[id] == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // Removing one that has none is not an error.
        later.removePhoto(for: id)
    }

    @Test("bytes that are not an image are refused and nothing is saved")
    func unreadable() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photos = HomeConfigurationPhotos(directory: folder.appendingPathComponent("HomeConfigurationPhotos"))
        await #expect(throws: HomeConfigurationPhotos.PhotoError.self) {
            try await photos.setPhoto(Data("not an image".utf8), for: .blank)
        }
        #expect(photos.images.isEmpty)
    }

    @Test("deleting a 首頁配置 deletes its photo")
    func deleteTakesPhoto() async throws {
        let folder = try makeFolder()
        let suite = "HomeConfigurationPhotosTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = HomePageStore(fileURL: folder.appendingPathComponent("explore_home.json"), defaults: defaults)
        _ = store.pageOrDefaults(mode: .publicLibraries, publicLibrariesAvailable: false, languages: [])
        store.createConfiguration(named: "週末", from: .blank)
        let weekend = store.selectedConfiguration
        try await store.photos.setPhoto(png(width: 300, height: 300), for: weekend)
        let file = folder.appendingPathComponent("HomeConfigurationPhotos/\(weekend.rawValue).jpg")
        #expect(FileManager.default.fileExists(atPath: file.path))

        store.deleteConfiguration(weekend)
        #expect(store.photos.images[weekend] == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        store.waitForPendingWritesForTesting()
    }
}
