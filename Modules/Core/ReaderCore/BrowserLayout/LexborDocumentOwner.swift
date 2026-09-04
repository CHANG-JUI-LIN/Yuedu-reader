import CLexbor

final class LexborDocumentOwner {
    enum Error: Swift.Error, Equatable {
        case invalidInput
        case parseFailed
        case outOfMemory
    }

    private var reference: OpaquePointer?

    init(html: String) throws {
        var status = YLX_STATUS_OK
        reference = html.utf8CString.withUnsafeBytes { bytes in
            ylx_document_create(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                max(0, bytes.count - 1),
                &status
            )
        }

        guard reference != nil else {
            throw Self.error(for: status)
        }
    }

    deinit {
        ylx_document_destroy(reference)
    }

    func withDocument<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        try body(reference!)
    }

    private static func error(for status: YLXStatus) -> Error {
        switch status {
        case YLX_STATUS_INVALID_ARGUMENT:
            return .invalidInput
        case YLX_STATUS_OUT_OF_MEMORY:
            return .outOfMemory
        default:
            return .parseFailed
        }
    }
}
