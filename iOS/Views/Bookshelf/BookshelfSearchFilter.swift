import Foundation

enum BookshelfSearchFilter {
    static func filter(_ books: [ReadingBook], query: String) -> [ReadingBook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return books }

        return books.filter { book in
            book.title.range(
                of: trimmed,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ) != nil
        }
    }
}
