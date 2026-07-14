import SwiftUI
import UIKit

struct ReaderOverlayFontPickerView: View {
    @Binding var selection: ReaderOverlayFontReference

    let readerFont: UIFont
    let importedFonts: [UserFontInfo]

    var body: some View {
        List {
            Section {
                fontRow(
                    title: localized("系統字體"),
                    reference: ReaderOverlayFontReference(kind: .system),
                    previewFont: DSFont.body
                )
                .listRowBackground(DSColor.surface)
                fontRow(
                    title: localized("目前閱讀字體"),
                    reference: ReaderOverlayFontReference(kind: .reader),
                    previewFont: Font(readerFont)
                )
                .listRowBackground(DSColor.surface)
            }

            Section(localized("已匯入字體")) {
                if importedFonts.isEmpty {
                    Text(localized("尚未匯入字體"))
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.textSecondary)
                        .listRowBackground(DSColor.surface)
                } else {
                    ForEach(importedFonts) { font in
                        fontRow(
                            title: font.displayName,
                            reference: ReaderOverlayFontReference(
                                kind: .imported,
                                postScriptName: font.postScriptName
                            ),
                            previewFont: previewFont(postScriptName: font.postScriptName)
                        )
                        .listRowBackground(DSColor.surface)
                    }
                }
            }

            if let missingPostScriptName {
                Section(localized("目前設定")) {
                    Label(
                        String(
                            format: localized(
                                "找不到字體「%@」，目前使用系統字體。重新匯入後會自動恢復。"
                            ),
                            missingPostScriptName
                        ),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.warning)
                    .accessibilityElement(children: .combine)
                    .listRowBackground(DSColor.surface)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(localized("字體"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface()
    }

    private func fontRow(
        title: String,
        reference: ReaderOverlayFontReference,
        previewFont: Font
    ) -> some View {
        let isSelected = selection.normalized == reference.normalized
        return Button {
            selection = reference
        } label: {
            HStack(spacing: DSSpacing.md) {
                Text(title)
                    .font(previewFont)
                    .foregroundStyle(DSColor.textPrimary)
                Spacer(minLength: DSSpacing.sm)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(DSColor.accent)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: DSLayout.readerAppleBooksControlSize)
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func previewFont(postScriptName: String) -> Font {
        let pointSize = UIFont.preferredFont(forTextStyle: .body).pointSize
        return Font(UIFont(name: postScriptName, size: pointSize) ?? UIFont.preferredFont(forTextStyle: .body))
    }

    private var missingPostScriptName: String? {
        guard selection.kind == .imported,
              let name = selection.postScriptName,
              !isAvailable(postScriptName: name) else {
            return nil
        }
        return name
    }

    private func isAvailable(postScriptName: String) -> Bool {
        importedFonts.contains(where: { $0.postScriptName == postScriptName })
            && UIFont(
                name: postScriptName,
                size: UIFont.preferredFont(forTextStyle: .body).pointSize
            ) != nil
    }
}

#Preview {
    NavigationStack {
        ReaderOverlayFontPickerView(
            selection: .constant(ReaderOverlayFontReference(kind: .system)),
            readerFont: UIFont.preferredFont(forTextStyle: .body),
            importedFonts: []
        )
    }
}
