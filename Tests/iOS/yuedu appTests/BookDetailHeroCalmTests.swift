import Foundation
import Testing
@testable import yuedu_app

/// The detail hero after 方案 A (2026-10-12): where reading resumes is written into the reading
/// button, and the wash behind the hero is the cover's hue, never a grey haze.
@Suite("Detail hero: resume label and cover wash")
struct BookDetailHeroCalmTests {
    @Test("a book read by chapters resumes at 「第 N 章」, counted from one")
    func chapterResume() {
        #expect(BookDetailResume.detail(chapterIndex: 11, progress: 0.4) == String(format: localized("第 %d 章"), 12))
        #expect(BookDetailResume.detail(chapterIndex: 0, progress: nil) == String(format: localized("第 %d 章"), 1))
    }

    @Test("a file resumes at its share read; unopened says nothing; the end says so")
    func shareResume() {
        #expect(BookDetailResume.detail(chapterIndex: nil, progress: 0.32) == String(format: localized("已讀 %d%%"), 32))
        #expect(BookDetailResume.detail(chapterIndex: nil, progress: 0) == nil)
        #expect(BookDetailResume.detail(chapterIndex: nil, progress: nil) == nil)
        #expect(BookDetailResume.detail(chapterIndex: nil, progress: 1) == localized("已讀完"))
    }

    @Test("a grey or near-grey cover gets no wash")
    func greyCoverHasNoWash() {
        #expect(CoverTint.wash(for: .init(red: 0.5, green: 0.5, blue: 0.5)) == nil)
        #expect(CoverTint.wash(for: .init(red: 0, green: 0, blue: 0)) == nil)
        #expect(CoverTint.wash(for: .init(red: 0.45, green: 0.42, blue: 0.40)) == nil, "Moby Dick's grey-brown")
    }

    @Test("a coloured cover's wash keeps its hue, its saturation capped")
    func colouredCoverWash() throws {
        let red = try #require(CoverTint.wash(for: .init(red: 0.8, green: 0.1, blue: 0.1)))
        #expect(abs(red.hue) < 0.001 || abs(red.hue - 1) < 0.001)
        #expect(red.saturation == DSLayout.bookDetailWashMaximumSaturation)
        let blue = try #require(CoverTint.wash(for: .init(red: 0.2, green: 0.3, blue: 0.7)))
        #expect(abs(blue.hue - (2.0 / 3.0 + (0.2 - 0.3) / 0.5 / 6 + 0)) < 0.05)
    }
}
