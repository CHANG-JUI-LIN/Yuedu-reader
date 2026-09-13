import Foundation

enum AIMemoryPlanner {
    static let version = "character-memory.v1"
    static func plan(source: AIBookContentAdapter, boundary: AIReadingBoundary, provider: String, model: String,
                     budget: AIMemoryBudget = .init(), analysisVersion: String = version, configurationDigest: String = "") throws -> AIMemoryJob {
        guard boundary.sourceVersion == source.contentFingerprint, budget.unitCharacters > 0,
              budget.unitCharacters <= 4_000, budget.auxiliaryCharacters >= 0, budget.auxiliaryCharacters <= 500,
              budget.maximumCalls > 0, budget.outputTokens >= 2_048, budget.automaticSplitDepth >= 0,
              budget.automaticSplitDepth <= 2 else { throw AIMemoryFailure.invalidPlan }
        var units: [AIMemoryUnit] = []
        for (spine, section) in source.chunkSections.enumerated() {
            guard boundary.wholeBook || spine <= boundary.spineIndex else { break }
            let text = boundary.wholeBook || spine < boundary.spineIndex ? section.text : AITextCoordinates.prefix(section.text, throughUTF16: boundary.utf16Offset)
            var start = text.startIndex
            while start < text.endIndex {
                let hardEnd = text.index(start, offsetBy: budget.unitCharacters, limitedBy: text.endIndex) ?? text.endIndex
                var end = hardEnd
                if hardEnd < text.endIndex,
                   let newline = text[start..<hardEnd].lastIndex(of: "\n"),
                   text.distance(from: start, to: newline) >= budget.unitCharacters / 2 { end = text.index(after: newline) }
                units.append(makeUnit(source: source, spine: spine, start: start.utf16Offset(in: text), end: end.utf16Offset(in: text),
                    budget: budget, provider: provider + configurationDigest, model: model, analysisVersion: analysisVersion))
                start = end
            }
        }
        return .init(id: UUID(), bookID: source.chunkBookID, sourceVersion: source.contentFingerprint, manifest: source.manifest,
            boundary: boundary, provider: provider, model: model, analysisVersion: analysisVersion, configurationDigest: configurationDigest, budget: budget, units: units, createdAt: Date())
    }

    static func makeUnit(source: AIBookContentAdapter, spine: Int, start: Int, end: Int, budget: AIMemoryBudget,
                         provider: String, model: String, analysisVersion: String, parent: String? = nil, depth: Int = 0) -> AIMemoryUnit {
        let chapter = source.manifest.chapters[spine]
        let primary = AIMemorySpan(sectionID: chapter.id, chapterDigest: chapter.digest ?? "", transformation: source.manifest.transformationVersion,
            spine: spine, start: start, end: end)
        var auxiliary: AIMemorySpan?
        if start > 0, budget.auxiliaryCharacters > 0 {
            let previous = AITextCoordinates.prefix(source.chunkSections[spine].text, throughUTF16: start)
            let suffix = String(previous.suffix(budget.auxiliaryCharacters))
            auxiliary = .init(sectionID: chapter.id, chapterDigest: chapter.digest ?? "", transformation: primary.transformation,
                spine: spine, start: start - suffix.utf16.count, end: start)
        }
        // Conservative prefix dependency: append-only chapters preserve this hash. An edit,
        // insertion or newly available earlier chapter invalidates every later interpretation.
        let prefix = AISourceManifest(transformationVersion: source.manifest.transformationVersion,
            chapters: Array(source.manifest.chapters.prefix(spine + 1))).identifier
        let key = [source.chunkBookID.uuidString, prefix, "\(spine):\(start):\(end)", analysisVersion, provider, model,
            "\(budget.auxiliaryCharacters):\(budget.maximumBackgroundRecords):\(budget.maximumInputCharacters):\(budget.maximumInputBytes):\(budget.outputTokens)"].joined(separator: "|")
        return .init(id: AISourceManifest.digest(key), primary: primary, auxiliary: auxiliary, dependencyDigest: prefix,
            analysisVersion: analysisVersion, parentID: parent, depth: depth)
    }

    static func split(_ unit: AIMemoryUnit, source: AIBookContentAdapter, job: AIMemoryJob) throws -> [AIMemoryUnit] {
        guard let text = unit.primary.text(in: source), text.count >= 2 else { throw AIMemoryFailure.invalidPlan }
        let middle = unit.primary.start + AITextCoordinates.characterToUTF16(text.count / 2, in: text)
        return [(unit.primary.start, middle), (middle, unit.primary.end)].map { start, end in
            makeUnit(source: source, spine: unit.primary.spine, start: start, end: end, budget: job.budget,
                provider: job.provider + job.configurationDigest, model: job.model, analysisVersion: job.analysisVersion, parent: unit.id, depth: unit.depth + 1)
        }
    }

    static func matches(_ record: AIMemoryRecord, source: AIBookContentAdapter, job: AIMemoryJob) -> Bool {
        guard record.committed, record.schema == 1, record.unit.primary.text(in: source) != nil else { return false }
        let unit = makeUnit(source: source, spine: record.unit.primary.spine, start: record.unit.primary.start,
            end: record.unit.primary.end, budget: job.budget, provider: job.provider + job.configurationDigest, model: job.model, analysisVersion: job.analysisVersion)
        return unit.id == record.unit.id && record.unit.analysisVersion == job.analysisVersion
    }
}
