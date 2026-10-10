import SwiftUI

/// Which validation outcome the book-source list is filtered to.
enum ValidationListFilter: Hashable { case all, fetchError, contentError }

/// Row badge: last validation verdict + total time, shown under the source URL.
struct SourceValidationBadge: View {
    let summary: SourceValidationSummary?

    var body: some View {
        if let summary {
            HStack(spacing: DSSpacing.xs) {
                HStack(spacing: 3) {
                    Image(systemName: icon(summary.health))
                        .font(DSFont.fixed(size: 10))
                    Text(label(summary.health))
                        .font(DSFont.caption2.weight(.semibold))
                }
                .foregroundColor(color(summary.health))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color(summary.health).opacity(0.14))
                .clipShape(Capsule())

                Text("\(summary.responseMs)ms")
                    .font(DSFont.caption2)
                    .foregroundColor(DSColor.textSecondary.opacity(0.8))
                    .monospacedDigit()
            }
            .padding(.top, 2)
        }
    }

    private func label(_ health: SourceHealth) -> String {
        switch health {
        case .passed:       return localized("驗證通過")
        case .fetchError:   return localized("抓取異常")
        case .contentError: return localized("正文異常")
        }
    }

    private func icon(_ health: SourceHealth) -> String {
        switch health {
        case .passed:       return "checkmark.circle.fill"
        case .fetchError:   return "exclamationmark.triangle.fill"
        case .contentError: return "doc.text.fill"
        }
    }

    private func color(_ health: SourceHealth) -> Color {
        switch health {
        case .passed:       return DSColor.success
        case .fetchError:   return DSColor.warning
        case .contentError: return DSColor.warning
        }
    }
}

/// Stats card + page buttons shown at the top of the book-source list.
/// Counts are computed by `BookSourceManagementModel` once per library or validation
/// change — this used to scan every source four times per render, trimming each
/// `exploreUrl` on the way. Before any run the failure pages read 0.
struct SourceValidationListHeader: View {
    let counts: BookSourceManagementModel.Counts
    @Binding var filter: ValidationListFilter
    /// Grouped ⇄ flat layout switch, parked at the trailing end of the page buttons.
    @Binding var grouped: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            statsCard
            pageButtons
        }
        .padding(.vertical, DSSpacing.sm)
    }

    private var statsCard: some View {
        VStack(spacing: 0) {
            statRow(
                icon: "checkmark.circle.fill",
                title: localized("已啟用"),
                value: "\(counts.enabled) / \(counts.total)"
            )
            Divider()
            statRow(icon: "safari.fill", title: localized("支持發現"), value: "\(counts.discover)")
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.xs)
        // The card carries its own surface so it follows 毛玻璃／分組卡片／透明度 like the
        // rows below it. A hardcoded `secondarySystemBackground` here was opaque at every
        // setting, which is what made the header read as a solid slab above a see-through
        // list. `clipShape` stays for the `Divider`, which is content rather than surface.
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
    }

    private func statRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: icon)
                .foregroundColor(DSColor.accent)
            Text(title)
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textPrimary)
            Spacer()
            Text(value)
                .font(DSFont.subheadline)
                .foregroundColor(DSColor.textSecondary)
                .monospacedDigit()
        }
        .padding(.vertical, DSSpacing.sm)
    }

    /// 全部／抓取異常／正文異常 as system glass buttons. Each one is a page: switching
    /// clears the selection, and the bottom bar's 全選 counts only the page on screen.
    /// The buttons keep their natural width and scroll sideways once a large count
    /// (「全部 50,000」), a longer language or an accessibility text size makes them wider
    /// than the row — instead of wrapping into circles or truncating their counts.
    private var pageButtons: some View {
        HStack(spacing: DSSpacing.sm) {
            ScrollView(.horizontal) {
                SourceFilterButtonGroup {
                    pageButtonRow
                }
                // Room for the glass edge inside the scroll view's clip.
                .padding(.vertical, DSSpacing.xs)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            groupingToggle
        }
    }

    private var pageButtonRow: some View {
        HStack(spacing: DSSpacing.sm) {
            pageButton(.all, label: localized("全部"), count: counts.total)
            pageButton(.fetchError, label: localized("抓取異常"), count: counts.fetchError)
            pageButton(.contentError, label: localized("正文異常"), count: counts.contentError)
        }
    }

    /// Grouped ⇄ flat toggle. Icon-only, so the symbol is hidden from VoiceOver and the
    /// button carries the name itself — an `accessibilityLabel` alone would be shadowed by
    /// the SF Symbol's own element (docs/design.md §7.1).
    private var groupingToggle: some View {
        Button {
            grouped.toggle()
        } label: {
            Image(systemName: grouped ? "list.bullet.indent" : "list.bullet")
                .font(DSFont.subheadline)
                .foregroundColor(grouped ? DSColor.accent : DSColor.textSecondary)
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("來源配置排列方式"))
        .accessibilityValue(localized(grouped ? "分組顯示" : "不分組"))
        .accessibilityHint(localized("點兩下切換分組與不分組"))
    }

    /// A system button with a text label. The label keeps one weight in both states, so
    /// choosing a page never changes the buttons' widths.
    private func pageButton(_ value: ValidationListFilter, label: String, count: Int) -> some View {
        let selected = filter == value
        return Button {
            filter = value
        } label: {
            Text("\(label) \(count)")
                .font(DSFont.subheadline)
                .monospacedDigit()
                .lineLimit(1)
        }
        .sourceFilterButtonStyle(selected: selected)
        // VoiceOver could not tell which page was showing: the selected state was color only.
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Filter buttons
//
// One look for the book-source filter choices: 書源管理's 全部／抓取異常／正文異常 pages
// and 書源驗證's four 失敗類型細分 tiles.

/// Holds a row of filter buttons. iOS 26 blends neighbouring glass shapes only inside
/// one container; earlier systems just lay the buttons out.
struct SourceFilterButtonGroup<Content: View>: View {
    var spacing: CGFloat = DSSpacing.sm
    @ViewBuilder let content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    /// The selected choice: prominent (tinted) glass; the others: plain glass. Before
    /// iOS 26 the system bordered styles are the same pair of controls without the
    /// material.
    @ViewBuilder
    func sourceFilterButtonStyle(selected: Bool, shape: ButtonBorderShape = .capsule) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if selected {
                buttonStyle(.glassProminent).buttonBorderShape(shape).tint(DSColor.accent)
            } else {
                buttonStyle(.glass).buttonBorderShape(shape)
            }
        } else {
            legacySourceFilterButtonStyle(selected: selected, shape: shape)
        }
        #else
        legacySourceFilterButtonStyle(selected: selected, shape: shape)
        #endif
    }

    @ViewBuilder
    private func legacySourceFilterButtonStyle(selected: Bool, shape: ButtonBorderShape) -> some View {
        if selected {
            buttonStyle(.borderedProminent).buttonBorderShape(shape).tint(DSColor.accent)
        } else {
            buttonStyle(.bordered).buttonBorderShape(shape)
        }
    }
}

#Preview {
    @Previewable @State var filter: ValidationListFilter = .all
    @Previewable @State var grouped = true
    SourceValidationListHeader(
        counts: BookSourceManagementModel.Counts(
            total: 29, enabled: 29, discover: 27, fetchError: 3, contentError: 1),
        filter: $filter,
        grouped: $grouped
    )
    .padding()
}
