import SwiftUI

/// 人物關係圖: one character in the middle, the people the records relate to them around it.
///
/// A whole-cast graph turns into a knot on a phone, so the map shows one character's
/// relations at a time and re-centres on whoever is tapped. The same relations are listed as
/// text below it — the map is a picture of the list, never the only way to read it.
struct AIRelationshipMapView: View {
    let adapter: AIBookContentAdapter
    var onOpenCitation: ((LLMCitation) -> Void)? = nil
    /// Previews and the design fixture hand in a graph instead of reading the records.
    private let preloaded: AIRelationshipGraph?
    @ObservedObject private var memory = AICharacterMemoryService.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var graph: AIRelationshipGraph?
    @State private var centerID: String?
    @State private var error: String?

    init(adapter: AIBookContentAdapter, onOpenCitation: ((LLMCitation) -> Void)? = nil, graph: AIRelationshipGraph? = nil) {
        self.adapter = adapter
        self.onOpenCitation = onOpenCitation
        preloaded = graph
        _graph = State(initialValue: graph)
    }

    /// Around the centre; the rest are in the list below.
    private static let ringLimit = 8

    private var center: AIRelationshipGraph.Node? {
        guard let graph else { return nil }
        return centerID.flatMap(graph.node) ?? graph.hub
    }

