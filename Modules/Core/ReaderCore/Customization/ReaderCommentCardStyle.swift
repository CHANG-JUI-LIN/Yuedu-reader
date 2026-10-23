import Foundation

/// The source review *cards* a reader can redraw with a template of their own — as opposed to
/// 段評's count bubble, which `ReaderCommentBubbleCustomStyle` covers. Each kind has its own
/// page under 氣泡設定, its own templates and its own choice.
///
/// A card is told apart by the heading its source draws on it (`ReviewCardContent`), so 熱評
/// is a 神評論: both are a picked comment set after a paragraph (maintainer, 2026-10-21).
enum ReaderCommentCardKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 本章說: the chapter's discussion, under the chapter.
    case chapterSay
    /// 作者說: the author's note.
    case authorSay
    /// 神評論 and 熱評: a picked comment after a paragraph.
    case hotComment

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .chapterSay: return "本章說"
        case .authorSay: return "作者說"
        case .hotComment: return "神評論"
        }
    }

    var localizedTitle: String { localized(titleKey) }

    var systemImage: String {
        switch self {
        case .chapterSay: return "bubble.left.and.text.bubble.right"
        case .authorSay: return "person.bubble"
        case .hotComment: return "star.bubble"
        }
    }
}

/// One template for one kind of card. The SVG carries `${…}` placeholders that
/// `ReviewCardTemplate` fills from the source's card.
struct ReaderCommentCardCustomStyle: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: ReaderCommentCardKind
    var name: String
    var svg: String
    /// Last local edit, stamped by `ReaderCommentCardStyleLibrary.upserting`; the iCloud
    /// last-write-wins clock.
    var updatedAt: Date?
    /// `${color}` in day and in night, as CSS hex. Nil follows the reading text colour.
    var dayColor: String?
    var nightColor: String?

    init(
        id: UUID = UUID(),
        kind: ReaderCommentCardKind,
        name: String,
        svg: String,
        updatedAt: Date? = nil,
        dayColor: String? = nil,
        nightColor: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.svg = svg
        self.updatedAt = updatedAt
        self.dayColor = dayColor
        self.nightColor = nightColor
    }

    /// The colour `${color}` stands for, or nil for the reading text colour.
    func colorHex(isNight: Bool) -> String? {
        let raw = isNight ? nightColor : dayColor
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return raw
    }
}

/// Which template one kind of card wears.
struct ReaderCommentCardChoice: Codable, Hashable, Sendable {
    /// 優先使用選取的樣式. Off draws the card the source drew — the default, so nothing
    /// changes until a reader picks a style.
    var prefersSelectedStyle = false
    /// The custom template worn; nil is the built-in 玻璃. A template deleted since (here
    /// or on another device) reads as nil too.
    var selectedStyleID: UUID?

    init(prefersSelectedStyle: Bool = false, selectedStyleID: UUID? = nil) {
        self.prefersSelectedStyle = prefersSelectedStyle
        self.selectedStyleID = selectedStyleID
    }
}

/// The three choices, stored and synced as one value (the 段評氣泡 row of 排版生效範圍).
struct ReaderCommentCardChoices: Codable, Hashable, Sendable {
    var chapterSay = ReaderCommentCardChoice()
    var authorSay = ReaderCommentCardChoice()
    var hotComment = ReaderCommentCardChoice()

    init() {}

