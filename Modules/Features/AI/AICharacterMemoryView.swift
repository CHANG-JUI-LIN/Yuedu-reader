import SwiftUI

struct AICharacterMemoryView: View {
    let adapter: AIBookContentAdapter
    var onOpenCitation: ((LLMCitation) -> Void)? = nil
    @ObservedObject private var service = AICharacterMemoryService.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var buildWholeBook = false
    @State private var budget = AIMemoryBudget()
    @State private var proposal: AIMemoryJob?
    @State private var proposalCoverage: AIMemoryCoverage?
    @State private var projection = AIMemoryView(cards: [], aliases: [], approvedAliasIDs: [])
    @State private var loadedKey = ""
    @State private var query = ""
    @State private var page = 0
    @State private var error: String?
    @State private var viewingWholeBook = false
    @State private var chapterView = false
    @State private var viewChapter = 0
    @State private var allowFutureView = false
    @State private var confirmView = false
    @State private var confirmResume = false
    @State private var confirmClear = false
    @State private var additionalCalls = 0
    @State private var operation: Task<Void, Never>?
    @State private var selected: Selection?
    private struct Selection: Identifiable { let id: String }
    private var job: AIMemoryJob? { service.jobs[adapter.chunkBookID] }
    private var coverage: AIMemoryCoverage? { service.coverages[adapter.chunkBookID] }
    private var boundary: AIReadingBoundary {
        if viewingWholeBook { return adapter.boundary(wholeBook: true) }
        let chapter = min(viewChapter, maximumViewChapter)
        if chapterView, adapter.chunkSections.indices.contains(chapter) {
            let read = adapter.boundary()
            let offset = !allowFutureView && chapter == read.spineIndex ? read.utf16Offset : adapter.chunkSections[chapter].text.utf16.count
            return .init(sourceVersion: adapter.contentFingerprint, sectionID: adapter.chunkSections[chapter].id,
                spineIndex: chapter, utf16Offset: offset)
        }
        return adapter.boundary()
    }
    private var viewKey: String { "\(adapter.contentFingerprint)@\(boundary)@\(service.revisions[adapter.chunkBookID] ?? 0)" }
    private var visible: AIMemoryView { loadedKey == viewKey ? projection : .init(cards: [], aliases: [], approvedAliasIDs: []) }
    private var maximumViewChapter: Int { max(0, min(adapter.chunkSections.count - 1, allowFutureView ? adapter.chunkSections.count - 1 : adapter.boundary().spineIndex)) }

