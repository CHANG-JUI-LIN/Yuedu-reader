import Foundation
import QuartzCore

struct CoreTextScrollProgressThrottle {
    var minimumInterval: CFTimeInterval

    private var lastProgressReportTime: CFTimeInterval = 0
    private var lastProgressRow: Int?

    init(minimumInterval: CFTimeInterval) {
        self.minimumInterval = minimumInterval
    }

    mutating func shouldReport(row: Int, time: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard row == lastProgressRow else {
            lastProgressRow = row
            lastProgressReportTime = time
            return true
        }

        guard time - lastProgressReportTime >= minimumInterval else {
            return false
        }

        lastProgressReportTime = time
        return true
    }

    mutating func reset() {
        lastProgressReportTime = 0
        lastProgressRow = nil
    }
}
