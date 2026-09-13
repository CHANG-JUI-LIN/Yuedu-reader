import Foundation

/// Request-local source reads. Prefixes never enter the persisted index or vector path.
enum AIQuestionSourceReader {
    static func fragment(_ parent: AIContentChunk, start: Int, end: Int, source: AIBookContentAdapter,
                         boundary: AIReadingBoundary, kind: AIQuestionEvidence.Kind) -> AIQuestionEvidence? {
        guard parent.bookID == source.chunkBookID, parent.sourceVersion == source.contentFingerprint,
              boundary.sourceVersion == source.contentFingerprint,
              source.chunkSections.indices.contains(parent.start.spineIndex), start >= parent.start.charOffset,
              end <= parent.end.charOffset, start < end else { return nil }
        let text = source.chunkSections[parent.start.spineIndex].text
        let safeEnd = AITextCoordinates.prefix(text, throughUTF16: end).utf16.count
        guard start < safeEnd, let range = Range(NSRange(location: start, length: safeEnd - start), in: text),
              text.indices.contains(range.lowerBound) else { return nil }
        let location = AIChunkLocation(spineIndex: parent.start.spineIndex, charOffset: safeEnd, progress: parent.end.progress)
        guard boundary.allows(location) else { return nil }
        var chunk = AIContentChunk(id: "fragment:\(AISourceManifest.digest(parent.id + source.contentFingerprint)):\(start):\(safeEnd)",
            bookID: parent.bookID, sectionID: parent.sectionID, ordinal: parent.ordinal, text: String(text[range]),
            start: .init(spineIndex: parent.start.spineIndex, charOffset: start, progress: parent.start.progress), end: location)
        chunk.sourceVersion = source.contentFingerprint
        return .init(chunk: chunk, parentChunkID: parent.id, kind: kind)
    }

    static func prefixes(index: AIBookRetrievalIndex, context: AIQuestionContext, query: String) -> [AIQuestionEvidence] {
        guard !context.boundary.wholeBook, context.boundary.utf16Offset > 0 else { return [] }
        return index.chunks.compactMap { chunk in
            guard chunk.start.spineIndex == context.boundary.spineIndex,
                  chunk.start.charOffset < context.boundary.utf16Offset,
                  chunk.end.charOffset > context.boundary.utf16Offset,
                  let prefix = fragment(chunk, start: chunk.start.charOffset, end: context.boundary.utf16Offset,
                    source: context.source, boundary: context.boundary, kind: .prefix),
                  isCurrentPositionQuestion(query) || literalScore(query, text: prefix.chunk.text) > 0 else { return nil }
            return prefix
        }
    }

    static func isCurrentPositionQuestion(_ query: String) -> Bool {
        ["剛剛", "這一段", "這段", "目前這", "current passage", "just read"].contains { query.localizedCaseInsensitiveContains($0) }
    }

    /// Local phrase signal supplements NLTokenizer when a proper name is split differently.
    /// It authorizes no alias equivalence, and only examines already eligible source text.
    static func literalScore(_ query: String, text: String) -> Double {
        var terms = Set(AIBM25Index.tokenize(query).filter { $0.count >= 2 })
        let chars = Array(query)
        if chars.count >= 2 {
            for i in 0..<(chars.count - 1) {
                let pair = String(chars[i...i + 1])
                if pair.unicodeScalars.allSatisfy({ (0x3400...0x9FFF).contains($0.value) }) { terms.insert(pair) }
            }
        }
        return Double(terms.filter { text.range(of: $0, options: [.caseInsensitive, .literal]) != nil }.count)
    }

    static func collect(hits: [AIRetrievalHit], index: AIBookRetrievalIndex, context: AIQuestionContext,
                        query: String, kind: AIQuestionEvidence.Kind) -> [AIQuestionEvidence] {
        var result = hits.map { AIQuestionEvidence(chunk: $0.chunk, parentChunkID: $0.id, kind: kind) }
        result += prefixes(index: index, context: context, query: query)
        if isCurrentPositionQuestion(query) {
            if let current = index.chunks.last(where: { $0.start.spineIndex == context.boundary.spineIndex && context.boundary.contains($0) }) {
                result.insert(.init(chunk: current, parentChunkID: current.id, kind: .currentPosition), at: 0)
            }
        }
        // Subject/dialogue/cause can cross a chunk boundary. Start at +/- one in the same
        // section; the assembler may remove neighbors before higher-priority direct hits.
        for hit in hits {
            for neighbor in index.chunks where neighbor.sectionID == hit.chunk.sectionID &&
                abs(neighbor.ordinal - hit.chunk.ordinal) == 1 && context.boundary.contains(neighbor) {
                result.append(.init(chunk: neighbor, parentChunkID: neighbor.id, kind: .adjacent))
            }
        }
        return deduplicated(result, context: context)
    }

