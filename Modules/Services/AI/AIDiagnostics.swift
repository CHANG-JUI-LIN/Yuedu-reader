import Combine
import Foundation

/// Metadata is retained locally. Content capture is a separate, explicit next-request opt-in.
enum AIDiagnostics {
    @TaskLocal static var current: AIRequestTrace?
    enum Origin: String, Codable, Sendable { case observed, testFixture, reconstructed }
}

final class AIRequestTrace: @unchecked Sendable {
    struct Event: Codable, Sendable {
        let stage: String
        let milliseconds: Double
        let values: [String: String]
    }
    struct Export: Codable {
        let requestID: UUID
        let origin: AIDiagnostics.Origin
        let events: [Event]
        let selectedContent: [String: [String]]?
        let unavailableContentCategories: [String]
    }
    let requestID: UUID
    let bookID: UUID
    let origin: AIDiagnostics.Origin
    private let start = Date()
    private let lock = NSLock()
    private var events: [Event] = []
    private var sensitive: [String: [String]] = [:]
    private let captureContent: Bool

    init(feature: String, bookID: UUID, adapter: AIBookContentAdapter, boundary: AIReadingBoundary,
         origin: AIDiagnostics.Origin = .observed, captureContent: Bool = false, requestID: UUID = UUID()) {
        self.requestID = requestID
        self.bookID = bookID
        self.origin = origin
        self.captureContent = captureContent
        event("request", ["feature": feature, "bookID": bookID.uuidString,
            "sourceVersion": adapter.contentFingerprint, "snapshot": adapter.contentFingerprint,
            "snapshotAcquisitionMs": adapter.acquisitionMilliseconds.map { String($0) } ?? "unavailable",
            "boundarySpine": "\(boundary.spineIndex)", "boundaryUTF16": "\(boundary.utf16Offset)",
            "boundarySectionDigest": AISourceManifest.digest(boundary.sectionID), "wholeBook": "\(boundary.wholeBook)",
            "totalChapters": "\(adapter.manifest.chapters.count)",
            "availableChapters": "\(adapter.manifest.chapters.filter { $0.status == .available }.count)",
            "llmExtraction": feature == "characterMemory" ? "batchedCharacterMemory" : "notApplicable"])
        for chapter in adapter.manifest.chapters where chapter.status != .available {
            event("missingChapter", ["order": "\(chapter.order)", "status": chapter.status.rawValue])
        }
    }
    func event(_ stage: String, _ values: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        events.append(.init(stage: stage, milliseconds: Date().timeIntervalSince(start) * 1000,
            values: values.mapValues(Self.redact)))
    }
    func content(_ category: String, _ values: [String]) {
        guard captureContent else { return }
        lock.lock(); defer { lock.unlock() }
        sensitive[category, default: []].append(contentsOf: values.map(Self.redact))
    }
    func retrieval(total: Int, eligible: Int, candidates: [Int], hits: [AIRetrievalHit], scoreType: String, degradation: String?, elapsed: TimeInterval) {
        event("retrieval", ["total": "\(total)", "eligible": "\(eligible)", "excluded": "\(total - eligible)",
            "candidateCounts": candidates.map(String.init).joined(separator: ","), "scoreType": scoreType,
            "degradation": degradation ?? "none", "elapsedMs": "\(elapsed * 1000)"])
        for hit in hits {
            event("evidence", ["chunkID": hit.id, "spine": "\(hit.chunk.start.spineIndex)",
                "sourceUTF16Start": "\(hit.chunk.start.charOffset)", "sourceUTF16End": "\(hit.chunk.end.charOffset)",
                "score": "\(hit.score)", "scoreType": scoreType])
        }
        content("evidence", hits.map { "[\($0.id)]\n\($0.chunk.text)" })
    }
    var retrievalDegradation: String? {
        lock.lock(); defer { lock.unlock() }
        return events.last(where: { $0.stage == "retrieval" })?.values["degradation"].flatMap { $0 == "none" ? nil : $0 }
    }
    func export(including categories: Set<String> = []) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let selected = sensitive.filter { categories.contains($0.key) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Export(requestID: requestID, origin: origin, events: events,
            selectedContent: selected.isEmpty ? nil : selected,
            unavailableContentCategories: categories.filter { sensitive[$0] == nil }.sorted()))
    }
    static func redact(_ value: String) -> String {
        var result = value
        for pattern in [#"(?i)https?://[^\s<>\"]+"#, #"(?i)bearer\s+[^\s\"]+"#,
                        #"(?i)\bsk-[a-z0-9_-]+"#, #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
                        #"(?i)(authorization|api[_ -]?key|password|account|token)\s*[=:]\s*[^\s,;]+"#] {
            result = result.replacingOccurrences(of: pattern, with: "<redacted>", options: [.regularExpression, .caseInsensitive])
        }
        return result
    }
}

