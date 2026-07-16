import Foundation

extension EPUBTestFixtures {
    /// Reduced from IDPF `cc-shared-culture.epub`, `xhtml/p60.xhtml`.
    static func controlslessAudioFallback() -> Sample {
        Sample(entries: makeBaseEntries(
            title: "Controls-less Audio Fallback",
            language: "en",
            body: """
            <p>Before media.</p>
            <audio id="bgsound" autoplay="" loop="">
              <source src="audio/soundtrack.mp3" type="audio/mpeg"/>
              <div class="errmsg">
                <p>Your Reading System does not support (this) audio</p>
              </div>
            </audio>
            <p>After media.</p>
            """,
            extraManifest: #"<item id="soundtrack" href="audio/soundtrack.mp3" media-type="audio/mpeg"/>"#,
            extraEntries: ["OPS/audio/soundtrack.mp3": Data("fixture audio".utf8)]
        ))
    }
}
