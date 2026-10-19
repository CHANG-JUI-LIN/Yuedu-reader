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

        let path = try MetricKitCallStack.heaviestPath(fromJSON: data, order: .rootIsEntryPoint)

        #expect(path.frames.map(\.offsetIntoTextSegment) == [300, 200, 100])
        #expect(path.frames.first?.binaryName == "YueduReader")
        #expect(path.totalSamples == 23)
        #expect(path.threadAttributed)
    }

    /// A crash's tree is a backtrace whose root is the crashing frame. Reversing it, as
    /// for sampled trees, put `start` at frame 0: every MetricKit crash then blamed the
    /// thread entry point and folded into one issue.
    @Test("a crash backtrace keeps its root, the crashing frame, first")
    func crashBacktraceStaysLeafFirst() throws {
        let entry = frame("AAAA", 100, 1, "dyld")
        let caller = frame("BBBB", 200, 1, "YueduReader", sub: [entry])
        let crashed = frame("CCCC", 300, 1, "libsystem_kernel.dylib", sub: [caller])
        let data = try tree([["threadAttributed": true, "callStackRootFrames": [crashed]]])

        let path = try MetricKitCallStack.heaviestPath(fromJSON: data, order: .rootIsLeaf)

        #expect(path.frames.map(\.offsetIntoTextSegment) == [300, 200, 100])
    }

    /// Field shape, 3.0.0 (129) on iOS 27.2: a scene-update watchdog kill delivered as a
    /// sampled tree (sample counts 25…53) whose root is `start_wqthread`, not the frame that
    /// was running. Read as the crash order says, the report put the thread entry point at
    /// frame 0 and cut the real leaf (`write`) off the end.
    @Test("a crash tree rooted at the thread entry point is still returned leaf first")
    func crashTreeRootedAtEntryPointIsReversed() throws {
        let leaf = frame("CCCC", 300, 25, "libsystem_kernel.dylib")
        let caller = frame("BBBB", 200, 25, "YueduReader", sub: [leaf])
        let entry = frame("AAAA", 100, 53, "libsystem_pthread.dylib", sub: [caller])
        let data = try tree([["threadAttributed": true, "callStackRootFrames": [entry]]])

        let path = try MetricKitCallStack.heaviestPath(fromJSON: data, order: .rootIsLeaf)

        #expect(path.frames.map(\.offsetIntoTextSegment) == [300, 200, 100])
    }

    /// Field shape, 3.0.0 (129) on iOS 17.0: the watchdog backtrace's root is the leaf
    /// (`libobjc`) and `dyld` is its deepest frame. A sampled-order hint must not flip it.
    @Test("a tree whose deepest frame is dyld keeps its root first whatever the hint")
    func treeEndingInDyldKeepsRootFirst() throws {
        let entry = frame("AAAA", 100, 1, "dyld")
        let caller = frame("BBBB", 200, 1, "UIKitCore", sub: [entry])
        let leaf = frame("CCCC", 300, 1, "libobjc.A.dylib", sub: [caller])
        let data = try tree([["threadAttributed": true, "callStackRootFrames": [leaf]]])

        let path = try MetricKitCallStack.heaviestPath(fromJSON: data, order: .rootIsEntryPoint)

        #expect(path.frames.map(\.offsetIntoTextSegment) == [300, 200, 100])
    }

    /// The scene-update watchdog judges the main thread. With no thread attributed, the
    /// busiest one was a libdispatch worker writing a file, and the report blamed it.
    @Test("with no thread attributed, the main thread wins over a busier worker")
    func mainThreadWinsWhenNoneAttributed() throws {
        let workerLeaf = frame("DDDD", 40, 53, "libsystem_kernel.dylib")
        let worker = frame("CCCC", 30, 53, "libsystem_pthread.dylib", sub: [workerLeaf])
        let mainLeaf = frame("BBBB", 20, 9, "SwiftUI")
        let main = frame("AAAA", 10, 9, "dyld", sub: [mainLeaf])
        let data = try tree([
            ["threadAttributed": false, "callStackRootFrames": [worker]],
            ["threadAttributed": false, "callStackRootFrames": [main]],
        ])

        let path = try MetricKitCallStack.heaviestPath(fromJSON: data, order: .rootIsLeaf)

        #expect(path.frames.map(\.offsetIntoTextSegment) == [20, 10])
    }

    @Test("the attributed thread wins over a busier unattributed one")
    func attributedThreadWins() throws {
        let busy = frame("AAAA", 1, 90)
        let blamed = frame("BBBB", 2, 10)
        let data = try tree([
            ["threadAttributed": false, "callStackRootFrames": [busy]],
            ["threadAttributed": true, "callStackRootFrames": [blamed]],
        ])
        #expect(try MetricKitCallStack.heaviestPath(fromJSON: data, order: .rootIsEntryPoint).frames.map(\.offsetIntoTextSegment) == [2])
    }

    @Test("a frame in a binary loaded now maps to its address in this process")
    func loadedBinaryFrameGetsAddress() throws {
        let header = try #require(_dyld_get_image_header(0))
        let uuid = try #require(LoadedImages.uuid(of: header))
        let data = try tree([["threadAttributed": true, "callStackRootFrames": [frame(uuid.lowercased(), 0x1234, 5)]]])

        let path = try MetricKitCallStack.heaviestPath(fromJSON: data, order: .rootIsEntryPoint)

        #expect(path.frames.first?.loadedAddress == UInt(bitPattern: header) + 0x1234)
    }

    @Test("a frame from a binary that is not loaded keeps its offset as text")
    func unloadedBinaryFrameHasNoAddress() throws {
        let data = try tree([["callStackRootFrames": [frame("00000000-0000-0000-0000-000000000000", 0xbeef, 1, "OldBuild")]]])
        let first = try #require(try MetricKitCallStack.heaviestPath(fromJSON: data, order: .rootIsEntryPoint).frames.first)
        #expect(first.loadedAddress == nil)
        #expect(first.readable == "OldBuild + 0xbeef")
    }

    @Test("a tree without stacks is an error, not an empty report")
    func emptyTreeThrows() throws {
        #expect(throws: MetricKitCallStack.ParseError.self) {
            try MetricKitCallStack.heaviestPath(fromJSON: try tree([]), order: .rootIsEntryPoint)
        }
    }
}
