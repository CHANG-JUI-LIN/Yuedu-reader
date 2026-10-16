import Foundation
import Testing
@testable import yuedu_app

// MARK: - Plan states and selection

@MainActor
@Suite("SourceImportPlan")
struct SourceImportPlanTests {

    private func source(_ name: String, url: String, clock: Int64) -> BookSource {
        var source = BookSource(bookSourceUrl: url, bookSourceName: name)
        source.lastUpdateTime = clock
        return source
    }

    @Test("classifies each entry as new, update or existing")
    func classifiesEntries() {
        let incoming = [
            source("新的", url: "https://new.example", clock: 100),
            source("較新的", url: "https://known.example", clock: 200),
            source("不比本機新", url: "https://stale.example", clock: 50),
        ]
        let local: [String: Int64] = [
            "https://known.example": 100,
            "https://stale.example": 50,
        ]

        let plan = SourceImportPlan(incoming: incoming) { local[$0] }

        #expect(plan.entries.map(\.state) == [.new, .update, .existing])
        #expect(plan.newCount == 1)
        #expect(plan.updateCount == 1)
        #expect(plan.existingCount == 1)
    }

    /// Upstream ticks 新增 and 更新 but leaves 已有 alone: re-importing a copy the author has
    /// not dated as newer would overwrite local edits for nothing.
    @Test("preselects new and updated entries but not existing ones")
    func preselectsNewAndUpdated() {
        let incoming = [
            source("新的", url: "https://new.example", clock: 100),
            source("較新的", url: "https://known.example", clock: 200),
            source("不比本機新", url: "https://stale.example", clock: 50),
        ]
        let local: [String: Int64] = [
            "https://known.example": 100,
            "https://stale.example": 50,
        ]

        let plan = SourceImportPlan(incoming: incoming) { local[$0] }

        #expect(plan.selectedCount == 2)
        #expect(plan.isSelected(0))
        #expect(plan.isSelected(1))
        #expect(plan.isSelected(2) == false)
        #expect(plan.selectedSources.map(\.bookSourceName) == ["新的", "較新的"])
    }

    /// A pack can carry the same name and URL twice; selection keys on row position so the
    /// two rows stay independent.
    @Test("duplicate entries in one pack remain separately selectable")
    func duplicateEntriesStaySeparate() {
        let incoming = [
            source("重複", url: "https://dup.example", clock: 10),
            source("重複", url: "https://dup.example", clock: 10),
        ]

        let plan = SourceImportPlan(incoming: incoming) { _ in nil }
        #expect(plan.selectedCount == 2)

        plan.toggle(0)

        #expect(plan.isSelected(0) == false)
        #expect(plan.isSelected(1))
        #expect(plan.selectedCount == 1)
    }

    @Test("select all toggles every row both ways")
    func selectAllTogglesEveryRow() {
        let incoming = (0..<4).map { source("源\($0)", url: "https://s\($0).example", clock: 1) }
        let plan = SourceImportPlan(incoming: incoming) { _ in nil }

        plan.toggle(0)
        #expect(plan.isSelectingAll == false)

        plan.toggleSelectAll()
        #expect(plan.isSelectingAll)
        #expect(plan.selectedCount == 4)

        plan.toggleSelectAll()
        #expect(plan.selectedCount == 0)
    }

    @Test("select all new leaves other states untouched")
    func selectAllNewLeavesOthersAlone() {
        let incoming = [
            source("新的", url: "https://new.example", clock: 100),
            source("已有", url: "https://stale.example", clock: 50),
        ]
        let local: [String: Int64] = ["https://stale.example": 50]
        let plan = SourceImportPlan(incoming: incoming) { local[$0] }

        // Starts ticked by default, so the first toggle clears the 新增 rows.
        #expect(plan.isSelectingAllNew)
        plan.toggleSelectAllNew()
        #expect(plan.isSelectingAllNew == false)
        #expect(plan.selectedCount == 0)

        plan.toggleSelectAllNew()
        #expect(plan.isSelected(0))
        #expect(plan.isSelected(1) == false, "已有 must stay unticked")
    }

    @Test("select all update covers only updated rows")
    func selectAllUpdateCoversUpdatesOnly() {
        let incoming = [
            source("新的", url: "https://new.example", clock: 100),
            source("更新", url: "https://known.example", clock: 200),
        ]
        let local: [String: Int64] = ["https://known.example": 100]
        let plan = SourceImportPlan(incoming: incoming) { local[$0] }

        plan.toggleSelectAllUpdate()
        #expect(plan.isSelected(1) == false)
        #expect(plan.isSelected(0), "新增 must be unaffected by 全選更新")

        plan.toggleSelectAllUpdate()
        #expect(plan.isSelected(1))
    }

