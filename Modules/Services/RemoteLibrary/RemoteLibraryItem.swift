import Foundation

struct RemoteLibraryFormat: Codable, Hashable, Identifiable, Sendable {
    let url: URL
    let fileExtension: String
    let mimeType: String
    var size: Int64? = nil

    init(url: URL, fileExtension: String, mimeType: String, size: Int64? = nil) {
        self.url = url
        self.fileExtension = fileExtension.lowercased()
        self.mimeType = mimeType
        self.size = size
    }

    var id: String { url.absoluteString + "#" + fileExtension.lowercased() }
    var isSupported: Bool { ["epub", "pdf", "txt", "md", "markdown"].contains(fileExtension.lowercased()) }
    var displayName: String { fileExtension.uppercased() }
}

struct RemoteLibraryItem: Identifiable, Hashable, Sendable {
    let id: String
    let connectionID: String
    let title: String
    var author: String? = nil
    var summary: String? = nil
    var coverURL: URL? = nil
    let formats: [RemoteLibraryFormat]
}

/// A remote file is not a rule-based web novel. Its format still selects the
/// normal EPUB/TXT/PDF pipeline; only resource acquisition differs.
struct RemoteBookReference: Codable, Hashable, Sendable {
    let connectionID: String
    let entryID: String
    var format: RemoteLibraryFormat
    var version: String? = nil
    var contentLength: Int64? = nil
    var entityTag: String? = nil
    var lastModified: String? = nil
    var cachedFilename: String? = nil
    var offlineFilename: String? = nil

    func matches(item: RemoteLibraryItem, format: RemoteLibraryFormat) -> Bool {
        connectionID == item.connectionID && entryID == item.id
            && self.format.fileExtension.lowercased() == format.fileExtension.lowercased()
    }
}

enum RemoteLibraryError: LocalizedError {
    case missingConnection, unsupportedFormat, missingBook, contentChanged, invalidResponse, offlineContentMissing

    var errorDescription: String? {
        switch self {
        case .missingConnection: return localized("找不到書庫連線，請重新設定伺服器")
        case .unsupportedFormat: return localized("此格式暫不支援閱讀")
        case .missingBook: return localized("找不到閱讀紀錄")
        case .contentChanged: return localized("遠端書籍已更新，請返回書籍詳情重新開啟")
        case .invalidResponse: return localized("伺服器傳回的書籍資料無效")
        case .offlineContentMissing: return localized("目前沒有可用的離線內容，請連線後再試")
        }
    }
}
