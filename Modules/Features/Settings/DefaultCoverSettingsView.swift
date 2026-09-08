import SwiftUI
import UIKit

/// 預設封面 — what a book without its own cover shows.
///
/// Legado keeps one default cover per appearance; this keeps a small library and
/// picks one per book (deterministically, see `DefaultCoverLibrary`), so a shelf
/// of coverless books doesn't turn into the same picture repeated. With the
/// library empty the book falls through to `GeneratedBookCover`.
struct DefaultCoverSettingsView: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @State private var importErrorMessage: String?

    private var cornerRadiusText: String {
        String(format: localized("%d pt"), Int(settings.bookshelfCoverCornerRadius.rounded()))
    }

    var body: some View {
        Form {
            Section {
                Toggle(
                    localized("強制使用預設封面"),
                    isOn: $settings.useDefaultCoverForAllBooks
                )
            } footer: {
                Text(localized("開啟後所有書籍都使用預設封面，忽略書籍自帶的封面圖。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            Section {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    HStack {
                        Text(localized("封面圓角"))
                        Spacer()
                        Text(cornerRadiusText)
                            .font(DSFont.subheadline)
                            .foregroundStyle(DSColor.textSecondary)
                            // The slider below speaks this value; read on its own
                            // it is just a loose number.
                            .accessibilityHidden(true)
                    }
                    Slider(
                        value: $settings.bookshelfCoverCornerRadius,
                        in: GlobalSettings.bookshelfCoverCornerRadiusRange,
                        step: 1
                    )
                    // A Slider has no label of its own and would otherwise
                    // announce a bare percentage of its range.
                    .accessibilityLabel(localized("封面圓角"))
                    .accessibilityValue(cornerRadiusText)
                }
                .padding(.vertical, DSSpacing.xs)
            } footer: {
                Text(localized("用於書架卡片中的封面裁切，不影響卡片背景圓角。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            Section {
                Toggle(
                    localized("探索頁啟用預設封面"),
                    isOn: $settings.exploreUsesDefaultCover
                )
            } footer: {
                Text(localized("開啟後，探索頁中沒有封面的書卡也使用隨機預設封面圖（列表和網格均生效）。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            Section {
                Toggle(
                    localized("封面顯示書名"),
                    isOn: $settings.defaultCoverDrawsBookName
                )
                Toggle(
                    localized("封面顯示作者"),
                    isOn: $settings.defaultCoverDrawsBookAuthor
                )
            } header: {
                Text(localized("自動生成的封面"))
            } footer: {
                Text(localized("沒有封面的書會自動生成一張，這裡決定要不要把書名和作者直排寫上去。你自己匯入的封面圖不受影響。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            coverLibrarySection(for: .light)
            coverLibrarySection(for: .dark)
        }
        .navigationTitle(localized("預設封面"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .alert(
            localized("封面匯入失敗"),
            isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { if !$0 { importErrorMessage = nil } }
            )
        ) {
            Button(localized("確定"), role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private func coverLibrarySection(for scheme: DefaultCoverScheme) -> some View {
        let fileNames = settings.defaultCoverFileNames(for: scheme)

        Section {
            if fileNames.isEmpty {
                Text(
                    scheme == .dark
                        ? localized("暫無深色封面，未設置時使用亮色封面")
                        : localized("暫無封面，點擊下方按鈕添加")
                )
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DSSpacing.md) {
                        ForEach(fileNames, id: \.self) { fileName in
                            coverThumbnail(fileName: fileName, scheme: scheme)
                        }
                    }
                    .padding(.vertical, DSSpacing.xs)
                }
            }

            ImageSourcePickerButton(
                accessibilityTitle: scheme == .dark
                    ? localized("添加深色封面圖")
                    : localized("添加封面圖"),
                onPick: { result in handlePick(result, for: scheme) }
            ) {
                Label(
                    scheme == .dark ? localized("添加深色封面圖") : localized("添加封面圖"),
                    systemImage: "photo.badge.plus"
                )
            }
        } header: {
            Text(scheme.title)
        } footer: {
            Text(
                scheme == .dark
                    ? localized("深色模式下優先使用這裡的封面，未設置時跟隨亮色封面。")
                    : localized("書籍沒有封面時隨機使用其中一張作為預設封面。")
            )
            .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    @ViewBuilder
    private func coverThumbnail(fileName: String, scheme: DefaultCoverScheme) -> some View {
        let image = DefaultCoverLibrary.image(fileName: fileName)

        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    // The file is gone (deleted outside the app, failed restore):
                    // show the slot as broken rather than an invisible gap.
                    Rectangle().fill(DSColor.neutralControlFill)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundStyle(DSColor.textSecondary)
                                .accessibilityHidden(true)
                        )
                }
            }
            .frame(
                width: DSLayout.searchResultCoverWidth,
                height: DSLayout.searchResultCoverHeight
            )
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                    .stroke(DSColor.textSecondary.opacity(0.2), lineWidth: 0.5)
            )

            Button(role: .destructive) {
                settings.removeDefaultCover(fileName: fileName, for: scheme)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(DSFont.fixed(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, DSColor.destructive)
            }
            .buttonStyle(.plain)
            .padding(DSSpacing.xs)
            .accessibilityLabel(localized("移除這張封面"))
        }
    }

    private func handlePick(
        _ result: Result<PickedImageSource, PickedImageError>,
        for scheme: DefaultCoverScheme
    ) {
        do {
            switch result {
            case .success(.data(let data)):
                try settings.importDefaultCover(data: data, for: scheme)
            case .success(.file(let url)):
                try settings.importDefaultCover(from: url, for: scheme)
            case .failure(let error):
                importErrorMessage = localized(error.messageKey)
            }
        } catch let error as DefaultCoverStorageError {
            importErrorMessage = localized(error.messageKey)
        } catch {
            importErrorMessage = localized("無法讀取圖片。")
        }
    }
}

#Preview {
    NavigationStack {
        DefaultCoverSettingsView()
    }
}
