//
// Derived from ChatBook (https://github.com/bsnmldb/ChatBook),
// Sources/ChatBookCore/Retrieval/BM25Index.swift — Apache License 2.0.
// See NOTICE at the repository root.
//
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif
import Foundation

/// In-memory keyword retrieval over a book's chunks.
///
/// Not persisted: it is rebuilt from the stored chunks when a book's index loads, which costs
/// far less than keeping a second on-disk structure in sync with the first.
///
/// Tokenisation is `NLTokenizer` at word level — the system's own CJK word segmentation, with
/// no jieba or SQLite FTS dependency to ship. This is also the tier that works with **no model
/// downloaded at all**: exact hits on names, places and terms are what Chinese readers
/// actually ask about, which is why keyword weight is set above vector weight when both run.
struct AIBM25Index: Sendable {
    private struct Posting: Sendable {
        let documentIndex: Int
        let frequency: Int
    }

    private let chunks: [AIContentChunk]
    /// Only the inverted lists and per-document lengths are kept. Holding the tokenised text
    /// as well would mean millions of small `String`s on a long web novel.
    private let postingsByTerm: [String: [Posting]]
    private let documentLengths: [Int]
    private let averageDocumentLength: Double
    private let documentCount: Int
    private let k1: Double
    private let b: Double

    init(chunks: [AIContentChunk], k1: Double = 1.5, b: Double = 0.75) {
        self.chunks = chunks
        self.k1 = k1
        self.b = b
        self.documentCount = chunks.count
        var postings: [String: [Posting]] = [:]
        var lengths: [Int] = []
        lengths.reserveCapacity(chunks.count)
        for (documentIndex, chunk) in chunks.enumerated() {
            let tokens = Self.tokenize(chunk.text)
            lengths.append(tokens.count)
            var frequencies: [String: Int] = [:]
            for token in tokens { frequencies[token, default: 0] += 1 }
            for (term, frequency) in frequencies {
                postings[term, default: []].append(
                    Posting(documentIndex: documentIndex, frequency: frequency)
                )
            }
        }
        self.postingsByTerm = postings
        self.documentLengths = lengths
        let total = lengths.reduce(0, +)
        self.averageDocumentLength = documentCount > 0 ? Double(total) / Double(documentCount) : 0
    }

    /// Scores `query`, returning hits with a positive score, best first.
    func search(query: String, limit: Int) -> [AIRetrievalHit] {
        let terms = Set(Self.tokenize(query))
        guard !terms.isEmpty, documentCount > 0, limit > 0 else { return [] }
        var scoresByDocument: [Int: Double] = [:]
        for term in terms {
            guard let postings = postingsByTerm[term] else { continue }
            let documentFrequency = Double(postings.count)
            let idf = log(
                1 + (Double(documentCount) - documentFrequency + 0.5) / (documentFrequency + 0.5)
            )
            for posting in postings {
                let length = Double(documentLengths[posting.documentIndex])
                let frequency = Double(posting.frequency)
                let denominator = frequency
                    + k1 * (1 - b + b * length / max(averageDocumentLength, 1))
                scoresByDocument[posting.documentIndex, default: 0] +=
                    idf * (frequency * (k1 + 1)) / denominator
            }
        }
        return AIRetrievalRanking.topK(
            scoresByDocument.lazy.map { documentIndex, score in
                AIRetrievalHit(chunk: chunks[documentIndex], score: score)
            },
            limit: min(limit, documentCount)
        )
    }

    static func tokenize(_ text: String) -> [String] {
        #if canImport(NaturalLanguage)
        var tokens: [String] = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            tokens.append(String(text[range]).lowercased())
            return true
        }
        return tokens
        #else
        return text.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
        #endif
    }
}
