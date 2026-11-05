import SwiftUI

/// Edits one TXT chapter rule, previewing the chapters it finds as it is typed: in its own
/// example, or in a TXT book on the shelf. A rule whose regex does not compile cannot be
/// saved; the error shows under the field.
struct TXTTocRuleEditView: View {
    /// What the preview reads.
    enum PreviewSource: Hashable {
        case example
        case book(UUID)
    }

    private struct PreviewResult: Equatable {
        var titles: [String] = []
        var failure: String?
    }

    let original: TXTTocRule
    let books: [ReadingBook]
    let onSave: (TXTTocRule) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var chapterRule: String
    @State private var volumeRule: String
    @State private var example: String
    @State private var enabled: Bool
    @State private var previewSource: PreviewSource = .example
    @State private var preview = PreviewResult()
    @State private var isPreviewing = false
    @State private var loadedBook: (id: UUID, file: TXTMappedTextFile)?

    /// The preview lists this many titles, then the count of the rest.
    private static let previewLimit = 100

    init(rule: TXTTocRule, books: [ReadingBook], onSave: @escaping (TXTTocRule) -> Void) {
        original = rule
        self.books = books
        self.onSave = onSave
        _name = State(initialValue: TXTTocRuleDefaults.displayName(of: rule))
        _chapterRule = State(initialValue: rule.chapterRule)
        _volumeRule = State(initialValue: rule.volumeRule)
        _example = State(initialValue: rule.example ?? "")
        _enabled = State(initialValue: rule.enable)
    }

    private var draft: TXTTocRule {
        var rule = original
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.name = TXTTocRuleDefaults.storedName(trimmedName.isEmpty ? localized("未命名規則") : trimmedName,
                                                  for: original.id)
        rule.chapterRule = chapterRule
        rule.volumeRule = volumeRule
        rule.example = example.isEmpty ? nil : example
        rule.enable = enabled
        return rule
    }

    private var compileError: TXTTocRuleError? {
        do {
            _ = try draft.compiled()
            return nil
        } catch let error as TXTTocRuleError {
            return error
        } catch {
            return .invalidRegex(field: .chapter, message: error.localizedDescription)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(localized("名稱"), text: $name)
                    Toggle(localized("啟用"), isOn: $enabled)
                }
                .interfaceSectionSurface()

                Section {
                    regexField(localized("章節正則"), text: $chapterRule)
                } header: {
                    Text(localized("章節正則")).foregroundStyle(DSColor.textSecondary)
                } footer: {
                    if case .invalidRegex(.chapter, _)? = compileError {
                        errorFooter
                    } else if compileError == .emptyChapterRule, !chapterRule.isEmpty {
                        errorFooter
                    }
                }
                .interfaceSectionSurface()

                Section {
                    regexField(localized("選填"), text: $volumeRule)
                } header: {
                    Text(localized("分卷正則")).foregroundStyle(DSColor.textSecondary)
                } footer: {
                    if case .invalidRegex(.volume, _)? = compileError {
                        errorFooter
                    } else {
                        Text(localized("分卷標題只在緊接著章節標題時才成為一章。"))
                            .dsSectionFooter()
                    }
                }
                .interfaceSectionSurface()

                Section {
                    TextField(localized("範例文字"), text: $example, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text(localized("範例")).foregroundStyle(DSColor.textSecondary)
                }
                .interfaceSectionSurface()

                previewSection
            }
            .softScrollEdges()
            .navigationTitle(localized(original.chapterRule.isEmpty ? "新增分章規則" : "編輯分章規則"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(localized("取消"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onSave(draft)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(localized("儲存"))
                    .disabled(compileError != nil)
                }
            }
            .task(id: PreviewKey(chapterRule: chapterRule, volumeRule: volumeRule, example: example,
                                 source: previewSource)) {
                await refreshPreview()
            }
        }
    }

    private func regexField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text, axis: .vertical)
            .font(DSFont.callout.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lineLimit(1...6)
    }

