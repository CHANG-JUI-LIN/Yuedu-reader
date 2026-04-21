import SwiftUI
import Combine

// MARK: - ReadingStatsView

struct ReadingStatsView: View {
    @ObservedObject private var store = ReadingStatsStore.shared
    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPeriod: Period = .today

    // MARK: - Period

    enum Period: Int, CaseIterable {
        case today, week, month, all

        func localizedLabel(gs: GlobalSettings) -> String {
            switch self {
            case .today: return gs.t("今日")
            case .week:  return gs.t("本週")
            case .month: return gs.t("本月")
            case .all:   return gs.t("全部")
            }
        }

        func dateRange() -> (from: Date, to: Date) {
            let cal = Calendar.current
            let now = Date()
            switch self {
            case .today:
                return (cal.startOfDay(for: now), now)
            case .week:
                let start = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? now
                return (start, now)
            case .month:
                let comps = cal.dateComponents([.year, .month], from: now)
                let start = cal.date(from: comps) ?? now
                return (start, now)
            case .all:
                return (Date.distantPast, now)
            }
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                periodPicker
                ScrollView {
                    VStack(spacing: DSSpacing.lg) {
                        summarySection
                        barChartSection
                        topBooksSection
                    }
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.vertical, DSSpacing.lg)
                }
            }
            .background(DSColor.groupedBackground.ignoresSafeArea())
            .navigationTitle(gs.t("閱讀統計"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(DSColor.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - Period Picker

    private var periodPicker: some View {
        Picker(gs.t("時間範圍"), selection: $selectedPeriod) {
            ForEach(Period.allCases, id: \.rawValue) { period in
                Text(period.localizedLabel(gs: gs)).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.md)
        .background(DSColor.background)
    }

    // MARK: - Filtered Sessions

    private var filteredSessions: [ReadingSession] {
        let range = selectedPeriod.dateRange()
        return store.sessionsInRange(from: range.from, to: range.to)
    }

    // MARK: - Summary Section

    private var summarySection: some View {
        HStack(spacing: DSSpacing.md) {
            summaryCard(
                icon: "clock.fill",
                title: gs.t("閱讀時長"),
                value: formatDuration(store.totalDuration(in: filteredSessions))
            )
            summaryCard(
                icon: "text.alignleft",
                title: gs.t("閱讀字數"),
                value: "\(store.totalCharacters(in: filteredSessions))"
            )
        }
    }

    private func summaryCard(icon: String, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(spacing: DSSpacing.xs) {
                Image(systemName: icon)
                    .foregroundColor(DSColor.accent)
                    .font(DSFont.caption)
                Text(title)
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
            }
            Text(value)
                .font(DSFont.headline)
                .foregroundColor(DSColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(DSSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
    }

    // MARK: - Bar Chart Section

    private var barChartSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text(gs.t("每日閱讀（分鐘）"))
                .font(DSFont.subheadline)
                .foregroundColor(DSColor.textSecondary)

            let data = dailyMinutes()
            let maxVal = data.map { $0.minutes }.max() ?? 1
            let chartHeight: CGFloat = 120

            HStack(alignment: .bottom, spacing: DSSpacing.xs) {
                ForEach(data.indices, id: \.self) { i in
                    let entry = data[i]
                    let barHeight = maxVal > 0
                        ? chartHeight * CGFloat(entry.minutes) / CGFloat(maxVal)
                        : 2
                    VStack(spacing: DSSpacing.xs) {
                        Rectangle()
                            .fill(DSColor.accent.opacity(0.8))
                            .frame(height: max(2, barHeight))
                            .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm))
                        Text(entry.label)
                            .font(DSFont.caption2)
                            .foregroundColor(DSColor.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: chartHeight + 24)
        }
        .padding(DSSpacing.md)
        .background(DSColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
    }

    private struct DayEntry {
        let label: String
        let minutes: Int
    }

    private func dailyMinutes() -> [DayEntry] {
        let cal = Calendar.current
        let sessions = filteredSessions

        switch selectedPeriod {
        case .today:
            let hours = Array(0..<24)
            return hours.map { h -> DayEntry in
                let secs = sessions.filter { s in
                    cal.component(.hour, from: s.startDate) == h
                }.reduce(0) { $0 + $1.duration }
                return DayEntry(label: "\(h)", minutes: Int(secs / 60))
            }.filter { $0.minutes > 0 || true }
            .enumerated()
            .compactMap { idx, e -> DayEntry? in
                idx % 4 == 0 ? e : DayEntry(label: "", minutes: e.minutes)
            }

        case .week:
            guard let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) else { return [] }
            return (0..<7).map { offset -> DayEntry in
                let day = cal.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
                let secs = sessions.filter { cal.isDate($0.startDate, inSameDayAs: day) }
                    .reduce(0) { $0 + $1.duration }
                let fmt = DateFormatter()
                fmt.dateFormat = "E"
                return DayEntry(label: fmt.string(from: day), minutes: Int(secs / 60))
            }

        case .month:
            let comps = cal.dateComponents([.year, .month], from: Date())
            guard let monthStart = cal.date(from: comps),
                  let range2 = cal.range(of: .day, in: .month, for: monthStart) else { return [] }
            let days = range2.count
            return (0..<days).map { offset -> DayEntry in
                let day = cal.date(byAdding: .day, value: offset, to: monthStart) ?? monthStart
                let secs = sessions.filter { cal.isDate($0.startDate, inSameDayAs: day) }
                    .reduce(0) { $0 + $1.duration }
                let d = offset + 1
                let label = (d == 1 || d % 7 == 0) ? "\(d)" : ""
                return DayEntry(label: label, minutes: Int(secs / 60))
            }

        case .all:
            var byMonth: [String: Int] = [:]
            let fmt = DateFormatter()
            fmt.dateFormat = "MM/yy"
            for s in sessions {
                let key = fmt.string(from: s.startDate)
                byMonth[key, default: 0] += Int(s.duration / 60)
            }
            if byMonth.isEmpty { return [] }
            return byMonth.sorted { $0.key < $1.key }
                .map { DayEntry(label: $0.key, minutes: $0.value) }
        }
    }

    // MARK: - Top Books Section

    private var topBooksSection: some View {
        let books = store.topBooks(limit: 5, sessions: filteredSessions)
        return VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text(gs.t("閱讀最多"))
                .font(DSFont.subheadline)
                .foregroundColor(DSColor.textSecondary)

            if books.isEmpty {
                Text(gs.t("暫無資料"))
                    .font(DSFont.body)
                    .foregroundColor(DSColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DSSpacing.md)
            } else {
                ForEach(books.indices, id: \.self) { i in
                    let book = books[i]
                    HStack {
                        Text("\(i + 1)")
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                            .frame(width: 20, alignment: .center)
                        Text(book.bookTitle)
                            .font(DSFont.body)
                            .foregroundColor(DSColor.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(formatDuration(book.duration))
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                    if i < books.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding(DSSpacing.md)
        .background(DSColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return gs.t("\(hours) 小時 \(minutes) 分鐘")
        } else {
            return gs.t("\(minutes) 分鐘")
        }
    }
}
