import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// The detail hero: where reading resumes (方案 A, 2026-10-12), and the block of the cover's
/// colour it stands on (2026-11-12), dark enough for the text on it.
@Suite("Detail hero: resume label and cover colour")
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

    // The hero's block (2026-11-12): the cover's colour, darkened until its text reads on it.

    @Test("the block is dark enough for its light line and for white, whatever the cover")
    func blockGroundReads() {
        let white = CoverTint.RGB(red: 1, green: 1, blue: 1)
        let covers: [CoverTint.RGB] = [
            .init(red: 0.94, green: 0.91, blue: 0.82), .init(red: 0.5, green: 0.5, blue: 0.5),
            .init(red: 0.8, green: 0.1, blue: 0.1), .init(red: 0.2, green: 0.3, blue: 0.7),
            .init(red: 0.98, green: 0.85, blue: 0.2), .init(red: 0.05, green: 0.05, blue: 0.05),
        ]
        for cover in covers {
            for (increased, minimum) in [(false, 4.5), (true, 7.0)] {
                let ground = CoverTint.blockGround(for: cover, increasedContrast: increased)
                // The bisection stops a hair under the target.
                #expect(CoverTint.contrast(CoverTint.blockLine(for: cover), ground) >= minimum - 0.01)
                #expect(CoverTint.contrast(white, ground) >= minimum - 0.01)
            }
        }
    }

    @Test("a cover dark already keeps its colour; none yet is the placeholder grey, darkened as a cover is")
    func blockGroundKeepsADarkCover() {
        let dark = CoverTint.RGB(red: 0.1, green: 0.12, blue: 0.2)
        #expect(CoverTint.blockGround(for: dark, increasedContrast: false) == dark)
        let waiting = CoverTint.blockGround(for: nil, increasedContrast: false)
        #expect(waiting == CoverTint.blockGround(for: CoverTint.placeholder, increasedContrast: false))
        #expect(CoverTint.contrast(CoverTint.blockLine(for: nil), waiting) >= 4.5 - 0.01)
    }

    // A video's page is drawn in the colour of its poster's foot, the part it fades into.
    @Test("the foot of a poster is its bottom rows, not its top")
    func posterFootAverage() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let poster = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 30), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 24))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 24, width: 20, height: 6))
        }
        let foot = try #require(CoverTint.average(of: poster, bottomFraction: 0.2))
        #expect(foot.blue > 0.9 && foot.red < 0.1)
        let whole = try #require(CoverTint.average(of: poster))
        #expect(whole.red > 0.7 && whole.blue > 0.1)
    }
}
