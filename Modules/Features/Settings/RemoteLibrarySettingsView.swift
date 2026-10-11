import SwiftUI

/// 設定 → 遠端書庫 (unified library 2b): every WebDAV, OPDS and Calibre connection in one place,
/// as configuration. A connection is a library the reader adds, edits or removes here;
/// browsing it is Explore's job (its 我的書庫 tiles). Since unified library 5c-5 this is also
/// the only place to add one, and holds OPDS's 範例目錄, both once in the bookshelf ＋ menu.
///
/// The editor is pushed, as the bookshelf's library list pushes it; nothing here presents a
/// modal, so the iOS 17 menu-to-sheet rule does not apply. No browse route is registered in
/// this stack.
struct RemoteLibrarySettingsView: View {
    @ObservedObject private var catalogStore = RemoteLibraryConnectionStore.shared
    @ObservedObject private var indexing = WebDAVIndexCoordinator.shared

    /// The order the bookshelf ＋ menu had.
    static let kinds: [RemoteLibraryKind] = [.webDAV, .opds, .calibre]

    var body: some View {
        List {
            ForEach(Self.kinds) { kind in
                Section {
                    ForEach(catalogStore.connections.filter { $0.kind == kind }) { connection in
                        NavigationLink {
                            RemoteLibraryConnectionEditor(kind: kind, connection: connection, surface: .settings)
                        } label: {
                            RemoteLibraryConnectionRow(connection: connection, status: indexing.statuses[connection.id])
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
                if kind == .opds, !examples.isEmpty {
                    Section(localized("範例目錄")) {
                        ForEach(examples, id: \.url) { preset in
                            Button {
                                catalogStore.add(name: preset.name, url: preset.url, username: nil, password: nil)
                            } label: {
                                SettingsRowLabel(preset.name, systemImage: "plus", role: .action)
                            }
                            .accessibilityIdentifier("remote_library_example")
                        }
                    }
                    .interfaceSectionSurface()
                }
            }
        }
        .softScrollEdges()
        .navigationTitle(localized("遠端書庫"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
    }

    /// The example OPDS catalogs not added yet. Added as an ordinary connection, as from the
    /// bookshelf's OPDS list before 5c-5: the public-library region gate does not apply to it
    /// (Phase 2 findings, item 2, still open).
    private var examples: [OPDSCatalog] {
        OPDSCatalogStore.presets.filter { preset in !catalogStore.connections.contains { $0.url == preset.url } }
    }
}

/// A connection's name, server and indexing status, read by VoiceOver as one element.
private struct RemoteLibraryConnectionRow: View {
    let connection: RemoteLibraryConnection
    /// WebDAV indexing (2d): read with the row, as one element.
    var status: WebDAVIndexStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(connection.name).foregroundStyle(DSColor.textPrimary)
            // The full address, as the bookshelf's library list shows it: an unnamed connection
            // is named after its host, so the host alone would repeat the name.
            Text(connection.url).font(DSFont.caption).foregroundStyle(DSColor.textSecondary).lineLimit(1)
            if let status {
                Text(status.title).font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
            }
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

#Preview("Row states") {
    List {
        ForEach([WebDAVIndexStatus.indexing(128), .indexed(2_431), .pausedNotOnWiFi, .limitReached(20_000), .failed("認證失敗，請確認帳號和密碼")], id: \.self) { status in
            RemoteLibraryConnectionRow(connection: OPDSCatalog(name: "NAS", url: "https://nas.local/books/", kind: .webDAV), status: status)
        }
    }
}