    private var errorFooter: some View {
        Text(compileError?.localizedMessage ?? "")
            .font(DSFont.footnote)
            .foregroundStyle(DSColor.destructive)
    }

    @ViewBuilder
    private var previewSection: some View {
        Section {
            Picker(localized("預覽內容"), selection: $previewSource) {
                Text(localized("範例文字")).tag(PreviewSource.example)
                ForEach(books) { book in
                    Text(book.title).tag(PreviewSource.book(book.id))
                }
            }
            if isPreviewing {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(localized("正在預覽"))
            } else if let failure = preview.failure {
                Text(failure).foregroundStyle(DSColor.textSecondary)
            } else if preview.titles.isEmpty {
                Text(localized("沒有找到章節")).foregroundStyle(DSColor.textSecondary)
            } else {
                ForEach(Array(preview.titles.prefix(Self.previewLimit).enumerated()), id: \.offset) { _, title in
                    Text(title)
                        .foregroundStyle(DSColor.textPrimary)
                        .lineLimit(1)
                }
            }
        } header: {
            Text(localized("預覽")).foregroundStyle(DSColor.textSecondary)
        } footer: {
            if !isPreviewing, preview.failure == nil, !preview.titles.isEmpty {
                Text(previewCountText).dsSectionFooter()
            }
        }
        .interfaceSectionSurface()
    }

    private var previewCountText: String {
        let count = preview.titles.count
        if count > Self.previewLimit {
            return String(format: localized("找到 %d 章，顯示前 %d 章。"), count, Self.previewLimit)
        }
        return String(format: localized("找到 %d 章。"), count)
    }

    private struct PreviewKey: Hashable {
        let chapterRule: String
        let volumeRule: String
        let example: String
        let source: PreviewSource
    }

    private func refreshPreview() async {
        var rule = draft
        rule.enable = true
        do {
            _ = try rule.compiled()
        } catch let error as TXTTocRuleError {
            preview = PreviewResult(failure: localized(error == .emptyChapterRule ? "輸入章節正則後顯示預覽" : "正則有誤，無法預覽"))
            return
        } catch {
            preview = PreviewResult(failure: localized("正則有誤，無法預覽"))
            return
        }
        isPreviewing = true
        defer { isPreviewing = false }
        let source = previewSource
        let exampleText = example
        let cached = loadedBook
        let bookURL: URL? = {
            guard case .book(let id) = source, let book = books.first(where: { $0.id == id }) else { return nil }
            return StorageLocations.bookFile(book.contentFilename)
        }()
        let result: Result<(titles: [String], file: (UUID, TXTMappedTextFile)?), any Error> = await Task.detached(priority: .userInitiated) {
            do {
                let ruleSet = TXTTocRuleSet(rules: [rule])
                switch source {
                case .example:
                    let file = TXTMappedTextFile(data: Data(exampleText.utf8), encoding: .utf8)
                    return .success((TXTChapterParser.previewTitles(in: file, rules: ruleSet), nil))
                case .book(let id):
                    let file: TXTMappedTextFile
                    if let cached, cached.id == id {
                        file = cached.file
                    } else if let bookURL {
                        file = try TXTFileReader.readMappedTextFile(url: bookURL)
                    } else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    return .success((TXTChapterParser.previewTitles(in: file, rules: ruleSet), (id, file)))
                }
            } catch {
                return .failure(error)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let value):
            if let file = value.file { loadedBook = (file.0, file.1) }
            preview = PreviewResult(titles: value.titles)
        case .failure(let error):
            AppLogger.error("TXT chapter rule preview could not read the book", error: error)
            preview = PreviewResult(failure: localized("無法讀取這本書"))
        }
    }
}

#Preview {
    TXTTocRuleEditView(rule: TXTTocRuleDefaults.rules[0], books: []) { _ in }
}
