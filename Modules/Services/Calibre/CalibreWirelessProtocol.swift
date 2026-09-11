import CryptoKit
import Foundation

/// Calibre 9.14 smart_device_app: decimal UTF-8 byte length immediately followed
/// by a JSON [opcode, object]. File bytes are unframed after SEND_BOOK's OK.
enum CalibreJSON: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([CalibreJSON]), object([String: CalibreJSON]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(Double.self) { self = .number(result) }
        else if let result = try? value.decode(String.self) { self = .string(result) }
        else if let result = try? value.decode([CalibreJSON].self) { self = .array(result) }
        else { self = .object(try value.decode([String: CalibreJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let result): try value.encode(result)
        case .number(let result): try value.encode(result)
        case .bool(let result): try value.encode(result)
        case .array(let result): try value.encode(result)
        case .object(let result): try value.encode(result)
        case .null: try value.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var object: [String: CalibreJSON]? { if case .object(let value) = self { value } else { nil } }
    var array: [CalibreJSON]? { if case .array(let value) = self { value } else { nil } }
    var integer: Int64? {
        guard case .number(let value) = self, value.isFinite,
              value.rounded(.towardZero) == value, value >= Double(Int64.min), value < Double(Int64.max)
        else { return nil }
        return Int64(value)
    }
}

struct CalibreFrame: Equatable, Sendable {
    let opcode: Int
    var arguments: [String: CalibreJSON]

    init(_ opcode: Int, _ arguments: [String: CalibreJSON] = [:]) {
        self.opcode = opcode
        self.arguments = arguments
    }

    func encoded() throws -> Data {
        let json = try JSONEncoder().encode(CalibreJSON.array([.number(Double(opcode)), .object(arguments)]))
        guard json.count <= CalibreWireBuffer.maximumFrameLength else { throw CalibreWirelessError.invalidFrame }
        var data = Data(String(json.count).utf8)
        data.append(json)
        return data
    }
}

/// Keeps one bounded frame plus one socket read. The caller consumes binary
/// content before asking for the next frame, even when both share a TCP packet.
struct CalibreWireBuffer {
    static let maximumFrameLength = 8 * 1_024 * 1_024
    static let packetLength = 65_536
    private(set) var data = Data()

    mutating func append(_ chunk: Data) throws {
        guard data.count + chunk.count <= Self.maximumFrameLength + Self.packetLength + 10 else {
            throw CalibreWirelessError.invalidFrame
        }
        data.append(chunk)
    }

    mutating func nextFrame() throws -> CalibreFrame? {
        guard !data.isEmpty else { return nil }
        var prefixLength = 0
        var payloadLength = 0
        for byte in data {
            if byte == 91 { break }
            guard byte >= 48, byte <= 57, prefixLength < 8 else { throw CalibreWirelessError.invalidFrame }
            payloadLength = payloadLength * 10 + Int(byte - 48)
            prefixLength += 1
            guard payloadLength <= Self.maximumFrameLength else { throw CalibreWirelessError.invalidFrame }
        }
        guard prefixLength < data.count else { return nil }
        guard prefixLength > 0, payloadLength > 0 else { throw CalibreWirelessError.invalidFrame }
        guard data.count >= prefixLength + payloadLength else { return nil }
        let payload = Data(data.dropFirst(prefixLength).prefix(payloadLength))
        let json: CalibreJSON
        do { json = try JSONDecoder().decode(CalibreJSON.self, from: payload) }
        catch { throw CalibreWirelessError.invalidFrame }
        guard let values = json.array, values.count == 2, let opcode = values[0].integer,
              opcode >= 0, opcode <= 255, let arguments = values[1].object else {
            throw CalibreWirelessError.invalidFrame
        }
        data.removeFirst(prefixLength + payloadLength)
        return CalibreFrame(Int(opcode), arguments)
    }

    mutating func takeBinary(upTo count: Int) -> Data {
        let result = Data(data.prefix(count))
        data.removeFirst(result.count)
        return result
    }
}

enum CalibreWirelessError: LocalizedError, Equatable {
    case invalidFrame, unsupportedProtocol, disconnected, invalidAddress, invalidBook
    case insufficientSpace, passwordRejected, busy, unsupportedCommand, changedBook
    case message(String)

    var errorDescription: String? {
        switch self {
        case .invalidFrame: localized("Calibre 傳輸資料格式無效")
        case .unsupportedProtocol: localized("此 Calibre 無線裝置協定版本尚未支援")
        case .disconnected: localized("Calibre 連線已中斷，未完成的檔案不會加入書架")
        case .invalidAddress: localized("請輸入有效的電腦位址與連接埠")
        case .invalidBook: localized("Calibre 傳來的書籍格式或大小無效")
        case .insufficientSpace: localized("可用空間不足，無法接收書籍")
        case .passwordRejected: localized("Calibre 無線裝置密碼不正確")
        case .busy: localized("Calibre 已連接其他裝置，請先中斷該連線")
        case .unsupportedCommand: localized("此 Calibre 裝置操作尚未支援")
        case .changedBook: localized("此 Calibre 書籍已有不同的本機副本，請先移除舊副本再傳送")
        case .message(let message): message
        }
    }
}

enum CalibreWirelessHandshake {
    static let supportedExtensions = ["epub", "pdf", "txt", "md", "markdown"]

    static func response(to arguments: [String: CalibreJSON], password: String, deviceName: String) throws -> CalibreFrame {
        guard arguments["serverProtocolVersion"]?.integer == 1 else { throw CalibreWirelessError.unsupportedProtocol }
        let valid = Set(arguments["validExtensions"]?.array?.compactMap(\.string) ?? [])
        let accepted = supportedExtensions.filter { valid.contains($0) }
        guard !accepted.isEmpty else { throw CalibreWirelessError.unsupportedProtocol }
        let challenge = arguments["passwordChallenge"]?.string ?? ""
        let hash = challenge.isEmpty ? "" : Insecure.SHA1.hash(data: Data((password + challenge).utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return CalibreFrame(0, [
            "versionOK": .bool(true), "passwordHash": .string(hash),
            "maxBookContentPacketLen": .number(Double(CalibreWireBuffer.packetLength)),
            "acceptedExtensions": .array(accepted.map(CalibreJSON.string)),
            "canStreamBooks": .bool(true), "canStreamMetadata": .bool(true),
            "canReceiveBookBinary": .bool(true), "canDeleteMultipleBooks": .bool(true),
            "canUseCachedMetadata": .bool(false), "cacheUsesLpaths": .bool(false),
            "canSendOkToSendbook": .bool(true), "canAcceptLibraryInfo": .bool(true),
            "willAskForUpdateBooks": .bool(false), "useUuidFileNames": .bool(true),
            "deviceKind": .string("iOS"), "deviceName": .string(deviceName), "appName": .string("Yuedu")
        ])
    }
}

struct CalibreIncomingBook: Sendable {
    let lpath: String
    let length: Int64
    let metadata: [String: CalibreJSON]
    let fileExtension: String

    init(arguments: [String: CalibreJSON], availableSpace: Int64) throws {
        guard let lpath = arguments["lpath"]?.string, !lpath.isEmpty, lpath.utf8.count <= 4_096,
              !lpath.contains("\0"), !lpath.split(separator: "/").contains(".."),
              let length = arguments["length"]?.integer, length > 0, length <= 20 * 1_024 * 1_024 * 1_024,
              let metadata = arguments["metadata"]?.object,
              arguments["willStreamBinary"] == .bool(true) else { throw CalibreWirelessError.invalidBook }
        let ext = (lpath as NSString).pathExtension.lowercased()
        guard CalibreWirelessHandshake.supportedExtensions.contains(ext) else { throw CalibreWirelessError.invalidBook }
        // The existing import pipeline copies the staged original. Reserve both
        // copies plus working space before telling Calibre to send raw bytes.
        let workingSpace: Int64 = 64 * 1_024 * 1_024
        guard availableSpace >= workingSpace, length <= (availableSpace - workingSpace) / 2 else { throw CalibreWirelessError.insufficientSpace }
        self.lpath = lpath
        self.length = length
        self.metadata = metadata
        self.fileExtension = ext
    }

    var title: String { String((metadata["title"]?.string ?? (lpath as NSString).lastPathComponent).prefix(500)) }
    var author: String? { metadata["authors"]?.array?.prefix(20).compactMap(\.string).map { String($0.prefix(500)) }.joined(separator: ", ") }
    var uuid: String { metadata["uuid"]?.string ?? lpath }
}

/// Disk-backed receive transaction. No partial file is visible to the importer.
final class CalibreIncomingFile {
    let directory: URL
    private let partialURL: URL
    private let finalURL: URL
    private let length: Int64
    private var handle: FileHandle?
    private var hash = SHA256()
    private(set) var received: Int64 = 0

    init(book: CalibreIncomingBook, temporaryRoot: URL = FileManager.default.temporaryDirectory) throws {
        length = book.length
        directory = temporaryRoot.appendingPathComponent("CalibreReceive-\(UUID().uuidString)", isDirectory: true)
        partialURL = directory.appendingPathComponent("incoming.partial")
        finalURL = directory.appendingPathComponent("book.\(book.fileExtension)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
            try FileManager.default.removeItem(at: directory)
            throw CalibreWirelessError.insufficientSpace
        }
        do { handle = try FileHandle(forWritingTo: partialURL) }
        catch { try FileManager.default.removeItem(at: directory); throw error }
    }

    func append(_ data: Data) throws {
        guard let handle, Int64(data.count) <= length - received else { throw CalibreWirelessError.invalidBook }
        try handle.write(contentsOf: data)
        hash.update(data: data)
        received += Int64(data.count)
    }

    func finish() throws -> (url: URL, sha256: String) {
        guard received == length, let handle else { throw CalibreWirelessError.disconnected }
        try handle.synchronize()
        try handle.close()
        self.handle = nil
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        return (finalURL, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    func cleanup() {
        do { try handle?.close() } catch { AppLogger.error("Calibre receive close failed: \(error)") }
        handle = nil
        if FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) }
            catch { AppLogger.error("Calibre receive cleanup failed: \(error)") }
        }
    }

    deinit { cleanup() }
}
