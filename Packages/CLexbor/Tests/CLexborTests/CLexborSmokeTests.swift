import CLexbor
import Testing

@Test func reportsPinnedVersion() {
    #expect(String(cString: ylx_lexbor_version()) == "3.0.0")
}
