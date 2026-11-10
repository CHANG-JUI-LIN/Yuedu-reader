import Foundation

/// Files for the AI cast: one roster per book, one small file per analysed chapter.
///
/// One file per chapter rather than one per book: a long web novel listened to end to end is
/// thousands of chapters, and rewriting all of them every time one more is analysed is the
/// kind of disk write that grows with the user's library. An actor, so writes to one book's
/// roster cannot land out of order.
actor AIDialogueCastStore {
    static let shared = AIDialogueCastStore()

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIDialogueCast", isDirectory: true)
    }

    private func bookURL(_ book: UUID) -> URL {
        directory.appendingPathComponent(book.uuidString, isDirectory: true)
    }

    private func rosterURL(_ book: UUID) -> URL {
        bookURL(book).appendingPathComponent("roster.json")
    }

    private func chapterURL(_ book: UUID, key: String) -> URL {
        bookURL(book).appendingPathComponent("chapters", isDirectory: true).appendingPathComponent("\(key).json")
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    /// An empty roster when the book was never analysed; a corrupt file throws rather than
    /// reading as empty, so a later save cannot overwrite a cast the reader built up.
    func roster(book: UUID) throws -> TTSDialogueRoster {
        let url = rosterURL(book)
        guard FileManager.default.fileExists(atPath: url.path) else { return TTSDialogueRoster() }
        return try JSONDecoder().decode(TTSDialogueRoster.self, from: Data(contentsOf: url))
    }

    func save(roster: TTSDialogueRoster, book: UUID) throws {
        try write(roster, to: rosterURL(book))
    }

    func chapter(book: UUID, key: String) throws -> TTSChapterDialogue? {
        let url = chapterURL(book, key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(TTSChapterDialogue.self, from: Data(contentsOf: url))
    }

    func save(chapter: TTSChapterDialogue, book: UUID) throws {
        try write(chapter, to: chapterURL(book, key: chapter.key))
    }

    func clear(book: UUID) throws {
        let url = bookURL(book)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
