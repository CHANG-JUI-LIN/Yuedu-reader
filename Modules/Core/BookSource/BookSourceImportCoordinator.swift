import Combine
import Foundation

// MARK: - BookSourceImportCoordinator

/// Owns the book-source import confirmation list: parse a payload into a plan, hold the
/// import options while the user reviews it, then write the ticked rows.
///
/// Every manual import route (本地導入 / 網路導入 / 粘貼源 / WebView / Share Extension /
/// deep link) hands its payload here and presents the same sheet, so "what does importing
/// do" is answered in one place instead of once per entry point.
@MainActor
final class BookSourceImportCoordinator: ObservableObject {

    /// The sheet's identity. A fresh id per payload so presenting a second import while one
    /// is on screen swaps the contents rather than being dropped as "already presented".
    struct Pending: Identifiable {
        let id = UUID()
        let plan: SourceImportPlan<BookSource>
    }

    @Published var pending: Pending?

    /// Reviewed-import options. The three keep-switches persist, as they do upstream in
    /// `AppConfig`; the destination group does not — it belongs to one import, not to the app.
    @Published var options: BookSourceImportOptions {
        didSet { persistSwitches() }
    }

    /// 顯示源註釋, remembered like upstream's `importShowComment`.
    @Published var showsComments: Bool {
        didSet { defaults.set(showsComments, forKey: Self.showCommentKey) }
    }

    private let store: BookSourceStore
    private let defaults: UserDefaults
    /// The library's clocks as of the moment the pending list was built. Held rather than
    /// re-derived because a per-row edit asks for one key at a time, and rebuilding the map
    /// per lookup would walk the whole library on every keystroke-committed edit.
    private var clocksForPending: [String: Int64] = [:]

    // Kept in `UserDefaults` directly rather than in `GlobalSettings`: these are import-time
    // options read only while this sheet is open, not app-wide appearance or reading state.
    private static let keepNameKey = "yd_import_keep_name"
    private static let keepGroupKey = "yd_import_keep_group"
    private static let keepEnableKey = "yd_import_keep_enable"
    private static let showCommentKey = "yd_import_show_comment"

    init(store: BookSourceStore = .shared, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        var restored = BookSourceImportOptions.manualDefaults
        restored.keepName = defaults.bool(forKey: Self.keepNameKey)
        restored.keepGroup = defaults.bool(forKey: Self.keepGroupKey)
        restored.keepEnable = defaults.bool(forKey: Self.keepEnableKey)
        self.options = restored
        self.showsComments = defaults.bool(forKey: Self.showCommentKey)
    }

    private func persistSwitches() {
        defaults.set(options.keepName, forKey: Self.keepNameKey)
        defaults.set(options.keepGroup, forKey: Self.keepGroupKey)
        defaults.set(options.keepEnable, forKey: Self.keepEnableKey)
    }

    // MARK: Presenting

    /// Parses `data` and presents the confirmation list. Throws the same parse errors the
    /// direct importers throw, so each entry point keeps reporting failures its own way.
    func present(data: Data, fileExtension ext: String) throws {
        present(sources: try store.parseForImport(data: data, fileExtension: ext))
    }

    func present(json: String) throws {
        present(sources: try store.parseForImport(json: json))
    }

    func present(sources: [BookSource]) {
        // A fresh group choice per import; the keep-switches carry over.
        options.groupName = nil
        options.addsToExistingGroups = false
        clocksForPending = store.existingUpdateClocks()
        pending = Pending(
            plan: SourceImportPlan(incoming: sources) { [clocksForPending] in clocksForPending[$0] }
        )
    }

    // MARK: Committing

    /// Writes the ticked rows and dismisses. Returns how many sources were written, or `0`
    /// when nothing was pending or nothing was ticked.
    @discardableResult
    func confirmImport() throws -> Int {
        guard let pending else { return 0 }
        let selected = pending.plan.selectedSources
        guard !selected.isEmpty else {
            self.pending = nil
            return 0
        }
        let count = try store.importSelected(selected, options: options)
        self.pending = nil
        return count
    }

    func cancel() {
        pending = nil
    }

    /// The library's clock for one identity key — handed to the list so a per-row JSON edit
    /// can recompute that row's 新增/更新/已有 badge.
    func existingClock(for identityKey: String) -> Int64? {
        clocksForPending[identityKey]
    }
}
