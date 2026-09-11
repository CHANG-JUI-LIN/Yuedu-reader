import Foundation
import Testing
@testable import yuedu_app

@Suite("Calibre wireless protocol", .serialized)
struct CalibreWirelessProtocolTests {
    @Test("Length prefixes count UTF-8 bytes and accept every TCP split")
    func unicodeFrameFragmentation() throws {
        let frame = CalibreFrame(16, ["title": .string("中文😀 [電子書]"), "authors": .array([.string("作者")])])
        let bytes = try frame.encoded()
        let bracket = try #require(bytes.firstIndex(of: 91))
        let length = try #require(Int(String(decoding: bytes[..<bracket], as: UTF8.self)))
        #expect(length == bytes.count - bracket)
        for split in 0...bytes.count {
            var decoder = CalibreWireBuffer()
            try decoder.append(Data(bytes.prefix(split)))
            let first = try decoder.nextFrame()
            if split == bytes.count { #expect(first == frame) }
            else {
                #expect(first == nil)
                try decoder.append(Data(bytes.dropFirst(split)))
                let completed = try decoder.nextFrame()
                #expect(completed == frame)
            }
            #expect(decoder.data.isEmpty)
        }
    }

    @Test("Binary content and the next command can occupy the same socket buffer")
    func coalescedFileAndCommand() throws {
        let header = CalibreFrame(8, ["length": .number(9)])
        let file = Data([91, 48, 44, 255, 0, 93, 91, 49, 93])
        let next = CalibreFrame(12, ["ejecting": .bool(true)])
        var decoder = CalibreWireBuffer()
        var bytes = try header.encoded()
        bytes.append(file)
        bytes.append(try next.encoded())
        try decoder.append(bytes)
        let receivedHeader = try decoder.nextFrame()
        #expect(receivedHeader == header)
        let firstChunk = decoder.takeBinary(upTo: 4)
        let lastChunk = decoder.takeBinary(upTo: 5)
        #expect(firstChunk + lastChunk == file)
        let nextCommand = try decoder.nextFrame()
        #expect(nextCommand == next)
        #expect(decoder.data.isEmpty)
    }

    @Test("Malformed framing and excessive lengths fail before allocation")
    func rejectsInvalidFrames() throws {
        let invalid = ["-1[0,{}]", "0[0,{}]", "999999999[0,{}]", "8388609[0,{}]", "3[0]", "8[999,{}]", "8[0, null", "6[0,[]]"]
        for source in invalid {
            var decoder = CalibreWireBuffer()
            try decoder.append(Data(source.utf8))
            #expect(throws: CalibreWirelessError.self) { _ = try decoder.nextFrame() }
        }
        var decoder = CalibreWireBuffer()
        #expect(throws: CalibreWirelessError.self) {
            try decoder.append(Data(repeating: 0, count: CalibreWireBuffer.maximumFrameLength + CalibreWireBuffer.packetLength + 11))
        }
    }

    @Test("Handshake uses Calibre SHA1 challenge and advertises only implemented capabilities")
    func challengeAndCapabilities() throws {
        let response = try CalibreWirelessHandshake.response(to: [
            "serverProtocolVersion": .number(1),
            "passwordChallenge": .string("2026-09-10T12:00:00+00:00"),
            "validExtensions": .array([.string("epub"), .string("mobi"), .string("pdf")])
        ], password: "secret", deviceName: "Yuedu iPhone")
        #expect(response.opcode == 0)
        #expect(response.arguments["passwordHash"] == .string("74f13475f71d6e993fda62bf704e51fbfaddd213"))
        #expect(response.arguments["acceptedExtensions"] == .array([.string("epub"), .string("pdf")]))
        #expect(response.arguments["canUseCachedMetadata"] == .bool(false))
        #expect(response.arguments["canDeleteMultipleBooks"] == .bool(true))
        #expect(response.arguments["canReceiveBookBinary"] == .bool(true))
        #expect(response.arguments["canSendOkToSendbook"] == .bool(true))
        #expect(throws: CalibreWirelessError.unsupportedProtocol) {
            _ = try CalibreWirelessHandshake.response(to: ["serverProtocolVersion": .number(2)], password: "", deviceName: "Yuedu")
        }
    }

    @Test("Transfer preflight rejects traversal, unsupported, zero, fractional and excessive files")
    func incomingValidation() throws {
        let valid: [String: CalibreJSON] = ["lpath": .string("中文/library.epub"), "length": .number(20), "metadata": .object([:]), "willStreamBinary": .bool(true)]
        let accepted = try CalibreIncomingBook(arguments: valid, availableSpace: 1_000_000_000)
        #expect(accepted.lpath == "中文/library.epub")
        let replacements: [[String: CalibreJSON]] = [
            ["lpath": .string("../secrets.epub")], ["lpath": .string("book.exe")],
            ["length": .number(0)], ["length": .number(-1)], ["length": .number(1.5)],
            ["length": .number(30_000_000_000)], ["willStreamBinary": .bool(false)]
        ]
        for replacement in replacements {
            let arguments = valid.merging(replacement) { _, new in new }
            #expect(throws: CalibreWirelessError.invalidBook) { _ = try CalibreIncomingBook(arguments: arguments, availableSpace: Int64.max) }
        }
        #expect(throws: CalibreWirelessError.insufficientSpace) { _ = try CalibreIncomingBook(arguments: valid, availableSpace: 10) }
    }

    @Test("Partial and oversized receives are never committed; cleanup removes every temporary byte")
    func partialCancellationAndCommit() throws {
        let incoming = try CalibreIncomingBook(arguments: ["lpath": .string("book.txt"), "length": .number(6), "metadata": .object([:]), "willStreamBinary": .bool(true)], availableSpace: 1_000_000_000)
        let incomplete = try CalibreIncomingFile(book: incoming)
        try incomplete.append(Data("abc".utf8))
        #expect(throws: CalibreWirelessError.disconnected) { _ = try incomplete.finish() }
        #expect(throws: CalibreWirelessError.invalidBook) { try incomplete.append(Data("defg".utf8)) }
        incomplete.cleanup()
        #expect(!FileManager.default.fileExists(atPath: incomplete.directory.path))
        let complete = try CalibreIncomingFile(book: incoming)
        defer { complete.cleanup() }
        try complete.append(Data("abc".utf8))
        try complete.append(Data("def".utf8))
        let committed = try complete.finish()
        #expect(committed.url.pathExtension == "txt")
        #expect(try Data(contentsOf: committed.url) == Data("abcdef".utf8))
        #expect(committed.sha256 == "bef57ec7f53a6d40beb640a780a639c83bc29ac8a9816f1fc6c5c6dcd93c4721")
        #expect(!FileManager.default.fileExists(atPath: complete.directory.appendingPathComponent("incoming.partial").path))
    }
}
