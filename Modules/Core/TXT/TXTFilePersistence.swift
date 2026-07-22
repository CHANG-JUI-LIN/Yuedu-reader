import Foundation

/// Persists a local text document without rewriting its bytes. The reader
/// already decodes UTF-8, GB18030, Big5, and UTF-16 from a memory-mapped file;
/// transcoding the whole book during import only delays entry into the library
/// and destroys the cheap clone/copy path offered by the file system.
enum TXTFilePersistence {
    static func persistOriginal(source: URL, destination: URL) throws {
        do {
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: source, to: destination)
            try Task.checkCancellation()

            let fileSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let validationPrefix = try TXTFileReader.readPrefix(
                url: destination,
                maxByteCount: 128
            )
            guard !validationPrefix.isEmpty || fileSize == 0 else {
                throw TXTFileReaderError.encodingNotSupported
            }
        } catch {
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
    }
}
