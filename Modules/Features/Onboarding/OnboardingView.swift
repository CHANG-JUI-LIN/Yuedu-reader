import SwiftUI

/// 新手導覽 over the whole app (`OnboardingState`): an overlay rather than a full-screen
/// cover, so a book opened into 閱讀 at the same launch still presents its reader, and the
/// tour is waiting when it closes.
struct OnboardingPresentation: ViewModifier {
    let state: OnboardingState
    @Binding var selectedTab: RootTabItem
    /// The theme's accent, set by the root inside this modifier and so not reaching the tour.
    let tint: Color?
    @Bindable private var gs = GlobalSettings.shared
    @ObservedObject private var availability = PublicLibraryAvailability.shared
    @ObservedObject private var aggregation = AggregationSettingsStore.shared
    @EnvironmentObject private var subscriptionStore: SubscriptionStore

    func body(content: Content) -> some View {
        content
            .overlay {
                if state.isPresented {
                    OnboardingView(content: tourContent, finish: finish)
                        .tint(tint)
                        .transition(.opacity)
                }
            }
    }

    private var tourContent: OnboardingContent {
        OnboardingContent(
            visibleTabs: gs.visibleRootTabs,
            // A storefront not yet known may be Mainland China's (`PublicLibraryAvailability`):
            // the public libraries are named once it is known not to be.
            librariesAvailable: availability.countryCode != nil && availability.isAvailable,
            // The languages 探索 makes a new home for (`ExploreHome.defaultsContext`).
            languages: aggregation.readingLanguages.languages,
            lockedFeatures: Set(PremiumFeature.allCases.filter { !subscriptionStore.hasAccess($0) })
        )
    }

    /// The start's tab comes forward under the tour as it fades; the tab opens the start's
    /// page itself (`OnboardingState.take(_:)`).
    private func finish(_ start: OnboardingStart?) {
        if let start {
            selectedTab = start.tab
        }
        // A fade, which Reduce Motion keeps.
        withAnimation(DSAnimation.fast) {
            state.finish(startingAt: start)
        }
    }
}

/// The tour: 略過 at the top, the pages, and the dots and 繼續 at the bottom. The last page
/// says 開始使用 and offers where to start.
struct OnboardingView: View {
    let content: OnboardingContent
    let finish: (OnboardingStart?) -> Void

    @State private var page: OnboardingPage? = .welcome
    /// Whether the welcome page has come in, kept here because the pager drops pages it
    /// has scrolled away from: coming back to it does not play its entrance again.
    @State private var welcomeHasAppeared = false
    @AccessibilityFocusState private var focusedTitle: OnboardingPage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pages: [OnboardingPage] { content.pages }

    private var current: OnboardingPage { page ?? .welcome }

    private var currentIndex: Int { pages.firstIndex(of: current) ?? 0 }

