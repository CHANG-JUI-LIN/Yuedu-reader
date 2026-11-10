import Foundation

/// Azure AI Speech, through its REST endpoint and the reader's own key.
///
/// The REST call rather than Microsoft's Speech SDK: the SDK is a large binary framework, and
/// everything narration needs — SSML in, MP3 out — is one POST. This is also how other open
/// readers (anx-reader) reach it. Unlike the free Read Aloud endpoint, Azure honours
/// `mstts:express-as`, so a line can be spoken angry, sad, whispered, and a role-play voice can
/// act a child or an old man — the part 多角色朗讀 needs most.
struct AzureTTSConfiguration: Sendable, Equatable {
    let region: String
    let key: String

    var synthesisURL: URL? { URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1") }
    var voicesURL: URL? { URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/voices/list") }

    /// Regions are lowercase letters and digits (`eastasia`, `westus2`); anything else would be
    /// spliced into a hostname.
    static func isValidRegion(_ region: String) -> Bool {
        !region.isEmpty && region.unicodeScalars.allSatisfy {
            CharacterSet.lowercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0)
        } && region.allSatisfy(\.isASCII)
    }

    @MainActor
    static func current() throws -> AzureTTSConfiguration {
        let region = GlobalSettings.shared.azureTtsRegion
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let key = CloudTTSCredentials.key(for: .azure) else { throw CloudTTSError.missingKey(.azure) }
        guard isValidRegion(region) else { throw CloudTTSError.invalidEndpoint }
        return AzureTTSConfiguration(region: region, key: key)
    }
}

/// A voice, optionally acting one of its role-play roles (`zh-CN-XiaomoNeural#Girl`).
struct AzureTTSVoiceRef: Hashable, Sendable {
    let shortName: String
    let role: String?

    init(shortName: String, role: String? = nil) {
        self.shortName = shortName
        self.role = role?.isEmpty == true ? nil : role
    }

    init(storage: String) {
        let parts = storage.split(separator: "#", maxSplits: 1).map(String.init)
        self.init(shortName: parts.first ?? storage, role: parts.count > 1 ? parts[1] : nil)
    }

    var storage: String { role.map { "\(shortName)#\($0)" } ?? shortName }

    /// `zh-CN` out of `zh-CN-XiaoxiaoNeural`.
    var locale: String {
        let parts = shortName.split(separator: "-")
        return parts.count >= 2 ? "\(parts[0])-\(parts[1])" : "zh-CN"
    }
}

/// One entry of Azure's `voices/list`, trimmed to what the app uses.
struct AzureTTSVoice: Codable, Hashable, Sendable, Identifiable {
    let shortName: String
    let localName: String
    let locale: String
    let gender: TTSVoiceGender
    let styles: [String]
    let roles: [String]

    var id: String { shortName }
    var languageGroup: String { TTSLanguageGroup.of(locale: locale) }

    /// Azure's own field names.
    struct Wire: Decodable {
        let ShortName: String
        let LocalName: String?
        let DisplayName: String?
        let Locale: String
        let Gender: String?
        let StyleList: [String]?
        let RolePlayList: [String]?
        let Status: String?
    }

    init(shortName: String, localName: String, locale: String, gender: TTSVoiceGender, styles: [String], roles: [String]) {
        self.shortName = shortName
        self.localName = localName
        self.locale = locale
        self.gender = gender
        self.styles = styles
        self.roles = roles
    }

    init(wire: Wire) {
        let gender: TTSVoiceGender
        switch wire.Gender?.lowercased() {
        case "male": gender = .male
        case "female": gender = .female
        default: gender = .unknown
        }
        self.init(
            shortName: wire.ShortName,
            localName: wire.LocalName ?? wire.DisplayName ?? wire.ShortName,
            locale: wire.Locale,
            gender: gender,
            styles: wire.StyleList ?? [],
            roles: (wire.RolePlayList ?? []).filter { $0 != "Default" }
        )
    }

