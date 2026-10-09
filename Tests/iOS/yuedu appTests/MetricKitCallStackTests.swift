import Foundation
import MachO
import Testing
@testable import yuedu_app

/// MetricKit hands over a sampled call tree. Crashlytics only received the first 7 000
/// characters of it — the root frames — so every hang report showed the run loop and none
/// showed the code that blocked. These pin down the heaviest path and the address mapping
/// Crashlytics symbolicates.
@Suite("MetricKit call stack")
struct MetricKitCallStackTests {
    private func frame(_ uuid: String, _ offset: Int, _ samples: Int, _ name: String? = nil, sub: [[String: Any]] = []) -> [String: Any] {
        var object: [String: Any] = [
            "binaryUUID": uuid, "offsetIntoBinaryTextSegment": offset, "sampleCount": samples, "subFrames": sub,
        ]
        if let name { object["binaryName"] = name }
        return object
    }

    private func tree(_ stacks: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["callStackPerThread": true, "callStacks": stacks])
    }

    @Test("the heaviest path is followed to the leaf, and returned leaf first")
    func heaviestPathLeafFirst() throws {
        let leafHeavy = frame("CCCC", 300, 20, "YueduReader")
        let leafLight = frame("DDDD", 400, 3, "YueduReader")
        let middle = frame("BBBB", 200, 23, "UIKitCore", sub: [leafLight, leafHeavy])
        let root = frame("AAAA", 100, 23, "dyld", sub: [middle])
        let data = try tree([["threadAttributed": true, "callStackRootFrames": [root]]])

        let path = try MetricKitCallStack.heaviestPath(fromJSON: data)

        #expect(path.frames.map(\.offsetIntoTextSegment) == [300, 200, 100])
        #expect(path.frames.first?.binaryName == "YueduReader")
        #expect(path.totalSamples == 23)
        #expect(path.threadAttributed)
    }

    @Test("the attributed thread wins over a busier unattributed one")
    func attributedThreadWins() throws {
        let busy = frame("AAAA", 1, 90)
        let blamed = frame("BBBB", 2, 10)
        let data = try tree([
            ["threadAttributed": false, "callStackRootFrames": [busy]],
            ["threadAttributed": true, "callStackRootFrames": [blamed]],
        ])
        #expect(try MetricKitCallStack.heaviestPath(fromJSON: data).frames.map(\.offsetIntoTextSegment) == [2])
    }

    @Test("a frame in a binary loaded now maps to its address in this process")
    func loadedBinaryFrameGetsAddress() throws {
        let header = try #require(_dyld_get_image_header(0))
        let uuid = try #require(LoadedImages.uuid(of: header))
        let data = try tree([["threadAttributed": true, "callStackRootFrames": [frame(uuid.lowercased(), 0x1234, 5)]]])

        let path = try MetricKitCallStack.heaviestPath(fromJSON: data)

        #expect(path.frames.first?.loadedAddress == UInt(bitPattern: header) + 0x1234)
    }

    @Test("a frame from a binary that is not loaded keeps its offset as text")
    func unloadedBinaryFrameHasNoAddress() throws {
        let data = try tree([["callStackRootFrames": [frame("00000000-0000-0000-0000-000000000000", 0xbeef, 1, "OldBuild")]]])
        let first = try #require(try MetricKitCallStack.heaviestPath(fromJSON: data).frames.first)
        #expect(first.loadedAddress == nil)
        #expect(first.readable == "OldBuild + 0xbeef")
    }

    @Test("a tree without stacks is an error, not an empty report")
    func emptyTreeThrows() throws {
        #expect(throws: MetricKitCallStack.ParseError.self) {
            try MetricKitCallStack.heaviestPath(fromJSON: try tree([]))
        }
    }
}
