import Foundation

/// Where reading resumes, as a detail page's primary action shows it after its title
/// (「繼續閱讀　第 12 章」, Editorial Minimalism 方案 A, 2026-10-12). One wording for every
/// detail page.
enum BookDetailResume {
    /// 「第 N 章」 for a book read by its chapters — an online book, an audiobook — whose
    /// reading point is known; else 「已讀 N%」 for a copy read part way, 「已讀完」 for one
    /// read to the end; nil for a book not yet opened.
    ///
    /// - Parameters:
    ///   - chapterIndex: The zero-based chapter reading resumes in; nil for a book whose
    ///     spine items are not its chapters (EPUB, TXT, PDF).
    ///   - progress: The shelf copy's `currentPosition`, 0…1; nil when nothing is on the shelf.
    static func detail(chapterIndex: Int?, progress: Double?) -> String? {
        if let chapterIndex, chapterIndex >= 0 {
            return String(format: localized("第 %d 章"), chapterIndex + 1)
        }
        guard let progress, progress > 0 else { return nil }
        if progress >= 0.99 { return localized("已讀完") }
        return String(format: localized("已讀 %d%%"), Int((progress * 100).rounded()))
    }
}