    /// Keeps the languages a reader of this app can use and drops retired voices.
    static func decodeCatalogue(_ data: Data) throws -> [AzureTTSVoice] {
        let wanted: Set<String> = ["cmn", "yue", "wuu", "en", "ja", "ko"]
        return try JSONDecoder().decode([Wire].self, from: data)
            .filter { $0.Status?.lowercased() != "deprecated" }
            .map(AzureTTSVoice.init(wire:))
            .filter { wanted.contains($0.languageGroup) }
            .sorted { $0.locale == $1.locale ? $0.shortName < $1.shortName : $0.locale < $1.locale }
    }
}

/// Azure's role-play names and who each one sounds like.
enum AzureTTSRole {
    static func traits(_ role: String) -> (gender: TTSVoiceGender, age: TTSVoiceAge) {
        switch role {
        case "Girl": return (.female, .child)
        case "Boy": return (.male, .child)
        case "YoungAdultFemale": return (.female, .young)
        case "YoungAdultMale": return (.male, .young)
        case "OlderAdultFemale": return (.female, .adult)
        case "OlderAdultMale": return (.male, .adult)
        case "SeniorFemale": return (.female, .elder)
        case "SeniorMale": return (.male, .elder)
        default: return (.unknown, .unknown)
        }
    }

    static func displayNameKey(_ role: String) -> String {
        switch role {
        case "Girl": return "小女孩"
        case "Boy": return "小男孩"
        case "YoungAdultFemale": return "年輕女性"
        case "YoungAdultMale": return "年輕男性"
        case "OlderAdultFemale": return "成年女性"
        case "OlderAdultMale": return "成年男性"
        case "SeniorFemale": return "年長女性"
        case "SeniorMale": return "年長男性"
        case "Narrator": return "旁白"
        default: return role
        }
    }
}

enum AzureTTSSSML {
    /// Styles to try for each emotion, best first. Voices support different subsets, so the
    /// first one the voice actually has wins; none at all falls back to prosody.
    static let stylePreferences: [TTSEmotion: [String]] = [
        .happy: ["cheerful", "excited", "affectionate", "friendly", "chat"],
        .sad: ["sad", "depressed", "sorry"],
        .angry: ["angry", "disgruntled"],
        .fearful: ["fearful", "terrified", "embarrassed"],
        .surprised: ["excited", "cheerful"],
        .gentle: ["gentle", "affectionate", "calm", "lyrical"],
        .cold: ["unfriendly", "serious", "disgruntled", "calm"],
        .whisper: ["whispering", "whisper"],
        .shout: ["shouting", "angry"],
        .serious: ["serious", "calm"],
        .playful: ["cheerful", "affectionate", "friendly"],
    ]

    /// The style for `delivery` among `supported`. With no catalogue to consult (`supported`
    /// nil) the first preference is sent: Azure reads an unsupported style as its neutral one.
    static func style(for delivery: TTSDelivery?, supported: Set<String>?) -> String? {
        guard let delivery, let preferences = stylePreferences[delivery.emotion] else { return nil }
        guard let supported else { return preferences.first }
        return preferences.first { supported.contains($0) }
    }

    /// `styledegree` spans 0.01–2; 1 is the voice's default intensity.
    static func styleDegree(for intensity: Int) -> String {
        switch intensity {
        case 1: return "0.8"
        case 3: return "1.8"
        default: return "1.3"
        }
    }

    static func document(
        text: String,
        voice: AzureTTSVoiceRef,
        rate: Float,
        delivery: TTSDelivery?,
        supportedStyles: Set<String>?
    ) -> String {
        let escaped = EdgeTTSProtocol.escapedTextChunks(text).joined()
        let style = style(for: delivery, supported: supportedStyles)
        // A real style carries the emotion; prosody is the fallback for voices without one.
        let prosody = style == nil ? TTSProsody.approximating(delivery) : .zero
        let rateValue = EdgeTTSProtocol.rateString(rate, adjustedBy: prosody.ratePercent)
        let pitch = EdgeTTSProtocol.percentString(prosody.pitchPercent)
        let volume = EdgeTTSProtocol.percentString(prosody.volumePercent)
        var body = "<prosody rate='\(rateValue)' pitch='\(pitch)' volume='\(volume)'>\(escaped)</prosody>"
        if style != nil || voice.role != nil {
            var attributes = ""
            if let role = voice.role { attributes += " role='\(role)'" }
            if let style {
                attributes += " style='\(style)' styledegree='\(styleDegree(for: delivery?.intensity ?? 2))'"
            }
            body = "<mstts:express-as\(attributes)>\(body)</mstts:express-as>"
        }
        return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xmlns:mstts='https://www.w3.org/2001/mstts' xml:lang='\(voice.locale)'>"
            + "<voice name='\(voice.shortName)'>\(body)</voice></speak>"
    }
}

final class AzureTTSAudioProvider: TTSAudioProvider {
    let configuration: AzureTTSConfiguration
    let voice: AzureTTSVoiceRef
    let delivery: TTSDelivery?
    /// From the fetched catalogue, so an emotion picks a style this voice really has.
    let supportedStyles: Set<String>?

