# Search Source Scope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Add a persistent search scope that lets users search every enabled book source or a custom multi-selected subset.

**Architecture:** A small SearchSourceScope value and SearchSourceScopeStore own URL-based resolution and UserDefaults persistence. BookSearchView renders one native capsule entry point and delegates editing to a native SwiftUI sheet, then passes only the resolved [BookSource] into the existing SearchAggregator; the aggregator gains one explicit cancel-and-clear command for scope changes.

**Tech Stack:** Swift 6, SwiftUI, Combine, Foundation UserDefaults, Swift Testing, Xcode 16+ / iOS 17+

---

## File Structure

- Create Modules/Services/Online/SearchSourceScope.swift: scope value, URL-based source resolution, and persisted observable store.
- Create Modules/Features/Search/SearchSourceScopeSheet.swift: native scope capsule and editable multi-select sheet.
- Modify Modules/Features/Search/BookSearchView.swift: replace the single-source chips, present the sheet, resolve sources, and reset stale results after scope changes.
- Modify Modules/Services/Online/SearchAggregator.swift: add the single service-level cancel-and-clear operation.
- Create Tests/iOS/yuedu appTests/SearchSourceScopeTests.swift: persistence, filtering, stable identity, and aggregator-reset regressions.
- Modify Resources/{zh-Hant,zh-Hans,en}.lproj/Localizable.strings: synchronized user-visible copy.

### Task 1: Persisted Search Scope Model

**Files:**

- Create: Modules/Services/Online/SearchSourceScope.swift
- Create: Tests/iOS/yuedu appTests/SearchSourceScopeTests.swift

- [ ] **Step 1: Write the failing model and persistence tests**

Create Tests/iOS/yuedu appTests/SearchSourceScopeTests.swift:

~~~swift
import Foundation
import Testing
@testable import yuedu_app

@Suite("Search source scope", .serialized)
struct SearchSourceScopeTests {
    @Test("default scope resolves every enabled source")
    func defaultScopeResolvesEnabledSources() {
        let enabled = makeSource(name: "Enabled", url: "https://enabled.test")
        let disabled = makeSource(
            name: "Disabled",
            url: "https://disabled.test",
            enabled: false
        )

        #expect(
            SearchSourceScope.all
                .resolvedSources(from: [enabled, disabled])
                .map(\.id) == [enabled.id]
        )
    }

    @Test("custom scope resolves only selected enabled source URLs")
    func customScopeFiltersSources() {
        let first = makeSource(name: "First", url: "https://first.test")
        let second = makeSource(name: "Second", url: "https://second.test")
        let disabled = makeSource(
            name: "Disabled",
            url: "https://disabled.test",
            enabled: false
        )
        let scope = SearchSourceScope(
            mode: .custom,
            selectedSourceURLs: [second.bookSourceUrl, disabled.bookSourceUrl]
        )

        #expect(
            scope.resolvedSources(from: [first, second, disabled]).map(\.id)
                == [second.id]
        )
    }

    @Test("source URL keeps custom selection stable across a new UUID")
    func sourceURLSurvivesIdentityChange() {
        let original = makeSource(name: "Original", url: "https://stable.test")
        var reimported = original
        reimported.id = UUID()
        let scope = SearchSourceScope(
            mode: .custom,
            selectedSourceURLs: [original.bookSourceUrl]
        )

        #expect(scope.resolvedSources(from: [reimported]).map(\.id) == [reimported.id])
        #expect(reimported.id != original.id)
    }

    @Test("unavailable custom selection does not fall back to all sources")
    func unavailableSelectionDoesNotFallback() {
        let available = makeSource(name: "Available", url: "https://available.test")
        let scope = SearchSourceScope(
            mode: .custom,
            selectedSourceURLs: ["https://deleted.test"]
        )

        #expect(scope.resolvedSources(from: [available]).isEmpty)
    }

    @MainActor
    @Test("custom scope round-trips through UserDefaults")
    func customScopePersists() throws {
        let suiteName = "SearchSourceScopeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let saved = SearchSourceScope(
            mode: .custom,
            selectedSourceURLs: ["https://one.test", "https://two.test"]
        )

        let store = SearchSourceScopeStore(defaults: defaults)
        #expect(store.scope == .all)
        store.save(saved)
        let reloaded = SearchSourceScopeStore(defaults: defaults)

        #expect(reloaded.scope == saved)
    }

    private func makeSource(
        name: String,
        url: String,
        enabled: Bool = true
    ) -> BookSource {
        var source = BookSource()
        source.bookSourceName = name
        source.bookSourceUrl = url
        source.enabled = enabled
        return source
    }
}
~~~

