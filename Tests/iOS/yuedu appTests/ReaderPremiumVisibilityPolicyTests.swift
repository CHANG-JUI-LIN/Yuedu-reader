import Testing

@Suite("Reader Premium Visibility Policy")
struct ReaderPremiumVisibilityPolicyTests {
    @Test("free users do not see premium customization surfaces")
    func freeVisibility() {
        let policy = ReaderPremiumVisibilityPolicy(isProActive: false)

        #expect(!policy.showsReaderDecoration)
        #expect(!policy.showsBottomTabCustomization)
        #expect(!policy.showsBackgroundImageImport)
        #expect(!policy.showsLayoutPresetImport)
        #expect(!policy.showsTouchZoneEditor)
    }

    @Test("Pro users see premium customization surfaces")
    func proVisibility() {
        let policy = ReaderPremiumVisibilityPolicy(isProActive: true)

        #expect(policy.showsReaderDecoration)
        #expect(policy.showsBottomTabCustomization)
        #expect(policy.showsBackgroundImageImport)
        #expect(policy.showsLayoutPresetImport)
        #expect(policy.showsTouchZoneEditor)
    }
}
