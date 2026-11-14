import SwiftUI
import UIKit

// MARK: - Parameter rows

/// A module's parameters as form rows, written by name: a home section's own (its `篩選`), or the
/// module's `globalParams` on its page (format 3.0.2). A choice is a `Picker`, a count a
/// `Stepper`, typed text is kept once the reader is done with it, and an `input` with
/// `placeholders` offers them in a menu. A choice that follows 中繼資料語言偏好推薦 offers that
/// first, and picking it again clears the reader's own. Only the parameters their `belongTo`
/// shows are drawn: the caller passes those.
struct RuleModuleParameterRows: View {
    let params: [RuleModule.Param]
    let values: [String: String]
    /// A value by the parameter's name; nil goes back to the module's default.
    let set: (String, String?) -> Void
    /// The accessibility identifier's prefix (`homeSection.parameter`).
    let identifier: String
    @ObservedObject private var aggregation = AggregationSettingsStore.shared

    init(params: [RuleModule.Param], values: [String: String], identifier: String,
         set: @escaping (String, String?) -> Void) {
        self.params = params
        self.values = values
        self.identifier = identifier
        self.set = set
    }

    /// The picker's tag for following 中繼資料語言偏好推薦: no option's value.
    private static let followsLanguageTag = "\u{1F}followsLanguage"

    var body: some View {
        ForEach(params, id: \.name) { param in
            let title = param.title ?? param.name
            let value = param.currentValue(in: values, language: aggregation.readingLanguages.language)
            switch param.kind {
            case .enumeration:
                let follows = param.followsLanguage == true
                let selection = follows && values[param.name] == nil ? Self.followsLanguageTag : value
                Picker(title, selection: Binding(get: { selection }, set: { picked in
                    set(param.name, picked == Self.followsLanguageTag ? nil : picked)
                })) {
                    if follows {
                        Text(localized("跟隨中繼資料語言偏好推薦")).tag(Self.followsLanguageTag)
                    }
                    ForEach(param.enumOptions ?? [], id: \.value) { option in
                        Text(option.title).tag(option.value)
                    }
                }
                .accessibilityIdentifier("\(identifier).\(param.name)")
            case .count:
                let count = Int(value) ?? 1
                let binding = Binding(get: { count }, set: { set(param.name, String($0)) })
                Stepper(value: binding, in: 1...max(100, count)) {
                    LabeledContent(title, value: String(count))
                }
                .accessibilityStepper(title, value: binding, in: 1...max(100, count), valueText: String(count))
                .accessibilityIdentifier("\(identifier).\(param.name)")
            default:
                RuleModuleTextParameter(title: title, committed: value, placeholders: param.placeholders ?? [],
                                        identifier: "\(identifier).\(param.name)") { set(param.name, $0) }
            }
        }
    }
}

/// An `input` parameter. Kept on submit or when the field loses focus, never on each keystroke:
/// every value written reloads the preview with a real request. Its `placeholders` (format 3.0.2)
/// are in a menu beside the field; one picked is kept at once.
private struct RuleModuleTextParameter: View {
    let title: String
    let committed: String
    let placeholders: [RuleModule.Placeholder]
    let identifier: String
    let commit: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: DSSpacing.sm) {
                TextField(title, text: $text)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit(save)
                    .accessibilityIdentifier(identifier)
                if !placeholders.isEmpty {
                    Menu {
                        ForEach(Array(placeholders.enumerated()), id: \.offset) { _, placeholder in
                            Button(placeholder.title) {
                                text = placeholder.value
                                save()
                            }
                        }
                    } label: {
                        Label(String(format: localized("%@的建議"), title), systemImage: "text.badge.plus")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityIdentifier("\(identifier).placeholders")
                }
            }
        }
        .onAppear { text = committed }
        .onChange(of: committed) { _, value in if !focused { text = value } }
        .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
    }

    private func save() {
        guard text != committed else { return }
        commit(text.isEmpty ? nil : text)
    }
}

