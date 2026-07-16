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

/// Stats card + failure-filter chips shown at the top of the book-source list.
/// Counts come from the last validation run; before any run the failure chips read 0.
struct SourceValidationListHeader: View {
    let sources: [BookSource]
    let healthById: [UUID: SourceValidationSummary]
    @Binding var filter: ValidationListFilter

    private var enabledCount: Int { sources.filter(\.enabled).count }
    private var discoverCount: Int {
        sources.filter {
            $0.enabledExplore
                && !$0.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    private func healthCount(_ health: SourceHealth) -> Int {
        sources.filter { healthById[$0.id]?.health == health }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            statsCard
            filterChips
        }
        .padding(.vertical, DSSpacing.sm)
    }

    private var statsCard: some View {
        VStack(spacing: 0) {
            statRow(
                icon: "checkmark.circle.fill",
                title: localized("已啟用"),
                value: "\(enabledCount) / \(sources.count)"
            )
            Divider()
            statRow(icon: "safari.fill", title: localized("支持發現"), value: "\(discoverCount)")
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.xs)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
    }

    private func statRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: icon)
                .foregroundColor(DSColor.accent)
            Text(title)
                .font(DSFont.subheadline)
            Spacer()
            Text(value)
                .font(DSFont.subheadline)
                .foregroundColor(DSColor.textSecondary)
                .monospacedDigit()
        }
        .padding(.vertical, DSSpacing.sm)
    }

    private var filterChips: some View {
        HStack(spacing: DSSpacing.sm) {
            chip(.all, label: localized("全部"), count: sources.count)
            chip(.fetchError, label: localized("抓取異常"), count: healthCount(.fetchError))
            chip(.contentError, label: localized("正文異常"), count: healthCount(.contentError))
            Spacer(minLength: 0)
        }
    }

    private func chip(_ value: ValidationListFilter, label: String, count: Int) -> some View {
        let selected = filter == value
        return Button {
            filter = value
        } label: {
            Text("\(label) \(count)")
                .font(DSFont.subheadline.weight(selected ? .semibold : .regular))
                .foregroundColor(selected ? .white : DSColor.textSecondary)
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.sm)
                .background(selected ? DSColor.accent : Color(.secondarySystemBackground))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
