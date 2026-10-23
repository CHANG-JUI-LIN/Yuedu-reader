import SwiftUI
import UIKit

/// 氣泡設定: what the reader draws for a source's review marks — the 段評 count bubble and
/// the 本章說 / 作者說 / 神評論 cards, each on its own page with its own styles.
struct ReaderCommentBubbleSettingsView: View {
    @Bindable private var settings = GlobalSettings.shared
    /// Hands a 匯入樣式 to whoever owns the first-level document picker
    /// (`ReaderSettingsView.requestStyleImporter`); nil hides 匯入.
    var onOpenImporter: ((ReaderStyleImportRoute) -> Void)?

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ReaderParagraphBubbleSettingsView(onOpenImporter: onOpenImporter.map { open in
                        { open(.commentBubble) }
                    })
                } label: {
                    SettingsValueLabel(
                        title: localized("段評氣泡"),
                        systemImage: ReadingSettingsScopeItem.commentBubble.systemImage,
                        value: bubbleValue
                    )
                }

                ForEach(ReaderCommentCardKind.allCases) { kind in
                    NavigationLink {
                        ReaderCommentCardSettingsView(kind: kind, onOpenImporter: onOpenImporter.map { open in
                            { open(.commentCard(kind)) }
                        })
                    } label: {
                        SettingsValueLabel(
                            title: kind.localizedTitle,
                            systemImage: kind.systemImage,
                            value: cardValue(kind)
                        )
                    }
                }
            } footer: {
                Text(localized("內建「玻璃」的本章說與神評論字級固定、作者說隨閱讀字級縮放；自訂模板跟隨閱讀字體與字級。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .navigationTitle(localized("氣泡設定"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
    }

    private var bubbleValue: String {
        guard !settings.commentBubbleFollowsSourceSVG else { return localized("來源樣式") }
        switch settings.commentBubblePresetMode {
        case .builtin, .square:
            return localized(settings.commentBubblePresetMode.titleKey)
        case .custom:
            let name = settings.commentBubbleCustomStyleName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? localized("自訂 SVG") : name
        }
    }

    private func cardValue(_ kind: ReaderCommentCardKind) -> String {
        switch settings.wornCommentCardTemplate(for: kind) {
        case nil: return localized("來源樣式")
        case .builtin: return localized("玻璃")
        case .custom(let style): return style.name
        }
    }
}

#Preview {
    NavigationStack {
        ReaderCommentBubbleSettingsView(onOpenImporter: { _ in })
    }
}
