import Foundation

enum OnlineInitialChapterResolver {
    static func preferredInitialChapter(
        chapterCount: Int,
        savedPositionSnapshot: Double,
        restoreTargetChapter: Int?
    ) -> Int {
        guard chapterCount > 0 else { return 0 }

        let maxIndex = chapterCount - 1
        if let restoreTargetChapter {
            return max(0, min(restoreTargetChapter, maxIndex))
        }

        let clampedProgress = min(1.0, max(0.0, savedPositionSnapshot))
        let resolved = Int(round(clampedProgress * Double(maxIndex)))
        return max(0, min(resolved, maxIndex))
    }
}
