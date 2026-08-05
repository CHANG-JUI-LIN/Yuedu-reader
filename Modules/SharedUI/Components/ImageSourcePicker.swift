import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// What an image pick produced.
///
/// The two cases stay distinct rather than collapsing to `Data` because the
/// storage managers key their output extension off the source file name, and a
/// Photos pick has no file name to key off.
enum PickedImageSource {
    /// A photo-library pick, already loaded into memory.
    case data(Data)
    /// A Files pick. The URL's security scope is open for the duration of the
    /// callback only — read or copy it there, don't stash the URL.
    case file(URL)
}

/// Why an image pick produced nothing. Surfaced instead of swallowed so each
/// screen can show its own import-failure alert.
enum PickedImageError: Error {
    case cannotReadPhoto
    case cannotOpenFile(Error)

    var messageKey: String {
        switch self {
        case .cannotReadPhoto, .cannotOpenFile:
            return "無法讀取圖片。"
        }
    }
}

/// An extra row shown alongside 從相簿選擇 / 從檔案選擇 — in practice 移除, which
/// belongs in the same control as the thing it removes.
struct ImageSourcePickerAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    var isDestructive: Bool = false
    let action: () -> Void

    init(
        title: String,
        systemImage: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isDestructive = isDestructive
        self.action = action
    }
}

enum ImageSourcePicker {
    /// The image formats every importer in the app accepts. Kept here so the
    /// four import screens can't drift apart on what they'll open.
    static let contentTypes: [UTType] = [
        UTType(filenameExtension: "webp") ?? .data,
        UTType(filenameExtension: "jpg") ?? .jpeg,
        UTType(filenameExtension: "jpeg") ?? .jpeg,
        .png,
    ]
}

/// One control offering both 從相簿選擇 and 從檔案選擇 for a single image slot.
///
/// Every image the user can import — 頁面背景、啟動圖、閱讀背景、頭像 — goes through
/// this, so a slot can never end up offering only one of the two sources.
///
/// Two presentation paths, for the reason documented in
/// `Technotes/iOS17MenuModalPresentation.md`: on iOS 18+ this is a native
/// `Menu`, but on iOS 17 a menu action can lose the photo-picker / document-picker
/// presentation while the menu's UIKit controller is still dismissing, so the
/// choice is taken in a real sheet and the destination is launched from that
/// sheet's `onDismiss`. No timing workaround. Collapse to the `Menu` branch when
/// the deployment target reaches iOS 18.
struct ImageSourcePickerButton<LabelContent: View>: View {
    private enum Route: Hashable {
        case photos
        case files
        case extra(Int)
    }

    /// Spoken name of the control (the label is usually just "選擇" or an icon).
    let accessibilityTitle: String
    var contentTypes: [UTType] = ImageSourcePicker.contentTypes
    var extraActions: [ImageSourcePickerAction] = []
    let onPick: (Result<PickedImageSource, PickedImageError>) -> Void
    let label: () -> LabelContent

    @State private var isShowingPhotos = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isShowingFiles = false
    @State private var isShowingChooser = false
    @State private var sequence = DismissalSequencedPresentation<Route>()

    init(
        accessibilityTitle: String,
        contentTypes: [UTType] = ImageSourcePicker.contentTypes,
        extraActions: [ImageSourcePickerAction] = [],
        onPick: @escaping (Result<PickedImageSource, PickedImageError>) -> Void,
        @ViewBuilder label: @escaping () -> LabelContent
    ) {
        self.accessibilityTitle = accessibilityTitle
        self.contentTypes = contentTypes
        self.extraActions = extraActions
        self.onPick = onPick
        self.label = label
    }

    var body: some View {
        trigger
            .accessibilityLabel(accessibilityTitle)
            .photosPicker(
                isPresented: $isShowingPhotos,
                selection: $photoItem,
                matching: .images
            )
            .fileImporter(
                isPresented: $isShowingFiles,
                allowedContentTypes: contentTypes,
                allowsMultipleSelection: false,
                onCompletion: handleFileImport
            )
            .sheet(isPresented: $isShowingChooser, onDismiss: runSequencedRoute) {
                DismissalSequencedActionChooser(
                    title: accessibilityTitle,
                    actions: chooserActions,
                    onSelect: { sequence.select($0) }
                )
            }
            .onChange(of: photoItem) { _, item in
                loadPhoto(item)
            }
    }

