import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Pro settings page for the custom app launch splash: a master switch plus a
/// light / dark image slot. Reached from 外觀主題 (gated at that entry point), so
/// this page itself assumes access and only manages the images.
struct LaunchImageSettingsView: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @State private var isImporting = false
    @State private var importScheme: LaunchImageScheme = .light
    @State private var importAlert: LaunchImageImportAlert?

    private static let imageContentTypes: [UTType] = [
        UTType(filenameExtension: "webp") ?? .data,
        UTType(filenameExtension: "jpg") ?? .jpeg,
        UTType(filenameExtension: "jpeg") ?? .jpeg,
        .png,
    ]

    private var hasAnyLaunchImage: Bool {
        settings.launchImageFileName(for: .light) != nil
            || settings.launchImageFileName(for: .dark) != nil
    }

    var body: some View {
        Form {
            Section {
                Toggle(localized("啟用啟動圖"), isOn: $settings.launchImageEnabled)
            } footer: {
                if settings.launchImageEnabled && !hasAnyLaunchImage {
                    Text(localized("尚未導入任何啟動圖，請在下方選擇圖片。"))
                        .foregroundStyle(.orange)
                } else {
                    Text(localized("開啟後，每次啟動 App 會短暫顯示你設定的啟動圖。"))
                }
            }

            Section {
                launchImageSlot(.light)
            } header: {
                Text(localized("淺色啟動圖"))
            } footer: {
                Text(localized("淺色模式啟動時顯示。"))
            }

            Section {
                launchImageSlot(.dark)
            } header: {
                Text(localized("深色啟動圖"))
            } footer: {
                Text(localized("深色模式啟動時顯示。若只設定一張，另一模式會沿用。"))
            }
        }
        .navigationTitle(localized("啟動圖"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: Self.imageContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleImport
        )
        .alert(item: $importAlert) { alert in
            Alert(
                title: Text(localized("啟動圖匯入失敗")),
                message: Text(alert.message),
                dismissButton: .default(Text(localized("確定")))
            )
        }
    }

    @ViewBuilder
    private func launchImageSlot(_ scheme: LaunchImageScheme) -> some View {
        let image = thumbnail(for: scheme)

        if let image {
            HStack(spacing: DSSpacing.md) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                            .stroke(DSColor.textSecondary.opacity(0.25), lineWidth: 0.5)
                    )
                Text(localized("已設定"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, DSSpacing.xs)
        }

        Button {
            beginImport(scheme)
        } label: {
            Label(
                image == nil ? localized("選擇圖片") : localized("更換圖片"),
                systemImage: "photo"
            )
        }

        if image != nil {
            Button(role: .destructive) {
                settings.clearLaunchImage(for: scheme)
            } label: {
                Label(localized("移除"), systemImage: "trash")
            }
        }
    }

    private func thumbnail(for scheme: LaunchImageScheme) -> UIImage? {
        guard let name = settings.launchImageFileName(for: scheme),
              let url = try? LaunchImageStorageManager.shared.fileURL(fileName: name),
              let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        return image
    }

    private func beginImport(_ scheme: LaunchImageScheme) {
        importScheme = scheme
        isImporting = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            try settings.importLaunchImage(from: url, for: importScheme)
        } catch let error as LaunchImageStorageError {
            importAlert = LaunchImageImportAlert(message: localized(error.messageKey))
        } catch {
            importAlert = LaunchImageImportAlert(message: localized("無法匯入啟動圖。"))
        }
    }
}

struct LaunchImageImportAlert: Identifiable {
    let id = UUID()
    let message: String
}

#Preview {
    NavigationStack {
        LaunchImageSettingsView()
    }
}