    var body: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DSColor.destructive)
                }
                .interfaceSectionSurface()
            } else if graph == nil {
                Section { ProgressView(localized("載入中…")) }
                    .interfaceSectionSurface()
            } else if let graph, let center {
                let neighbors = graph.neighbors(of: center.id)
                if !dynamicTypeSize.isAccessibilitySize {
                    Section {
                        ring(center: center, neighbors: Array(neighbors.prefix(Self.ringLimit)))
                            .frame(height: DSLayout.relationshipMapHeight)
                            .listRowInsets(EdgeInsets())
                    } footer: {
                        Text(localized("點任一人物，改看這個人物的關係。"))
                            .dsSectionFooter()
                    }
                    .interfaceSectionSurface()
                }
                Section {
                    ForEach(neighbors) { neighbor in
                        Button { recenter(neighbor.node.id) } label: { relationRow(neighbor) }
                            .accessibilityHint(localized("改看這個人物的關係"))
                    }
                } header: {
                    Text(String(format: localized("%@的關係"), center.name))
                        .foregroundStyle(DSColor.textSecondary)
                } footer: {
                    Text(localized("依整理已讀人物的記錄繪製，只含目前讀到的內容；每條關係都可到人物頁核對原文。"))
                        .dsSectionFooter()
                }
                .interfaceSectionSurface()
                Section {
                    NavigationLink {
                        AIMemoryCardView(entityID: center.entityID, source: adapter, boundary: adapter.boundary(),
                                         onOpenCitation: onOpenCitation, showsDone: false)
                    } label: {
                        SettingsRowLabel(String(format: localized("%@的人物頁"), center.name), systemImage: "person.text.rectangle")
                    }
                }
                .interfaceSectionSurface()
            } else {
                ContentUnavailableView {
                    UnavailableLabel(localized("還沒有人物關係"), systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text(localized("先用「整理已讀人物」建立人物記錄，關係就會畫在這裡。")).foregroundStyle(DSColor.textSecondary)
                } actions: {
                    NavigationLink(localized("整理已讀人物")) {
                        AICharacterMemoryView(adapter: adapter, onOpenCitation: onOpenCitation)
                    }
                    .buttonStyle(.bordered)
                }
                .listRowBackground(Color.clear)
            }
        }
        .softScrollEdges()
        .themedAppSurface(for: .settings)
        .navigationTitle(localized("人物關係圖"))
        .toolbarTitleDisplayMode(.inline)
        .task(id: "\(adapter.contentFingerprint):\(memory.revisions[adapter.chunkBookID] ?? 0)") { await load() }
    }

    // MARK: - Map

    private func ring(center: AIRelationshipGraph.Node, neighbors: [AIRelationshipGraph.Neighbor]) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            let middle = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = max(0, min(size.width, size.height) / 2 - DSLayout.relationshipNodeInset)
            let points = neighbors.indices.map { index -> CGPoint in
                let angle = 2 * Double.pi * Double(index) / Double(max(neighbors.count, 1)) - Double.pi / 2
                return CGPoint(x: middle.x + radius * cos(angle), y: middle.y + radius * sin(angle))
            }
            ZStack {
                Path { path in
                    for point in points { path.move(to: middle); path.addLine(to: point) }
                }
                .stroke(DSColor.separator, lineWidth: DSLayout.relationshipLineWidth)
                .accessibilityHidden(true)
                ForEach(Array(neighbors.enumerated()), id: \.element.id) { index, neighbor in
                    Button { recenter(neighbor.node.id) } label: {
                        VStack(spacing: 0) {
                            node(neighbor.node.name, emphasized: false)
                            // The relation sits under the name, away from the crowded centre.
                            Text(neighbor.relations[0].text)
                                .font(DSFont.caption2)
                                .foregroundStyle(DSColor.textSecondary)
                                .lineLimit(1)
                                .frame(maxWidth: DSLayout.relationshipLabelWidth)
                        }
                    }
                    .buttonStyle(.plain)
                    .position(points[index])
                    .accessibilityLabel(neighbor.node.name)
                    .accessibilityValue(neighbor.relations.map(\.text).joined(separator: "；"))
                    .accessibilityHint(localized("改看這個人物的關係"))
                }
                node(center.name, emphasized: true)
                    .position(middle)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    private func node(_ name: String, emphasized: Bool) -> some View {
        Text(name)
            .font(emphasized ? DSFont.headline : DSFont.subheadline)
            .foregroundStyle(emphasized ? AnyShapeStyle(DSColor.textOnAccent) : AnyShapeStyle(DSColor.textPrimary))
            .lineLimit(1)
            .padding(.horizontal, DSSpacing.md)
            .padding(.vertical, DSSpacing.sm)
            .background(emphasized ? DSColor.accent : DSColor.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(DSColor.separator, lineWidth: emphasized ? 0 : DSLayout.relationshipLineWidth) }
            .frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
    }

    private func relationRow(_ neighbor: AIRelationshipGraph.Neighbor) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(neighbor.node.name)
                .font(DSFont.body.weight(.semibold))
                .foregroundStyle(DSColor.textPrimary)
            ForEach(neighbor.relations) { relation in
                Text(relation.chapter.map { String(format: localized("%1$@（第 %2$d 章）"), relation.text, $0 + 1) } ?? relation.text)
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
            }
        }
        .padding(.vertical, DSSpacing.xs)
    }

    private func recenter(_ id: String) {
        withAnimation(reduceMotion ? nil : DSAnimation.standard) { centerID = id }
    }

    private func load() async {
        guard preloaded == nil else { return }
        do {
            let view = try await memory.view(source: adapter, boundary: adapter.boundary())
            let built = AIRelationshipGraph(view: view)
            graph = built
            if let centerID, built.node(centerID) == nil { self.centerID = nil }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension AIRelationshipGraph {
    /// 張若塵 and the people around him, for previews and the design fixture.
    static var sample: AIRelationshipGraph {
        let people = ["張若塵", "池瑤", "雲武郡王", "林妃", "黃煙塵", "萬柯", "青霄聖者", "璇璣老人", "朱洪濤"]
        let relations = ["與張若塵曾有婚約", "張若塵的父親", "張若塵的母親", "與張若塵有婚約", "張若塵的師兄",
                         "張若塵的師尊", "指點張若塵劍道", "張若塵的同門"]
        let nodes = people.enumerated().map { Node(id: "n\($0.offset)", name: $0.element, entityID: "e\($0.offset)") }
        let edges = relations.enumerated().map { index, text in
            Edge(id: "r\(index)", first: "n0", second: "n\(index + 1)", text: text, chapter: index * 40)
        }
        return AIRelationshipGraph(nodes: nodes, edges: edges)
    }
}

#Preview("Map") {
    NavigationStack {
        AIRelationshipMapView(adapter: AIBookContentAdapter(bookID: UUID(), chapters: [], textForChapter: { _ in nil }),
                              graph: .sample)
    }
}

#Preview("Empty") {
    NavigationStack {
        AIRelationshipMapView(adapter: AIBookContentAdapter(bookID: UUID(), chapters: [], textForChapter: { _ in nil }))
    }
}
