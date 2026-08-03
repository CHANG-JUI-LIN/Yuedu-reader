import SwiftUI

/// 查看詳情 — read-only summary of one book source.
///
/// Deliberately not an editor: it answers "why is this source behaving like this" without the
/// risk of a stray edit. Everything shown is derived from the stored `BookSource` plus the last
/// validation result, so it works offline and never re-fetches.
struct BookSourceInfoSheet: View {
    let source: BookSource
    let validation: SourceValidationSummary?

    @Environment(\.dismiss) private var dismiss

    private var sourceTypeText: String {
        switch source.bookSourceType {
        case 1: return localized("音頻")
        case 2: return localized("圖片")
        case 3: return localized("文件")
        default: return localized("文本")
        }
    }

    private var lastUpdateText: String? {
        guard source.lastUpdateTime > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(source.lastUpdateTime) / 1000)
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    infoRow(localized("書源名稱"), value: displayName)
                    infoRow(
                        localized("分組"),
                        value: source.bookSourceGroup.isEmpty
                            ? localized("默認分組") : source.bookSourceGroup)
                    infoRow(localized("網址"), value: source.bookSourceUrl, monospaced: true)
                    infoRow(localized("類型"), value: sourceTypeText)
                }
                .interfaceSectionSurface()

                Section {
                    infoRow(
                        localized("狀態"),
                        value: localized(source.enabled ? "已啟用" : "已停用"))
                    infoRow(
                        localized("支持發現"),
                        value: localized(supportsExplore ? "是" : "否"))
                    if let validation {
                        infoRow(localized("驗證結果"), value: validationText(validation))
                    }
                    infoRow(localized("響應時間"), value: "\(source.respondTime) ms")
                    if let lastUpdateText {
                        infoRow(localized("最後更新"), value: lastUpdateText)
                    }
                    if !source.concurrentRate.isEmpty {
                        infoRow(localized("併發限制"), value: source.concurrentRate)
                    }
                    if !source.loginUrl.isEmpty {
                        infoRow(localized("登入網址"), value: source.loginUrl, monospaced: true)
                    }
                }
                .interfaceSectionSurface()

                Section {
                    ruleRow(localized("搜索規則"), present: !source.searchUrl.isEmpty)
                    ruleRow(localized("發現規則"), present: !source.exploreUrl.isEmpty)
                    ruleRow(localized("詳情規則"), present: !source.ruleBookInfo.tocUrl.isEmpty)
                    ruleRow(localized("目錄規則"), present: !source.ruleToc.chapterList.isEmpty)
                    ruleRow(localized("正文規則"), present: !source.ruleContent.content.isEmpty)
                } header: {
                    Text(localized("規則"))
                }
                .interfaceSectionSurface()

                if !source.bookSourceComment.isEmpty {
                    Section {
                        Text(source.bookSourceComment)
                            .font(DSFont.subheadline)
                            .foregroundColor(DSColor.textSecondary)
                            .textSelection(.enabled)
                    } header: {
                        Text(localized("註釋"))
                    }
                    .interfaceSectionSurface()
                }

                if !source.variableComment.isEmpty {
                    Section {
                        Text(source.variableComment)
                            .font(DSFont.subheadline)
                            .foregroundColor(DSColor.textSecondary)
                            .textSelection(.enabled)
                    } header: {
                        Text(localized("源變量說明"))
                    }
                    .interfaceSectionSurface()
                }
            }
            .navigationTitle(localized("查看詳情"))
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

    private var displayName: String {
        source.bookSourceName.isEmpty ? localized("未命名書源") : source.bookSourceName
    }

    private var supportsExplore: Bool {
        source.enabledExplore
            && !source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func validationText(_ summary: SourceValidationSummary) -> String {
        let label: String
        switch summary.health {
        case .passed:       label = localized("驗證通過")
        case .fetchError:   label = localized("抓取異常")
        case .contentError: label = localized("正文異常")
        }
        return "\(label)・\(summary.responseMs) ms"
    }

    /// Label + value as one VoiceOver element, so a detail row is read as
    /// 「網址，https://…」 instead of two separate swipes.
    private func infoRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(label)
                .font(DSFont.caption)
                .foregroundColor(DSColor.textSecondary)
            Text(value)
                .font(monospaced ? DSFont.fixed(size: 13, design: .monospaced) : DSFont.subheadline)
                .foregroundColor(DSColor.textPrimary)
                .textSelection(.enabled)
        }
        .padding(.vertical, DSSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    private func ruleRow(_ label: String, present: Bool) -> some View {
        HStack {
            Text(label)
                .font(DSFont.subheadline)
            Spacer()
            Image(systemName: present ? "checkmark.circle.fill" : "minus.circle")
                .foregroundColor(present ? DSColor.success : DSColor.textSecondary.opacity(0.5))
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(localized(present ? "已設定" : "未設定"))
    }
}

#Preview {
    var source = BookSource()
    source.bookSourceName = "範例書源"
    source.bookSourceUrl = "https://example.com"
    source.bookSourceGroup = "小說"
    source.searchUrl = "https://example.com/search?q={{key}}"
    source.bookSourceComment = "這是一個範例書源的註釋。"
    return BookSourceInfoSheet(
        source: source,
        validation: SourceValidationSummary(health: .passed, responseMs: 320)
    )
}
