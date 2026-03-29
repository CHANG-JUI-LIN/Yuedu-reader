import XCTest
@testable import yuedu_app

@MainActor
final class EPUBSnapshotManagerTests: XCTestCase {
    
    func testPriorityQueueSorting() {
        let req1 = SnapshotRequest(chapterIndex: 0, pageIndex: 1, priority: .background)
        let req2 = SnapshotRequest(chapterIndex: 0, pageIndex: 2, priority: .immediate)
        let req3 = SnapshotRequest(chapterIndex: 0, pageIndex: 3, priority: .onDemand)
        
        var queue = [req1, req2, req3]
        queue.sort { $0.priority > $1.priority }
        
        XCTAssertEqual(queue[0].priority, .immediate)
        XCTAssertEqual(queue[1].priority, .onDemand)
        XCTAssertEqual(queue[2].priority, .background)
    }
    
    func testLRUMemoryCacheInstantiation() {
        let manager = EPUBSnapshotManager(workerCount: 0)
        // Memory limit of 6 as per specs
        // We will just verify it doesn't crash on instantiation
        XCTAssertNotNil(manager)
    }
}
