import Foundation

struct ReaderContentMetrics: Equatable, Sendable {
    let currentUnitOffset: Int
    let totalUnitCount: Int

    var remainingUnitCount: Int {
        max(0, totalUnitCount - currentUnitOffset)
    }
}

struct ReaderContentUnitMap: Equatable, Sendable {
    private let chapterOffsets: [Int]

    init?(chapterUnitCounts: [Int]) {
        guard !chapterUnitCounts.isEmpty,
              chapterUnitCounts.allSatisfy({ $0 >= 0 })
        else {
            return nil
        }

        var offsets = [0]
        offsets.reserveCapacity(chapterUnitCounts.count + 1)
        for count in chapterUnitCounts {
            let (next, overflow) = offsets[offsets.count - 1].addingReportingOverflow(count)
            guard !overflow else { return nil }
            offsets.append(next)
        }
        guard offsets[offsets.count - 1] > 0 else { return nil }
        chapterOffsets = offsets
    }

    var totalUnitCount: Int {
        chapterOffsets[chapterOffsets.count - 1]
    }

    func metrics(
        spineIndex: Int,
        localCharacterOffset: Int,
        currentChapterCharacterCount: Int?
    ) -> ReaderContentMetrics? {
        guard spineIndex >= 0,
              spineIndex + 1 < chapterOffsets.count,
              localCharacterOffset >= 0
        else {
            return nil
        }

        let chapterStart = chapterOffsets[spineIndex]
        let chapterUnitCount = chapterOffsets[spineIndex + 1] - chapterStart
        let localUnitOffset: Int

        if localCharacterOffset == 0 || chapterUnitCount == 0 {
            localUnitOffset = 0
        } else {
            guard let currentChapterCharacterCount,
                  currentChapterCharacterCount > 0
            else {
                return nil
            }
            let clampedOffset = min(localCharacterOffset, currentChapterCharacterCount)
            let fraction = Double(clampedOffset) / Double(currentChapterCharacterCount)
            let scaled = fraction * Double(chapterUnitCount)
            guard scaled.isFinite, scaled >= 0, scaled <= Double(Int.max) else {
                return nil
            }
            localUnitOffset = min(Int(scaled), chapterUnitCount)
        }

        let (currentUnitOffset, overflow) = chapterStart.addingReportingOverflow(localUnitOffset)
        guard !overflow else { return nil }
        return ReaderContentMetrics(
            currentUnitOffset: currentUnitOffset,
            totalUnitCount: totalUnitCount
        )
    }
}
