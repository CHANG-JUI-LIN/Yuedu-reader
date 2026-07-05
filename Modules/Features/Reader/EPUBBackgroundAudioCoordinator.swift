import AVKit
import Foundation
import SwiftSoup

/// Plays an EPUB chapter's authored background soundtrack: a controls-less
/// `<audio autoplay loop epub:type="media:background …">` element. Such audio has no visible UI per the
/// HTML spec, so the reader draws nothing for it (see `HTMLAttributedStringBuilder.mediaAttachment`), but
/// the author still intends it to play — this coordinator fulfils that intent.
///
/// Playback lives here (not on a page view), so it continues across page turns. It is keyed by source URL,
/// so paging *within* a chapter does not restart the track; it switches when the chapter's soundtrack
/// changes and stops when a chapter has none (or the reader closes).
@MainActor
final class EPUBBackgroundAudioCoordinator {
    private var queuePlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentSource: String?
    /// Guards against overlapping async chapter switches: only the latest `update` may commit playback.
    private var generation = 0

    /// Reconciles background-audio playback with the chapter the reader is now showing. Call on chapter
    /// change and on initial load. No-ops if the chapter's soundtrack is unchanged.
    func update(session: PublicationSession, chapterIndex: Int) async {
        generation += 1
        let token = generation

        guard session.chapters.indices.contains(chapterIndex) else { stop(); return }
        let chapterHref = session.chapters[chapterIndex].href

        guard let audio = await backgroundAudio(session: session, chapterIndex: chapterIndex) else {
            stop()
            return
        }

        let resolved = EPUBStyleResolver.resolveImageHref(audio.href, chapterHref: chapterHref)
        let urlString = session.resourceURL(for: resolved).absoluteString
        // Already playing this exact track — keep it going across the page turn.
        if urlString == currentSource, queuePlayer != nil { return }

        guard let url = try? await EPUBMediaURLResolver.playableURL(
            for: EPUBMediaAttachment(kind: .audio, sourceHref: urlString)
        ) else {
            stop()
            return
        }
        // A newer chapter change happened while we were resolving — abandon this one.
        guard token == generation else { return }

        stop()
        activateAudioSession()

        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        if audio.loop {
            looper = AVPlayerLooper(player: queue, templateItem: item)
        } else {
            queue.insert(item, after: nil)
        }
        queue.play()
        queuePlayer = queue
        currentSource = urlString
    }

    func stop() {
        queuePlayer?.pause()
        queuePlayer = nil
        looper = nil
        currentSource = nil
    }

    private func activateAudioSession() {
        // Off-main to avoid the AVAudioSession main-thread hang risk.
        AudioSessionActivator.activate(category: .playback, mode: .default)
    }

    private struct BackgroundAudio {
        let href: String
        let loop: Bool
    }

    private func backgroundAudio(session: PublicationSession, chapterIndex: Int) async -> BackgroundAudio? {
        guard let html = try? await session.chapterHTML(at: chapterIndex) else { return nil }
        return Self.parseBackgroundAudio(html: html)
    }

    /// Finds the first background soundtrack `<audio>` in the chapter: a controls-less element that is
    /// `autoplay` and/or carries an `epub:type` of `media:background`/`media:soundtrack`.
    nonisolated private static func parseBackgroundAudio(html: String) -> BackgroundAudio? {
        guard let doc = try? SwiftSoup.parse(html),
              let audios = try? doc.select("audio").array() else { return nil }
        for audio in audios {
            if audio.hasAttr("controls") { continue }
            let epubType = ((try? audio.attr("epub:type")) ?? "").lowercased()
            let isBackground = epubType.contains("background") || epubType.contains("soundtrack")
            guard audio.hasAttr("autoplay") || isBackground else { continue }
            let loop = audio.hasAttr("loop")
            if let src = try? audio.attr("src"), !src.isEmpty {
                return BackgroundAudio(href: src, loop: loop)
            }
            if let source = try? audio.select("source").first(),
               let src = try? source.attr("src"), !src.isEmpty {
                return BackgroundAudio(href: src, loop: loop)
            }
        }
        return nil
    }
}