- [ ] **Step 2: Run the focused test to confirm the missing types fail compilation**

~~~bash
xcodebuild test -quiet \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/SearchSourceScopeTests'
~~~

Expected: FAIL with Cannot find 'SearchSourceScope' in scope and Cannot find 'SearchSourceScopeStore' in scope.

- [ ] **Step 3: Implement the scope and preference store**

Create Modules/Services/Online/SearchSourceScope.swift:

~~~swift
import Combine
import Foundation

struct SearchSourceScope: Equatable {
    enum Mode: String, Equatable {
        case all
        case custom
    }

    static let all = SearchSourceScope(mode: .all)

    var mode: Mode
    var selectedSourceURLs: Set<String>

    init(mode: Mode, selectedSourceURLs: Set<String> = []) {
        self.mode = mode
        self.selectedSourceURLs = selectedSourceURLs
    }

    func resolvedSources(from sources: [BookSource]) -> [BookSource] {
        let enabledSources = sources.filter(\.enabled)
        guard mode == .custom else { return enabledSources }

        return enabledSources.filter { source in
            let key = Self.sourceKey(for: source)
            return !key.isEmpty && selectedSourceURLs.contains(key)
        }
    }

    static func sourceKey(for source: BookSource) -> String {
        source.bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class SearchSourceScopeStore: ObservableObject {
    static let shared = SearchSourceScopeStore()

    @Published private(set) var scope: SearchSourceScope

    private enum Keys {
        static let mode = "yd_search_source_scope_mode"
        static let selectedURLs = "yd_search_source_scope_selected_urls"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let mode = defaults.string(forKey: Keys.mode)
            .flatMap(SearchSourceScope.Mode.init(rawValue:)) ?? .all
        let selectedURLs = Set(defaults.stringArray(forKey: Keys.selectedURLs) ?? [])
        scope = SearchSourceScope(mode: mode, selectedSourceURLs: selectedURLs)
    }

    func save(_ newScope: SearchSourceScope) {
        scope = newScope
        defaults.set(newScope.mode.rawValue, forKey: Keys.mode)
        defaults.set(newScope.selectedSourceURLs.sorted(), forKey: Keys.selectedURLs)
    }
}
~~~

- [ ] **Step 4: Run the focused tests and confirm all four pass**

Run the Step 2 command again.

Expected: TEST SUCCEEDED with 5 passing tests and 0 failures.

- [ ] **Step 5: Commit the scope model**

~~~bash
git add Modules/Services/Online/SearchSourceScope.swift \
  'Tests/iOS/yuedu appTests/SearchSourceScopeTests.swift'
git commit -m "feat(search): persist source scope"
~~~

### Task 2: Cancel and Clear Stale Aggregate Results

**Files:**

- Modify: Tests/iOS/yuedu appTests/SearchSourceScopeTests.swift
- Modify: Modules/Services/Online/SearchAggregator.swift:737

- [ ] **Step 1: Add the failing aggregator reset test**

Add this test inside SearchSourceScopeTests before makeSource:

~~~swift
    @MainActor
    @Test("cancel and clear resets aggregate search state")
    func cancelAndClearResetsSearchState() {
        var source = makeSource(name: "Pending", url: "https://pending.invalid")
        source.searchUrl = "https://pending.invalid/search?q={{key}}"
        source.ruleSearch.bookList = ".book"
        source.ruleSearch.name = ".name"
        source.ruleSearch.bookUrl = "a@href"
        let aggregator = SearchAggregator()

        aggregator.search(query: "scope", sources: [source])
        #expect(aggregator.isSearching)
        #expect(aggregator.progress.total == 1)
        aggregator.pause()
        #expect(aggregator.isPaused)

        aggregator.cancelAndClear()

        #expect(!aggregator.isSearching)
        #expect(!aggregator.isPaused)
        #expect(aggregator.results.isEmpty)
        #expect(!aggregator.hasMoreResults)
        #expect(aggregator.progress.total == 0)
        #expect(aggregator.progress.completed == 0)
        #expect(aggregator.progress.failed == 0)
        #expect(aggregator.progress.timedOut == 0)
        #expect(aggregator.progress.skipped == 0)
    }
~~~

- [ ] **Step 2: Run only the reset test and confirm the missing API failure**

~~~bash
xcodebuild test -quiet \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/SearchSourceScopeTests/cancelAndClearResetsSearchState'
~~~

Expected: FAIL with Value of type 'SearchAggregator' has no member 'cancelAndClear'.

- [ ] **Step 3: Add the explicit service-level clear command**

Add this method immediately after cancel() in SearchAggregator:

~~~swift
    /// Stops the current search and removes every query-scoped value.
    ///
    /// Scope changes use this command so results, progress, resume bookkeeping,
    /// and cross-source paging can never belong to a different source range than
    /// the range currently shown by the search screen.
    func cancelAndClear() {
        searchTask?.cancel()
        searchTask = nil
        resultsPublicationTask?.cancel()
        resultsPublicationTask = nil

        internalResults = []
        resultsNeedSort = false
        internalProgress = SearchProgress()
        internalHasMoreResults = false
        deduplicationMap = [:]
        allSources = []
        completedSourceIds = []
        currentQuery = ""
        autoPausePolicy = SearchAutoPausePolicy(count: 0)
        coverDecodeSourcesById = [:]
        searchPage = 1
        successfulSourceIds = []
        exhaustedSourceIds = []
        publicationMetrics = ResultPublicationMetrics()
        isSearching = false
        isPaused = false

        requestResultsPublication(force: true, reason: "clear")
        SourceHealthStore.shared.flush()
    }
~~~

- [ ] **Step 4: Run the complete scope suite**

Run the Task 1 Step 2 command.

Expected: TEST SUCCEEDED with 6 passing tests and 0 failures.

- [ ] **Step 5: Commit the reset behavior**

~~~bash
git add Modules/Services/Online/SearchAggregator.swift \
  'Tests/iOS/yuedu appTests/SearchSourceScopeTests.swift'
git commit -m "feat(search): clear results when scope changes"
~~~

### Task 3: Native Multi-Source Scope Sheet

**Files:**

- Create: Modules/Features/Search/SearchSourceScopeSheet.swift
- Modify: Resources/zh-Hant.lproj/Localizable.strings
- Modify: Resources/zh-Hans.lproj/Localizable.strings
- Modify: Resources/en.lproj/Localizable.strings

- [ ] **Step 1: Add synchronized localized copy**

Add the following localized values. Also change the existing English value for 全部書源 from all-book-sources to All Sources.

| Key | zh-Hant | zh-Hans | English |
| --- | --- | --- | --- |
| 搜索範圍 | 搜索範圍 | 搜索范围 | Search Scope |
| 自選書源 | 自選書源 | 自选书源 | Selected Sources |
| 已選 %d 個書源 | 已選 %d 個書源 | 已选 %d 个书源 | %d Sources Selected |
| 快速選擇 | 快速選擇 | 快速选择 | Quick Selection |
| 請至少選擇一個可用書源 | 請至少選擇一個可用書源 | 请至少选择一个可用书源 | Select at least one available source. |
| 已選取 | 已選取 | 已选中 | Selected |
| 未選取 | 未選取 | 未选中 | Not Selected |
| 搜索範圍已更新，請再次搜索 | 搜索範圍已更新，請再次搜索 | 搜索范围已更新，请再次搜索 | Search scope updated. Search again. |

- [ ] **Step 2: Create the native capsule and editor sheet**

Create Modules/Features/Search/SearchSourceScopeSheet.swift:

~~~swift
import SwiftUI

struct SearchSourceScopeCapsule: View {
    let title: String
    let isCustom: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                title,
                systemImage: isCustom
                    ? "checkmark.circle.fill"
                    : "line.3.horizontal.decrease.circle.fill"
            )
            .font(DSFont.subheadline)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(DSColor.accent)
        .accessibilityLabel(localized("搜索範圍"))
        .accessibilityValue(title)
    }
}