    @Test("editing a row reparses it and recomputes its state")
    func editingRowRecomputesState() {
        let plan = SourceImportPlan(
            incoming: [source("原本", url: "https://new.example", clock: 100)]
        ) { url in url == "https://known.example" ? 100 : nil }

        #expect(plan.entries[0].state == .new)

        // Edited onto a URL the library already holds, with a newer stamp → 更新.
        let edited = """
        {"bookSourceName":"改過","bookSourceUrl":"https://known.example","lastUpdateTime":500}
        """
        let applied = plan.applyEdit(json: edited, to: 0) { url in
            url == "https://known.example" ? 100 : nil
        }

        #expect(applied)
        #expect(plan.entries[0].source.bookSourceName == "改過")
        #expect(plan.entries[0].state == .update)
        #expect(plan.updateCount == 1)
        #expect(plan.newCount == 0)
    }

    @Test("an unparsable edit is rejected and keeps the original row")
    func unparsableEditIsRejected() {
        let plan = SourceImportPlan(
            incoming: [source("原本", url: "https://new.example", clock: 100)]
        ) { _ in nil }

        #expect(plan.applyEdit(json: "not json at all", to: 0) { _ in nil } == false)
        #expect(plan.entries[0].source.bookSourceName == "原本")

        // A well-formed object that is not a source (no URL) is rejected too.
        #expect(plan.applyEdit(json: #"{"bookSourceName":"沒有網址"}"#, to: 0) { _ in nil } == false)
        #expect(plan.entries[0].source.bookSourceUrl == "https://new.example")
    }
}

// MARK: - Import options

@Suite("BookSourceImportOptions")
struct BookSourceImportOptionsTests {

    private func local() -> BookSource {
        var source = BookSource(bookSourceUrl: "https://a.example", bookSourceName: "本機名稱")
        source.bookSourceGroup = "我的分組"
        source.enabled = false
        source.enabledExplore = false
        source.customOrder = 7
        return source
    }

    private func incoming() -> BookSource {
        var source = BookSource(bookSourceUrl: "https://a.example", bookSourceName: "作者名稱")
        source.bookSourceGroup = "作者分組"
        source.enabled = true
        source.enabledExplore = true
        source.customOrder = 999
        return source
    }

    @Test("direct import takes everything the pack declares")
    func directImportTakesPackValues() {
        let merged = BookSourceImportOptions.direct.merged(incoming: incoming(), local: local())

        #expect(merged.bookSourceName == "作者名稱")
        #expect(merged.bookSourceGroup == "作者分組")
        #expect(merged.enabled)
        #expect(merged.customOrder == 999)
    }

    @Test("keep switches preserve the local name, group and enabled state")
    func keepSwitchesPreserveLocalValues() {
        var options = BookSourceImportOptions()
        options.keepName = true
        options.keepGroup = true
        options.keepEnable = true

        let merged = options.merged(incoming: incoming(), local: local())

        #expect(merged.bookSourceName == "本機名稱")
        #expect(merged.bookSourceGroup == "我的分組")
        #expect(merged.enabled == false)
        #expect(merged.enabledExplore == false)
    }

    /// A manual import must not throw an existing source back to wherever the pack author
    /// happened to place it in their own list.
    @Test("manual defaults keep local ordering")
    func manualDefaultsKeepLocalOrdering() {
        let merged = BookSourceImportOptions.manualDefaults
            .merged(incoming: incoming(), local: local())

        #expect(merged.customOrder == 7)
    }

    @Test("a destination group replaces the pack's group")
    func destinationGroupReplaces() {
        var options = BookSourceImportOptions.manualDefaults
        options.groupName = "新分組"

        let merged = options.merged(incoming: incoming(), local: nil)
        #expect(merged.bookSourceGroup == "新分組")
    }

    @Test("附加分組 adds onto the existing groups without duplicating")
    func destinationGroupAppends() {
        var options = BookSourceImportOptions.manualDefaults
        options.groupName = "新分組"
        options.addsToExistingGroups = true

        var source = incoming()
        source.bookSourceGroup = "甲,乙"
        #expect(options.merged(incoming: source, local: nil).bookSourceGroup == "甲,乙,新分組")

        source.bookSourceGroup = "甲,新分組"
        #expect(
            options.merged(incoming: source, local: nil).bookSourceGroup == "甲,新分組",
            "already-present group must not be added twice"
        )
    }

    /// 保留分組 restores the local groups first, so 附加 lands on the user's own grouping
    /// rather than the pack author's.
    @Test("附加分組 applies on top of the kept local group")
    func appendAppliesOnKeptLocalGroup() {
        var options = BookSourceImportOptions.manualDefaults
        options.keepGroup = true
        options.groupName = "新分組"
        options.addsToExistingGroups = true

        let merged = options.merged(incoming: incoming(), local: local())
        #expect(merged.bookSourceGroup == "我的分組,新分組")
    }

    @Test("blank group names are ignored")
    func blankGroupIgnored() {
        var options = BookSourceImportOptions.manualDefaults
        options.groupName = "   "

        #expect(options.trimmedGroupName == nil)
        #expect(options.merged(incoming: incoming(), local: nil).bookSourceGroup == "作者分組")
    }

    @Test("Legado group separators all split")
    func groupSeparatorsSplit() {
        #expect(BookSourceImportOptions.splitGroups("甲,乙;丙，丁；戊 己") == ["甲", "乙", "丙", "丁", "戊", "己"])
    }
}

