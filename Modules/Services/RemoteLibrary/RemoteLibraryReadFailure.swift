import Foundation
import ReadiumShared

/// A sendable presentation snapshot of a resource failure. It carries no reader
/// state, credentials, response body, or source-controlled HTML into the alert.
struct RemoteLibraryReadFailure: Hashable, Sendable {
    let bookID: UUID
    let message: String

    init(bookID: UUID, message: String) {
        self.bookID = bookID
        self.message = message
    }

    init?(bookID: UUID, error: HTTPError) {
        self.bookID = bookID
        switch error {
        case .cancelled:
            return nil
        case .errorResponse(let response):
            switch response.status.rawValue {
            case 401, 403: message = localized("認證失敗，請確認帳號和密碼")
            case 412: message = localized("遠端書籍已更新，請返回書籍詳情重新開啟")
            default: message = String(format: localized("連線失敗（HTTP %d）"), response.status.rawValue)
            }
        case .offline, .unreachable:
            message = localized("無法連線至書庫，請檢查網路與伺服器。")
        case .timeout:
            message = localized("連線逾時")
        case .rangeNotSupported:
            message = localized("伺服器不支援分段讀取")
        case .malformedRequest, .malformedResponse:
            message = localized("伺服器傳回的書籍資料無效")
        case .security(let underlying):
            message = underlying?.localizedDescription ?? localized("無法建立安全連線")
        case .redirection(let underlying):
            message = underlying?.localizedDescription ?? localized("伺服器重新導向失敗")
        case .fileSystem(let underlying):
            message = underlying.localizedDescription
        case .other(let underlying):
            message = underlying.localizedDescription
        }
    }
}