struct SearchSourceScopeSheet: View {
    let enabledSources: [BookSource]
    let onSave: (SearchSourceScope) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: SearchSourceScope.Mode
    @State private var selectedSourceURLs: Set<String>
    @State private var sourceQuery = ""

    init(
        enabledSources: [BookSource],
        initialScope: SearchSourceScope,
        onSave: @escaping (SearchSourceScope) -> Void
    ) {
        self.enabledSources = enabledSources
        self.onSave = onSave
        _mode = State(initialValue: initialScope.mode)
        _selectedSourceURLs = State(initialValue: initialScope.selectedSourceURLs)
    }

    var body: some View {
        NavigationStack {
            List {
                Section(localized("搜索範圍")) {
                    Picker(localized("搜索範圍"), selection: $mode) {
                        Text(localized("全部書源")).tag(SearchSourceScope.Mode.all)
                        Text(localized("自選書源")).tag(SearchSourceScope.Mode.custom)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(DSColor.surface)
                }

                if mode == .custom {
                    quickSelectionSection
                    sourceSection
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(PageBackgroundView(scope: .search).ignoresSafeArea())
            .pageBackgroundToolbar(for: .search)
            .navigationTitle(localized("搜索範圍"))
            .toolbarTitleDisplayMode(.inline)
            .searchable(text: $sourceQuery, prompt: localized("搜索書源"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(localized("取消"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveAndDismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .accessibilityHidden(true)
                    }
                    .disabled(!canSave)
                    .accessibilityLabel(localized("完成"))
                }
            }
        }
    }

    private var quickSelectionSection: some View {
        Section(localized("快速選擇")) {
            Button(localized("全選")) {
                selectedSourceURLs = Set(enabledSources.compactMap { source in
                    let key = SearchSourceScope.sourceKey(for: source)
                    return key.isEmpty ? nil : key
                })
            }
            .listRowBackground(DSColor.surface)

            Button(localized("清除")) {
                selectedSourceURLs.removeAll()
            }
            .listRowBackground(DSColor.surface)
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        Section {
            if enabledSources.isEmpty {
                ContentUnavailableView(
                    localized("尚未設置書源"),
                    systemImage: "exclamationmark.triangle"
                )
                .listRowBackground(Color.clear)
            } else if filteredSources.isEmpty {
                ContentUnavailableView.search(text: sourceQuery)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(filteredSources) { source in
                    sourceRow(source)
                }
            }
        } footer: {
            if !canSave {
                Text(localized("請至少選擇一個可用書源"))
                    .foregroundStyle(DSColor.destructive)
            }
        }
    }

    private func sourceRow(_ source: BookSource) -> some View {
        let key = SearchSourceScope.sourceKey(for: source)
        let isSelected = selectedSourceURLs.contains(key)

        return Button {
            if isSelected {
                selectedSourceURLs.remove(key)
            } else if !key.isEmpty {
                selectedSourceURLs.insert(key)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.md) {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text(source.bookSourceName)
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textPrimary)
                    Text(source.bookSourceUrl)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: DSSpacing.sm)
                if isSelected {
                    Label(localized("已選取"), systemImage: "checkmark")
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(DSColor.surface)
        .accessibilityLabel(source.bookSourceName)
        .accessibilityValue(localized(isSelected ? "已選取" : "未選取"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var filteredSources: [BookSource] {
        let query = sourceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return enabledSources }
        return enabledSources.filter {
            $0.bookSourceName.localizedCaseInsensitiveContains(query)
                || $0.bookSourceUrl.localizedCaseInsensitiveContains(query)
        }
    }

    private var validSelectedSourceURLs: Set<String> {
        let enabledURLs = Set(enabledSources.compactMap { source in
            let key = SearchSourceScope.sourceKey(for: source)
            return key.isEmpty ? nil : key
        })
        return selectedSourceURLs.intersection(enabledURLs)
    }

    private var canSave: Bool {
        mode == .all || !validSelectedSourceURLs.isEmpty
    }

    private func saveAndDismiss() {
        let scope = mode == .all
            ? SearchSourceScope.all
            : SearchSourceScope(
                mode: .custom,
                selectedSourceURLs: validSelectedSourceURLs
            )
        onSave(scope)
        dismiss()
    }
}

private let searchSourceScopePreviewSources: [BookSource] = {
    var first = BookSource()
    first.bookSourceName = "示例書源 A"
    first.bookSourceUrl = "https://source-a.example"
    var second = BookSource()
    second.bookSourceName = "示例書源 B"
    second.bookSourceUrl = "https://source-b.example"
    return [first, second]
}()

#Preview("搜索範圍") {
    SearchSourceScopeSheet(
        enabledSources: searchSourceScopePreviewSources,
        initialScope: SearchSourceScope(
            mode: .custom,
            selectedSourceURLs: ["https://source-a.example"]
        ),
        onSave: { _ in }
    )
}
~~~

- [ ] **Step 3: Run localization and whitespace checks**

~~~bash
ruby scripts/check_localizations.rb
git diff --check
~~~

Expected: localization checker exits 0 with synchronized catalogs; git diff --check prints nothing.

- [ ] **Step 4: Commit the native sheet and copy**

~~~bash
git add Modules/Features/Search/SearchSourceScopeSheet.swift \
  Resources/zh-Hant.lproj/Localizable.strings \
  Resources/zh-Hans.lproj/Localizable.strings \
  Resources/en.lproj/Localizable.strings
git commit -m "feat(search): add multi-source scope picker"
~~~

### Task 4: Integrate the Scope into Book Search

**Files:**

- Modify: Modules/Features/Search/BookSearchView.swift:55-150
- Modify: Modules/Features/Search/BookSearchView.swift:250-290
- Modify: Modules/Features/Search/BookSearchView.swift:380-430

- [ ] **Step 1: Replace local single-source selection with observed stores and sheet state**

Use these declarations in BookSearchView:

~~~swift
    @EnvironmentObject var bookStore: BookStore
    @StateObject private var aggregator = SearchAggregator()
    @StateObject private var scopeStore = SearchSourceScopeStore.shared
    @ObservedObject private var sourceStore = BookSourceStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var query = ""
    @State private var errorMsg: String?
    @State private var submittedQuery = ""
    @State private var selectedIOS17ResultRoute: BookSearchResultRoute?
    @State private var showsSourceScopeSheet = false
    @State private var needsSearchResubmission = false

    var enabledSources: [BookSource] { sourceStore.enabledSources }
~~~

Delete the computed sourceStore singleton property and selectedSourceId state.

- [ ] **Step 2: Replace the old chip list with the approved capsule entry point**

At the top of the search VStack use:

~~~swift
                if !enabledSources.isEmpty {
                    sourceScopeBar
                    Divider()
                }
~~~

Delete sourceSelector and sourceChip, then add:

~~~swift
    // MARK: Source Scope
    private var sourceScopeBar: some View {
        HStack {
            SearchSourceScopeCapsule(
                title: sourceScopeSummary,
                isCustom: scopeStore.scope.mode == .custom,
                action: { showsSourceScopeSheet = true }
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.sm)
    }

    private var sourceScopeSummary: String {
        switch scopeStore.scope.mode {
        case .all:
            return localized("全部書源")
        case .custom:
            return String(
                format: localized("已選 %d 個書源"),
                scopeStore.scope.resolvedSources(from: enabledSources).count
            )
        }
    }
~~~

- [ ] **Step 3: Present the sheet and clear stale results after a saved change**

Add after the searchable modifier:

~~~swift
        .sheet(isPresented: $showsSourceScopeSheet) {
            SearchSourceScopeSheet(
                enabledSources: enabledSources,
                initialScope: scopeStore.scope,
                onSave: applySearchSourceScope
            )
        }
~~~

Add beside doSearch():

~~~swift
    private func applySearchSourceScope(_ newScope: SearchSourceScope) {
        guard newScope != scopeStore.scope else { return }
        scopeStore.save(newScope)
        submittedQuery = ""
        needsSearchResubmission = !trimmedQuery.isEmpty
        aggregator.cancelAndClear()
    }
~~~

- [ ] **Step 4: Resolve selected sources through the model and guide resubmission**

Inside doSearch(), replace the source selection with:

~~~swift
        let sources = scopeStore.scope.resolvedSources(from: enabledSources)
        guard !sources.isEmpty else {
            errorMsg = scopeStore.scope.mode == .custom
                ? localized("請至少選擇一個可用書源")
                : localized("沒有可用的書源，請先啟用書源")
            return
        }

        needsSearchResubmission = false
        submittedQuery = q
        aggregator.search(query: q, sources: sources)
~~~

In the query-clear handler:

~~~swift
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                submittedQuery = ""
                needsSearchResubmission = false
                aggregator.cancelAndClear()
            }
~~~

Inside the enabled-source branch of hintView, replace the normal prompt with:

~~~swift
                if needsSearchResubmission {
                    Text(localized("搜索範圍已更新，請再次搜索"))
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.textSecondary)
                } else {
                    Text(localized("輸入書名或作者搜索"))
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.textSecondary)
                }
~~~

Keep the existing enabled-source count below this branch.

- [ ] **Step 5: Bring the touched close control and preview up to the UI contract**

Use this close button:

~~~swift
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(localized("關閉"))
~~~

Add at the end of BookSearchView.swift:

~~~swift
#Preview("搜索書籍") {
    NavigationStack {
        BookSearchView()
            .environmentObject(BookStore())
    }
}
~~~

- [ ] **Step 6: Run the focused regression suite and build**

~~~bash
xcodebuild test -quiet \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/SearchSourceScopeTests'

xcodebuild -quiet \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  build
~~~

Expected: both commands exit 0; tests and build succeed.

- [ ] **Step 7: Commit the page integration**

~~~bash
git add Modules/Features/Search/BookSearchView.swift
git commit -m "feat(search): use persistent source range"
~~~

### Task 5: Final Regression and UI Verification

**Files:**

- Verify only; no planned source changes.

- [ ] **Step 1: Run the directly affected search tests without parallel execution**

~~~bash
xcodebuild test -quiet \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/SearchSourceScopeTests' \
  -only-testing:'yuedu appTests/NetworkSettingsSearchTests'
~~~

Expected: TEST SUCCEEDED with 0 failures.

- [ ] **Step 2: Run localization, whitespace, and title-mode policy checks**

~~~bash
ruby scripts/check_localizations.rb
git diff --check
grep -rn -E "toolbarTitleDisplayMode\(\.(automatic|large|inlineLarge)\)|toolbarTitleDisplayModeInlineLarge\(\)|toolbarTitleDisplayModeInlineLargeOrInline\(\)" Modules Targets --include="*.swift"
~~~

Expected: localization and whitespace checks exit 0. Grep shows only the existing whitelisted root-screen helper uses and no forbidden title mode in search files.

- [ ] **Step 3: Build the simulator app into an inspectable Derived Data directory**

~~~bash
xcodebuild -quiet \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -derivedDataPath /tmp/yuedu-search-source-scope-derived \
  build
~~~

Expected: exit 0 and BUILD SUCCEEDED.

- [ ] **Step 4: Install, launch, and visually inspect the search scope states**

~~~bash
xcrun simctl boot D787D0F2-DD88-475A-9BC2-D4484B706011 2>/dev/null || true
xcrun simctl install D787D0F2-DD88-475A-9BC2-D4484B706011 \
  /tmp/yuedu-search-source-scope-derived/Build/Products/Debug-iphonesimulator/YueduReader.app
xcrun simctl launch D787D0F2-DD88-475A-9BC2-D4484B706011 \
  com.zhangruilin.yuedureader
~~~

Navigate to Search and verify: the all-sources capsule, custom selected count, sheet cancel/save semantics, list search, all/clear actions, empty custom validation, long source names, Light/Dark Mode, and persistence after terminating and relaunching the app.

Capture a screenshot:

~~~bash
xcrun simctl io D787D0F2-DD88-475A-9BC2-D4484B706011 screenshot \
  /tmp/yuedu-search-source-scope.png
~~~

Expected: the screenshot shows the approved leading capsule and a native inline-title sheet without clipped text, accidental white rows, or color-only selection state.

- [ ] **Step 5: Confirm the worktree and commit history are complete**

~~~bash
git status --short
git log -6 --oneline
~~~

Expected: clean status; implementation commits for persistence, clearing stale results, the multi-source picker, and page integration follow the design and plan commits.
