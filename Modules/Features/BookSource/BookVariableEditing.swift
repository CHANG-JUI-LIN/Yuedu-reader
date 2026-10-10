import SwiftUI

// MARK: - Legado book / source variables
//
// Legado (original, legado-E, MD3 alike) offers 設置源變量 and 設置書籍變量 wherever a
// book has a source: the source variable is free text a source's JS reads through
// `source.getVariable()`; the book variable is free text stored under the book's
// `custom` variable, read through `book.getVariable("custom")`. Saving refreshes
// nothing — the source reads the value on its next fetch. The detail pages and the
// reader both edit through this one implementation.

/// The book variable Legado edits: one free-text value, `book.getVariable("custom")`,
/// leaving every other key the source wrote untouched. A book's runtime-variable map keeps
/// each Legado book variable under `book.variable.<name>`; that prefix is what the parser
/// hands to `book.getVariable` (`ModernParserBridge.setBookContext`), so a bare `custom`
/// key would never reach the source.
enum BookCustomVariable {
    static let key = "book.variable.custom"

    static func value(in variables: [String: String]?) -> String {
        variables?[key] ?? ""
    }

    /// `variables` with `custom` set to `value`, or removed when `value` is empty.
    static func merged(_ value: String, into variables: [String: String]?) -> [String: String]? {
        var map = variables ?? [:]
        if value.isEmpty {
            map.removeValue(forKey: key)
        } else {
            map[key] = value
        }
        return map.isEmpty ? nil : map
    }

    /// The source author's `variableComment` above Legado's own hint.
    static func comment(source: BookSource?) -> String {
        SourceVariableEditing.displayComment(
            source: source,
            hint: localized("書籍變量可在 JS 中通過 book.getVariable(\"custom\") 取得")
        )
    }
}

enum SourceVariableEditing {
    static func currentValue(for source: BookSource) -> String {
        BookSourceRuntimeStateStore.shared.sourceVariableJSON(for: source.bookSourceUrl) ?? ""
    }

    static func save(_ value: String, for source: BookSource) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        BookSourceRuntimeStateStore.shared.setUserSourceVariableJSON(
            trimmed.isEmpty ? nil : trimmed,
            for: source.bookSourceUrl
        )
    }

    static func comment(source: BookSource) -> String {
        displayComment(
            source: source,
            hint: localized("源變量可在 JS 中通過 source.getVariable() 取得")
        )
    }

    /// Legado's `getDisplayVariableComment`: the source's own comment, then the hint.
    static func displayComment(source: BookSource?, hint: String) -> String {
        let own = source?.variableComment.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return own.isEmpty ? hint : "\(own)\n\(hint)"
    }
}

// MARK: - Editors

extension View {
    /// 設置源變量 / 設置書籍變量 sheets for a page that shows one book of `source`.
    func bookVariableEditors(
        source: BookSource?,
        showsSourceVariable: Binding<Bool>,
        showsBookVariable: Binding<Bool>,
        bookVariable: @escaping () -> String,
        onSaveBookVariable: @escaping (String) -> Void
    ) -> some View {
        self
            .sheet(isPresented: showsSourceVariable) {
                if let source {
                    RuntimeVariableEditorView(
                        title: localized("設置源變量"),
                        comment: SourceVariableEditing.comment(source: source),
                        initialValue: SourceVariableEditing.currentValue(for: source)
                    ) { value in
                        SourceVariableEditing.save(value, for: source)
                        return nil
                    }
                }
            }
            .sheet(isPresented: showsBookVariable) {
                RuntimeVariableEditorView(
                    title: localized("設置書籍變量"),
                    comment: BookCustomVariable.comment(source: source),
                    initialValue: bookVariable()
                ) { value in
                    onSaveBookVariable(value)
                    return nil
                }
            }
    }
}

/// The detail page's 「更多」 menu: the variable editors Legado's book page offers.
///
/// Before iOS 18 a `Menu` can drop the sheet its action asks for while the menu is still
/// dismissing (Technotes/iOS17MenuModalPresentation.md), so there the control is a plain
/// button that opens the chooser the screen attaches with `bookDetailMoreChooser`.
struct BookDetailMoreMenu: View {
    let hasSource: Bool
    let onSetSourceVariable: () -> Void
    let onSetBookVariable: () -> Void
    /// Before iOS 18: shows the screen's `bookDetailMoreChooser`.
    let onOpenChooser: () -> Void
    /// The items a source that listens for events adds (legado `SourceCallBack`).
    var sourceActions: BookDetailSourceMenuActions? = nil

