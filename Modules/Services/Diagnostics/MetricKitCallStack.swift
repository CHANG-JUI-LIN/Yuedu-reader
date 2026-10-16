import Foundation
import MachO

/// The useful part of an `MXCallStackTree`: its heaviest path, leaf first, with each frame
/// mapped onto the binaries loaded in this process so Crashlytics can symbolicate it.
///
/// Why this exists: the tree used to be sent as the first 7 000 characters of its
/// pretty-printed JSON. That kept the root frames (`start` → `main` → the run loop) and cut
/// off the leaf frames — the code that actually blocked — so every hang report read the same
/// and said nothing. A frame here is `binaryUUID` + offset into that binary's text segment;
/// when the same binary (same UUID: this build of the app, or this OS's frameworks) is loaded
/// now, `loadedAddress` is the address Crashlytics' backend symbolicates against the uploaded
/// dSYM — with file and line, and grouped per culprit instead of into one issue.
struct MetricKitCallStack: Sendable {
    struct Frame: Equatable, Sendable {
        let binaryUUID: String
        let binaryName: String?
        let offsetIntoTextSegment: UInt64
        let sampleCount: Int
        /// This frame's address in the current process, or nil when its binary is not loaded
        /// (a different build of the app, a framework this launch has not loaded).
        var loadedAddress: UInt?

        /// `UIKitCore + 0x1a2b3c`, plus the symbol `dladdr` finds for system frames.
        var readable: String {
            let binary = binaryName ?? String(binaryUUID.prefix(8))
            var text = "\(binary) + 0x\(String(offsetIntoTextSegment, radix: 16))"
            if let loadedAddress, let symbol = Self.symbolName(at: loadedAddress) {
                text += " \(symbol)"
            }
            return text
        }

        private static func symbolName(at address: UInt) -> String? {
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0,
                  let name = info.dli_sname else { return nil }
            return String(cString: name)
        }
    }

    /// Leaf first: `frames[0]` is where the samples were taken.
    let frames: [Frame]
    let totalSamples: Int
    let threadAttributed: Bool

    enum ParseError: Error {
        case notAnObject
        case noCallStacks
    }

    /// Which end of a call stack tree MetricKit puts at its roots. It differs by
    /// diagnostic, and reading one as the other blames the wrong end of the stack.
    enum TreeOrder: Sendable {
        /// Sampled diagnostics (cpu, disk writes, hangs): the root is the thread's entry
        /// point (`start` → `main` → …) and the samples were taken at the leaves.
        case rootIsEntryPoint
        /// A crash's backtrace: the root is the frame that crashed (`__pthread_kill`, a
        /// malloc trap) and each sub-frame is its caller. Verified against 2.0.7 (127)
        /// payloads symbolicated with the device's system symbols.
        case rootIsLeaf
    }

    /// Picks the attributed thread's stack (the one MetricKit blames), else the heaviest
    /// one, and follows the most-sampled child down from its roots.
    static func heaviestPath(fromJSON data: Data, order: TreeOrder) throws -> MetricKitCallStack {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notAnObject
        }
        let stacks = (root["callStacks"] as? [[String: Any]]) ?? []
        let candidates: [(attributed: Bool, roots: [[String: Any]], samples: Int)] = stacks.map { stack in
            let roots = (stack["callStackRootFrames"] as? [[String: Any]]) ?? []
            return (stack["threadAttributed"] as? Bool ?? false, roots, roots.reduce(0) { $0 + sampleCount($1) })
        }
        guard let chosen = candidates.first(where: { $0.attributed && !$0.roots.isEmpty })
            ?? candidates.filter({ !$0.roots.isEmpty }).max(by: { $0.samples < $1.samples })
        else { throw ParseError.noCallStacks }

        var path: [Frame] = []
        var level = chosen.roots
        while let heaviest = level.max(by: { sampleCount($0) < sampleCount($1) }) {
            if let frame = frame(from: heaviest) { path.append(frame) }
            level = (heaviest["subFrames"] as? [[String: Any]]) ?? []
        }
        let images = LoadedImages.current()
        let leafFirst = order == .rootIsLeaf ? path : Array(path.reversed())
        let resolved = leafFirst.map { frame -> Frame in
            var frame = frame
            if let base = images.loadAddress(forUUID: frame.binaryUUID) {
                frame.loadedAddress = base &+ UInt(frame.offsetIntoTextSegment)
            }
            return frame
        }
        return MetricKitCallStack(frames: resolved, totalSamples: chosen.samples, threadAttributed: chosen.attributed)
    }

    /// The first frames of the heaviest path, one per line — what a person reads first.
    func summary(maxFrames: Int = 30) -> String {
        frames.prefix(maxFrames).enumerated()
            .map { "\($0.offset) \($0.element.readable) (\($0.element.sampleCount))" }
            .joined(separator: "\n")
    }

    private static func sampleCount(_ frame: [String: Any]) -> Int {
        (frame["sampleCount"] as? NSNumber)?.intValue ?? 0
    }

    private static func frame(from object: [String: Any]) -> Frame? {
        guard let uuid = object["binaryUUID"] as? String,
              let offset = (object["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value
        else { return nil }
        return Frame(
            binaryUUID: uuid.uppercased(),
            binaryName: object["binaryName"] as? String,
            offsetIntoTextSegment: offset,
            sampleCount: sampleCount(object),
            loadedAddress: nil
        )
    }
}

/// UUID → load address of every Mach-O image in this process.
struct LoadedImages {
    private let baseByUUID: [String: UInt]

    func loadAddress(forUUID uuid: String) -> UInt? { baseByUUID[uuid.uppercased()] }

    static func current() -> LoadedImages {
        var map: [String: UInt] = [:]
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index),
                  let uuid = uuid(of: header) else { continue }
            map[uuid] = UInt(bitPattern: header)
        }
        return LoadedImages(baseByUUID: map)
    }

    /// Reads `LC_UUID` from a 64-bit Mach-O header already mapped in memory.
    static func uuid(of header: UnsafePointer<mach_header>) -> String? {
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.assumingMemoryBound(to: load_command.self).pointee
            if load.cmd == UInt32(LC_UUID) {
                let uuidCommand = command.assumingMemoryBound(to: uuid_command.self).pointee
                return UUID(uuid: uuidCommand.uuid).uuidString
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }
}