@MainActor
final class AIDiagnosticStore: ObservableObject {
    static let shared = AIDiagnosticStore()
    @Published var captureNextRequestContent = false
    @Published private(set) var retrievalDegradation: String?
    @Published private(set) var latest: AIRequestTrace?
    func begin(feature: String, bookID: UUID, adapter: AIBookContentAdapter, boundary: AIReadingBoundary, origin: AIDiagnostics.Origin = .observed, requestID: UUID = UUID()) -> AIRequestTrace {
        let trace = AIRequestTrace(feature: feature, bookID: bookID, adapter: adapter, boundary: boundary,
            origin: origin, captureContent: captureNextRequestContent, requestID: requestID)
        captureNextRequestContent = false
        latest = trace
        return trace
    }
    func recordPresentation(requestID: UUID, status: String) {
        guard let trace = latest, trace.requestID == requestID else { return }
        trace.event("uiFinalState", ["status": status])
        finish(trace)
    }
    func finish(_ trace: AIRequestTrace) {
        // Only the most recently started request owns the displayed/exported result.
        guard latest?.requestID == trace.requestID else { return }
        latest = trace
        retrievalDegradation = trace.retrievalDegradation
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AIDiagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try trace.export().write(to: directory.appendingPathComponent("latest-metadata.json"), options: [.atomic, .completeFileProtection])
        } catch { AppLogger.error("AI diagnostic metadata persistence failed") }
    }
}

/// Wraps the existing provider. Credentials/endpoints never enter this interface.
struct AITracedProvider: LLMProviding {
    let base: any LLMProviding
    var identifier: String { base.identifier }
    var defaultModel: String { base.defaultModel }
    func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
        let trace = AIDiagnostics.current
        let start = Date()
        trace?.event("messages", ["roles": request.messages.map { $0.role.rawValue }.joined(separator: ","),
            "count": "\(request.messages.count)", "characterCounts": request.messages.map { String($0.content.count) }.joined(separator: ","),
            "history": "\(request.messages.contains { $0.content.hasPrefix("<conversation-data") })", "dataMessages": "\(request.messages.filter { $0.role == .user }.count)", "provider": identifier, "model": AIRequestTrace.redact(model ?? defaultModel),
            "maxOutputTokens": request.maxTokens.map(String.init) ?? "providerDefault"])
        trace?.content("messages", request.messages.map { "\($0.role.rawValue):\n\($0.content)" })
        do {
            let raw = try await base.generate(request, model: model)
            trace?.event("generation", ["provider": raw.provider, "model": AIRequestTrace.redact(raw.model),
                "httpStatus": raw.httpStatus.map(String.init) ?? "unavailable", "finishReason": raw.finishReason ?? "unavailable",
                "characters": "\(raw.content.count)", "elapsedMs": "\(Date().timeIntervalSince(start) * 1000)",
                "promptTokens": raw.usage?.promptTokens.map(String.init) ?? "unavailable",
                "completionTokens": raw.usage?.completionTokens.map(String.init) ?? "unavailable"])
            trace?.content("response", [raw.content])
            try raw.validateCompletion()
            return raw
        } catch {
            trace?.event("generationFailure", ["kind": String(describing: type(of: error)), "elapsedMs": "\(Date().timeIntervalSince(start) * 1000)"])
            throw error
        }
    }
}