    var body: some View {
        List {
            Section {
                Picker(localized("建檔範圍"), selection: $buildWholeBook) {
                    Text(localized("截至目前閱讀位置")).tag(false)
                    Text(localized("本機可用全書正文")).tag(true)
                }
                Stepper(String(format: localized("總呼叫上限：%d"), budget.maximumCalls), value: $budget.maximumCalls, in: 1...100_000)
                Toggle(localized("截斷時允許自動分拆一次"), isOn: Binding(get: { budget.automaticSplitDepth > 0 }, set: { budget.automaticSplitDepth = $0 ? 1 : 0 }))
                Button(localized("規劃人物建檔")) { prepare() }.disabled(job?.state == .running)
            } footer: {
                Text(localized("建檔會逐批傳送允許範圍內的本機正文到你的生成服務；開始前會再次列明模型與預算。"))
                    .dsSectionFooter()
            }
            if let job { jobSection(job) }
            if let error = error ?? service.failures[adapter.chunkBookID] {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(DSColor.destructive) }
            }
            Section {
                Toggle(localized("查看後文人物資料"), isOn: Binding(get: { viewingWholeBook }, set: { value in
                    selected = nil
                    if value { confirmView = true } else { viewingWholeBook = false; allowFutureView = false; chapterView = false }
                }))
                Toggle(localized("按章節進度查看"), isOn: $chapterView).disabled(viewingWholeBook)
                if chapterView && !viewingWholeBook {
                    Stepper(String(format: localized("查看到第 %d 章"), viewChapter + 1), value: $viewChapter, in: 0...maximumViewChapter)
                }
                LabeledContent(localized("目前範圍人物數"), value: "\(visible.count)")
            } footer: {
                Text(localized("建檔範圍與查看範圍分開；卡片只使用目前範圍允許的提及、事實與身分關係。"))
                    .dsSectionFooter()
            }
            Section {
                if loadedKey != viewKey {
                    ProgressView(localized("載入中…"))
                } else if visible.cards.isEmpty {
                    ContentUnavailableView(localized("此範圍尚無人物資料"), systemImage: "person.text.rectangle")
                }
                ForEach(visible.page(query: query, offset: page * 40)) { card in
                    Button { selected = Selection(id: card.id) } label: {
                        LabeledContent(card.names.joined(separator: "、"), value: String(format: localized("%d 筆經歷記錄"), card.facts.count))
                    }
                }
                if page > 0 { Button(localized("上一頁")) { page -= 1 } }
                if !visible.page(query: query, offset: (page + 1) * 40).isEmpty { Button(localized("下一頁")) { page += 1 } }
            } footer: {
                Text(localized("這是模型抽取的結構化記錄，不代表人物或事實全部正確；每項保留原文供核對。新別名不會自動送入問答或朗讀。"))
                    .dsSectionFooter()
            }
            Section {
                NavigationLink(localized("AI 狀態與診斷")) { AIStatusView(adapter: adapter) }
                Button(localized("清除本書人物建檔資料"), role: .destructive) { confirmClear = true }
            } footer: {
                Text(localized("人物記錄與工作進度保存在本機 Application Support/AICharacterMemory；清除不會刪除正文、聊天或人工角色聲音設定。離開功能或退到背景會暫停。"))
                    .dsSectionFooter()
            }
        }
        .navigationTitle(localized("逐批人物建檔"))
        .toolbarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: localized("搜尋目前範圍的人物"))
        .onChange(of: query) { _, _ in page = 0 }
        .task(id: adapter.contentFingerprint) {
            do { try await service.load(source: adapter) } catch { self.error = error.localizedDescription }
        }
        .task(id: viewKey) {
            let key = viewKey
            do {
                let view = try await service.view(source: adapter, boundary: boundary)
                guard !Task.isCancelled, key == viewKey else { return }
                projection = view; loadedKey = key
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: boundary) { _, _ in selected = nil; page = 0 }
        .onChange(of: adapter.contentFingerprint) { _, _ in selected = nil; proposal = nil; operation?.cancel(); service.pause(book: adapter.chunkBookID) }
        .onChange(of: scenePhase) { _, value in if value != .active { operation?.cancel(); service.pause(book: adapter.chunkBookID) } }
        .onDisappear { operation?.cancel(); service.pause(book: adapter.chunkBookID) }
        .sheet(item: $proposal) { job in consent(job) }
        .sheet(item: $selected) { selection in
            NavigationStack {
                AIMemoryCardView(entityID: selection.id, source: adapter, boundary: boundary, onOpenCitation: onOpenCitation)
            }
        }
        .confirmationDialog(localized("查看後文可能揭露人物身分與關係"), isPresented: $confirmView, titleVisibility: .visible) {
            Button(localized("確認查看後文")) { allowFutureView = true; viewingWholeBook = true }
            Button(localized("取消"), role: .cancel) {}
        }
        .confirmationDialog(localized("確認續跑與呼叫預算"), isPresented: $confirmResume, titleVisibility: .visible) {
            Button(localized("確認續跑")) { resume() }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("未保存的上一批可能已呼叫並計費；續跑可能再次計費，所有呼叫仍計入此工作的總預算。"))
        }
        .confirmationDialog(localized("清除本書人物建檔資料？"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(localized("清除"), role: .destructive) { Task {
                do { try await service.clear(book: adapter.chunkBookID); projection = .init(cards: [], aliases: [], approvedAliasIDs: []) }
                catch { self.error = error.localizedDescription }
            } }
            Button(localized("取消"), role: .cancel) {}
        }
    }
    private func prepare() {
        error = nil
        Task {
            do {
                let job = try service.prepare(source: adapter, wholeBook: buildWholeBook, budget: budget)
                proposalCoverage = try await service.coverage(job: job, source: adapter)
                proposal = job
            } catch { self.error = error.localizedDescription }
        }
    }
    private func resume() {
        operation?.cancel()
        operation = Task { do { try await service.resume(source: adapter, acknowledgeUnknown: true, additionalCalls: additionalCalls); additionalCalls = 0; error = nil }
            catch { self.error = error.localizedDescription } }
    }
    private func jobSection(_ job: AIMemoryJob) -> some View {
        Section {
            LabeledContent(localized("建檔狀態"), value: state(job.state))
            LabeledContent(localized("生成模型"), value: job.model)
            LabeledContent(localized("模型呼叫"), value: "\(job.calls) / \(job.budget.maximumCalls)")
            if let coverage {
                LabeledContent(localized("目錄目標章節"), value: "\(job.targetChapters)")
                LabeledContent(localized("可分析章節／已分析章節"), value: "\(coverage.availableChapters) / \(coverage.analyzedChapters)")
                LabeledContent(localized("已保存批次"), value: "\(coverage.committedUnits) / \(coverage.plannedUnits)")
                LabeledContent(localized("已保存主要正文 UTF-16"), value: "\(coverage.committedUTF16) / \(coverage.plannedUTF16)")
                ForEach(coverage.missing, id: \.order) { chapter in
                    LabeledContent(String(format: localized("第 %d 章"), chapter.order + 1), value: missing(chapter.status))
                }
            }
            if let failure = job.failure {
                Text(failure == "length" ? localized("抽取輸出被截斷，可分拆該批後再確認續跑。") :
                    AIMemoryFailure(rawValue: failure)?.localizedDescription ?? localized("該批抽取失敗，未保存為成功。"))
                    .foregroundStyle(DSColor.destructive)
            }
            if job.state == .running { Button(localized("暫停建檔")) { service.pause(book: adapter.chunkBookID) } }
            else if job.state != .completedAvailable {
                Stepper(String(format: localized("追加呼叫額度：%d"), additionalCalls), value: $additionalCalls, in: 0...100_000)
                Button(localized("續跑／重試未完成批次")) { confirmResume = true }
                if job.state == .failed {
                    Button(localized("分拆未完成批次")) { Task {
                        do { try await service.splitFailed(source: adapter) } catch { self.error = error.localizedDescription }
                    } }
                }
            }
        } footer: {
            Text(localized("完成表示已分析本機可用且允許的正文；缺失章節與未保存批次不算完成，也不保證沒有漏抽人物。"))
                .dsSectionFooter()
        }
    }
    private func consent(_ job: AIMemoryJob) -> some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(localized("生成服務"), value: job.providerDisplayName)
                    LabeledContent(localized("生成模型"), value: job.model)
                    LabeledContent(localized("建檔範圍"), value: job.boundary.wholeBook ? localized("本機可用全書正文") : localized("截至目前閱讀位置"))
                    LabeledContent(localized("初始批次數"), value: "\(job.units.count)")
                    LabeledContent(localized("總模型呼叫上限"), value: "\(job.budget.maximumCalls)")
                    LabeledContent(localized("每批輸出 token 上限"), value: "\(job.budget.outputTokens)")
                    if let info = proposalCoverage {
                        LabeledContent(localized("可分析字元／UTF-16／bytes"), value: "\(info.characters) / \(info.plannedUTF16) / \(info.bytes)")
                        LabeledContent(localized("可重用已保存批次"), value: "\(info.committedUnits)")
                    }
                    LabeledContent(localized("token 數與金額估算"), value: localized("未知"))
                } footer: {
                    Text(localized("這會逐批傳送正文，不只是問答命中的少數片段。全書範圍可能包含後文；模型服務可能收費，沒有價格或 tokenizer 資料時不估價。"))
                        .dsSectionFooter()
                }
                Section {
                    Button(localized("確認傳送並開始建檔")) {
                        proposal = nil
                        operation?.cancel()
                        operation = Task { do { try await service.start(confirmed: job, source: adapter) } catch { self.error = error.localizedDescription } }
                    }.disabled(job.units.isEmpty)
                }
            }
            .navigationTitle(localized("確認人物建檔"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { proposal = nil } label: { Image(systemName: "xmark").accessibilityHidden(true) }.accessibilityLabel(localized("取消")) } }
        }
    }
    private func state(_ state: AIMemoryJob.State) -> String {
        switch state {
        case .running: return localized("正在逐批分析")
        case .completedAvailable: return localized("本機可用範圍已分析")
        case .budgetPaused: return localized("預算用盡，已暫停")
        case .resultUnknown: return localized("上一批結果未知")
        case .failed: return localized("失敗，等待重試")
        case .cancelled, .paused: return localized("已暫停")
        case .superseded: return localized("來源工作已更新")
        }
    }
    private func missing(_ status: AISourceManifest.Availability) -> String {
        switch status {
        case .available: return localized("正文已取得")
        case .notDownloaded: return localized("尚未下載")
        case .extractionFailed: return localized("正文抽取失敗")
        case .unsupported: return localized("格式不支援正文抽取")
        }
    }
}

