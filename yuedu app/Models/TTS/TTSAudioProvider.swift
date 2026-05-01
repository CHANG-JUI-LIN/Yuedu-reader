import Foundation

protocol TTSAudioProvider: AnyObject {
    var displayName: String { get }
    func audioData(for text: String, title: String, rate: Float) async throws -> Data
}

enum TTSAudioProviderError: LocalizedError {
    case emptyTemplate
    case invalidURL
    case emptyData
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .emptyTemplate:
            return "TTS URL template is empty"
        case .invalidURL:
            return "TTS URL template produced an invalid URL"
        case .emptyData:
            return "TTS provider returned empty audio data"
        case .badStatus(let status):
            return "TTS provider returned HTTP \(status)"
        }
    }
}

final class CustomHTTPProvider: TTSAudioProvider {
    var displayName: String { "網路語音" }

    func audioData(for text: String, title: String, rate: Float) async throws -> Data {
        let template = GlobalSettings.shared.httpTtsUrlTemplate
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ttsLog("[TTS][Provider] template empty=\(template.isEmpty) textCount=\(text.count) title=\(title) rate=\(rate)")
        guard !template.isEmpty else {
            throw TTSAudioProviderError.emptyTemplate
        }
        guard let url = buildURL(template: template, text: text, title: title, rate: rate) else {
            ttsLog("[TTS][Provider] invalid url template=\(template)")
            throw TTSAudioProviderError.invalidURL
        }
        ttsLog("[TTS][Provider] request url=\(url.absoluteString)")

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse {
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            ttsLog("[TTS][Provider] response status=\(http.statusCode) contentType=\(contentType) bytes=\(data.count)")
        } else {
            ttsLog("[TTS][Provider] response nonHTTP bytes=\(data.count)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TTSAudioProviderError.badStatus(http.statusCode)
        }
        guard !data.isEmpty else {
            throw TTSAudioProviderError.emptyData
        }
        return data
    }

    private func buildURL(template: String, text: String, title: String, rate: Float) -> URL? {
        var queryValueCS = CharacterSet.urlQueryAllowed
        queryValueCS.remove(charactersIn: "&+=?#%")
        let encodedText = text.addingPercentEncoding(withAllowedCharacters: queryValueCS) ?? text
        let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: queryValueCS) ?? title
        let speedStr = String(format: "%.2f", rate)

        let resolved = template
            .replacingOccurrences(of: "{{text}}", with: encodedText)
            .replacingOccurrences(of: "{{title}}", with: encodedTitle)
            .replacingOccurrences(of: "{{speakSpeed}}", with: speedStr)

        return URL(string: resolved)
    }
}
