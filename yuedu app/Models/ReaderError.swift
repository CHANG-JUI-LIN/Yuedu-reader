import Foundation

// MARK: - 閱讀器統一錯誤類型
//
// UI 層用來捕捉並呈現錯誤的統一抽象。
// 底層各 domain 錯誤（FetchError, WebViewError, ParseError…）在 call site
// 以 ReaderError.wrap(_:) 包裹後，UI 只需處理單一類型。

enum ReaderError: LocalizedError {
    /// 網路/HTTP 層錯誤（來自 FetchError / WebViewError / URLError 等）
    case network(underlying: Error)

    /// HTML/JSON 規則解析失敗（來自 ModernRuleEngineError 等）
    case parse(underlying: Error)

    /// 本地 I/O 或資料格式錯誤（EPUB 解壓縮、TXT 編碼等）
    case rendering(underlying: Error)

    /// 快取讀寫失敗
    case cache(underlying: Error)

    /// 無法識別的錯誤
    case unknown(underlying: Error)

    // MARK: LocalizedError

    var errorDescription: String? {
        switch self {
        case .network(let err):
            return "網路錯誤：\(err.localizedDescription)"
        case .parse(let err):
            return "解析失敗：\(err.localizedDescription)"
        case .rendering(let err):
            return "渲染失敗：\(err.localizedDescription)"
        case .cache(let err):
            return "快取錯誤：\(err.localizedDescription)"
        case .unknown(let err):
            return err.localizedDescription
        }
    }

    // MARK: 自動分類工廠方法

    /// 根據底層錯誤類型自動分配類別。
    static func wrap(_ error: Error) -> ReaderError {
        if error is ReaderError {
            return error as! ReaderError
        }
        if let fetchErr = error as? FetchError {
            switch fetchErr {
            case .httpError, .cloudflareChallengeRequired, .invalidURL, .noSearchURL, .encodingError, .emptyContent:
                return .network(underlying: fetchErr)
            }
        }
        if error is ModernRuleEngineError {
            return .parse(underlying: error)
        }
        if error is BookContentProviderError {
            return .rendering(underlying: error)
        }
        if let urlErr = error as? URLError {
            return .network(underlying: urlErr)
        }
        return .unknown(underlying: error)
    }
}

// MARK: - 便利擴展

extension Error {
    /// 將任意錯誤包裹為 ReaderError
    var asReaderError: ReaderError { ReaderError.wrap(self) }
}