private struct AIMemoryCardView: View {
    let entityID: String
    let source: AIBookContentAdapter
    let boundary: AIReadingBoundary
    let onOpenCitation: ((LLMCitation) -> Void)?
    @ObservedObject private var service = AICharacterMemoryService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var view = AIMemoryView(cards: [], aliases: [], approvedAliasIDs: [])
    @State private var loading = true
    @State private var page = 0
    @State private var error: String?
    private var card: AIMemoryCard? { view.cards.first { $0.entityIDs.contains(entityID) } }
    var body: some View {
        List {
            if let card {
                Section {
                    Text(card.names.joined(separator: "、")).font(DSFont.title3)
                    if card.mentions.allSatisfy(\.unresolved) { Text(localized("包含未決稱呼，身分仍待確認。")) }
                    if let earliest = card.earliest {
                        Text(localized("目前找到最早的明確提及"))
                        evidence(earliest.evidence)
                    }
                }
                Section {
                    ForEach(card.facts.dropFirst(page * 30).prefix(30)) { fact in
                        VStack(alignment: .leading, spacing: DSSpacing.xs) {
                            Text(kind(fact.kind)).font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
                            Text(fact.text).textSelection(.enabled)
                            ForEach(fact.evidence) { evidence($0) }
                        }
                    }
                    if page > 0 { Button(localized("上一頁")) { page -= 1 } }
                    if (page + 1) * 30 < card.facts.count { Button(localized("下一頁")) { page += 1 } }
                } header: { Text(localized("經歷與關係（原文揭露順序）")) }
                ForEach(card.aliases) { alias in
                    Section {
                        let otherIDs = [alias.first, alias.second]
                        Text(view.cards.filter { !$0.entityIDs.isDisjoint(with: otherIDs) }.flatMap(\.names).joined(separator: "、"))
                        Text(localized("是否同一人物：請核對原文"))
                        ForEach(alias.evidence) { evidence($0) }
                        Button(view.approvedAliasIDs.contains(alias.id) ? localized("撤回身分合併") : localized("確認是同一人物")) {
                            Task { do { try await service.decide(alias: alias, approved: !view.approvedAliasIDs.contains(alias.id), source: source, boundary: boundary) }
                                catch { self.error = error.localizedDescription } }
                        }
                    } footer: {
                        Text(localized("同名或模型信心不是合併依據；確認只影響此揭露範圍之後的檢視，原始提及與事實仍保留。"))
                            .dsSectionFooter()
                    }
                }
            } else if loading { ProgressView(localized("載入中…")) }
            else { ContentUnavailableView(localized("此範圍尚無人物資料"), systemImage: "person.crop.circle") }
            if let error { Text(error).foregroundStyle(DSColor.destructive) }
        }
        .navigationTitle(localized("人物經歷與證據"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Image(systemName: "checkmark").accessibilityHidden(true) }.accessibilityLabel(localized("完成")) } }
        .task(id: service.revisions[source.chunkBookID]) {
            loading = true
            do { view = try await service.view(source: source, boundary: boundary) } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
    @ViewBuilder private func evidence(_ proof: AIMemoryEvidence) -> some View {
        Text(String(format: localized("第 %d 章"), proof.span.spine + 1)).font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
        Text(proof.quote).font(DSFont.callout).textSelection(.enabled)
        if let citation = proof.citation(source: source), let onOpenCitation {
            Button(localized("跳到原文")) { dismiss(); onOpenCitation(citation) }
        } else {
            Text(localized("此入口無法精準跳轉，請依章節與引文核對。"))
                .font(DSFont.footnote).foregroundStyle(DSColor.textSecondary)
        }
    }
    private func kind(_ kind: AIMemoryFact.Kind) -> String {
        switch kind {
        case .narration: return localized("原文敘述")
        case .statement: return localized("角色發言／自述")
        case .rumor: return localized("傳聞／懷疑")
        case .interpretation: return localized("模型解讀")
        case .correction: return localized("後文反駁／修正")
        case .relationship: return localized("關係記錄")
        }
    }
}

#Preview {
    NavigationStack { AICharacterMemoryView(adapter: .init(bookID: UUID(), chapters: [], textForChapter: { _ in nil })) }
}
