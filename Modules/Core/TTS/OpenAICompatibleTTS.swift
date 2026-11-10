import Foundation

/// A voice of a cloud service the app knows by name.
struct CloudTTSVoiceOption: Identifiable, Hashable, Sendable {
    let id: String
    /// Localisation key, or the voice's own name when it has no translation.
    let nameKey: String
    let gender: TTSVoiceGender
    var age: TTSVoiceAge = .adult
    var languageGroup: String = "cmn"

    var displayName: String { localized(nameKey) }
}

/// OpenAI's speech voices. Each is multilingual; none is native Mandarin, which is why
/// Azure is the one recommended for Chinese and these are offered beside it.
enum OpenAITTSVoices {
    static let all: [CloudTTSVoiceOption] = [
        .init(id: "coral", nameKey: "Coral・女聲", gender: .female),
        .init(id: "nova", nameKey: "Nova・女聲", gender: .female, age: .young),
        .init(id: "shimmer", nameKey: "Shimmer・女聲", gender: .female),
        .init(id: "sage", nameKey: "Sage・女聲", gender: .female),
        .init(id: "alloy", nameKey: "Alloy・女聲", gender: .female),
        .init(id: "marin", nameKey: "Marin・女聲", gender: .female),
        .init(id: "ash", nameKey: "Ash・男聲", gender: .male),
        .init(id: "echo", nameKey: "Echo・男聲", gender: .male, age: .young),
        .init(id: "onyx", nameKey: "Onyx・男聲", gender: .male),
        .init(id: "fable", nameKey: "Fable・男聲", gender: .male),
        .init(id: "ballad", nameKey: "Ballad・男聲", gender: .male),
        .init(id: "verse", nameKey: "Verse・男聲", gender: .male),
        .init(id: "cedar", nameKey: "Cedar・男聲", gender: .male),
    ]
    static let defaultVoice = "coral"
}

/// Xiaomi MiMo's voices, as listed by MiMo and used by ReadAny.
enum MiMoTTSVoices {
    static let all: [CloudTTSVoiceOption] = [
        .init(id: "冰糖", nameKey: "冰糖・中文女聲", gender: .female, age: .young),
        .init(id: "茉莉", nameKey: "茉莉・中文女聲", gender: .female),
        .init(id: "苏打", nameKey: "蘇打・中文男聲", gender: .male, age: .young),
        .init(id: "白桦", nameKey: "白樺・中文男聲", gender: .male),
        .init(id: "mimo_default", nameKey: "MiMo 預設", gender: .unknown),
    ]
    static let defaultVoice = "冰糖"
}

/// Endpoint, model and key for OpenAI's `audio/speech` or MiMo's chat-completions audio.
struct OpenAICompatibleTTSConfiguration: Sendable, Equatable {
    let service: CloudTTSService
    let baseURL: String
    let model: String
    let key: String

    static let defaultOpenAIBaseURL = "https://api.openai.com/v1"
    static let defaultOpenAIModel = "gpt-4o-mini-tts"
    static let defaultMiMoBaseURL = "https://api.xiaomimimo.com/v1"
    static let miMoModel = "mimo-v2.5-tts"

    var endpointURL: URL? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        let path = service == .mimo ? "chat/completions" : "audio/speech"
        return url.appendingPathComponent(path)
    }

    @MainActor
    static func current(service: CloudTTSService) throws -> OpenAICompatibleTTSConfiguration {
        guard let key = CloudTTSCredentials.key(for: service) else { throw CloudTTSError.missingKey(service) }
        let settings = GlobalSettings.shared
        let configuration: OpenAICompatibleTTSConfiguration
        switch service {
        case .mimo:
            configuration = .init(service: .mimo, baseURL: settings.mimoTtsBaseURL, model: miMoModel, key: key)
        default:
            let model = settings.openAITtsModel.trimmingCharacters(in: .whitespacesAndNewlines)
            configuration = .init(
                service: .openAI,
                baseURL: settings.openAITtsBaseURL,
                model: model.isEmpty ? defaultOpenAIModel : model,
                key: key
            )
        }
        guard configuration.endpointURL != nil else { throw CloudTTSError.invalidEndpoint }
        return configuration
    }
}

/// The words an instruction-following voice is given for one line.
enum CloudTTSInstructions {
    static let narration = "以平穩自然、適合長時間聆聽的語氣朗讀小說旁白。"

    static func text(for delivery: TTSDelivery?) -> String {
        guard let delivery else { return narration }
        var parts = ["朗讀小說中的角色台詞，像配音演員一樣演出。"]
        if let persona = delivery.persona, !persona.isEmpty { parts.append("角色：\(persona)。") }
        parts.append("語氣：\(delivery.emotionDescription)。")
        if let instruct = delivery.instruct, !instruct.isEmpty { parts.append("表演指示：\(instruct)。") }
        return parts.joined()
    }
}

final class OpenAICompatibleTTSAudioProvider: TTSAudioProvider {
    let configuration: OpenAICompatibleTTSConfiguration
    let voice: String
    /// `nil` for narration, which is read as the narrator rather than acted.
    let delivery: TTSDelivery?
    var displayName: String { localized(configuration.service.displayNameKey) }

    init(configuration: OpenAICompatibleTTSConfiguration, voice: String, delivery: TTSDelivery? = nil) {
        self.configuration = configuration
        self.voice = voice
        self.delivery = delivery
    }

    func request(text: String) throws -> URLRequest {
        guard let url = configuration.endpointURL else { throw CloudTTSError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let instructions = CloudTTSInstructions.text(for: delivery)
        let body: [String: Any]
        switch configuration.service {
        case .mimo:
            // MiMo takes the direction as the user turn and speaks the assistant turn — the
            // shape MiMo documents and ReadAny uses.
            request.setValue(configuration.key, forHTTPHeaderField: "api-key")
            body = [
                "model": configuration.model,
                "messages": [
                    ["role": "user", "content": instructions],
                    ["role": "assistant", "content": text],
                ],
                "audio": ["format": "wav", "voice": voice],
            ]
        default:
            request.setValue("Bearer \(configuration.key)", forHTTPHeaderField: "Authorization")
            body = [
                "model": configuration.model,
                "voice": voice,
                "input": text,
                "instructions": instructions,
                "response_format": "mp3",
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func audioData(for text: String, title: String, rate: Float) async throws -> Data {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudTTSError.emptyAudio }
        let (data, response) = try await CloudTTSSession.shared.data(for: request(text: text))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CloudTTSError.from(status: http.statusCode, body: data)
        }
        let audio = configuration.service == .mimo ? try Self.miMoAudio(from: data) : data
        guard !audio.isEmpty else { throw CloudTTSError.emptyAudio }
        guard TTSAudioPayload.looksLikeAudioContainer(audio) else { throw CloudTTSError.invalidResponse }
        return audio
    }

    /// `choices[0].message.audio.data`, base64 WAV.
    static func miMoAudio(from data: Data) throws -> Data {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    struct Audio: Decodable { let data: String? }
                    let audio: Audio?
                }
                let message: Message?
            }
            let choices: [Choice]?
        }
        let decoded: Response
        do { decoded = try JSONDecoder().decode(Response.self, from: data) } catch { throw CloudTTSError.invalidResponse }
        guard let base64 = decoded.choices?.first?.message?.audio?.data,
              let audio = Data(base64Encoded: base64) else { throw CloudTTSError.emptyAudio }
        return audio
    }
}
