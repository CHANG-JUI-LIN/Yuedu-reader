import SwiftUI

/// 官方模組 → AI 推薦 (AI 推薦 plan 8d): what it sends and to which service, the last run,
/// 加到首頁 and 產生推薦／重新產生. The works themselves show on the home.
struct AIRecommendationModuleView: View {
    @EnvironmentObject private var shelf: BookStore
    @ObservedObject private var service: AIRecommendationService
    @ObservedObject private var recommendations: AIRecommendationStore
    @ObservedObject private var subscription = SubscriptionStore.shared
    @ObservedObject private var pageStore = HomePageStore.shared
    @State private var showsPaywall = false

    /// - Parameter service: the shared one; a preview passes its own, with its own store.
    init(service: AIRecommendationService? = nil) {
        let service = service ?? .shared
        _service = ObservedObject(wrappedValue: service)
        _recommendations = ObservedObject(wrappedValue: service.store)
    }

    private var allowsAI: Bool {
        ReaderPremiumVisibilityPolicy(isProActive: subscription.isProActive).allowsAI
    }

    var body: some View {
        Form {
            if allowsAI {
                serviceSection
                lastRunSection
                actionsSection
            } else {
                ContentUnavailableView {
                    UnavailableLabel(localized("需要 Pro"), systemImage: "lock.fill")
                } description: {
                    Text(localized("依你最近讀的書推薦作品")).foregroundStyle(DSColor.textSecondary)
                } actions: {
                    Button(localized("升級")) { showsPaywall = true }
                        .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(localized("AI 推薦"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .sheet(isPresented: $showsPaywall) {
            PaywallView(highlightedFeature: .aiReading)
                .environmentObject(subscription)
        }
    }

    // MARK: Sections

    private var serviceSection: some View {
        Section {
            switch service.service() {
            case .success(let active):
                ThemedLabeledContent(localized("生成服務"), value: active.name)
                ThemedLabeledContent(localized("生成模型"), value: active.model)
            case .failure(let reason):
                Text(reason.message)
                    .foregroundStyle(DSColor.textSecondary)
                NavigationLink(localized("AI 助手設定")) { AISettingsView(embedded: true) }
                    .accessibilityIdentifier("aiModule.settings")
            }
        } footer: {
            Text(localized("會送出最近讀的 30 本書的書名、作者和分類，以及閱讀類型偏好，只送到這個服務。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var lastRunSection: some View {
        Section {
            if let list = recommendations.list {
                ThemedLabeledContent(localized("上次產生"),
                                     value: list.generatedAt.formatted(date: .abbreviated, time: .shortened))
                ThemedLabeledContent(localized("推薦作品"), value: "\(list.entries.count)")
                ThemedLabeledContent(localized("生成服務"), value: list.service)
            } else {
                ThemedLabeledContent(localized("上次產生"), value: localized("尚未產生"))
            }
            switch service.state {
            case .generating:
                progress(localized("正在產生推薦…"))
            case .resolving(let completed, let total):
                progress(String(format: localized("正在查詢封面與簡介（%d/%d）"), completed, total))
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(DSColor.destructive)
            case .idle:
                EmptyView()
            }
        }
        .interfaceSectionSurface()
    }

    private var actionsSection: some View {
        Section {
            Button {
                service.generate(shelf: shelf)
            } label: {
                SettingsRowLabel(recommendations.list == nil ? localized("產生推薦") : localized("重新產生"),
                                 systemImage: "sparkles", role: .action)
            }
            .disabled(service.state.isRunning)
            .accessibilityIdentifier("aiModule.generate")
            if let page = pageStore.page {
                if page.sections.contains(where: { $0.binding == .aiRecommendations }) {
                    SettingsRowLabel(localized("已在首頁"), systemImage: "checkmark.circle")
                        .foregroundStyle(DSColor.textSecondary)
                        .accessibilityIdentifier("aiModule.onHome")
                } else {
                    Button {
                        pageStore.edit { $0.appendSection(HomeSection(layout: .row, binding: .aiRecommendations)) }
                    } label: {
                        SettingsRowLabel(localized("加到首頁"), systemImage: "rectangle.stack.badge.plus", role: .action)
                    }
                    .accessibilityIdentifier("aiModule.addToHome")
                }
            }
        }
        .interfaceSectionSurface()
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: DSSpacing.sm) {
            ProgressView()
            Text(text)
                .foregroundStyle(DSColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("AI 推薦") {
    NavigationStack {
        AIRecommendationModuleView(service: AIRecommendationRowPreview.service(list: AIRecommendationRowPreview.list))
    }
    .environmentObject(BookStore())
}
