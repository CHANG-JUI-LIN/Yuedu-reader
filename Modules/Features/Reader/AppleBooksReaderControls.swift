import Foundation
import SwiftUI

enum AppleBooksReaderControlPanel: Equatable {
    case menu

    static func panel(
        afterTapping target: AppleBooksReaderControlPanel,
        current: AppleBooksReaderControlPanel?
    ) -> AppleBooksReaderControlPanel? {
        current == target ? nil : target
    }
}

enum AppleBooksProgressScrubber {
    static func value(at locationX: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return clamped(Double(locationX / width))
    }

    static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

struct AppleBooksReaderAction: Identifiable {
    enum ID: String {
        case playback
        case download
        case changeSource
        case refresh
    }

    let id: ID
    let icon: String
    let label: String
    let action: () -> Void
}

struct AppleBooksReaderControls: View {
    @Binding var activePanel: AppleBooksReaderControlPanel?
    let progressValue: () -> Double
    let applyProgress: (Double) -> Void
    let progressDescription: (Double) -> String
    let secondaryActions: [AppleBooksReaderAction]
    let onOpenTOC: () -> Void
    let onOpenSearch: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sliderDraft: Double?
    @State private var progressFeedbackPhase = 0

    var body: some View {
        ZStack {
            readerScrim

            VStack {
                Spacer(minLength: 0)

                HStack {
                    Spacer(minLength: 0)

                    if activePanel == .menu {
                        menuPanel
                            .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.bottom, DSSpacing.xs)
        }
        .animation(panelAnimation, value: activePanel)
        .sensoryFeedback(.impact(weight: .light), trigger: progressFeedbackPhase)
        .onChange(of: activePanel) { _, panel in
            if panel == nil {
                sliderDraft = nil
            }
        }
    }

    private var panelAnimation: Animation {
        reduceMotion ? DSAnimation.fast : DSAnimation.standard
    }

    private var readerScrim: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: DSColor.textPrimary, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .contentShape(Rectangle())
            .onTapGesture {
                closePanels()
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    private var menuPanel: some View {
        VStack(spacing: DSSpacing.sm) {
            VStack(spacing: DSSpacing.sm) {
                progressMenuRow

                menuRow(localized("Search Book"), icon: "magnifyingglass") {
                    performPanelAction(onOpenSearch)
                }

                menuRow(localized("Themes & Settings"), icon: "textformat.size") {
                    performPanelAction(onOpenSettings)
                }
            }

            if !secondaryActions.isEmpty {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)

                    HStack(spacing: DSSpacing.sm) {
                        ForEach(Array(secondaryActions.reversed())) { item in
                            Button {
                                performPanelAction(item.action)
                            } label: {
                                Image(systemName: item.icon)
                                    .font(DSFont.toolbarIconLarge)
                                    .foregroundStyle(DSColor.textPrimary)
                                    .frame(
                                        width: DSLayout.readerAppleBooksActionWidth,
                                        height: DSLayout.readerAppleBooksActionHeight
                                    )
                                    .background(.regularMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.label)
                        }
                    }
                }
            }
        }
        .frame(width: DSLayout.readerAppleBooksPanelWidth)
    }

    private var progressMenuRow: some View {
        let value = AppleBooksProgressScrubber.clamped(sliderDraft ?? progressValue())

        return HStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    let fillWidth = geometry.size.width * CGFloat(value)

                    Rectangle()
                        .fill(DSColor.neutralControlProgressFill)
                        .frame(width: fillWidth)
                        .allowsHitTesting(false)

                    progressLabel(
                        value,
                        foreground: DSColor.neutralControlEmphasizedForeground
                    )

                    progressLabel(
                        value,
                        foreground: DSColor.neutralControlProgressForeground
                    )
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: fillWidth)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            if sliderDraft == nil {
                                progressFeedbackPhase += 1
                            }
                            sliderDraft = AppleBooksProgressScrubber.value(
                                at: drag.location.x,
                                width: geometry.size.width
                            )
                        }
                        .onEnded { drag in
                            let value = AppleBooksProgressScrubber.value(
                                at: drag.location.x,
                                width: geometry.size.width
                            )
                            applyProgress(value)
                            sliderDraft = nil
                            progressFeedbackPhase += 1
                        }
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(localized("閱讀進度"))
                .accessibilityValue(progressAccessibilityValue(value))
                .accessibilityAdjustableAction { direction in
                    adjustProgress(direction)
                }
            }

