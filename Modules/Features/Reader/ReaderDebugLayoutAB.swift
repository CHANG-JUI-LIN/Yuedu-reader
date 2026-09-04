#if DEBUG
import SwiftUI

enum ReaderDebugLayoutEngine: String, CaseIterable, Identifiable, Equatable, Hashable {
    case legacy
    case browserForced

    var id: Self { self }

    init(featureMode: EPUBLayoutEngineMode) {
        self = featureMode == .legacy ? .legacy : .browserForced
    }

    var featureMode: EPUBLayoutEngineMode {
        switch self {
        case .legacy: return .legacy
        case .browserForced: return .browserForced
        }
    }

    var title: String {
        switch self {
        case .legacy: return localized("Legacy")
        case .browserForced: return localized("BrowserForced")
        }
    }
}

struct ReaderDebugLayoutABOverlay: View {
    let effectiveEngine: ReaderDebugLayoutEngine
    let selectedEngine: ReaderDebugLayoutEngine
    let isSwitching: Bool
    let onSelect: (ReaderDebugLayoutEngine) -> Void

    var body: some View {
        VStack(spacing: DSSpacing.sm) {
            HStack(spacing: DSSpacing.sm) {
                Text(localized("目前引擎"))
                Text(effectiveEngine.title)
                    .fontWeight(.semibold)
                if isSwitching {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(localized("正在切換版面引擎"))
                }
            }
            .font(DSFont.caption)
            .foregroundStyle(DSColor.textPrimary)

            Picker(
                localized("版面引擎"),
                selection: Binding(
                    get: { selectedEngine },
                    set: onSelect
                )
            ) {
                ForEach(ReaderDebugLayoutEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isSwitching)
            .accessibilityLabel(localized("版面引擎"))
        }
        .padding(DSSpacing.sm)
        .frame(maxWidth: DSLayout.readableNarrowWidth)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DSRadius.md))
        .padding(.horizontal, DSSpacing.lg)
    }
}
#endif
