import Foundation

struct ReaderCommentBubbleCustomStyle: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var svg: String

    init(id: UUID = UUID(), name: String, svg: String) {
        self.id = id
        self.name = name
        self.svg = svg
    }
}

enum ReaderCommentBubbleCustomStyleLibrary {
    enum V2DecodingResult: Equatable {
        case missing
        case valid([ReaderCommentBubbleCustomStyle])
        case invalid
    }

    static func decodeV2(
        keyExists: Bool,
        data: Data?
    ) -> V2DecodingResult {
        guard keyExists else { return .missing }
        guard let data,
              let styles = try? JSONDecoder().decode(
                  [ReaderCommentBubbleCustomStyle].self,
                  from: data
              ) else {
            return .invalid
        }
        return .valid(styles)
    }

    static func uniqued(
        _ styles: [ReaderCommentBubbleCustomStyle]
    ) -> [ReaderCommentBubbleCustomStyle] {
        var seenIDs = Set<UUID>()
        return styles.filter { seenIDs.insert($0.id).inserted }
    }

    static func validatedSelectedID(
        _ selectedID: UUID?,
        in styles: [ReaderCommentBubbleCustomStyle]
    ) -> UUID? {
        guard let selectedID,
              styles.contains(where: { $0.id == selectedID }) else {
            return nil
        }
        return selectedID
    }

    static func upserting(
        _ style: ReaderCommentBubbleCustomStyle,
        into styles: [ReaderCommentBubbleCustomStyle]
    ) -> [ReaderCommentBubbleCustomStyle] {
        guard let matchingIndex = styles.firstIndex(where: { $0.id == style.id }) else {
            return styles + [style]
        }

        var updatedStyles = styles
        updatedStyles[matchingIndex] = style
        return updatedStyles
    }

    static func deleting(
        id: UUID,
        from styles: [ReaderCommentBubbleCustomStyle]
    ) -> [ReaderCommentBubbleCustomStyle] {
        styles.filter { $0.id != id }
    }

    static func migratingLegacyStyleIfNeeded(
        in savedStyles: [ReaderCommentBubbleCustomStyle],
        legacySVG: String,
        generatedPlaceholderSVG: String,
        migratedName: String,
        migratedID: UUID = UUID()
    ) -> [ReaderCommentBubbleCustomStyle] {
        guard savedStyles.isEmpty else { return savedStyles }

        let trimmedLegacySVG = legacySVG.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLegacySVG.isEmpty else { return savedStyles }

        let trimmedPlaceholderSVG = generatedPlaceholderSVG.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLegacySVG != trimmedPlaceholderSVG else { return savedStyles }

        return [
            ReaderCommentBubbleCustomStyle(
                id: migratedID,
                name: migratedName,
                svg: trimmedLegacySVG
            )
        ]
    }
}
