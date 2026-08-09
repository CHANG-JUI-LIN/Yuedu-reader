import Combine
import Foundation
import UIKit

@MainActor
final class RegexHighlightRuleEditorModel: ObservableObject {
    let original: RegexHighlightRule

    @Published var isEnabled: Bool
    @Published var name: String
    @Published var pattern: String
    @Published var options: RegexHighlightOptions
    @Published var lightStyle: ReaderStyleRuleStyle
    @Published var darkStyle: ReaderStyleRuleStyle
    @Published var testText: String
    @Published private(set) var matches: [NSRange] = []
    @Published private(set) var regexError: RegexHighlightError?
    @Published private(set) var cssError: ReaderStyleCSSCodecError?
    @Published private(set) var saveError: Error?
    @Published private(set) var isFinished = false

    private let onSave: (RegexHighlightRule) throws -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(
        rule: RegexHighlightRule,
        testText: String = "“Sample dialogue”\n「範例對話」",
        onSave: @escaping (RegexHighlightRule) throws -> Void
    ) {
        original = rule
        isEnabled = rule.isEnabled
        name = rule.name
        pattern = rule.pattern
        options = rule.options
        lightStyle = rule.lightStyle
        darkStyle = rule.darkStyle
        self.testText = testText
        self.onSave = onSave

        Publishers.CombineLatest3($pattern, $options, $testText)
            .debounce(for: .milliseconds(180), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.refreshMatches()
            }
            .store(in: &cancellables)

        refreshMatches()
    }

    var isBuiltIn: Bool { original.isBuiltIn }

    func refreshMatches() {
        let rule = draftRule()
        do {
            _ = try RegexHighlightEngine.compile(rule)
            let result = try RegexHighlightEngine.evaluate(
                text: testText,
                rules: [rule],
                appearance: .light
            )
            matches = result.segments.map(\.range)
            regexError = nil
        } catch let error as RegexHighlightError {
            matches = []
            regexError = error
        } catch {
            matches = []
            regexError = .invalidPattern(ruleID: rule.id, message: error.localizedDescription)
        }
    }

    @discardableResult
    func applyCSS(
        _ source: String,
        appearance: ReaderStyleAppearance
    ) -> Bool {
        do {
            let decoded = try ReaderStyleCSSCodec.decodeDeclarations(
                source,
                context: .regexHighlight
            )
            switch appearance {
            case .light:
                lightStyle = decoded
            case .dark:
                darkStyle = decoded
            }
            cssError = nil
            return true
        } catch let error as ReaderStyleCSSCodecError {
            cssError = error
            return false
        } catch {
            cssError = .malformedDeclaration(line: 1, column: 1)
            return false
        }
    }

    func encodedCSS(for appearance: ReaderStyleAppearance) -> String {
        ReaderStyleCSSCodec.encodeDeclarations(
            appearance == .light ? lightStyle : darkStyle,
            context: .regexHighlight
        )
    }

    func previewAttributedString(
        appearance: ReaderStyleAppearance
    ) throws -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: testText,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label,
            ]
        )
        _ = try RegexHighlightEngine.apply(
            configuration: RegexHighlightConfiguration(
                isEnabled: true,
                rules: [draftRule()],
                customRules: []
            ),
            appearance: appearance,
            to: attributed
        )
        return attributed
    }

    @discardableResult
    func removeAssetReferences(assetID: UUID) -> Bool {
        guard !isFinished else { return false }
        if lightStyle.decoration.backgroundImage?.assetID == assetID {
            lightStyle.decoration.backgroundImage = nil
        }
        if darkStyle.decoration.backgroundImage?.assetID == assetID {
            darkStyle.decoration.backgroundImage = nil
        }
        return true
    }

    /// Forced deletion commits the reference-free rule before removing bytes.
    /// If store deletion fails, the previous rule is restored, so persisted
    /// settings never point at an asset that has already disappeared.
    @discardableResult
    func deleteAsset(
        id: UUID,
        store: ReaderStyleAssetStore = .shared
    ) async -> Bool {
        guard !isFinished else { return false }
        let previousLight = lightStyle
        let previousDark = darkStyle
        _ = removeAssetReferences(assetID: id)
        let updated = draftRule().sanitized()
        do {
            _ = try RegexHighlightEngine.compile(updated)
            try onSave(updated)
            try await store.delete(id, removingReferences: true)
            saveError = nil
            return true
        } catch {
            lightStyle = previousLight
            darkStyle = previousDark
            // The asset still exists when deletion throws. Restore the saved
            // configuration best-effort; surface either failure to the editor.
            do {
                try onSave(draftRule().sanitized())
                saveError = error
            } catch {
                saveError = error
            }
            return false
        }
    }

    @discardableResult
    func save() -> Bool {
        guard !isFinished else { return false }
        regexError = nil
        saveError = nil
        let result = draftRule().sanitized()
        do {
            _ = try RegexHighlightEngine.compile(result)
            regexError = nil
            try onSave(result)
            saveError = nil
            isFinished = true
            return true
        } catch let error as RegexHighlightError {
            regexError = error
            saveError = nil
            return false
        } catch {
            regexError = nil
            saveError = error
            return false
        }
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
    }

    private func draftRule() -> RegexHighlightRule {
        RegexHighlightRule(
            id: original.id,
            name: original.isBuiltIn ? original.name : name,
            pattern: original.isBuiltIn ? original.pattern : pattern,
            isEnabled: isEnabled,
            isBuiltIn: original.isBuiltIn,
            options: options,
            lightStyle: lightStyle,
            darkStyle: darkStyle
        )
    }
}
