private enum ContractRoute: Equatable {
    case local
    case network
}

@main
private enum DismissalSequencedPresentationContract {
    static func main() {
        precondition(
            MenuModalPresentationPolicy.requiresDismissalSequencedChooser(
                osMajorVersion: 17
            )
        )
        precondition(
            !MenuModalPresentationPolicy.requiresDismissalSequencedChooser(
                osMajorVersion: 18
            )
        )
        precondition(
            BookSourceManagementPresentationPolicy.prefersNavigationDestination(
                osMajorVersion: 17
            )
        )
        precondition(
            !BookSourceManagementPresentationPolicy.prefersNavigationDestination(
                osMajorVersion: 18
            )
        )
        precondition(
            ReaderSettingsPresentationPolicy.requiresFirstLevelFontImporter(
                osMajorVersion: 17
            )
        )
        precondition(
            !ReaderSettingsPresentationPolicy.requiresFirstLevelFontImporter(
                osMajorVersion: 18
            )
        )

        var sequence = DismissalSequencedPresentation<ContractRoute>()
        sequence.select(.network)
        precondition(sequence.pendingRoute == .network)
        precondition(sequence.consumeAfterDismissal() == .network)
        precondition(sequence.pendingRoute == nil)
        precondition(sequence.consumeAfterDismissal() == nil)

        sequence.select(.local)
        sequence.cancel()
        precondition(sequence.consumeAfterDismissal() == nil)
    }
}
