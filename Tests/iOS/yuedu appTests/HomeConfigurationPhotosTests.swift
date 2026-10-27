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

    private let square = CGSize(width: 288, height: 288)

    @Test("the middle square, at most the side asked for, never larger than the image")
    func squareJPEG() throws {
        let wide = try #require(HomeConfigurationPhotos.croppedJPEG(from: png(width: 1200, height: 600), size: square))
        #expect(pixelSize(of: wide) == CGSize(width: 288, height: 288))
        let small = try #require(HomeConfigurationPhotos.croppedJPEG(from: png(width: 100, height: 50), size: square))
        #expect(pixelSize(of: small) == CGSize(width: 50, height: 50))
        #expect(HomeConfigurationPhotos.croppedJPEG(from: Data("not an image".utf8), size: square) == nil)
    }

    @Test("a 大圖卡片 photo: the middle cut to the card's shape, at most its size")
    func cardJPEG() throws {
        let card = CGSize(width: 1200, height: 659)
        let tall = try #require(HomeListCardPhotos.croppedJPEG(from: png(width: 1500, height: 2000), size: card))
        #expect(pixelSize(of: tall) == card)
        let small = try #require(HomeListCardPhotos.croppedJPEG(from: png(width: 600, height: 600), size: card))
        let smallSize = try #require(pixelSize(of: small))
        #expect(smallSize.width == 600)
        #expect(abs(smallSize.width / smallSize.height - card.width / card.height) < 0.01)
    }

    @Test("a card's photo is its list's in its section, wherever the card is put")
    func cardPhotoID() throws {
        let section = UUID()
        let trending = try #require(HomeListCardPhotoID(section: section, binding: .latest, parameters: ["地區": "jp", "a": "b"]))
        #expect(HomeListCardPhotoID(section: section, binding: .latest, parameters: ["a": "b", "地區": "jp"]) == trending)
        #expect(HomeListCardPhotoID(section: section, binding: .latest, parameters: ["地區": "tw", "a": "b"]) != trending)
        #expect(HomeListCardPhotoID(section: UUID(), binding: .latest, parameters: ["地區": "jp", "a": "b"]) != trending)
    }

    @Test("a photo is saved, read again by a later launch, and removed")
    func saveReadRemove() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("HomeConfigurationPhotos")
        let id = HomeConfigurationID(UUID())

        let photos = HomeConfigurationPhotos(directory: directory, pixelSize: square)
        photos.loadIfNeeded()
        #expect(photos.images.isEmpty)
        try await photos.setPhoto(png(width: 400, height: 900), for: id)
        try await photos.setPhoto(png(width: 400, height: 900), for: .defaults)
        #expect(photos.images[id] != nil)
        let file = directory.appendingPathComponent("\(id.rawValue).jpg")
        #expect(pixelSize(of: try Data(contentsOf: file)) == CGSize(width: 288, height: 288))

        let later = HomeConfigurationPhotos(directory: directory, pixelSize: square)
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
        let photos = HomeConfigurationPhotos(directory: folder.appendingPathComponent("HomeConfigurationPhotos"), pixelSize: square)
        await #expect(throws: HomeConfigurationPhotos.PhotoError.self) {
            try await photos.setPhoto(Data("not an image".utf8), for: .defaults)
        }
        #expect(photos.images.isEmpty)
    }

    @Test("a photo kept as another id's; one with none moves nothing")
    func move() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("HomeListCardPhotos")
        let photos = HomeListCardPhotos(directory: directory, pixelSize: CGSize(width: 1200, height: 659))
        let section = UUID()
        let jp = try #require(HomeListCardPhotoID(section: section, binding: .latest, parameters: ["地區": "jp"]))
        let tw = try #require(HomeListCardPhotoID(section: section, binding: .latest, parameters: ["地區": "tw"]))
        try await photos.setPhoto(png(width: 600, height: 400), for: jp)

        photos.movePhoto(from: jp, to: tw)
        #expect(photos.images[jp] == nil)
        #expect(photos.images[tw] != nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(jp.rawValue).jpg").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(tw.rawValue).jpg").path))

        photos.movePhoto(from: jp, to: tw)
        #expect(photos.images[tw] != nil)
    }

    @Test("a card named anew keeps its photo; a removed card's goes when the home is next read, a section of books keeps its")
    func cardPhotosFollowTheirCards() async throws {
        let folder = try makeFolder()
        let suite = "HomeConfigurationPhotosTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
        let fileURL = folder.appendingPathComponent("explore_home.json")
        let store = HomePageStore(fileURL: fileURL, defaults: defaults)
        let trending = HomeSectionBinding.module(moduleID: "m", entryID: "trending")
        let classics = HomeSectionBinding.gutenbergCollection(id: "chinese")
        let banner = HomeSection(layout: .bannerCards, binding: .lists([HomeListCard(binding: trending, parameters: ["地區": "jp"]),
                                                                       HomeListCard(binding: classics)]))
        let single = HomeSection(layout: .bannerCards, binding: classics)
        store.save(HomePage(sections: [banner, single]))
        let editor = HomeSectionEditor(section: banner, store: store, preview: HomeModel(providers: { [] }, waitForSources: {}))
        let jp = try #require(editor.photoID(of: editor.listCards[0]))
        let removed = try #require(editor.photoID(of: editor.listCards[1]))
        let kept = try #require(HomeListCardPhotoID(section: single, card: single.listCards[0]))
        for id in [jp, removed, kept] {
            try await store.cardPhotos.setPhoto(png(width: 600, height: 400), for: id)
        }

        editor.setCardParameter(at: 0, "地區", to: "tw")
        let tw = try #require(editor.photoID(of: editor.listCards[0]))
        #expect(tw != jp)
        #expect(store.cardPhotos.images[tw] != nil)
        #expect(store.cardPhotos.images[jp] == nil)

        editor.removeCard(at: 1)
        store.edit { $0.setLayout(.row, section: single.id) }
        store.waitForPendingWritesForTesting()

        let later = HomePageStore(fileURL: fileURL, defaults: defaults)
        later.cardPhotos.loadIfNeeded()
        #expect(Set(later.cardPhotos.images.keys) == [tw, kept])
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
        store.createConfiguration(named: "週末", from: .blank,
                                  defaults: HomePageDefaults.Context(mode: .publicLibraries, publicLibrariesAvailable: false,
                                                                     languages: []))
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
