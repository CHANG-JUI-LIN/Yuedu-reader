import SwiftUI

/// 整章翻譯's controls for the book being read: how translations show, into which language,
/// and where the chapter on screen stands.
struct ReaderTranslationSheet: View {
    @Binding var presentation: ReaderTranslationPresentation
    let bookID: UUID
    /// The chapter on screen and its own text, when it is laid out.
    let chapter: Int
    let chapterText: String?
    /// Translates what the chapter on screen is missing (and retries a failed run).
    let onTranslateChapter: () -> Void
    @ObservedObject private var service = AIChapterTranslationService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsClear = false
    @State private var clearError: String?

    private var currentChapter: AIChapterTranslationService.Chapter {
        .init(book: bookID, spine: chapter, language: presentation.language)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(localized("顯示方式"), selection: $presentation.mode) {
                        Text(localized("狀態：關閉")).tag(ReaderTranslationPresentation.Mode.off)
                        Text(localized("雙語對照")).tag(ReaderTranslationPresentation.Mode.bilingual)
                        Text(localized("只看譯文")).tag(ReaderTranslationPresentation.Mode.translationOnly)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text(localized("顯示方式"))
                        .foregroundStyle(DSColor.textSecondary)
                }
                .interfaceSectionSurface()

                if presentation.isActive {
                    Section {
                        Picker(localized("翻譯成"), selection: $presentation.language) {
                            ForEach(AIAnswerLanguage.allCases) { Text($0.displayName).tag($0) }
                        }
                    }
                    .interfaceSectionSurface()
                    chapterSection
                    serviceSection
                }

                Section {
                    Button(localized("清除本書譯文"), role: .destructive) { confirmsClear = true }
                } footer: {
                    if let clearError {
                        Text(clearError).dsSectionFooter()
                    }
                }
                .interfaceSectionSurface()
            }
            .softScrollEdges()
            .themedAppSurface(for: .settings)
            .navigationTitle(localized("整章翻譯"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(localized("關閉"))
                }
            }
            .confirmationDialog(localized("清除本書的所有譯文？"), isPresented: $confirmsClear, titleVisibility: .visible) {
                Button(localized("清除譯文"), role: .destructive) { clear() }
                Button(localized("取消"), role: .cancel) {}
            } message: {
                Text(localized("譯文會刪除，翻譯也會關閉；之後再開啟要重新翻譯。"))
            }
        }
    }

    @ViewBuilder private var chapterSection: some View {
        Section {
            switch service.runs[currentChapter] {
            case let .running(completed, total):
                ProgressView(value: Double(completed), total: Double(max(total, 1))) {
                    Text(localized("翻譯中…"))
                        .foregroundStyle(DSColor.textPrimary)
                } currentValueLabel: {
                    Text(verbatim: "\(completed)/\(total)")
                        .foregroundStyle(DSColor.textSecondary)
                }
            case .finished:
                Label(localized("本章已翻譯"), systemImage: "checkmark.circle")
                    .foregroundStyle(DSColor.textPrimary)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(DSColor.destructive)
                Button(localized("重試"), action: onTranslateChapter)
            case nil:
                if let chapterText {
                    if service.pendingBatchCount(book: bookID, language: presentation.language, text: chapterText) == 0 {
                        Label(localized("本章已翻譯"), systemImage: "checkmark.circle")
                            .foregroundStyle(DSColor.textPrimary)
                    } else {
                        Button(localized("翻譯本章"), action: onTranslateChapter)
                    }
                } else {
                    Text(localized("本章還在載入"))
                        .foregroundStyle(DSColor.textSecondary)
                }
            }
        } header: {
            Text(localized("本章"))
                .foregroundStyle(DSColor.textSecondary)
        }
        .interfaceSectionSurface()
    }

    @ViewBuilder private var serviceSection: some View {
        switch service.service() {
        case let .success(active):
            Section {
                ThemedLabeledContent(localized("生成服務"), value: active.name)
                ThemedLabeledContent(localized("生成模型"), value: active.model)
            } footer: {
                Text(localized("會翻譯你讀到的章節和下一章，約每 2,000 字一次模型呼叫；原文、劃線與閱讀進度不受影響。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        case let .failure(reason):
            Section {
                Text(reason.message)
                    .foregroundStyle(DSColor.textSecondary)
                NavigationLink(localized("AI 助手設定")) { AISettingsView(embedded: true) }
            }
            .interfaceSectionSurface()
        }
    }

    private func clear() {
        presentation.mode = .off
        Task {
            do {
                try await service.clear(book: bookID)
                clearError = nil
            } catch {
                AppLogger.error("Clearing a book's translations failed", error: error, context: ["book": bookID.uuidString])
                clearError = error.localizedDescription
            }
        }
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        ReaderTranslationSheet(presentation: .constant(.init(mode: .bilingual, language: .traditionalChinese)),
                               bookID: UUID(), chapter: 0, chapterText: "It was a bright cold day in April.",
                               onTranslateChapter: {})
    }
}
