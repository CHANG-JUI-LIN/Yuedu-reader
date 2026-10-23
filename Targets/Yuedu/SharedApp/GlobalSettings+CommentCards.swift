import Foundation

/// The card templates of 氣泡設定 — 本章說, 作者說, 神評論: the library, each kind's choice,
/// and how both are stored and synced.
extension GlobalSettings {

    // MARK: - Choice

    func setCommentCardPrefersSelectedStyle(_ prefers: Bool, for kind: ReaderCommentCardKind) {
        commentCardChoices[kind].prefersSelectedStyle = prefers
    }

    /// Wears `id` for `kind`; nil wears the built-in 玻璃. Picking a style is asking for it,
    /// so it also turns 優先使用選取的樣式 on.
    func selectCommentCardStyle(id: UUID?, for kind: ReaderCommentCardKind) {
        let validID = id.flatMap { id in
            commentCardCustomStyles.contains { $0.id == id && $0.kind == kind } ? id : nil
        }
        commentCardChoices[kind] = ReaderCommentCardChoice(
            prefersSelectedStyle: true,
            selectedStyleID: validID
        )
    }

    /// The template `kind` wears now, or nil when the source's own card is drawn.
    func wornCommentCardTemplate(for kind: ReaderCommentCardKind) -> ReaderCommentCardStyleLibrary.WornTemplate? {
        ReaderCommentCardStyleLibrary.wornTemplate(
            for: kind,
            choice: commentCardChoices[kind],
            styles: commentCardCustomStyles
        )
    }

    func commentCardStyles(of kind: ReaderCommentCardKind) -> [ReaderCommentCardCustomStyle] {
        commentCardCustomStyles.filter { $0.kind == kind }
    }

    // MARK: - Library

    /// Saves a new or edited template and wears it for its kind.
    func upsertCommentCardStyle(_ style: ReaderCommentCardCustomStyle) {
        commentCardCustomStyles = ReaderCommentCardStyleLibrary.uniqued(
            ReaderCommentCardStyleLibrary.upserting(style, into: commentCardCustomStyles)
        )
        selectCommentCardStyle(id: style.id, for: style.kind)
    }

    /// Removes a template. A kind that wore it goes back to the built-in 玻璃, keeping its
    /// 優先使用選取的樣式 as it was.
    func deleteCommentCardStyle(id: UUID) {
        commentCardCustomStyles = ReaderCommentCardStyleLibrary.deleting(id: id, from: commentCardCustomStyles)
        for kind in ReaderCommentCardKind.allCases where commentCardChoices[kind].selectedStyleID == id {
            commentCardChoices[kind].selectedStyleID = nil
        }
    }

    /// Applies the iCloud-merged template list (per-template last-write-wins). Does not
    /// re-stamp `updatedAt`: the merged values carry the winning device's clock. A choice
    /// naming a template the merge removed reads as the built-in one
    /// (`ReaderCommentCardStyleLibrary.wornTemplate`), so the choices are left alone — they
    /// sync on their own, with the reading setup.
    @MainActor
    func applyCommentCardStylesSync(_ styles: [ReaderCommentCardCustomStyle]) {
        var updates = SettingsUpdateBatch(self, reason: "commentCardStyles")
        defer { updates.finish() }
        updates.set(
            \.commentCardCustomStyles,
            ReaderCommentCardStyleLibrary.uniqued(styles),
            field: "commentCardCustomStyles"
        )
    }

    // MARK: - Storage

    static func loadCommentCardChoices(defaults: UserDefaults = .standard) -> ReaderCommentCardChoices {
        guard let data = defaults.data(forKey: commentCardChoicesKey) else { return ReaderCommentCardChoices() }
        do {
            return try JSONDecoder().decode(ReaderCommentCardChoices.self, from: data)
        } catch {
            AppLogger.error("comment card choices unreadable", error: error)
            return ReaderCommentCardChoices()
        }
    }

    static func saveCommentCardChoices(_ choices: ReaderCommentCardChoices, defaults: UserDefaults = .standard) {
        do {
            defaults.set(try JSONEncoder().encode(choices), forKey: commentCardChoicesKey)
        } catch {
            AppLogger.error("comment card choices not stored", error: error)
        }
    }

    static func loadCommentCardCustomStyles(defaults: UserDefaults = .standard) -> [ReaderCommentCardCustomStyle] {
        guard let data = defaults.data(forKey: commentCardCustomStylesKey) else { return [] }
        do {
            return try ReaderCommentCardStyleLibrary.decode(data)
        } catch {
            AppLogger.error("comment card templates unreadable", error: error)
            return []
        }
    }

    static func saveCommentCardCustomStyles(
        _ styles: [ReaderCommentCardCustomStyle],
        defaults: UserDefaults = .standard
    ) {
        guard !styles.isEmpty else {
            defaults.removeObject(forKey: commentCardCustomStylesKey)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(styles), forKey: commentCardCustomStylesKey)
        } catch {
            AppLogger.error("comment card templates not stored", error: error)
        }
    }
}
