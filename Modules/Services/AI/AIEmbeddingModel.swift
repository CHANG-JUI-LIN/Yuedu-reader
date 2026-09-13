import Combine
import CoreML
import CryptoKit
import Foundation

/// What an installed embedding model must be, and how a download is checked against it.
///
/// The model is **not bundled**: it is ~258 MB, and vector retrieval is opt-in. Shipping it
/// would make every install pay for a feature most readers never turn on, so it is downloaded
/// on request — and until then the assistant runs on keyword retrieval, which is a supported
/// tier rather than a broken one.
struct AIEmbeddingModelDescriptor: Codable, Equatable, Sendable {
    let name: String
    let revision: String
    let license: String
    let dimensions: Int
    /// Expected SHA-256 of the downloaded file, lowercase hex, or empty to skip the check.
    ///
    /// Empty is allowed because the reader supplies the URL — a private CDN or their own
    /// GitHub release — and may not have a digest for it. When it is set it is enforced
    /// strictly: a truncated or substituted model does not fail loudly, it silently produces
    /// vectors that retrieve the wrong passages.
    var sha256: String

    var identifier: String { "\(name)@\(revision)" }

    /// The model ChatBook converted and verified, and whose licence permits redistribution
    /// (Apache-2.0, redistribution and commercial use both reviewed and approved) — which is
    /// what lets it be self-hosted instead of pulled from HuggingFace, unreachable from China.
    ///
    /// fp32 as converted. The conversion script's `compute_precision=FLOAT16` did not take
    /// effect on this model, and quantising afterwards changes retrieval quality, so it is
    /// left as it is rather than shrunk by guesswork.
    static let `default` = AIEmbeddingModelDescriptor(
        name: "distiluse-base-multilingual-cased-v2",
        revision: "1",
        license: "apache-2.0",
        dimensions: 512,
        sha256: ""
    )
}

/// Owns the optional embedding model: whether one is installed, downloading a new one, and
/// throwing away every index built with the old answer.
@MainActor
final class AIEmbeddingModelStore: ObservableObject {
    static let shared = AIEmbeddingModelStore()

    enum State: Equatable {
        case absent
        case downloading(fractionCompleted: Double)
        case verifying
        case ready
        case failed(String)
    }

    enum DownloadError: LocalizedError, Equatable {
        case invalidURL
        case digestMismatch
        case notAModel

        var errorDescription: String? {
            switch self {
            case .invalidURL: return localized("下載位址無效")
            case .digestMismatch: return localized("下載的檔案與預期的校驗碼不符，已捨棄")
            case .notAModel: return localized("下載的檔案不是可用的 Core ML 模型")
            }
        }
    }

    @Published private(set) var state: State = .absent

    /// Where to fetch the model from. Empty until the reader supplies one — there is no
    /// Yuedu-operated host for it, and pointing at a third party's bandwidth without asking
    /// would be someone else's bill.
    @Published var sourceURLString: String {
        didSet { UserDefaults.standard.set(sourceURLString, forKey: Self.sourceKey) }
    }

    private static let sourceKey = "yd_ai_embedding_source_url"
    private let directory: URL
    private var provider: (any AIEmbeddingProviding)?
    private var descriptor = AIEmbeddingModelDescriptor.default

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("AIEmbedding", isDirectory: true)
        }
        self.sourceURLString = UserDefaults.standard.string(forKey: Self.sourceKey) ?? ""
        self.state = FileManager.default.fileExists(atPath: modelURL.path) ? .ready : .absent
    }

    private var modelURL: URL {
        directory.appendingPathComponent("\(descriptor.identifier).mlmodelc", isDirectory: true)
    }

    var isInstalled: Bool {
        if case .ready = state { return true }
        return false
    }

    /// The vector provider, or `nil` when no model is installed.
    ///
    /// `nil` selects the keyword tier. It is not an error path.
    func readyProvider() -> (any AIEmbeddingProviding)? {
        guard case .ready = state else { return nil }
        if let provider { return provider }
        do {
            let built = try CoreMLEmbeddingProvider(modelURL: modelURL, descriptor: descriptor)
            provider = built
            return built
        } catch {
            // A model that will not load is not a model. Saying so beats answering
            // keyword-only while the UI claims vectors are on.
            AppLogger.error("AI embedding model failed to load", error: error)
            state = .failed(DownloadError.notAModel.localizedDescription)
            return nil
        }
    }

    /// Downloads, verifies, compiles and installs the model, then drops every existing index.
    ///
    /// Discarding the indexes is the point of the whole exercise: without it, a book indexed
    /// on keywords keeps being queried as though it had vectors.
    func download() async {
        guard let url = URL(string: sourceURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil
        else {
            state = .failed(DownloadError.invalidURL.localizedDescription)
            return
        }
        state = .downloading(fractionCompleted: 0)
        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                state = .failed("HTTP \(http.statusCode)")
                return
            }

            state = .verifying
            if !descriptor.sha256.isEmpty {
                let digest = try Self.sha256(ofFileAt: temporaryURL)
                guard digest == descriptor.sha256.lowercased() else {
                    state = .failed(DownloadError.digestMismatch.localizedDescription)
                    return
                }
            }

            // Compiled before install: `MLModel.compileModel` is the only real check that the
            // bytes are a model this device can run, and a failure here must not leave a
            // half-installed directory behind.
            let compiled = try await MLModel.compileModel(at: temporaryURL)
            defer { try? FileManager.default.removeItem(at: compiled) }

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: modelURL.path) {
                try FileManager.default.removeItem(at: modelURL)
            }
            try FileManager.default.copyItem(at: compiled, to: modelURL)

            provider = nil
            state = .ready
            await AIBookIndexStore.shared.discardAll()
        } catch {
            AppLogger.error("AI embedding model download failed", error: error)
            state = .failed(error.localizedDescription)
        }
    }

    /// Removes the model and every index built with it.
    func remove() async {
        provider = nil
        try? FileManager.default.removeItem(at: modelURL)
        state = .absent
        await AIBookIndexStore.shared.discardAll()
    }

    /// Streamed rather than read whole: the archive is a quarter of a gigabyte, and hashing it
    /// in memory is how a background app gets killed.
    private static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Core ML sentence embeddings.
///
/// Deliberately thin: when vectors are used at all, and how they fuse with keyword hits, are
/// decisions that live in `AIBookRetrievalIndex`. This only turns text into numbers.
final class CoreMLEmbeddingProvider: AIEmbeddingProviding, @unchecked Sendable {
    let identifier: String
    let dimensions: Int

    private let model: MLModel
    private let inputName: String

    init(modelURL: URL, descriptor: AIEmbeddingModelDescriptor) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        // Read from the model's own description rather than hard-coded: the converted package
        // declares its input, and duplicating that name here is how the two drift apart.
        guard let input = model.modelDescription.inputDescriptionsByName.keys.sorted().first else {
            throw AIEmbeddingModelStore.DownloadError.notAModel
        }
        self.model = model
        self.inputName = input
        self.identifier = descriptor.identifier
        self.dimensions = descriptor.dimensions
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        try texts.map { try encode($0) }
    }

    private func encode(_ text: String) throws -> [Float] {
        let input = try MLDictionaryFeatureProvider(dictionary: [inputName: text as NSString])
        let output = try model.prediction(from: input)
        guard let name = output.featureNames.sorted().first,
              let array = output.featureValue(for: name)?.multiArrayValue
        else { throw AIEmbeddingModelStore.DownloadError.notAModel }
        var vector = [Float](repeating: 0, count: array.count)
        for index in 0..<array.count {
            vector[index] = array[index].floatValue
        }
        return vector
    }
}
