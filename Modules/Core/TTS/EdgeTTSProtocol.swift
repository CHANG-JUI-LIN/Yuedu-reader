import CryptoKit
import Foundation

enum EdgeTTSError: Error, LocalizedError, Equatable {
    case invalidVoice
    case invalidResponse
    case emptyAudio
    case serviceStatus(Int)
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidVoice:
            return localized("微軟語音無效，請重新選擇音色。")
        case .invalidResponse:
            return localized("微軟語音回應格式異常，請稍後再試。")
        case .emptyAudio:
            return localized("微軟語音未傳回音訊，請更換音色或稍後再試。")
        case .serviceStatus(let status):
            return String(format: localized("微軟語音服務無法使用（HTTP %d），請稍後再試。"), status)
        case .responseTooLarge:
            return localized("微軟語音回應超過大小限制。")
        }
    }
}

/// Edge Read Aloud wire format, checked against rany2/edge-tts in September 2026.
/// This is an online consumer protocol, not Azure's authenticated REST API.
enum EdgeTTSProtocol {
    static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    static let clientVersion = "143.0.3650.75"
    static let maxTextBytes = 4096
    static let maxAudioBytes = 16 * 1024 * 1024

    static func securityToken(date: Date) -> String {
        let seconds = Int64(floor(date.timeIntervalSince1970)) + 11_644_473_600
        let ticks = (seconds - seconds % 300) * 10_000_000
        let bytes = SHA256.hash(data: Data("\(ticks)\(trustedClientToken)".utf8))
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    static func request(date: Date = Date(), connectionID: UUID = UUID()) -> URLRequest {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "speech.platform.bing.com"
        components.path = "/consumer/speech/synthesize/readaloud/edge/v1"
        components.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: trustedClientToken),
            URLQueryItem(name: "ConnectionId", value: compactID(connectionID)),
            URLQueryItem(name: "Sec-MS-GEC", value: securityToken(date: date)),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: "1-" + clientVersion),
        ]
        // All URL components are fixed ASCII or internally generated hexadecimal strings.
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("muid=\(compactID(UUID()).uppercased());", forHTTPHeaderField: "Cookie")
        return request
    }

    static func rateString(_ rate: Float) -> String {
        let value = rate.isFinite ? rate : 0.5
        let percent = Int(((max(0.1, min(value, 2.5)) / 0.5 - 1) * 100).rounded())
        return String(format: "%+d%%", percent)
    }

    /// Bound escaped UTF-8, rather than Character count: XML entities and combining
    /// sequences can exceed the service limit even in a normal reader chunk.
    static func escapedTextChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var buffer = ""
        var count = 0
        for scalar in text.unicodeScalars {
            let escaped: String
            switch scalar.value {
            case 0...8, 11...12, 14...31, 0xFFFE...0xFFFF: escaped = " "
            case 38: escaped = "&amp;"
            case 60: escaped = "&lt;"
            case 62: escaped = "&gt;"
            case 34: escaped = "&quot;"
            case 39: escaped = "&apos;"
            default: escaped = String(scalar)
            }
            let size = escaped.utf8.count
            if count + size > maxTextBytes {
                chunks.append(buffer)
                buffer = ""
                count = 0
            }
            buffer += escaped
            count += size
        }
        if !buffer.isEmpty { chunks.append(buffer) }
        return chunks
    }

    static func messages(escapedText: String, voice: EdgeTTSVoice, rate: Float, date: Date = Date()) -> [String] {
        let timestamp = timestamp(date)
        let config = "X-Timestamp:\(timestamp)\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n"
            + #"{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}"# + "\r\n"
        // The trailing Z matches Edge's wire timestamp, including its historical suffix.
        let ssml = "X-RequestId:\(compactID(UUID()))\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(timestamp)Z\r\nPath:ssml\r\n\r\n"
            + "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='\(voice.id)'><prosody pitch='+0Hz' rate='\(rateString(rate))' volume='+0%'>\(escapedText)</prosody></voice></speak>"
        return [config, ssml]
    }

    enum Event: Equatable {
        case audio(Data)
        case finished
        case metadata
    }

    static func event(_ message: URLSessionWebSocketTask.Message) throws -> Event {
        switch message {
        case .data(let data):
            guard data.count >= 2 else { throw EdgeTTSError.invalidResponse }
            let bytes = Array(data.prefix(2))
            let headerLength = Int(bytes[0]) * 256 + Int(bytes[1])
            guard headerLength > 0, headerLength <= data.count - 2,
                  let header = String(data: data.dropFirst(2).prefix(headerLength), encoding: .utf8)
            else { throw EdgeTTSError.invalidResponse }
            let headers = headers(header)
            guard headers["path"] == "audio" else { throw EdgeTTSError.invalidResponse }
            let payload = Data(data.dropFirst(headerLength + 2))
            if headers["content-type"] == nil, payload.isEmpty { return .metadata }
            guard headers["content-type"] == "audio/mpeg", !payload.isEmpty else {
                throw EdgeTTSError.invalidResponse
            }
            return .audio(payload)
        case .string(let text):
            guard let separator = text.range(of: "\r\n\r\n") else { throw EdgeTTSError.invalidResponse }
            let values = headers(String(text[..<separator.lowerBound]))
            switch values["path"] {
            case "turn.end": return .finished
            case "turn.start", "response", "audio.metadata": return .metadata
            default: throw EdgeTTSError.invalidResponse
            }
        @unknown default:
            throw EdgeTTSError.invalidResponse
        }
    }

    private static func headers(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            result[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private static func compactID(_ id: UUID) -> String {
        id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: date)
    }
}
