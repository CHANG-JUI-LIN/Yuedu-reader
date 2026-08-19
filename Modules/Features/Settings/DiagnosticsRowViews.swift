import SwiftUI

// MARK: - Why these are their own View structs
//
// `List` defers a child view's `body`; it does NOT defer construction of the view
// value a `ForEach` closure returns, and it calls that closure for every element.
// The book-source list learned this the expensive way — 3000 rows built up front,
// ~1.4 s of blocked main thread (see `BookSourceRowViews.swift`). A diagnostics log
// is the same shape: thousands of rows, each with expandable detail. Anything more
// than a couple of views inside a row belongs in a `View` struct.

/// One log line. Tapping expands the detail, which is where call stacks and position
/// trails live.
struct DiagnosticEntryRow: View {
    let entry: DiagnosticEntry
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private var hasDetail: Bool { !(entry.detail ?? "").isEmpty }

    private var timeText: String { Self.timeFormatter.string(from: entry.timestamp) }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                // Severity is carried by symbol + colour + the text below, never by
                // colour alone (design.md H6).
                Image(systemName: entry.severity.symbolName)
                    .font(DSFont.footnote)
                    .foregroundStyle(Self.tint(for: entry.severity))
                    .accessibilityHidden(true)

                Text(entry.message)
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(isExpanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: DSSpacing.sm) {
                Text(entry.severity.localizedName)
                    .foregroundStyle(Self.tint(for: entry.severity))
                Text(entry.category.localizedName)
                Text(timeText)
                    .monospacedDigit()
                Spacer(minLength: 0)
                if hasDetail {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .accessibilityHidden(true)
                }
            }
            .font(DSFont.caption)
            .foregroundStyle(DSColor.textSecondary)

            if isExpanded, let detail = entry.detail, !detail.isEmpty {
                Text(detail)
                    .font(DSFont.monospaced(size: 11))
                    .foregroundStyle(DSColor.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, DSSpacing.xs)
            }
        }
        .padding(.vertical, DSSpacing.xs)
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasDetail else { return }
            // A `DSAnimation` token alone does not satisfy Reduce Motion — the branch
            // has to remove the animation, not just shorten it (design.md §7).
            if reduceMotion {
                isExpanded.toggle()
            } else {
                withAnimation(DSAnimation.fast) { isExpanded.toggle() }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.severity.localizedName)，\(entry.category.localizedName)，\(timeText)")
        .accessibilityValue(isExpanded ? "\(entry.message)。\(entry.detail ?? "")" : entry.message)
        .accessibilityHint(hasDetail ? localized("點兩下展開詳細內容") : "")
        .accessibilityAddTraits(hasDetail ? .isButton : [])
    }

    private static func tint(for severity: DiagnosticSeverity) -> Color {
        switch severity {
        case .trace, .info:  return DSColor.textSecondary
        case .notice:        return DSColor.accent
        case .warning:       return DSColor.warning
        case .error:         return DSColor.destructive
        case .anomaly, .fault: return DSColor.destructive
        }
    }
}

/// A previous launch that ended while the user was looking at the app.
struct DiagnosticCrashSessionRow: View {
    let session: DiagnosticSession

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(Self.formatter.string(from: session.startedAt))
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textPrimary)
            Text("\(session.appVersion) (\(session.build)) · \(session.deviceModel)")
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
        }
        .padding(.vertical, DSSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}

/// The "something went wrong, please tell us" banner.
///
/// Only shown when there is an anomaly or fault to report. It is the one place the
/// app asks the user for something, so it stays quiet the rest of the time.
struct DiagnosticAnomalyBanner: View {
    let count: Int

    var body: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DSFont.title3)
                .foregroundStyle(DSColor.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(String(format: localized("偵測到 %d 個非預期行為"), count))
                    .font(DSFont.bodyBold)
                    .foregroundStyle(DSColor.textPrimary)
                Text(localized("這些是 app 沒有照自己的規則運作的地方。匯出後傳給開發者，就能知道發生了什麼。"))
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, DSSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}
