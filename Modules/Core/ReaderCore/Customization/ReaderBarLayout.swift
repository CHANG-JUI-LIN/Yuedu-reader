import Foundation

// MARK: - Bars

/// The two info bands that frame the reading text.
///
/// They are *bars*, not free-floating components: the text area is inset to make
/// room for them and never passes underneath, which is what lets scroll mode have
/// a header and footer at all. legado's `view_book_page.xml` is the reference —
/// `ll_header` / `ll_footer` are siblings of the content view, and the content is
/// constrained between the two dividers rather than drawn under them.
enum ReaderBar: String, CaseIterable, Codable, Equatable, Hashable, Sendable, Identifiable {
    case header
    case footer

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .header: return "頁眉"
        case .footer: return "頁腳"
        }
    }
}

/// Where one field sits. Six slots plus hidden, matching legado's
/// `tipHeaderLeft` / `tipHeaderMiddle` / … set.
///
/// Unlike legado — which lets a slot hold exactly one tip type — several fields
/// may share a slot here and render side by side, separated by a middle dot. That
/// is the behaviour the app already had in `ReaderHeaderFieldPosition`, and
/// dropping it would take away layouts people are using today.
enum ReaderBarSlot: String, CaseIterable, Codable, Equatable, Hashable, Sendable, Identifiable {
    case hidden
    case headerLeft
    case headerCenter
    case headerRight
    case footerLeft
    case footerCenter
    case footerRight

    var id: String { rawValue }

    /// Which bar this slot belongs to; `nil` for `.hidden`.
    var bar: ReaderBar? {
        switch self {
        case .hidden: return nil
        case .headerLeft, .headerCenter, .headerRight: return .header
        case .footerLeft, .footerCenter, .footerRight: return .footer
        }
    }

    var titleKey: String {
        switch self {
        case .hidden: return "隱藏"
        case .headerLeft: return "頁眉靠左"
        case .headerCenter: return "頁眉置中"
        case .headerRight: return "頁眉靠右"
        case .footerLeft: return "頁腳靠左"
        case .footerCenter: return "頁腳置中"
        case .footerRight: return "頁腳靠右"
        }
    }

    /// The three slots of one bar, in reading order.
    static func slots(in bar: ReaderBar) -> [ReaderBarSlot] {
        switch bar {
        case .header: return [.headerLeft, .headerCenter, .headerRight]
        case .footer: return [.footerLeft, .footerCenter, .footerRight]
        }
    }
}

// MARK: - Field

/// One info field and the slot it was assigned to.
///
/// `kind` and `configuration` are the same types the free-position layout used, so
/// the value layer (`ReaderOverlayValueFormatter`, `ReaderBatteryValueResolver`)
/// and per-field options (time format, battery as icon or percentage, an imported
/// battery SVG) carry over untouched. Only *position* changed representation.
struct ReaderBarField: Codable, Equatable, Sendable, Identifiable {
    var kind: ReaderOverlayComponentKind
    var slot: ReaderBarSlot
    var configuration: ReaderOverlayComponentConfiguration
    /// Nil inherits the shared bar color; an explicit reference overrides it.
    var color: ReaderOverlayColorReference?

    /// One entry per kind, so the kind is the identity.
    var id: String { kind.rawValue }

    init(
        kind: ReaderOverlayComponentKind,
        slot: ReaderBarSlot,
        configuration: ReaderOverlayComponentConfiguration = ReaderOverlayComponentConfiguration(),
        color: ReaderOverlayColorReference? = nil
    ) {
        self.kind = kind
        self.slot = slot
        self.configuration = configuration
        self.color = color
    }

    var normalized: ReaderBarField {
        ReaderBarField(
            kind: kind,
            slot: slot,
            configuration: configuration.normalized,
            color: color?.normalized
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case slot
        case configuration
        case color
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(ReaderOverlayComponentKind.self, forKey: .kind)
        slot = try container.decodeIfPresent(ReaderBarSlot.self, forKey: .slot) ?? .hidden
        configuration = try container.decodeIfPresent(
            ReaderOverlayComponentConfiguration.self,
            forKey: .configuration
        ) ?? ReaderOverlayComponentConfiguration()
        color = try container.decodeIfPresent(ReaderOverlayColorReference.self, forKey: .color)
    }
}

// MARK: - Shared style

/// Shared typography, opacity and default color. Each field can override color.
struct ReaderBarStyle: Codable, Equatable, Sendable {
    static let defaultFontSize: Double = 11
    static let fontSizeRange: ClosedRange<Double> = 8...16
    static let defaultOpacity: Double = 0.45
    static let opacityRange: ClosedRange<Double> = 0.1...1

