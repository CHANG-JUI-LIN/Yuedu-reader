import Foundation

// MARK: - A source's explore controls

/// One of a source's explore entries that is a control rather than a category — legado-E
/// and MD3's `button`, `text` and `toggle` explore kinds. 發現頁設定 lists them under
/// 快捷操作. Each reads and writes the source's explore `infoMap` under its title, and a
/// tap or an edit runs the kind's `action` script.
struct DiscoverQuickAction: Identifiable {
    enum Kind: String {
        case button, text, toggle
    }

    let kind: Kind
    let title: String
    /// What a tap or an edit runs. A button without an `action` runs its `url` as script,
    /// as the original Legado's explore buttons do.
    let script: String?
    /// A toggle's values, cycled in order.
    let options: [String]
    let defaultValue: String?
    let viewName: String?
    /// A toggle draws its value after the title rather than before it
    /// (`layout_justifySelf: right` in legado-E).
    let valueTrails: Bool

    var id: String { kind.rawValue + "\u{1F}" + title }

    init?(_ raw: ModernParserBridge.DiscoverItem) {
        guard let kind = raw.type.flatMap(Kind.init(rawValue:)) else { return nil }
        let title = (raw.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        self.kind = kind
        self.title = title
        let action = raw.action?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = raw.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !action.isEmpty {
            script = action
        } else if kind == .button, !url.isEmpty {
            script = ModernParserBridge.isJSExploreRule(url) ? ModernParserBridge.jsCode(fromExploreRule: url) : url
        } else {
            script = nil
        }
        let chars = (raw.chars ?? []).filter { !$0.isEmpty }
        // legado-E shows a toggle without values as these two words rather than hiding it.
        options = chars.isEmpty ? ["chars", "is null"] : chars
        defaultValue = raw.default
        viewName = raw.viewName
        valueTrails = raw.style?["layout_justifySelf"] == "right"
    }

    /// A display name written out in the source: `'名稱'`, 3 to 19 characters with the
    /// quotes, as Legado reads one. Any other `viewName` is a script.
    var literalDisplayName: String? {
        guard let viewName, (3...19).contains(viewName.count),
              viewName.first == "'", viewName.last == "'" else { return nil }
        return String(viewName.dropFirst().dropLast())
    }

    /// A `viewName` to evaluate for the display name.
    var displayNameScript: String? {
        guard let viewName, !viewName.isEmpty, literalDisplayName == nil else { return nil }
        return viewName
    }

    /// A toggle's value: the stored one, else its default, else its first value.
    func toggleValue(in values: [String: String]) -> String {
        if let stored = values[title], !stored.isEmpty { return stored }
        return defaultValue ?? options[0]
    }

    /// The value after `current`, wrapping round.
    func toggleValue(after current: String) -> String {
        let index = options.firstIndex(of: current).map { ($0 + 1) % options.count } ?? 0
        return options[index]
    }

    /// The source's controls, each once, in the order the source lists them.
    static func actions(from raw: [ModernParserBridge.DiscoverItem]) -> [DiscoverQuickAction] {
        var seen = Set<String>()
        return raw.compactMap(DiscoverQuickAction.init).filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Running a control's script

/// What one explore control's script asked of the page.
struct DiscoverQuickActionOutcome {
    /// `java.refreshExplore()` ran: reload the source's categories.
    var refreshesExplore = false
    var errorMessage: String?
}

enum DiscoverQuickActionRunner {
    /// Runs an explore control's script on the source's host, as legado-E's
    /// `evalButtonClick` does: the context's `java`, `source`, `cache` and `infoMap`,
    /// toasts shown, `java.startBrowser` opening the browser, `java.refreshExplore()`
    /// reported back.
    static func run(
        _ script: String,
        title: String,
        source: BookSource,
        presentToast: @escaping @MainActor @Sendable (String) -> Void
    ) async -> DiscoverQuickActionOutcome {
        let outcome = await BookSourceSession.session(for: source).host.run {
            bridge -> DiscoverQuickActionOutcome in
            let sink = RefreshSink()
            let previousBrowser = bridge.browserPresentHandler
            let previousToast = bridge.toastHandler
            let previousRefresh = bridge.refreshExploreHandler
            bridge.browserPresentHandler = LegadoJSBridge.sharedBrowserPresenter
            // The bridge delivers toasts on the main queue.
            bridge.toastHandler = { message in
                MainActor.assumeIsolated { presentToast(message) }
            }
            bridge.refreshExploreHandler = { sink.mark() }
            defer {
                bridge.browserPresentHandler = previousBrowser
                bridge.toastHandler = previousToast
                bridge.refreshExploreHandler = previousRefresh
            }
            _ = bridge.evaluateExploreKindScript(script)
            return DiscoverQuickActionOutcome(
                refreshesExplore: sink.isMarked,
                errorMessage: bridge.lastSourceScriptError
            )
        }
        AppLogger.parse("⟐ exploreAction", context: [
            "source": source.bookSourceName,
            "title": title,
            "refresh": outcome.refreshesExplore ? "yes" : "no",
            "error": outcome.errorMessage ?? "none"
        ])
        return outcome
    }

    /// Evaluates a `viewName` script for a control's display name. Legado shows `null`
    /// for an empty result and `err` for a script that throws; so does this.
    static func displayName(_ script: String, source: BookSource) async -> String {
        await BookSourceSession.session(for: source).host.run { bridge -> String in
            let value = bridge.evaluateExploreKindScript(script)
            if let error = bridge.lastSourceScriptError {
                AppLogger.parse("⟐ exploreViewName failed", context: [
                    "source": source.bookSourceName, "error": error
                ])
                return "err"
            }
            guard let value, !value.isEmpty else { return "null" }
            return value
        }
    }

    /// The source's explore `infoMap` as its scripts hold it now.
    static func infoMapValues(source: BookSource) async -> [String: String] {
        await BookSourceSession.session(for: source).host.run { $0.exploreInfoMapValues() }
    }

    /// Stores one `infoMap` entry, as an input or a toggle does.
    static func setInfoMapValue(_ value: String, forKey key: String, source: BookSource) async {
        await BookSourceSession.session(for: source).host.run {
            $0.setExploreInfoMapValue(value, forKey: key)
        }
    }
}

/// Records `java.refreshExplore()`. The bridge calls in from the JS engine's queue.
private final class RefreshSink: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    func mark() {
        lock.lock()
        marked = true
        lock.unlock()
    }

    var isMarked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return marked
    }
}