            Button {
                performPanelAction(onOpenTOC)
            } label: {
                Image(systemName: "list.bullet")
                    .font(DSFont.toolbarIconLarge)
                    .foregroundStyle(DSColor.neutralControlEmphasizedForeground)
                    .frame(
                        width: DSLayout.readerAppleBooksControlSize,
                        height: DSLayout.readerAppleBooksMenuRowHeight
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localized("目錄"))
        }
        .frame(height: DSLayout.readerAppleBooksMenuRowHeight)
        .background(DSColor.neutralControlEmphasizedFill, in: Capsule())
        .clipShape(Capsule())
    }

    private func progressLabel(_ value: Double, foreground: Color) -> some View {
        Text(String(format: localized("Contents · %@"), formattedPercent(value)))
            .font(DSFont.subheadline)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.leading, DSSpacing.lg)
    }

    private func menuRow(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DSSpacing.md) {
                Text(title)
                    .font(DSFont.subheadline)
                    .lineLimit(1)

                Spacer(minLength: DSSpacing.sm)

                Image(systemName: icon)
                    .font(DSFont.toolbarIconLarge)
            }
            .foregroundStyle(DSColor.textPrimary)
            .padding(.horizontal, DSSpacing.lg)
            .frame(height: DSLayout.readerAppleBooksMenuRowHeight)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func formattedPercent(_ value: Double) -> String {
        NumberFormatter.localizedString(
            from: NSNumber(value: min(max(value, 0), 1)),
            number: .percent
        )
    }

    private func progressAccessibilityValue(_ value: Double) -> String {
        let description = progressDescription(value)
        let percent = formattedPercent(value)
        return description.isEmpty ? percent : "\(percent), \(description)"
    }

    private func adjustProgress(_ direction: AccessibilityAdjustmentDirection) {
        let current = sliderDraft ?? progressValue()
        let delta: Double
        switch direction {
        case .increment:
            delta = DSLayout.readerAppleBooksProgressAccessibilityStep
        case .decrement:
            delta = -DSLayout.readerAppleBooksProgressAccessibilityStep
        @unknown default:
            return
        }
        let adjusted = AppleBooksProgressScrubber.clamped(current + delta)
        applyProgress(adjusted)
        sliderDraft = nil
    }

    private func closePanels() {
        withAnimation(panelAnimation) {
            activePanel = nil
            sliderDraft = nil
        }
    }

    private func performPanelAction(_ action: () -> Void) {
        closePanels()
        action()
    }
}

#Preview("Apple Books Reader Controls") {
    ZStack {
        ReaderTheme.white.backgroundColor
            .ignoresSafeArea()

        AppleBooksReaderControls(
            activePanel: .constant(.menu),
            progressValue: { 0.01 },
            applyProgress: { _ in },
            progressDescription: { _ in
                String(format: localized("第 %d 章"), 5)
            },
            secondaryActions: [
                AppleBooksReaderAction(
                    id: .playback,
                    icon: "headphones",
                    label: localized("聽書"),
                    action: {}
                ),
                AppleBooksReaderAction(
                    id: .download,
                    icon: "arrow.down.circle",
                    label: localized("下載"),
                    action: {}
                ),
                AppleBooksReaderAction(
                    id: .changeSource,
                    icon: "arrow.left.and.right",
                    label: localized("換源"),
                    action: {}
                ),
                AppleBooksReaderAction(
                    id: .refresh,
                    icon: "arrow.clockwise",
                    label: localized("刷新"),
                    action: {}
                )
            ],
            onOpenTOC: {},
            onOpenSearch: {},
            onOpenSettings: {}
        )
    }
}