    @ViewBuilder
    private var trigger: some View {
        if MenuModalPresentationPolicy.requiresDismissalSequencedChooser {
            Button {
                // A stale pending route would fire on the next dismissal.
                sequence.cancel()
                isShowingChooser = true
            } label: {
                label()
            }
        } else {
            Menu {
                Button {
                    isShowingPhotos = true
                } label: {
                    Label(localized("從相簿選擇"), systemImage: "photo.on.rectangle")
                }
                Button {
                    isShowingFiles = true
                } label: {
                    Label(localized("從檔案選擇"), systemImage: "folder")
                }
                ForEach(extraActions) { extra in
                    Button(role: extra.isDestructive ? .destructive : nil) {
                        extra.action()
                    } label: {
                        Label(extra.title, systemImage: extra.systemImage)
                    }
                }
            } label: {
                label()
            }
        }
    }

    private var chooserActions: [DismissalSequencedAction<Route>] {
        var actions: [DismissalSequencedAction<Route>] = [
            DismissalSequencedAction(
                route: .photos,
                title: localized("從相簿選擇"),
                systemImage: "photo.on.rectangle"
            ),
            DismissalSequencedAction(
                route: .files,
                title: localized("從檔案選擇"),
                systemImage: "folder"
            ),
        ]
        for (index, extra) in extraActions.enumerated() {
            actions.append(
                DismissalSequencedAction(
                    route: .extra(index),
                    title: extra.title,
                    systemImage: extra.systemImage,
                    isDestructive: extra.isDestructive
                )
            )
        }
        return actions
    }

    private func runSequencedRoute() {
        guard let route = sequence.consumeAfterDismissal() else { return }
        switch route {
        case .photos:
            isShowingPhotos = true
        case .files:
            isShowingFiles = true
        case .extra(let index):
            guard extraActions.indices.contains(index) else { return }
            extraActions[index].action()
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task { @MainActor in
            defer { photoItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                onPick(.failure(.cannotReadPhoto))
                return
            }
            onPick(.success(.data(data)))
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            // An empty selection is a cancel, not a failure.
            guard let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            onPick(.success(.file(url)))
        case .failure(let error):
            onPick(.failure(.cannotOpenFile(error)))
        }
    }
}

extension ImageSourcePickerButton where LabelContent == ImageSourcePickerCapsuleLabel {
    /// The capsule "選擇 ⌄" affordance used next to an image thumbnail.
    init(
        accessibilityTitle: String,
        contentTypes: [UTType] = ImageSourcePicker.contentTypes,
        extraActions: [ImageSourcePickerAction] = [],
        onPick: @escaping (Result<PickedImageSource, PickedImageError>) -> Void
    ) {
        self.init(
            accessibilityTitle: accessibilityTitle,
            contentTypes: contentTypes,
            extraActions: extraActions,
            onPick: onPick,
            label: {
                ImageSourcePickerCapsuleLabel(
                    showsChevron: !MenuModalPresentationPolicy.requiresDismissalSequencedChooser
                )
            }
        )
    }
}

/// Capsule label for `ImageSourcePickerButton`. The chevron is only drawn for
/// the `Menu` path — on the iOS 17 sheet path the control is a plain button.
struct ImageSourcePickerCapsuleLabel: View {
    var title: String = localized("選擇")
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            Text(title)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(DSFont.caption2.weight(.semibold))
                    // Decorative: VoiceOver would otherwise read the raw symbol
                    // name as its own element (docs/design.md §7.1).
                    .accessibilityHidden(true)
            }
        }
        .font(DSFont.subheadline.weight(.medium))
        .foregroundStyle(DSColor.accent)
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.xs)
        .background(DSColor.accent.opacity(0.12), in: Capsule())
    }
}

#Preview("Capsule") {
    ImageSourcePickerButton(
        accessibilityTitle: localized("亮色背景圖"),
        extraActions: [
            ImageSourcePickerAction(
                title: localized("移除背景圖"),
                systemImage: "trash",
                isDestructive: true,
                action: {}
            )
        ],
        onPick: { _ in }
    )
    .padding()
}

#Preview("Row") {
    Form {
        ImageSourcePickerButton(
            accessibilityTitle: localized("選擇圖片"),
            onPick: { _ in }
        ) {
            Label(localized("選擇圖片"), systemImage: "photo")
        }
    }
}