    var fontSize: Double
    var weight: ReaderOverlayFontWeight
    var color: ReaderOverlayColorReference
    var opacity: Double

    init(
        fontSize: Double = ReaderBarStyle.defaultFontSize,
        weight: ReaderOverlayFontWeight = .regular,
        color: ReaderOverlayColorReference = ReaderOverlayColorReference(source: .readerText),
        opacity: Double = ReaderBarStyle.defaultOpacity
    ) {
        self.fontSize = fontSize
        self.weight = weight
        self.color = color
        self.opacity = opacity
    }

    var normalized: ReaderBarStyle {
        ReaderBarStyle(
            fontSize: Self.clamp(fontSize, to: Self.fontSizeRange, fallback: Self.defaultFontSize),
            weight: weight,
            color: color.normalized,
            opacity: Self.clamp(opacity, to: Self.opacityRange, fallback: Self.defaultOpacity)
        )
    }

    private static func clamp(
        _ value: Double,
        to range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case fontSize
        case weight
        case color
        case opacity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? Self.defaultFontSize
        weight = try container.decodeIfPresent(ReaderOverlayFontWeight.self, forKey: .weight) ?? .regular
        color = try container.decodeIfPresent(ReaderOverlayColorReference.self, forKey: .color)
            ?? ReaderOverlayColorReference(source: .readerText)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? Self.defaultOpacity
    }
}

// MARK: - Layout

/// Absolute distances from the reading surface edges. Nil preserves the
/// existing safe-area-relative placement until the user edits that bar.
struct ReaderBarEdgeDistances: Codable, Equatable, Sendable {
    static let adjustmentRange: ClosedRange<Double> = 0...200
    var header: Double?
    var footer: Double?

    init(header: Double? = nil, footer: Double? = nil) {
        self.header = header
        self.footer = footer
    }

    subscript(bar: ReaderBar) -> Double? {
        get { bar == .header ? header : footer }
        set {
            if bar == .header { header = newValue } else { footer = newValue }
        }
    }

    var normalized: Self {
        func normalize(_ value: Double?) -> Double? {
            guard let value, value.isFinite else { return nil }
            return min(max(value, Self.adjustmentRange.lowerBound), Self.adjustmentRange.upperBound)
        }
        return Self(header: normalize(header), footer: normalize(footer))
    }
}

/// Which fields exist, which slot each one sits in, and how the two bars are drawn.
///
/// Visibility and legacy padding remain in GlobalSettings. Explicit edge
/// distances take precedence and travel with the layout through save and export.
struct ReaderBarLayout: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    /// One entry per `ReaderOverlayComponentKind`. Array order is render order
    /// within a slot, so reordering in the editor reorders on the page.
    var fields: [ReaderBarField]
    var showsHeaderDivider: Bool
    var showsFooterDivider: Bool
    /// The chapter-opening page usually already carries the chapter title in large
    /// type, so repeating it in the header reads as a duplicate. This replaces the
    /// two independent free-position layouts the editor used to keep per page scope.
    var hidesHeaderOnChapterOpening: Bool
    var style: ReaderBarStyle
    var edgeDistances: ReaderBarEdgeDistances

    init(
        version: Int = ReaderBarLayout.currentVersion,
        fields: [ReaderBarField],
        showsHeaderDivider: Bool = false,
        showsFooterDivider: Bool = false,
        hidesHeaderOnChapterOpening: Bool = true,
        style: ReaderBarStyle = ReaderBarStyle(),
        edgeDistances: ReaderBarEdgeDistances = ReaderBarEdgeDistances()
    ) {
        self.version = version
        self.fields = fields
        self.showsHeaderDivider = showsHeaderDivider
        self.showsFooterDivider = showsFooterDivider
        self.hidesHeaderOnChapterOpening = hidesHeaderOnChapterOpening
        self.style = style
        self.edgeDistances = edgeDistances
    }

    static var `default`: ReaderBarLayout {
        ReaderBarLayoutMigration.defaultLayout
    }

