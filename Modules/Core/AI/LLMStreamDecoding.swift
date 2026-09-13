//
// Derived from ChatBook (https://github.com/bsnmldb/ChatBook),
// Sources/ChatBookCore/Assistant/LLMStreaming.swift — Apache License 2.0.
// See NOTICE at the repository root.
//
import Foundation

/// Turns one SSE `data:` line from an OpenAI-compatible `/v1/chat/completions` stream into a
/// content delta.
///
/// Pure and network-free so the wire format is unit-testable; the provider feeds it lines
/// from `URLSession.bytes`.
///
/// Ported to `Codable` from the original's `JSONSerialization` dictionary walk: the shape is
/// fixed by the protocol, and a typed decode fails loudly on a response that is not a chat
/// completion chunk instead of quietly reading `nil` out of the wrong key.
enum LLMStreamDecoding {

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        let choices: [Choice]?
    }

    static let donePayload = "[DONE]"

    /// The payload of a `data:` line, or `nil` for anything that is not one (`event:`,
    /// `:` heartbeats, blank lines).
    static func payload(ofDataLine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
    }

    static func isDone(_ line: String) -> Bool {
        payload(ofDataLine: line) == donePayload
    }

    /// The content delta carried by one SSE line.
    ///
    /// `nil` for a non-`data:` line, for `[DONE]`, and for the protocol's first chunk (which
    /// carries only `delta.role`) — none of those are text the user should see.
    static func contentDelta(from dataLine: String) -> String? {
        guard let payload = payload(ofDataLine: dataLine), payload != donePayload,
              let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(Chunk.self, from: data),
              let content = chunk.choices?.first?.delta?.content,
              !content.isEmpty
        else { return nil }
        return content
    }
}
