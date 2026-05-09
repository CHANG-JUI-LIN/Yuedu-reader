import Foundation

enum ReaderProgressRestoreResolver {
    static func resolvePage(
        chapterIndex: Int,
        charOffset: Int,
        resolver: (CoreTextReadingPosition) -> Int?
    ) -> Int? {
        resolver(
            CoreTextReadingPosition(
                spineIndex: chapterIndex,
                charOffset: max(0, charOffset)
            )
        )
    }
}