    /// Fields assigned to one slot, in render order, skipping hidden ones.
    func fields(in slot: ReaderBarSlot) -> [ReaderBarField] {
        guard slot != .hidden else { return [] }
        return fields.filter { $0.slot == slot }
    }

    /// Whether a bar has anything to draw. A bar with no assigned field reserves
    /// no space, so the text gets that height back instead of a blank strip.
    func hasContent(in bar: ReaderBar) -> Bool {
        let slots = Set(ReaderBarSlot.slots(in: bar))
        return fields.contains { slots.contains($0.slot) }
    }

    func slot(for kind: ReaderOverlayComponentKind) -> ReaderBarSlot {
        fields.first { $0.kind == kind }?.slot ?? .hidden
    }

    mutating func setSlot(_ slot: ReaderBarSlot, for kind: ReaderOverlayComponentKind) {
        if let index = fields.firstIndex(where: { $0.kind == kind }) {
            fields[index].slot = slot
        } else {
            fields.append(ReaderBarField(kind: kind, slot: slot))
        }
    }

    mutating func setConfiguration(
        _ configuration: ReaderOverlayComponentConfiguration,
        for kind: ReaderOverlayComponentKind
    ) {
        if let index = fields.firstIndex(where: { $0.kind == kind }) {
            fields[index].configuration = configuration
        } else {
            fields.append(
                ReaderBarField(kind: kind, slot: .hidden, configuration: configuration)
            )
        }
    }

    mutating func setColor(_ color: ReaderOverlayColorReference?, for kind: ReaderOverlayComponentKind) {
        if let index = fields.firstIndex(where: { $0.kind == kind }) {
            fields[index].color = color
        } else {
            fields.append(ReaderBarField(kind: kind, slot: .hidden, color: color))
        }
    }

    /// Collapses duplicates and guarantees one entry per kind, so the editor can
    /// address every field by kind without first checking whether it exists.
    func normalized(preservingVersion: Bool = true) -> ReaderBarLayout {
        var seen = Set<ReaderOverlayComponentKind>()
        var ordered: [ReaderBarField] = []
        for field in fields where !seen.contains(field.kind) {
            seen.insert(field.kind)
            ordered.append(field.normalized)
        }
        for kind in ReaderOverlayComponentKind.allCases where !seen.contains(kind) {
            ordered.append(ReaderBarField(kind: kind, slot: .hidden))
        }
        return ReaderBarLayout(
            version: preservingVersion ? version : Self.currentVersion,
            fields: ordered,
            showsHeaderDivider: showsHeaderDivider,
            showsFooterDivider: showsFooterDivider,
            hidesHeaderOnChapterOpening: hidesHeaderOnChapterOpening,
            style: style.normalized,
            edgeDistances: edgeDistances.normalized
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case fields
        case showsHeaderDivider
        case showsFooterDivider
        case hidesHeaderOnChapterOpening
        case style
        case edgeDistances
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        fields = try container.decodeIfPresent([ReaderBarField].self, forKey: .fields) ?? []
        showsHeaderDivider = try container.decodeIfPresent(Bool.self, forKey: .showsHeaderDivider) ?? false
        showsFooterDivider = try container.decodeIfPresent(Bool.self, forKey: .showsFooterDivider) ?? false
        hidesHeaderOnChapterOpening = try container
            .decodeIfPresent(Bool.self, forKey: .hidesHeaderOnChapterOpening) ?? true
        style = try container.decodeIfPresent(ReaderBarStyle.self, forKey: .style) ?? ReaderBarStyle()
        edgeDistances = try container.decodeIfPresent(ReaderBarEdgeDistances.self, forKey: .edgeDistances)
            ?? ReaderBarEdgeDistances()
    }
}

// MARK: - Sync

/// The iCloud-synced bar layout, replacing `ReaderOverlayLayoutSyncRecord`.
///
/// Synced as ONE always-present last-write-wins record for the same reason the
/// free-position layout was: an *absent* record lets the merge's local-deletion
/// loop tombstone the constant record id with `now` and destroy a layout a second
/// device had just edited. `modifiedAt` advances only when the user edits the
/// layout on that device.
///
/// Slots are symbolic, so unlike normalized coordinates they carry across screen
/// sizes with no interpretation at all — an iPhone's 頁腳靠左 is an iPad's 頁腳靠左.
struct ReaderBarLayoutSyncRecord: Codable, Equatable, Sendable {
    var layout: ReaderBarLayout
    var modifiedAt: Date?
}
