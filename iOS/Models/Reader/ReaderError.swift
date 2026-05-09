import Foundation

// MARK: - Reader Unified Error Type
//
// A unified abstraction for the UI layer to catch and present errors.
// Underlying domain errors (FetchError, WebViewError, ParseError, etc.) are
// wrapped via ReaderError.wrap(_:) at the call site, so the UI only handles a single type.

enum ReaderError: LocalizedError {
    /// Network/HTTP layer errors (from FetchError / WebViewError / URLError, etc.)
    case network(underlying: Error)

    /// HTML/JSON rule parsing failures (from ModernRuleEngineError, etc.)
    case parse(underlying: Error)

    /// Local I/O or data format errors (EPUB decompression, TXT encoding, etc.)
    case rendering(underlying: Error)

    /// Cache read/write failures
    case cache(underlying: Error)

    /// Unsupported format
    case unsupportedFormat(String)

    /// Unrecognized error
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
        case .unsupportedFormat(let msg):
            return "格式不支援：\(msg)"
        case .unknown(let err):
            return err.localizedDescription
        }
    }

    // MARK: Auto-categorization factory method

    /// Automatically categorizes based on the underlying error type.
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

// MARK: - Convenience Extension

extension Error {
    /// Wraps any error as a ReaderError
    var asReaderError: ReaderError { ReaderError.wrap(self) }
}
