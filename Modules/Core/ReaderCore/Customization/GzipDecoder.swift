import Compression
import Foundation

enum GzipDecoderError: Error, Equatable {
    case notGzip
    case unsupportedMethod(UInt8)
    case truncated
    case corrupt
    case tooLarge(maximum: Int)
    case lengthMismatch(expected: UInt32, actual: Int)
}

/// RFC 1952 gzip members, as Reeden writes its highlight packs and the artwork inside
/// them. Foundation only inflates raw DEFLATE, so the header and trailer are read here.
enum GzipDecoder {
    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    static func decompress(_ data: Data, maximumBytes: Int) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B else { throw GzipDecoderError.notGzip }
        guard bytes[2] == 8 else { throw GzipDecoderError.unsupportedMethod(bytes[2]) }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= bytes.count else { throw GzipDecoderError.truncated }
            offset += 2 + (Int(bytes[offset]) | Int(bytes[offset + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 { // FNAME, FCOMMENT
            guard let end = bytes[min(offset, bytes.count)...].firstIndex(of: 0) else {
                throw GzipDecoderError.truncated
            }
            offset = end + 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard offset < bytes.count - 8 else { throw GzipDecoderError.truncated }

        let trailer = bytes[(bytes.count - 4)...]
        let expectedLength = trailer.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let output = try inflate(Array(bytes[offset ..< bytes.count - 8]), maximumBytes: maximumBytes)
        // ISIZE is the length modulo 2^32.
        guard UInt32(truncatingIfNeeded: output.count) == expectedLength else {
            throw GzipDecoderError.lengthMismatch(expected: expectedLength, actual: output.count)
        }
        return output
    }

    /// Raw DEFLATE (`COMPRESSION_ZLIB` is headerless), streamed so a hostile member
    /// stops at `maximumBytes` instead of expanding in full first.
    private static func inflate(_ input: [UInt8], maximumBytes: Int) throws -> Data {
        let chunk = 64 * 1_024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { destination.deallocate() }
        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }
        var stream = compression_stream(
            dst_ptr: placeholder, dst_size: 0, src_ptr: placeholder, src_size: 0, state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK else { throw GzipDecoderError.corrupt }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        return try input.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { throw GzipDecoderError.truncated }
            stream.src_ptr = base
            stream.src_size = source.count
            while true {
                stream.dst_ptr = destination
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(destination, count: chunk - stream.dst_size)
                guard output.count <= maximumBytes else {
                    throw GzipDecoderError.tooLarge(maximum: maximumBytes)
                }
                switch status {
                case COMPRESSION_STATUS_END: return output
                case COMPRESSION_STATUS_OK:
                    // No progress with input left means the stream is cut short.
                    if stream.src_size == 0, stream.dst_size == chunk { throw GzipDecoderError.truncated }
                default: throw GzipDecoderError.corrupt
                }
            }
        }
    }
}