    static func deduplicated(_ evidence: [AIQuestionEvidence], context: AIQuestionContext) -> [AIQuestionEvidence] {
        var result: [AIQuestionEvidence] = []
        for item in evidence where context.boundary.contains(item.chunk) {
            var ranges = [item.chunk.start.charOffset..<item.chunk.end.charOffset]
            for previous in result where previous.chunk.sectionID == item.chunk.sectionID {
                let used = previous.chunk.start.charOffset..<previous.chunk.end.charOffset
                ranges = ranges.flatMap { range -> [Range<Int>] in
                    guard range.overlaps(used) else { return [range] }
                    return [range.lowerBound..<max(range.lowerBound, min(range.upperBound, used.lowerBound)),
                            min(range.upperBound, max(range.lowerBound, used.upperBound))..<range.upperBound].filter { !$0.isEmpty }
                }
            }
            for range in ranges {
                if range.lowerBound == item.chunk.start.charOffset && range.upperBound == item.chunk.end.charOffset { result.append(item) }
                else if let trimmed = fragment(item.chunk, start: range.lowerBound, end: range.upperBound,
                    source: context.source, boundary: context.boundary, kind: item.kind) {
                    result.append(.init(chunk: trimmed.chunk, parentChunkID: item.parentChunkID, kind: item.kind))
                }
            }
            if ranges.isEmpty { AIDiagnostics.current?.event("evidenceRemoved", ["id": item.chunk.id, "reason": "overlap"]) }
        }
        return result
    }
}

/// Counts serialized messages including controls. No model-specific tokenizer is available;
/// these are exact local Character/UTF-8 bounds, not a token-window guarantee.
enum AIQuestionPrompt {
    struct Selection {
        let request: LLMGenerationRequest
        let evidence: [AIQuestionEvidence]
        let history: [AIChatMessage]
    }
    static func fits(_ messages: [LLMMessage], budget: AIQuestionBudget) -> Bool {
        guard let data = try? JSONEncoder().encode(messages), let string = String(data: data, encoding: .utf8) else { return false }
        return data.count <= budget.maximumInputBytes && string.count <= budget.maximumInputCharacters
    }
    static func assemble(system: String, data: String, history: [AIChatMessage], evidence: [AIQuestionEvidence],
                         budget: AIQuestionBudget, requireHistory: Bool) throws -> Selection {
        var selected = evidence
        var selectedHistory = history
        func messages() -> [LLMMessage] {
            [.init(role: .system, content: system)] + selectedHistory.map {
                .init(role: $0.role == .user ? .user : .assistant,
                      content: "<conversation-data role=\"\($0.role.rawValue)\" evidence=\"false\">\n\($0.text)\n</conversation-data>")
            } + [.init(role: .user, content: data + "\n<source-evidence>\n" + selected.map {
                "[\($0.chunk.id)]\n\($0.chunk.text)"
            }.joined(separator: "\n\n") + "\n</source-evidence>")]
        }
        // Older optional history goes first. Referential context is preserved verbatim or
        // the request fails explicitly; it is never silently truncated into a new meaning.
        while !fits(messages(), budget: budget) {
            if !requireHistory && !selectedHistory.isEmpty { selectedHistory.removeFirst() }
            else if let removed = selected.popLast() {
                AIDiagnostics.current?.event("evidenceRemoved", ["id": removed.chunk.id, "reason": "contextBudget"])
            } else { throw AIQuestionFailure.contextBudget }
        }
        let messages = messages()
        let encoded = try JSONEncoder().encode(messages)
        AIDiagnostics.current?.event("contextBudget", ["tokenCount": "unavailable", "modelCapacity": "unknown",
            "counting": "exactCharactersAndUTF8NotTokens", "bytes": "\(encoded.count)",
            "characters": "\(String(decoding: encoded, as: UTF8.self).count)", "outputTokenReserve": "\(budget.maximumOutputTokens)",
            "historyIDs": selectedHistory.map { $0.id.uuidString }.joined(separator: ","), "selected": "\(selected.count)"])
        return .init(request: .init(messages: messages, maxTokens: budget.maximumOutputTokens,
            temperature: AIRAGPipeline.temperature, topP: AIRAGPipeline.topP), evidence: selected, history: selectedHistory)
    }
}
