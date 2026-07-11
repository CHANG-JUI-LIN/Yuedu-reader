import Foundation
import Testing
@testable import yuedu_app

@Suite("Reader comment bubble custom style library")
struct ReaderCommentBubbleCustomStyleTests {
    @Test("reports a missing V2 library when the key does not exist")
    func reportsMissingV2Library() {
        let result = ReaderCommentBubbleCustomStyleLibrary.decodeV2(
            keyExists: false,
            data: Data("not-json".utf8)
        )

        #expect(result == .missing)
    }

    @Test("reports a valid empty V2 library without treating it as missing")
    func reportsValidEmptyV2Library() throws {
        let data = try JSONEncoder().encode([ReaderCommentBubbleCustomStyle]())

        let result = ReaderCommentBubbleCustomStyleLibrary.decodeV2(
            keyExists: true,
            data: data
        )

        #expect(result == .valid([]))
    }

    @Test("decodes styles from a valid V2 library")
    func decodesValidV2Library() throws {
        let style = makeStyle(name: "Saved", svg: "<svg>saved</svg>")
        let data = try JSONEncoder().encode([style])

        let result = ReaderCommentBubbleCustomStyleLibrary.decodeV2(
            keyExists: true,
            data: data
        )

        #expect(result == .valid([style]))
    }

    @Test("reports an invalid V2 library when its existing value is corrupt")
    func reportsInvalidV2Library() {
        let corruptData = Data("not-json".utf8)

        #expect(
            ReaderCommentBubbleCustomStyleLibrary.decodeV2(
                keyExists: true,
                data: corruptData
            ) == .invalid
        )
        #expect(
            ReaderCommentBubbleCustomStyleLibrary.decodeV2(
                keyExists: true,
                data: nil
            ) == .invalid
        )
    }

    @Test("appends a new style")
    func appendsNewStyle() {
        let existing = makeStyle(name: "Existing", svg: "<svg>existing</svg>")
        let added = makeStyle(name: "Added", svg: "<svg>added</svg>")

        let result = ReaderCommentBubbleCustomStyleLibrary.upserting(added, into: [existing])

        #expect(result == [existing, added])
    }

    @Test("updates a matching ID without changing its order or ID")
    func updatesMatchingIDInPlace() {
        let first = makeStyle(name: "First", svg: "<svg>first</svg>")
        let target = makeStyle(name: "Before", svg: "<svg>before</svg>")
        let last = makeStyle(name: "Last", svg: "<svg>last</svg>")
        let updated = ReaderCommentBubbleCustomStyle(
            id: target.id,
            name: "After",
            svg: "<svg>after</svg>"
        )

        let result = ReaderCommentBubbleCustomStyleLibrary.upserting(
            updated,
            into: [first, target, last]
        )

        #expect(result == [first, updated, last])
        #expect(result.map(\.id) == [first.id, target.id, last.id])
    }

    @Test("deletes only the requested style")
    func deletesOnlyRequestedStyle() {
        let first = makeStyle(name: "First", svg: "<svg>first</svg>")
        let target = makeStyle(name: "Target", svg: "<svg>target</svg>")
        let last = makeStyle(name: "Last", svg: "<svg>last</svg>")

        let result = ReaderCommentBubbleCustomStyleLibrary.deleting(
            id: target.id,
            from: [first, target, last]
        )

        #expect(result == [first, last])
    }

    @Test("keeps only the first style for each UUID")
    func keepsOnlyFirstStyleForEachID() {
        let id = UUID()
        let first = ReaderCommentBubbleCustomStyle(
            id: id,
            name: "First",
            svg: "<svg>first</svg>"
        )
        let duplicate = ReaderCommentBubbleCustomStyle(
            id: id,
            name: "Duplicate",
            svg: "<svg>duplicate</svg>"
        )
        let unique = makeStyle(name: "Unique", svg: "<svg>unique</svg>")

        let result = ReaderCommentBubbleCustomStyleLibrary.uniqued(
            [first, duplicate, unique]
        )

        #expect(result == [first, unique])
    }

    @Test("clears a selected UUID that no longer exists")
    func clearsStaleSelectedID() {
        let style = makeStyle(name: "Saved", svg: "<svg>saved</svg>")

        let result = ReaderCommentBubbleCustomStyleLibrary.validatedSelectedID(
            UUID(),
            in: [style]
        )

        #expect(result == nil)
    }

    @Test("keeps a selected UUID that still exists")
    func keepsValidSelectedID() {
        let style = makeStyle(name: "Saved", svg: "<svg>saved</svg>")

        let result = ReaderCommentBubbleCustomStyleLibrary.validatedSelectedID(
            style.id,
            in: [style]
        )

        #expect(result == style.id)
    }

    @Test("migrates a non-placeholder legacy SVG when saved styles are empty")
    func migratesEligibleLegacySVG() {
        let migratedID = UUID()

        let result = ReaderCommentBubbleCustomStyleLibrary.migratingLegacyStyleIfNeeded(
            in: [],
            legacySVG: "  \n<svg>legacy</svg>\n  ",
            generatedPlaceholderSVG: "<svg>generated</svg>",
            migratedName: "Migrated",
            migratedID: migratedID
        )

        #expect(result == [
            ReaderCommentBubbleCustomStyle(
                id: migratedID,
                name: "Migrated",
                svg: "<svg>legacy</svg>"
            )
        ])
    }

    @Test("does not migrate when saved styles already exist")
    func doesNotMigrateOverSavedStyles() {
        let existing = makeStyle(name: "Existing", svg: "<svg>existing</svg>")

        let result = ReaderCommentBubbleCustomStyleLibrary.migratingLegacyStyleIfNeeded(
            in: [existing],
            legacySVG: "<svg>legacy</svg>",
            generatedPlaceholderSVG: "<svg>generated</svg>",
            migratedName: "Migrated"
        )

        #expect(result == [existing])
    }

    @Test("does not migrate an empty legacy SVG")
    func doesNotMigrateEmptyLegacySVG() {
        let result = ReaderCommentBubbleCustomStyleLibrary.migratingLegacyStyleIfNeeded(
            in: [],
            legacySVG: " \n\t ",
            generatedPlaceholderSVG: "<svg>generated</svg>",
            migratedName: "Migrated"
        )

        #expect(result.isEmpty)
    }

    @Test("does not migrate the generated placeholder SVG after trimming")
    func doesNotMigrateGeneratedPlaceholderSVG() {
        let result = ReaderCommentBubbleCustomStyleLibrary.migratingLegacyStyleIfNeeded(
            in: [],
            legacySVG: " \n<svg>generated</svg>\t ",
            generatedPlaceholderSVG: "<svg>generated</svg>",
            migratedName: "Migrated"
        )

        #expect(result.isEmpty)
    }

    @Test("preserves every field through a Codable JSON round trip")
    func preservesFieldsThroughJSONRoundTrip() throws {
        let original = ReaderCommentBubbleCustomStyle(
            id: UUID(),
            name: "Round trip",
            svg: "<svg>round-trip</svg>"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            ReaderCommentBubbleCustomStyle.self,
            from: data
        )

        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.svg == original.svg)
    }

    private func makeStyle(name: String, svg: String) -> ReaderCommentBubbleCustomStyle {
        ReaderCommentBubbleCustomStyle(id: UUID(), name: name, svg: svg)
    }
}
