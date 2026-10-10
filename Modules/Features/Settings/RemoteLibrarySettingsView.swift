import SwiftUI

/// 設定 → 遠端書庫 (unified library 2b): every WebDAV, OPDS and Calibre connection in one place,
/// as configuration. A connection is a library the reader adds, edits or removes here;
/// browsing it is Explore's job (Phase 5), and until then the bookshelf ＋ entries.
///
/// The editor is pushed, as the bookshelf's library list pushes it; nothing here presents a
/// modal, so the iOS 17 menu-to-sheet rule does not apply. No browse route is registered in
/// this stack.
struct RemoteLibrarySettingsView: View {
    @ObservedObject private var catalogStore = RemoteLibraryConnectionStore.shared

    /// The order of the bookshelf ＋ menu.
    static let kinds: [RemoteLibraryKind] = [.webDAV, .opds, .calibre]

    var body: some View {
        List {
            ForEach(Self.kinds) { kind in
                Section {
                    ForEach(catalogStore.connections.filter { $0.kind == kind }) { connection in
                        NavigationLink {
                            RemoteLibraryConnectionEditor(kind: kind, connection: connection, surface: .settings)
                        } label: {
                            RemoteLibraryConnectionRow(connection: connection)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { catalogStore.remove(connection) } label: {
                                Label(localized("刪除"), systemImage: "trash")
                            }
                        }
                    }
                    NavigationLink {
                        RemoteLibraryConnectionEditor(kind: kind, surface: .settings)
                    } label: {
                        SettingsRowLabel(localized("新增伺服器"), systemImage: "plus", role: .action)
                    }
                    .accessibilityIdentifier("remote_library_add_\(kind.rawValue)")
                } header: {
                    Text(kind.libraryTitle).foregroundStyle(DSColor.textSecondary)
                }
                .interfaceSectionSurface()
            }
        }
        .softScrollEdges()
        .navigationTitle(localized("遠端書庫"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
    }
}

/// A connection's name and server, read by VoiceOver as one element.
private struct RemoteLibraryConnectionRow: View {
    let connection: RemoteLibraryConnection

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(connection.name).foregroundStyle(DSColor.textPrimary)
            // The full address, as the bookshelf's library list shows it: an unnamed connection
            // is named after its host, so the host alone would repeat the name.
            Text(connection.url).font(DSFont.caption).foregroundStyle(DSColor.textSecondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Connections") {
    NavigationStack { RemoteLibrarySettingsView() }
}

#Preview("Large text") {
    NavigationStack { RemoteLibrarySettingsView() }
        .environment(\.dynamicTypeSize, .accessibility3)
}
