import Foundation
import SwiftUI
import Testing
@testable import yuedu_app

/// 預設封面 picking rules.
///
/// The pick has to be a pure function of the book's own key: a `randomElement()`
/// here would reshuffle every cover in the shelf on each scroll pass, and a
/// `hashValue` would reshuffle them on every relaunch (Swift seeds that per
/// process).
@Suite("Default cover library", .serialized)
struct DefaultCoverLibraryTests {
    private func withLibrary(
        light: [String],
        dark: [String],
        _ body: () throws -> Void
    ) rethrows {
        let settings = GlobalSettings.shared
        let previousLight = settings.defaultCoverLightFileNames
        let previousDark = settings.defaultCoverDarkFileNames
        defer {
            settings.defaultCoverLightFileNames = previousLight
            settings.defaultCoverDarkFileNames = previousDark
        }
        settings.defaultCoverLightFileNames = light
        settings.defaultCoverDarkFileNames = dark
        try body()
    }

    @Test("the same book always resolves to the same cover file")
    func pickIsStablePerBook() {
        withLibrary(light: ["a.jpg", "b.jpg", "c.jpg"], dark: []) {
            let names = DefaultCoverLibrary.fileNames(for: .light)
            let first = DefaultCoverLibrary.stableFileName(seed: "book-1", in: names)
            #expect(first != nil)
            for _ in 0..<20 {
                #expect(DefaultCoverLibrary.stableFileName(seed: "book-1", in: names) == first)
            }
        }
    }

    @Test("different books spread across the library")
    func pickSpreadsAcrossFiles() {
        withLibrary(light: ["a.jpg", "b.jpg", "c.jpg"], dark: []) {
            let names = DefaultCoverLibrary.fileNames(for: .light)
            let picked = Set((0..<60).compactMap {
                DefaultCoverLibrary.stableFileName(seed: "book-\($0)", in: names)
            })
            #expect(picked.count == names.count)
        }
    }

    @Test("dark falls back to the light library, light never falls back to dark")
    func darkFallsBackToLight() {
        withLibrary(light: ["light.jpg"], dark: []) {
            #expect(DefaultCoverLibrary.fileNames(for: .dark) == ["light.jpg"])
        }
        withLibrary(light: [], dark: ["dark.jpg"]) {
            #expect(DefaultCoverLibrary.fileNames(for: .dark) == ["dark.jpg"])
            #expect(DefaultCoverLibrary.fileNames(for: .light).isEmpty)
        }
    }

    @Test("an empty library resolves to nothing at all")
    func emptyLibraryHasNoCover() {
        withLibrary(light: [], dark: []) {
            #expect(DefaultCoverLibrary.fileNames(for: .light).isEmpty)
            #expect(!DefaultCoverLibrary.hasImages(for: .light))
            #expect(DefaultCoverLibrary.image(seed: "book-1", colorScheme: .light) == nil)
        }
    }

    @Test("the cover corner radius stays inside its range")
    func cornerRadiusIsClamped() {
        #expect(GlobalSettings.clampedBookshelfCoverCornerRadius(-10) == 0)
        #expect(
            GlobalSettings.clampedBookshelfCoverCornerRadius(999)
                == GlobalSettings.bookshelfCoverCornerRadiusRange.upperBound
        )
        #expect(GlobalSettings.clampedBookshelfCoverCornerRadius(8) == 8)
    }
}
