import Testing
@testable import yuedu_app

/// 分類卡's designed faces (maintainer, 2026-10-27: 「我們肯定要根據分類作默認的圖片設計」): the
/// kind of book a list's name says, in any of the app's languages, picks its drawing.
@Suite("分類卡's designed faces")
struct HomeCategoryFaceTests {
    @Test("a name's kind picks its drawing, in every language")
    func kinds() {
        let expected: [String: String] = [
            "玄幻": "wand.and.stars", "奇幻小說": "wand.and.stars", "言情": "heart.fill", "Romance": "heart.fill",
            "恋愛小説": "heart.fill", "懸疑推理": "magnifyingglass", "ミステリー": "magnifyingglass",
            "科幻": "atom", "Science Fiction": "atom", "歷史": "building.columns.fill", "武俠": "figure.martial.arts",
            "漫畫": "bubble.left.and.bubble.right.fill", "輕小說": "sparkles", "판타지": "wand.and.stars",
        ]
        for (name, symbol) in expected {
            #expect(HomeCategoryFace(name: name).symbol == symbol, "\(name)")
        }
    }

    @Test("a Latin keyword is a whole word: software is not war, nor newsletter new")
    func wholeWords() {
        #expect(HomeCategoryFace(name: "Software").symbol == "book.closed.fill")
        #expect(HomeCategoryFace(name: "Newsletter").symbol == "book.closed.fill")
        #expect(HomeCategoryFace(name: "War and Peace").symbol == "shield.fill")
    }

    @Test("a name of no kind gets a book, on the same ground every time, one of the palette's")
    func unmatched() {
        let face = HomeCategoryFace(name: "本週精選")
        #expect(face.symbol == "book.closed.fill")
        #expect(face == HomeCategoryFace(name: "本週精選"))
        #expect(DSColor.categoryArtPalette.indices.contains(face.palette))
        let grounds = Set(["本週精選", "編輯推薦", "Staff Picks", "おすすめ", "新世界"].map { HomeCategoryFace(name: $0).palette })
        #expect(grounds.count > 1, "names spread over the palette")
    }

    @Test("every kind's ground is one of the palette's")
    func palette() {
        for name in ["玄幻", "言情", "耽美", "科幻", "恐怖", "遊戲", "體育", "排行", "完結", "經典", "動物"] {
            #expect(DSColor.categoryArtPalette.indices.contains(HomeCategoryFace(name: name).palette), "\(name)")
        }
    }
}
