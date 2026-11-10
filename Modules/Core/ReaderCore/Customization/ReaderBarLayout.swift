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
    var usesCustomOptions: Bool?

    var isCustomizing: Bool {
        usesCustomOptions ?? (configuration != ReaderOverlayComponentConfiguration() || color != nil)
    }

    var effectiveConfiguration: ReaderOverlayComponentConfiguration {
        usesCustomOptions == false ? .init() : configuration
    }
    var effectiveColor: ReaderOverlayColorReference? {
        usesCustomOptions == false ? nil : color
    }

    /// A kind may appear independently in several positions.
    var id: String { "\(slot.rawValue).\(kind.rawValue)" }

    init(
        kind: ReaderOverlayComponentKind,
        slot: ReaderBarSlot,
        configuration: ReaderOverlayComponentConfiguration = ReaderOverlayComponentConfiguration(),
        color: ReaderOverlayColorReference? = nil,
        usesCustomOptions: Bool? = nil
    ) {
        self.kind = kind
        self.slot = slot
        self.configuration = configuration
        self.color = color
        self.usesCustomOptions = usesCustomOptions
    }

    var normalized: ReaderBarField {
        ReaderBarField(
            kind: kind,
            slot: slot,
            configuration: configuration.normalized,
            color: color?.normalized,
            usesCustomOptions: usesCustomOptions
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case slot
        case configuration
        case color
        case usesCustomOptions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usesCustomOptions = try container.decodeIfPresent(Bool.self, forKey: .usesCustomOptions)
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

/// Where the bars' typeface comes from (FB-126). Size and weight stay the bars' own
/// whichever one is picked.
enum ReaderBarFontSource: String, Codable, Equatable, Hashable, Sendable {
    /// The system font — what the bars always used, and still the default.
    case system
    /// Whatever the reading font is at the time, so changing it changes the bars too.
    case followsBody
    /// One installed reading font, named by `ReaderBarFontReference.postScriptName`.
    case custom
}

/// The bars' typeface, shaped like `ReaderOverlayColorReference`: a source, plus the
/// font's PostScript name when the source is `.custom`.
struct ReaderBarFontReference: Codable, Equatable, Hashable, Sendable {
    static let system = ReaderBarFontReference(source: .system)
    static let followsBody = ReaderBarFontReference(source: .followsBody)

    var source: ReaderBarFontSource
    var postScriptName: String?

    init(source: ReaderBarFontSource, postScriptName: String? = nil) {
        self.source = source
        self.postScriptName = postScriptName
    }

    static func custom(_ postScriptName: String) -> ReaderBarFontReference {
        ReaderBarFontReference(source: .custom, postScriptName: postScriptName)
    }

    /// A name only means something for `.custom`, and `.custom` without one has
    /// nothing to draw with, so it is the system font.
    var normalized: ReaderBarFontReference {
        switch source {
        case .system, .followsBody:
            return ReaderBarFontReference(source: source)
        case .custom:
            guard let postScriptName, !postScriptName.isEmpty else { return .system }
            return .custom(postScriptName)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case postScriptName
    }

    /// An unknown source reads as the system font rather than failing: the reference
    /// rides inside layout presets and 主題包, and a pack written by a later version
    /// with a source this one lacks should still import with everything else intact.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSource = try container.decodeIfPresent(String.self, forKey: .source)
        source = rawSource.flatMap(ReaderBarFontSource.init(rawValue:)) ?? .system
        postScriptName = try container.decodeIfPresent(String.self, forKey: .postScriptName)
    }
}

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
    var font: ReaderBarFontReference

    init(
        fontSize: Double = ReaderBarStyle.defaultFontSize,
        weight: ReaderOverlayFontWeight = .regular,
        color: ReaderOverlayColorReference = ReaderOverlayColorReference(source: .readerText),
        opacity: Double = ReaderBarStyle.defaultOpacity,
        font: ReaderBarFontReference = .system
    ) {
        self.fontSize = fontSize
        self.weight = weight
        self.color = color
        self.opacity = opacity
        self.font = font
    }

    var normalized: ReaderBarStyle {
        ReaderBarStyle(
            fontSize: Self.clamp(fontSize, to: Self.fontSizeRange, fallback: Self.defaultFontSize),
            weight: weight,
            color: color.normalized,
            opacity: Self.clamp(opacity, to: Self.opacityRange, fallback: Self.defaultOpacity),
            font: font.normalized
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
        case font
    }

    /// Layouts saved, synced or exported before FB-126 carry no `font`: they keep the
    /// system font they were drawn in.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? Self.defaultFontSize
        weight = try container.decodeIfPresent(ReaderOverlayFontWeight.self, forKey: .weight) ?? .regular
        color = try container.decodeIfPresent(ReaderOverlayColorReference.self, forKey: .color)
            ?? ReaderOverlayColorReference(source: .readerText)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? Self.defaultOpacity
        font = try container.decodeIfPresent(ReaderBarFontReference.self, forKey: .font) ?? .system
    }

    /// The system font is left out, so a layout nobody changed encodes exactly as it did
    /// before FB-126 — the iCloud record and its shadow copy see no difference, and a
    /// preset exported here still reads the same in a version without the option.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(weight, forKey: .weight)
        try container.encode(color, forKey: .color)
        try container.encode(opacity, forKey: .opacity)
        if font != .system {
            try container.encode(font, forKey: .font)
        }
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

/// Independent insets around each bar. Nil side insets retain legacy settings.
struct ReaderBarMargins: Codable, Equatable, Sendable {
    var left: Double?
    var right: Double?
    /// Header below / footer above, between the bar and body margin.
    var inner: Double = 0

    var normalized: Self {
        func clamp(_ value: Double) -> Double { value.isFinite ? min(200, max(0, value)) : 0 }
        return Self(left: left.map(clamp), right: right.map(clamp), inner: clamp(inner))
    }
}

/// Which fields exist, which slot each one sits in, and how the two bars are drawn.
///
/// Visibility and legacy padding remain in GlobalSettings. Explicit edge
/// distances take precedence and travel with the layout through save and export.
struct ReaderBarLayout: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    /// One entry per kind and slot. Array order is render order within a slot.
    var fields: [ReaderBarField]
    var showsHeaderDivider: Bool
    var showsFooterDivider: Bool
    /// Legacy opening-page behavior, used until an explicit opening selection exists.
    var hidesHeaderOnChapterOpening: Bool
    var style: ReaderBarStyle
    var edgeDistances: ReaderBarEdgeDistances
    var headerMargins: ReaderBarMargins
    var footerMargins: ReaderBarMargins
    var showsComponentSeparators: Bool
    /// Nil follows the legacy opening-page visibility; an empty array hides both bars.
    var chapterOpeningFields: [ReaderBarField]?

    func resolved(isChapterOpening: Bool) -> Self {
        guard isChapterOpening else { return self }
        var result = self
        result.fields = chapterOpeningFields ?? fields.filter {
            !hidesHeaderOnChapterOpening || $0.slot.bar != .header
        }
        return result
    }

    /// Pages reserve what either page type shows, so a chapter boundary never moves
    /// the text. Scroll mode has no opening page and only ever draws the body fields
    /// (FB-115), so a bar that only the opening page fills would be a blank band.
    func reservesSpace(in bar: ReaderBar, isScrolling: Bool) -> Bool {
        hasContent(in: bar) || (!isScrolling && resolved(isChapterOpening: true).hasContent(in: bar))
    }

    mutating func setSelected(_ selected: Bool, kind: ReaderOverlayComponentKind, in slot: ReaderBarSlot) {
        if selected {
            guard !fields.contains(where: { $0.kind == kind && $0.slot == slot }) else { return }
            var field = fields.first { $0.kind == kind && $0.slot == .hidden }
                ?? ReaderBarField(kind: kind, slot: slot, usesCustomOptions: false)
            field.slot = slot
            fields.removeAll { $0.kind == kind && $0.slot == .hidden }
            fields.append(field)
        } else {
            fields.removeAll { $0.kind == kind && $0.slot == slot }
        }
    }

    init(
        version: Int = ReaderBarLayout.currentVersion,
        fields: [ReaderBarField],
        showsHeaderDivider: Bool = false,
        showsFooterDivider: Bool = false,
        hidesHeaderOnChapterOpening: Bool = true,
        style: ReaderBarStyle = ReaderBarStyle(),
        edgeDistances: ReaderBarEdgeDistances = ReaderBarEdgeDistances(),
        headerMargins: ReaderBarMargins = ReaderBarMargins(),
        footerMargins: ReaderBarMargins = ReaderBarMargins(),
        showsComponentSeparators: Bool = true,
        chapterOpeningFields: [ReaderBarField]? = nil
    ) {
        self.version = version
        self.fields = fields
        self.showsHeaderDivider = showsHeaderDivider
        self.showsFooterDivider = showsFooterDivider
        self.hidesHeaderOnChapterOpening = hidesHeaderOnChapterOpening
        self.style = style
        self.edgeDistances = edgeDistances
        self.headerMargins = headerMargins
        self.footerMargins = footerMargins
        self.showsComponentSeparators = showsComponentSeparators
        self.chapterOpeningFields = chapterOpeningFields
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

    /// Collapse duplicates within each slot while retaining independent instances.
    func normalized(preservingVersion: Bool = true) -> ReaderBarLayout {
        let ordered = Self.normalizedFields(fields)
        return ReaderBarLayout(
            version: preservingVersion ? version : Self.currentVersion,
            fields: ordered,
            showsHeaderDivider: showsHeaderDivider,
            showsFooterDivider: showsFooterDivider,
            hidesHeaderOnChapterOpening: hidesHeaderOnChapterOpening,
            style: style.normalized,
            edgeDistances: edgeDistances.normalized,
            headerMargins: headerMargins.normalized,
            footerMargins: footerMargins.normalized,
            showsComponentSeparators: showsComponentSeparators,
            chapterOpeningFields: chapterOpeningFields.map(Self.normalizedFields)
        )
    }

    private static func normalizedFields(_ fields: [ReaderBarField]) -> [ReaderBarField] {
        var seen = Set<String>()
        let visibleKinds = Set(fields.filter { $0.slot != .hidden }.map(\.kind))
        var result = fields.filter {
            ($0.slot != .hidden || !visibleKinds.contains($0.kind)) && seen.insert($0.id).inserted
        }.map(\.normalized)
        let kinds = Set(result.map(\.kind))
        for kind in ReaderOverlayComponentKind.allCases where !kinds.contains(kind) {
            result.append(ReaderBarField(kind: kind, slot: .hidden))
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case fields
        case showsHeaderDivider
        case showsFooterDivider
        case hidesHeaderOnChapterOpening
        case style
        case edgeDistances
        case headerMargins, footerMargins, showsComponentSeparators, chapterOpeningFields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        headerMargins = try container.decodeIfPresent(ReaderBarMargins.self, forKey: .headerMargins) ?? .init()
        footerMargins = try container.decodeIfPresent(ReaderBarMargins.self, forKey: .footerMargins) ?? .init()
        showsComponentSeparators = try container.decodeIfPresent(Bool.self, forKey: .showsComponentSeparators) ?? true
        chapterOpeningFields = try container.decodeIfPresent([ReaderBarField].self, forKey: .chapterOpeningFields)
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