    subscript(kind: ReaderCommentCardKind) -> ReaderCommentCardChoice {
        get {
            switch kind {
            case .chapterSay: return chapterSay
            case .authorSay: return authorSay
            case .hotComment: return hotComment
            }
        }
        set {
            switch kind {
            case .chapterSay: chapterSay = newValue
            case .authorSay: authorSay = newValue
            case .hotComment: hotComment = newValue
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case chapterSay, authorSay, hotComment
    }

    /// Kind by kind, so a value a later build adds or changes costs that kind alone.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chapterSay = (try? c.decodeIfPresent(ReaderCommentCardChoice.self, forKey: .chapterSay)) ?? .init()
        authorSay = (try? c.decodeIfPresent(ReaderCommentCardChoice.self, forKey: .authorSay)) ?? .init()
        hotComment = (try? c.decodeIfPresent(ReaderCommentCardChoice.self, forKey: .hotComment)) ?? .init()
    }
}

enum ReaderCommentCardStyleLibrary {
    /// Decodes the stored library one template at a time: a template of a kind this build
    /// does not know is skipped instead of emptying the whole library.
    static func decode(_ data: Data) throws -> [ReaderCommentCardCustomStyle] {
        let items = try JSONDecoder().decode([LossyStyle].self, from: data)
        return uniqued(items.compactMap(\.style))
    }

    static func uniqued(_ styles: [ReaderCommentCardCustomStyle]) -> [ReaderCommentCardCustomStyle] {
        var seen = Set<UUID>()
        return styles.filter { seen.insert($0.id).inserted }
    }

    /// Every upsert is a local edit: it stamps the merge clock, so the edit outranks older
    /// copies on other devices.
    static func upserting(
        _ style: ReaderCommentCardCustomStyle,
        into styles: [ReaderCommentCardCustomStyle],
        now: Date = Date()
    ) -> [ReaderCommentCardCustomStyle] {
        var stamped = style
        stamped.updatedAt = now
        guard let index = styles.firstIndex(where: { $0.id == style.id }) else {
            return styles + [stamped]
        }
        var updated = styles
        updated[index] = stamped
        return updated
    }

    static func deleting(id: UUID, from styles: [ReaderCommentCardCustomStyle]) -> [ReaderCommentCardCustomStyle] {
        styles.filter { $0.id != id }
    }

    /// The template `kind` wears under `choice`: the selected custom one, the built-in one
    /// when none is selected or the selected one is gone, or nil when the source's own card
    /// is drawn.
    static func wornTemplate(
        for kind: ReaderCommentCardKind,
        choice: ReaderCommentCardChoice,
        styles: [ReaderCommentCardCustomStyle]
    ) -> WornTemplate? {
        guard choice.prefersSelectedStyle else { return nil }
        if let id = choice.selectedStyleID,
           let style = styles.first(where: { $0.id == id && $0.kind == kind }) {
            return .custom(style)
        }
        return .builtin
    }

    enum WornTemplate: Equatable, Sendable {
        case builtin
        case custom(ReaderCommentCardCustomStyle)
    }

    private struct LossyStyle: Decodable {
        let style: ReaderCommentCardCustomStyle?

        init(from decoder: Decoder) throws {
            do {
                style = try ReaderCommentCardCustomStyle(from: decoder)
            } catch {
                AppLogger.error("comment card template skipped", error: error)
                style = nil
            }
        }
    }
}

/// A card template as a file, for 匯出 and 匯入 when the template carries colours a bare
/// `.svg` cannot hold.
struct ReaderCommentCardPackageFile: Codable, Equatable {
    static let formatIdentifier = "yuedu.commentCard"

    var format: String
    var version: Int
    var kind: ReaderCommentCardKind
    var name: String
    var svgTemplate: String
    var dayColor: String?
    var nightColor: String?

    init(style: ReaderCommentCardCustomStyle) {
        format = Self.formatIdentifier
        version = 1
        kind = style.kind
        name = style.name
        svgTemplate = style.svg
        dayColor = style.dayColor
        nightColor = style.nightColor
    }

    /// A package from file contents, or nil when they are not one (a bare SVG takes the
    /// plain import path).
    static func decode(_ data: Data) -> ReaderCommentCardPackageFile? {
        guard let package = try? JSONDecoder().decode(Self.self, from: data),
              package.format == formatIdentifier else { return nil }
        return package
    }

    func makeStyle(id: UUID = UUID()) -> ReaderCommentCardCustomStyle {
        ReaderCommentCardCustomStyle(
            id: id,
            kind: kind,
            name: name,
            svg: svgTemplate,
            dayColor: dayColor,
            nightColor: nightColor
        )
    }
}
