import Foundation
import os
import Testing
@testable import yuedu_app

/// `LegadoScriptWaits` is read by the engine's runaway-script timer while network waits
/// (`java.ajax`, `java.ajaxAll`'s workers) start and end on other threads.
/// Crashlytics ecc0b5154d35969f8da82f73fa9270e6: `waitedSeconds` sampled the clock before
/// taking the lock, a wait starting in between set `since` past that sample, and the UInt64
/// subtraction trapped mid-search.
struct LegadoScriptWaitsTests {
    @Test func waitedSecondsStaysValidWhileWaitsStartAndEndOnOtherThreads() {
        let waits = LegadoScriptWaits()
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_500_000_000
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)

        // Writers: waits that start and end back to back, so `count` keeps crossing 0 → 1
        // and `since` keeps moving forward.
        for _ in 0..<6 {
            queue.async(group: group) {
                while DispatchTime.now().uptimeNanoseconds < deadline {
                    waits.during { }
                }
            }
        }

        // Readers: the engine's timer. Before the fix this traps on `now - since`.
        let lastRead = OSAllocatedUnfairLock(initialState: [TimeInterval](repeating: 0, count: 3))
        for index in 0..<3 {
            queue.async(group: group) {
                var previous: TimeInterval = 0
                while DispatchTime.now().uptimeNanoseconds < deadline {
                    let waited = waits.waitedSeconds
                    precondition(waited >= previous, "waitedSeconds went backwards")
                    previous = waited
                }
                let last = previous
                lastRead.withLock { $0[index] = last }
            }
        }

        group.wait()
        #expect(!waits.isWaiting)
        let finalWaited = waits.waitedSeconds
        #expect(finalWaited >= 0 && finalWaited < 10)
        #expect(lastRead.withLock { $0 }.allSatisfy { $0 <= finalWaited })
    }
}