// MARK: - The module's own settings

/// A module's `globalParams` on its page (format 3.0.2, maintainer 2026-11-14: set once on the
/// module's page): every list, search, lookup and review request of the module sends them.
struct RuleModuleGlobalSettingsSection: View {
    let module: RuleModule
    @ObservedObject var library: RuleModuleLibrary

    var body: some View {
        let globals = module.globalParams ?? []
        let values = library.globalValues[module.id] ?? [:]
        let shown = globals.filter { [.input, .count, .enumeration].contains($0.kind) }
        let current = RuleModule.Param.currentValues(of: globals, in: values, language: nil)
        let visible = shown.filter { $0.isShown(among: current) }
        if !visible.isEmpty {
            Section {
                // A parameter's `value` is the reader's own only where `values` has it too, so
                // each row shows the reader's value, else the file's default.
                RuleModuleParameterRows(params: visible, values: values, identifier: "module.setting") { name, value in
                    library.setGlobalValue(value, name: name, id: module.id)
                }
            } header: {
                Text(localized("模組：設定"))
            } footer: {
                Text(localized("套用到這個模組的所有欄目、搜尋、補資料和評論。")).dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
    }
}

// MARK: - Icon

/// A module's `icon` (format 3.0.2), from its own hosts and under its `rateLimit` as its covers
/// are; the symbol every module shares while it loads, and when it has none or it cannot be read.
struct RuleModuleIcon: View {
    let module: RuleModule
    /// Drawn without an icon, and while it loads.
    var fallback: String = "puzzlepiece.extension"
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
            } else {
                Image(systemName: fallback)
            }
        }
        .accessibilityHidden(true)
        .task(id: module.icon) { image = await RuleModuleIconCache.shared.image(for: module) }
    }
}

/// `RuleModuleIcon` in a square that grows with Dynamic Type: a header's, a row's.
struct RuleModuleSizedIcon: View {
    let module: RuleModule
    @ScaledMetric private var side: CGFloat

    init(module: RuleModule, base: CGFloat, relativeTo style: Font.TextStyle = .body) {
        self.module = module
        _side = ScaledMetric(wrappedValue: base, relativeTo: style)
    }

    var body: some View {
        RuleModuleIcon(module: module).frame(width: side, height: side)
    }
}

/// The icons read this launch, by address: a module's picture is drawn on several screens and
/// each would otherwise ask its site again.
@MainActor
final class RuleModuleIconCache {
    static let shared = RuleModuleIconCache()
    private let images = NSCache<NSString, UIImage>()
    private var loading: [String: Task<UIImage?, Never>] = [:]

    func image(for module: RuleModule, client: RuleModuleClient = RuleModuleClient()) async -> UIImage? {
        guard let address = module.icon?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else { return nil }
        if let image = images.object(forKey: address as NSString) { return image }
        if let task = loading[address] { return await task.value }
        let task = Task { () -> UIImage? in
            do {
                return try await client.image(address, in: module).flatMap(UIImage.init(data:))
            } catch {
                AppLogger.network("module icon not read", error: SourceFailure.loggable(error),
                                  context: ["module": module.id, "url": address])
                return nil
            }
        }
        loading[address] = task
        let image = await task.value
        loading[address] = nil
        if let image { images.setObject(image, forKey: address as NSString) }
        return image
    }
}

#Preview("A module's settings") {
    NavigationStack {
        Form {
            RuleModuleParameterRows(params: [
                RuleModule.Param(name: "lang", title: "語言", type: "enumeration", value: "zh",
                                 enumOptions: [.init(title: "中文", value: "zh"), .init(title: "日本語", value: "ja")]),
                RuleModule.Param(name: "tag", title: "標籤", type: "input",
                                 placeholders: [.init(title: "科幻", value: "sf"), .init(title: "推理", value: "mystery")]),
            ], values: [:], identifier: "preview") { _, _ in }
        }
        .navigationTitle("模組")
        .toolbarTitleDisplayMode(.inline)
    }
}