    var body: some View {
        Group {
            if MenuModalPresentationPolicy.requiresDismissalSequencedChooser {
                Button(action: onOpenChooser) { label }
            } else {
                Menu {
                    if let sourceActions {
                        ForEach(sourceActions.items) { item in
                            Button(action: item.perform) {
                                Label(item.title, systemImage: item.systemImage)
                            }
                        }
                    }
                    Button(action: onSetSourceVariable) {
                        Label(localized("設置源變量"), systemImage: "curlybraces")
                    }
                    Button(action: onSetBookVariable) {
                        Label(localized("設置書籍變量"), systemImage: "character.book.closed")
                    }
                } label: {
                    label
                }
            }
        }
        // Legado shows both only while the book has a source.
        .disabled(!hasSource)
    }

    private var label: some View {
        Label(localized("更多"), systemImage: "ellipsis")
            .labelStyle(.iconOnly)
    }
}

/// What legado's book page menu offers a source that listens for events: its custom button
/// (only with `customButton`), share, copy the book and TOC URLs, clear the cache. Each goes
/// to the source's `callBackJs` first and falls back to the action itself.
struct BookDetailSourceMenuActions {
    struct Item: Identifiable {
        let route: BookDetailMoreRoute
        let title: String
        let systemImage: String
        let perform: () -> Void
        var id: BookDetailMoreRoute { route }
    }

    var showsCustomButton: Bool
    var onCustomButton: () -> Void
    var onShare: () -> Void
    var onCopyBookURL: () -> Void
    var onCopyTOCURL: () -> Void
    var onClearCache: () -> Void

    var items: [Item] {
        var items: [Item] = []
        if showsCustomButton {
            items.append(Item(route: .customButton, title: localized("自訂按鈕"),
                              systemImage: "hand.tap", perform: onCustomButton))
        }
        items += [
            Item(route: .share, title: localized("分享"), systemImage: "square.and.arrow.up", perform: onShare),
            Item(route: .copyBookURL, title: localized("複製書籍網址"), systemImage: "link", perform: onCopyBookURL),
            Item(route: .copyTOCURL, title: localized("複製目錄網址"), systemImage: "list.bullet", perform: onCopyTOCURL),
            Item(route: .clearCache, title: localized("清除快取"), systemImage: "trash", perform: onClearCache),
        ]
        return items
    }
}

enum BookDetailMoreRoute: Hashable {
    case sourceVariable
    case bookVariable
    case customButton
    case share
    case copyBookURL
    case copyTOCURL
    case clearCache
}

extension View {
    /// The iOS 17 stand-in for `BookDetailMoreMenu`'s menu: a chooser sheet whose choice
    /// opens its editor only once the chooser has actually gone.
    func bookDetailMoreChooser(
        isPresented: Binding<Bool>,
        onSetSourceVariable: @escaping () -> Void,
        onSetBookVariable: @escaping () -> Void,
        sourceActions: BookDetailSourceMenuActions? = nil
    ) -> some View {
        modifier(BookDetailMoreChooser(
            isPresented: isPresented,
            onSetSourceVariable: onSetSourceVariable,
            onSetBookVariable: onSetBookVariable,
            sourceActions: sourceActions
        ))
    }
}

private struct BookDetailMoreChooser: ViewModifier {
    @Binding var isPresented: Bool
    let onSetSourceVariable: () -> Void
    let onSetBookVariable: () -> Void
    let sourceActions: BookDetailSourceMenuActions?

    @State private var sequence = DismissalSequencedPresentation<BookDetailMoreRoute>()

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: openChosenEditor) {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableCompactWidth) {
                DismissalSequencedActionChooser(
                    title: localized("更多"),
                    actions: (sourceActions?.items ?? []).map {
                        DismissalSequencedAction(route: $0.route, title: $0.title, systemImage: $0.systemImage)
                    } + [
                        DismissalSequencedAction(
                            route: .sourceVariable,
                            title: localized("設置源變量"),
                            systemImage: "curlybraces"
                        ),
                        DismissalSequencedAction(
                            route: .bookVariable,
                            title: localized("設置書籍變量"),
                            systemImage: "character.book.closed"
                        ),
                    ],
                    onSelect: { sequence.select($0) }
                )
            }
        }
    }

    private func openChosenEditor() {
        switch sequence.consumeAfterDismissal() {
        case .sourceVariable: onSetSourceVariable()
        case .bookVariable: onSetBookVariable()
        case let route?:
            sourceActions?.items.first { $0.route == route }?.perform()
        case nil: break
        }
    }
}
