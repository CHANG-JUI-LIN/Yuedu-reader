import Testing
import Foundation
@testable import yuedu_app

/// Isolating the BrowserLayout non-determinism found by the whole-book
/// line-break net: laying out identical input three times produced different
/// geometry for a *varying* subset of chapter title pages (spine 266 took
/// x = 168.20 / 170.20 / 164.20 across three runs).
///
/// These three tests separate the candidate causes rather than guessing:
///
///   1. `isolatedLayoutIsStable`      — is one chapter, alone, reproducible?
///   2. `loopResultMatchesIsolated`   — does laying out the whole book before
///                                      it change the answer?
///   3. `prefixLengthChangesResult`   — does *how much* came before it matter?
///
/// (1) failing means the instability is inside a single chapter's layout.
/// (1) passing while (2) or (3) fails means cross-chapter state is leaking —
/// the prefix is the carrier, and (3) narrows how far back it reaches.
@MainActor
struct BrowserLayoutDeterminismTests {

    typealias Net = BrowserLayoutLineBreakBaselineTests

    /// Chapter title pages seen flapping. 266 flapped in two separate runs.
    static let suspects = [266, 257, 262, 403]
    static let probe = 266

    private static func print(of session: PublicationSession, spine: Int) async -> Net.ChapterPrint? {
        guard let (pages, text) = await Net.layout(session: session, spine: spine) else { return nil }
        return Net.fingerprint(spine: spine, pages: pages, sourceText: text)
    }

    private static func freshSession() async throws -> PublicationSession {
        let path = try #require(Net.epubPath)
        return try await PublicationSession.open(sourceURL: URL(fileURLWithPath: path))
    }

    // MARK: - 1. Alone, repeated

    @Test("a single chapter laid out alone is reproducible", .enabled(if: Net.epubPath != nil))
    func isolatedLayoutIsStable() async throws {
        var seen: [String: Int] = [:]
        for _ in 0..<5 {
            // Fresh session each pass: nothing carries over but process-global state.
            let session = try await Self.freshSession()
            guard let p = await Self.print(of: session, spine: Self.probe) else { continue }
            seen[p.first, default: 0] += 1
        }
        Swift.print("DETERMINISM isolated spine=\(Self.probe) distinctFirstLines=\(seen.count) → \(seen)")
        #expect(seen.count == 1, "spine \(Self.probe) alone produced \(seen.count) different first lines: \(seen)")
    }

    // MARK: - 2. Alone vs after the whole book

    @Test("laying out the whole book first does not change a chapter", .enabled(if: Net.epubPath != nil))
    func loopResultMatchesIsolated() async throws {
        let solo = try await Self.freshSession()
        let alone = await Self.print(of: solo, spine: Self.probe)

        let looped = try await Self.freshSession()
        for spine in 0..<Self.probe {
            _ = await Net.layout(session: looped, spine: spine)
        }
        let afterLoop = await Self.print(of: looped, spine: Self.probe)

        Swift.print("DETERMINISM alone=\(alone?.first ?? "-")")
        Swift.print("DETERMINISM loop =\(afterLoop?.first ?? "-")")
        #expect(alone == afterLoop, "prefix of \(Self.probe) chapters changed the layout of spine \(Self.probe)")
    }

    // MARK: - 3. How far back does the carrier reach?

    @Test("the length of what came before does not change a chapter", .enabled(if: Net.epubPath != nil))
    func prefixLengthChangesResult() async throws {
        var byPrefix: [Int: String] = [:]
        for start in [Self.probe - 1, Self.probe - 16, Self.probe - 64, 0] {
            let session = try await Self.freshSession()
            for spine in start..<Self.probe {
                _ = await Net.layout(session: session, spine: spine)
            }
            byPrefix[Self.probe - start] = await Self.print(of: session, spine: Self.probe)?.first ?? "-"
        }
        Swift.print("DETERMINISM byPrefixLength=\(byPrefix)")
        #expect(Set(byPrefix.values).count == 1, "prefix length changed the result: \(byPrefix)")
    }

    // MARK: - Every suspect, alone

    @Test("all suspect title pages are reproducible alone", .enabled(if: Net.epubPath != nil))
    func allSuspectsStableAlone() async throws {
        var unstable: [Int] = []
        for spine in Self.suspects {
            var seen = Set<String>()
            for _ in 0..<3 {
                let session = try await Self.freshSession()
                if let p = await Self.print(of: session, spine: spine) { seen.insert(p.first) }
            }
            if seen.count > 1 { unstable.append(spine) }
        }
        Swift.print("DETERMINISM unstableAlone=\(unstable)")
        #expect(unstable.isEmpty, "unstable in isolation: \(unstable)")
    }
}
