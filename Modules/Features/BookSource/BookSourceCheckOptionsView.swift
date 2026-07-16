import SwiftUI

/// Pre-run page (screenshot 1): explains the four validation stages, offers the
/// bad/slow-source policy under "更多選項", and starts the run. Presented from the
/// source list; the run itself continues in the background after dismissal.
struct BookSourceCheckOptionsView: View {
    let sourceCount: Int
    @State private var policy: BookSourceCheckPolicy
    let onStart: (BookSourceCheckPolicy) -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        sourceCount: Int,
        initialPolicy: BookSourceCheckPolicy,
        onStart: @escaping (BookSourceCheckPolicy) -> Void
    ) {
        self.sourceCount = sourceCount
        self._policy = State(initialValue: initialPolicy)
        self.onStart = onStart
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DSSpacing.xl) {
                    Spacer(minLength: DSSpacing.xl)

                    Image(systemName: "waveform.and.magnifyingglass")
                        .font(DSFont.fixed(size: 48))
                        .foregroundColor(DSColor.accent)

                    VStack(spacing: DSSpacing.sm) {
                        Text(localized("準備驗證"))
                            .font(DSFont.title2.weight(.bold))
                        Text(
                            "\(localized("將對")) \(sourceCount) \(localized("個書源進行四階段驗證"))"
                        )
                        .font(DSFont.subheadline)
                        .foregroundColor(DSColor.textSecondary)
                    }

                    stageCard

                    moreOptions

                    Button {
                        onStart(policy)
                        dismiss()
                    } label: {
                        HStack(spacing: DSSpacing.sm) {
                            Image(systemName: "play.fill")
                            Text(localized("開始驗證"))
                        }
                        .font(DSFont.bodyBold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DSSpacing.md)
                        .background(DSColor.accent)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(sourceCount == 0)

                    Text(localized("驗證包含網絡請求，可能需要較長時間，請耐心等待"))
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, DSSpacing.xl)
                .padding(.bottom, DSSpacing.xl)
            }
            .navigationTitle(localized("書源驗證"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("關閉"))
                }
            }
        }
    }

    private var stageCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            ForEach(ValidationStage.allCases) { stage in
                HStack(alignment: .top, spacing: DSSpacing.md) {
                    Image(systemName: stage.symbol)
                        .font(DSFont.body)
                        .foregroundColor(stageColor(stage))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stage \(stage.rawValue + 1) · \(stage.longTitle)")
                            .font(DSFont.bodyBold)
                        Text(stage.explanation)
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSSpacing.lg)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
    }

    private func stageColor(_ stage: ValidationStage) -> Color {
        switch stage {
        case .connectivity: return .blue
        case .booklist:     return .green
        case .detail:       return .orange
        case .content:      return .purple
        }
    }

    private var moreOptions: some View {
        DisclosureGroup {
            VStack(spacing: DSSpacing.md) {
                Picker(localized("壞書源處理"), selection: $policy.badAction) {
                    ForEach(BookSourceCheckPolicy.BadAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                .pickerStyle(.segmented)

                if policy.badAction == .delete {
                    Text(localized("刪除無法復原，請謹慎選擇"))
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Toggle(localized("停用過慢書源"), isOn: $policy.disableSlow)

                if policy.disableSlow {
                    Picker(localized("過慢閾值"), selection: $policy.slowThresholdMs) {
                        ForEach(BookSourceCheckPolicy.slowOptionsMs, id: \.self) { ms in
                            Text("\(ms / 1000) \(localized("秒"))").tag(ms)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(.top, DSSpacing.sm)
        } label: {
            Text(localized("更多選項"))
                .font(DSFont.subheadline.weight(.semibold))
                .foregroundColor(DSColor.textPrimary)
        }
        .padding(DSSpacing.md)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
    }
}

#Preview {
    BookSourceCheckOptionsView(
        sourceCount: 32,
        initialPolicy: BookSourceCheckPolicy()
    ) { _ in }
}