// MARK: - Store integration

@MainActor
@Suite("BookSourceStore selected import", .serialized)
struct BookSourceSelectedImportTests {

    @Test("importSelected writes only the given sources and honours the keep switches")
    func importSelectedHonoursOptions() throws {
        let store = BookSourceStore.shared
        let previous = store.sources
        defer { store.replaceSourcesFromSync(previous) }

        var existing = BookSource(bookSourceUrl: "https://a.example", bookSourceName: "本機名稱")
        existing.bookSourceGroup = "我的分組"
        existing.lastUpdateTime = 100
        store.replaceSourcesFromSync([existing])

        var updated = BookSource(bookSourceUrl: "https://a.example", bookSourceName: "作者名稱")
        updated.bookSourceGroup = "作者分組"
        updated.lastUpdateTime = 500
        updated.searchUrl = "https://a.example/search"
        let unselected = BookSource(bookSourceUrl: "https://b.example", bookSourceName: "沒選它")

        var options = BookSourceImportOptions.manualDefaults
        options.keepName = true
        options.keepGroup = true

        // Only `updated` is handed over — the confirmation list drops unticked rows before
        // the store ever sees them.
        _ = try store.importSelected([updated], options: options)

        #expect(store.sources.count == 1)
        let merged = try #require(store.sources.first)
        #expect(merged.bookSourceName == "本機名稱")
        #expect(merged.bookSourceGroup == "我的分組")
        #expect(merged.searchUrl == "https://a.example/search", "rules must still update")
        #expect(store.sources.contains { $0.bookSourceUrl == unselected.bookSourceUrl } == false)
    }

    @Test("existingUpdateClocks reports the newest clock per URL")
    func existingClocksReportNewest() {
        let store = BookSourceStore.shared
        let previous = store.sources
        defer { store.replaceSourcesFromSync(previous) }

        var older = BookSource(bookSourceUrl: "https://dup.example", bookSourceName: "舊")
        older.lastUpdateTime = 100
        var newer = BookSource(bookSourceUrl: "https://dup.example", bookSourceName: "新")
        newer.lastUpdateTime = 900
        store.replaceSourcesFromSync([older, newer])

        // A duplicate must never make an incoming source look newer than it is.
        #expect(store.existingUpdateClocks()["https://dup.example"] == 900)
    }

    @Test("parseForImport reads a pack without writing anything")
    func parseForImportDoesNotWrite() throws {
        let store = BookSourceStore.shared
        let previous = store.sources
        defer { store.replaceSourcesFromSync(previous) }
        store.replaceSourcesFromSync([])

        let json = #"[{"bookSourceName":"甲","bookSourceUrl":"https://x.example"}]"#
        let parsed = try store.parseForImport(json: json)

        #expect(parsed.count == 1)
        #expect(store.sources.isEmpty, "reviewing a pack must not import it")
    }

    /// Crashlytics 4a7e76ac: a 2.4 GB file aborted the app while it became text.
    @Test("a file over the import limit is refused before it is read")
    func oversizedImportIsRefused() {
        let size = BookSourceStore.maxImportBytes + 1
        // Zero pages the guard never touches, so the test costs no real memory.
        let data = Data(count: size)
        #expect {
            try BookSourceStore.shared.parseForImport(data: data, fileExtension: "json")
        } throws: { error in
            guard case BookSourceStore.ImportError.tooLarge(let bytes) = error else { return false }
            return bytes == size
        }
    }

    @Test("an import file over the limit is refused by its size, unread")
    func oversizedImportFileIsNotRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        // Sparse: the file reports its size without the disk holding it.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(BookSourceStore.maxImportBytes + 1))
        try handle.close()
        #expect {
            try BookSourceStore.importData(contentsOf: url)
        } throws: { error in
            guard case BookSourceStore.ImportError.tooLarge(let bytes) = error else { return false }
            return bytes == BookSourceStore.maxImportBytes + 1
        }
    }

    @Test("a pack that is not UTF-8 is refused instead of read as Latin-1")
    func nonUTF8ImportIsRefused() {
        // 甲 in GBK: valid Latin-1, so the old fallback imported a garbled name.
        let data = Data(#"[{"bookSourceName":""#.utf8) + Data([0xBC, 0xD7])
            + Data(#"","bookSourceUrl":"https://x.example"}]"#.utf8)
        #expect {
            try BookSourceStore.shared.parseForImport(data: data, fileExtension: "json")
        } throws: { error in
            guard case BookSourceStore.ImportError.notUTF8 = error else { return false }
            return true
        }
    }
}