    var displayName: String { localized("Azure 語音") }

    init(
        configuration: AzureTTSConfiguration,
        voice: AzureTTSVoiceRef,
        delivery: TTSDelivery? = nil,
        supportedStyles: Set<String>? = nil
    ) {
        self.configuration = configuration
        self.voice = voice
        self.delivery = delivery
        self.supportedStyles = supportedStyles
    }

    func request(text: String, rate: Float) throws -> URLRequest {
        guard let url = configuration.synthesisURL else { throw CloudTTSError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(configuration.key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue("audio-24khz-48kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("Yuedu", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(AzureTTSSSML.document(
            text: text,
            voice: voice,
            rate: rate,
            delivery: delivery,
            supportedStyles: supportedStyles
        ).utf8)
        return request
    }

    func audioData(for text: String, title: String, rate: Float) async throws -> Data {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudTTSError.emptyAudio }
        let (data, response) = try await CloudTTSSession.shared.data(for: request(text: text, rate: rate))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CloudTTSError.from(status: http.statusCode, body: data)
        }
        guard !data.isEmpty else { throw CloudTTSError.emptyAudio }
        guard TTSAudioPayload.looksLikeAudioContainer(data) else { throw CloudTTSError.invalidResponse }
        return data
    }
}

/// Azure's voice list for the reader's region, fetched with their key and kept on disk.
///
/// Fetched, not hard-coded: Azure adds and retires voices and styles, and the list itself says
/// which styles and role-play roles each voice has — which is what lets an emotion pick a style
/// the voice can actually perform, and 自動配音 match a character to a role's age.
@MainActor
@Observable
final class AzureTTSVoiceCatalog {
    static let shared = AzureTTSVoiceCatalog()

    private(set) var voices: [AzureTTSVoice] = []
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private var loadTask: Task<Void, Never>?

    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudTTS", isDirectory: true)
        fileURL = base.appendingPathComponent("azure-voices.json")
    }

    func voice(named shortName: String) -> AzureTTSVoice? {
        voices.first { $0.shortName == shortName }
    }

    /// Reads the cached list off the main thread, once.
    func loadIfNeeded() {
        guard voices.isEmpty, loadTask == nil else { return }
        let url = fileURL
        loadTask = Task {
            let loaded = await Task.detached(priority: .utility) { () -> Result<[AzureTTSVoice], Error>? in
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return Result { try JSONDecoder().decode([AzureTTSVoice].self, from: Data(contentsOf: url)) }
            }.value
            switch loaded {
            case let .success(list)?:
                if voices.isEmpty { voices = list }
            case let .failure(error)?:
                AppLogger.error("Azure voice list unreadable", error: error)
            case nil:
                break
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }
        do {
            let configuration = try AzureTTSConfiguration.current()
            guard let url = configuration.voicesURL else { throw CloudTTSError.invalidEndpoint }
            var request = URLRequest(url: url)
            request.setValue(configuration.key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            let (data, response) = try await CloudTTSSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw CloudTTSError.from(status: http.statusCode, body: data)
            }
            let list = try AzureTTSVoice.decodeCatalogue(data)
            voices = list
            let destination = fileURL
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(list).write(to: destination, options: .atomic)
            }.value
        } catch {
            lastError = error.localizedDescription
            AppLogger.error("Azure voice list refresh failed", error: error)
        }
    }
}
