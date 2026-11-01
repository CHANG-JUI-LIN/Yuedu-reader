import Foundation

/// 書籤卡片上那段摘錄的整理。
enum ReaderBookmarkExcerpt {
    /// The excerpt as text to read. A stored excerpt keeps the U+FFFC of each picture it
    /// spans, character for character with the book (`PictureOffsetMigration` reads it so);
    /// a picture has no text to show.
    static func plain(_ excerpt: String) -> String {
        excerpt.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// 去掉摘錄開頭重複的章名。
    ///
    /// 章首那一頁的內文第一行就是排進版面的章節標題（`plainText(forPage:)` 取的是
    /// 排版後的文字，標題也在裡面），而卡片正上方的分組標題已經寫著同一個章名——
    /// 不處理的話，整張卡片的兩行就只是把標題再抄一次，看不出這一頁講什麼。
    ///
    /// 比對時忽略空白：版面裡的標題用全形空格分隔，目錄裡的同一個標題用半形，
    /// 直接 `hasPrefix` 對不上。
    static func body(of excerpt: String, chapterTitle: String) -> String {
        let trimmedExcerpt = plain(excerpt).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !trimmedExcerpt.isEmpty else { return trimmedExcerpt }

        var excerptIndex = trimmedExcerpt.startIndex
        var titleIndex = title.startIndex
        while titleIndex < title.endIndex {
            if title[titleIndex].isWhitespace {
                titleIndex = title.index(after: titleIndex)
                continue
            }
            guard excerptIndex < trimmedExcerpt.endIndex else { return trimmedExcerpt }
            if trimmedExcerpt[excerptIndex].isWhitespace {
                excerptIndex = trimmedExcerpt.index(after: excerptIndex)
                continue
            }
            guard trimmedExcerpt[excerptIndex] == title[titleIndex] else { return trimmedExcerpt }
            excerptIndex = trimmedExcerpt.index(after: excerptIndex)
            titleIndex = title.index(after: titleIndex)
        }

        let rest = trimmedExcerpt[excerptIndex...].trimmingCharacters(in: .whitespacesAndNewlines)
        // 整段摘錄就只有章名（標題自己佔滿一頁的封面頁）：留著章名，空白卡片更難認。
        return rest.isEmpty ? trimmedExcerpt : rest
    }
}