    private var isLastPage: Bool { currentIndex == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .accessibilitySortPriority(0)
            pager
                .accessibilitySortPriority(2)
            bottomBar
                .accessibilitySortPriority(1)
        }
        .background(PageBackgroundView(scope: .global).ignoresSafeArea())
        // VoiceOver reaches only the tour while it is up, not the tab bar or the mini player
        // under it: SwiftUI leaves a modal element's siblings out (`OnboardingVoiceOverTests`,
        // iOS 17.5 and 27), as for the public-library carousel.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { finish(nil) }
        .onAppear { focusedTitle = .welcome }
        // VoiceOver starts each page at its title, wherever the page was turned from.
        .onChange(of: page) { _, newPage in
            focusedTitle = newPage
        }
    }

    // MARK: - Bars

    private var topBar: some View {
        HStack {
            Spacer()
            Button(localized("略過")) { finish(nil) }
                .font(DSFont.body)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("onboarding.skip")
                // The last page leaves by its own choices and 開始使用; the bar keeps its
                // height so the pages do not move.
                .opacity(isLastPage ? 0 : 1)
                .disabled(isLastPage)
                .accessibilityHidden(onlyWhen: isLastPage)
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.sm)
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                // By the page itself, the type `scrollPosition` tracks.
                ForEach(pages, id: \.self) { item in
                    pageView(item)
                        // A page that scrolls says so as it comes into view.
                        .scrollIndicatorsFlash(trigger: item == current)
                        // VoiceOver reads the page in view; the dots and 繼續 turn the pages.
                        .accessibilityHidden(onlyWhen: item != current)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page, anchor: .center)
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func pageView(_ item: OnboardingPage) -> some View {
        switch item {
        case .welcome:
            OnboardingWelcomePage(hasAppeared: $welcomeHasAppeared, focus: $focusedTitle)
        case .explore:
            // In `pages` only with its copy.
            if let explore = content.explore {
                OnboardingExplorePage(copy: explore, focus: $focusedTitle)
            }
        case .works:
            OnboardingWorksPage(rows: content.works, focus: $focusedTitle)
        case .sources:
            OnboardingSourcesPage(copy: content.sources, focus: $focusedTitle)
        case .reading:
            OnboardingReadingPage(rows: content.reading, focus: $focusedTitle)
        case .start:
            OnboardingStartPage(starts: content.starts, focus: $focusedTitle, choose: { finish($0) })
        }
    }

    private var bottomBar: some View {
        VStack(spacing: DSSpacing.lg) {
            pageDots
            Button(action: advance) {
                Text(localized(isLastPage ? "開始使用" : "繼續"))
                    .font(DSFont.headline)
                    // As wide as the column. The height is `.controlSize(.large)`'s: a height
                    // set here comes on top of the padding the system adds around the label.
                    .frame(maxWidth: .infinity)
            }
            .onboardingPrimaryButtonStyle()
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("onboarding.continue")
        }
        .frame(maxWidth: DSLayout.readableNarrowWidth)
        .padding(.horizontal, DSSpacing.xl)
        .padding(.top, DSSpacing.md)
        .padding(.bottom, DSSpacing.lg)
        .frame(maxWidth: .infinity)
    }

    /// One element for VoiceOver: where in the tour this is, and swiping up or down turns
    /// the page.
    private var pageDots: some View {
        HStack(spacing: DSSpacing.sm) {
            ForEach(pages) { item in
                Circle()
                    .fill(item == current ? DSColor.textPrimary : DSColor.textTertiary)
                    .frame(width: DSLayout.onboardingPageDotSize, height: DSLayout.onboardingPageDotSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("新手導覽"))
        .accessibilityValue(String(format: localized("第 %d 頁（共 %d 頁）"), currentIndex + 1, pages.count))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                turn(to: currentIndex + 1)
            case .decrement:
                turn(to: currentIndex - 1)
            @unknown default:
                break
            }
        }
    }

    // MARK: - Turning

    private func advance() {
        if isLastPage {
            finish(nil)
        } else {
            turn(to: currentIndex + 1)
        }
    }

    private func turn(to index: Int) {
        guard pages.indices.contains(index) else { return }
        withAnimation(reduceMotion ? nil : DSAnimation.standard) {
            page = pages[index]
        }
    }
}

private extension View {
    /// The tour's one prominent action: Liquid Glass from iOS 26, the system's prominent
    /// capsule before it.
    @ViewBuilder
    func onboardingPrimaryButtonStyle() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large)
        } else {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
        }
        #else
        buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
        #endif
    }
}

#Preview("新手導覽") {
    OnboardingView(
        content: OnboardingContent(
            visibleTabs: RootTabItem.tabs,
            librariesAvailable: true,
            languages: ["zh"],
            lockedFeatures: Set(PremiumFeature.allCases)
        ),
        finish: { _ in }
    )
}

#Preview("新手導覽：閱讀Pro、無探索與起點") {
    OnboardingView(
        content: OnboardingContent(
            visibleTabs: [.settings, .search],
            librariesAvailable: false,
            languages: ["ko"],
            lockedFeatures: []
        ),
        finish: { _ in }
    )
}
