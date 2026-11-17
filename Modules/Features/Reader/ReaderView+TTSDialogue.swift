import Combine
import SwiftUI
import UIKit

/// AI 多角色朗讀 on the reader's side: which chapter to analyse, waiting for it, and handing
/// the result and the cast to the narrator. The analysis itself — requests, caching, the
/// roster, automatic voices — belongs to `AIDialogueCastService`.
extension ReaderView {

    /// What a start already asked the AI, so `startTTSChapter` does not wait on it again.
    enum TTSStartDialogue {
        /// Use the whole chapter's analysis, waiting for it if it is missing.
        case lookUp
        /// The whole chapter is still being analysed: speak with the opening's lines (`nil`
        /// when that request failed) up to `analysedThrough`, the prose's speakers after it,
        /// and switch once the chapter's analysis lands.
        case opening(TTSChapterDialogue?, analysedThrough: Int)
        /// Nothing the AI could add to what is read from here.
        case withoutAnalysis
    }

    /// Whether a narration result still needs the AI before it can be read.
    enum TTSDialogueAttachment {
        case ready(TTSNarrationUnit)
        case needsAnalysis(AIDialogueCastService.Request)
    }

    /// The analysis request for one chapter's narration, or `nil` when narration does not use
    /// the AI: multi-role off, the reader turned the AI part off, or no text.
    /// - Parameter whenEnabledOnly: `false` for the cast screen, which offers 分析本章 before the
    ///   reader has switched the feature on — with the same key playback will look up.
    func ttsDialogueRequest(chapterIndex: Int, text: String, whenEnabledOnly: Bool = true) -> AIDialogueCastService.Request? {
        let settings = GlobalSettings.shared
        guard !whenEnabledOnly || (settings.ttsMultiRoleEnabled && settings.ttsAIDialogueEnabled),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let family = TTSVoiceFamily.active()
        guard !whenEnabledOnly || family.supportsMultiRole() else { return nil }
        // A spoken direction per line only for voices that act on words; it lengthens the
        // answer, and the wait before a chapter, for nothing on the others.
        let takesInstructions = family.takesInstructions
            || (family == .bookSource && CustomHTTPProvider.templateTakesDelivery(settings.httpTtsUrlTemplate))
        return AIDialogueCastService.Request(
            bookID: bookId,
            chapterIndex: chapterIndex,
            text: text,
            includeInstruct: takesInstructions && settings.ttsEmotionEnabled
        )
    }

    /// The analysis in the engine's coordinates, for narration that starts `offset` into the
    /// chapter. Each speaker's description rides along for voices that act a persona.
    func ttsSpeakerAttributions(
        for dialogue: TTSChapterDialogue,
        droppingPrefix offset: Int,
        textLength: Int
    ) -> [TTSSpeakerAnnotator.Attribution] {
        let roster = AIDialogueCastService.shared.roster(forBook: bookId)
        let attributions = dialogue.attributions(droppingPrefix: offset, textLength: textLength) {
            roster.character(named: $0)?.persona
        }
        guard GlobalSettings.shared.ttsEmotionEnabled else {
            return attributions.map { TTSSpeakerAnnotator.Attribution(range: $0.range, speaker: $0.speaker) }
        }
        return attributions
    }

    /// A start spoken before the whole chapter is analysed: the opening's speakers up to
    /// `analysedThrough`, then the speakers read off the prose — the same the engine would find
    /// itself — rather than every later quote in the narrator's voice.
    func ttsSpeakerAttributions(
        opening: TTSChapterDialogue?,
        analysedThrough: Int,
        droppingPrefix offset: Int,
        text: String
    ) -> [TTSSpeakerAnnotator.Attribution] {
        let length = (text as NSString).length
        let analysed = opening.map { ttsSpeakerAttributions(for: $0, droppingPrefix: offset, textLength: length) } ?? []
        let boundary = max(0, analysedThrough - offset)
        let rest = TTSSpeakerAnnotator.attributions(in: text, aliases: activeTTSRoleAliases())
            .filter { $0.range.location >= boundary }
        return analysed + rest
    }

    /// Attaches the chapter's analysis when there is one, or says it must be awaited.
    func attachTTSDialogue(to narration: TTSNarrationUnit, chapterIndex: Int) -> TTSDialogueAttachment {
        guard let request = ttsDialogueRequest(chapterIndex: chapterIndex, text: narration.text) else {
            return .ready(narration)
        }
        let readiness = AIDialogueCastService.shared.readiness(request)
        // FB-192: whether the prefetch got there first. `miss` or `inFlight` at a chapter
        // boundary is the 「AI 正在分析本章角色與語氣…」 wait.
        let found: String
        switch readiness {
        case .ready: found = "hit"
        case .needsAnalysis: found = AIDialogueCastService.shared.state(of: request) == .analyzing ? "inFlight" : "miss"
        case .unavailable: found = "unavailable"
        }
        AppLogger.render(
            "⟐ [TTS][AI] cast lookup chapter=\(chapterIndex) \(found) key=\(request.key.prefix(8)) chars=\(narration.text.count)",
            level: .notice
        )
        switch readiness {
        case let .ready(dialogue):
            var analysed = narration
            analysed.speakerAttributions = ttsSpeakerAttributions(
                for: dialogue,
                droppingPrefix: 0,
                textLength: (narration.text as NSString).length
            )
            return .ready(analysed)
        case .needsAnalysis:
            return .needsAnalysis(request)
        case .unavailable:
            return .ready(narration)
        }
    }

    /// Starts narration at a chapter once the AI has analysed what is read first.
    ///
    /// Only the paragraphs from the start offset are waited for; the whole chapter is analysed
    /// alongside and switched to when it lands. Waiting for the whole chapter cost one full
    /// request before the first word — two to four minutes on a slow model (FB-192).
    ///
    /// The previous chapter is paused rather than left talking over the wait: when it ends
    /// during the analysis its own chapter advance would race this start.
    func startTTSChapterOnceAnalyzed(
        _ chapterIndex: Int,
        syncReader: Bool,
        startCharOffset: Int,
        request: AIDialogueCastService.Request
    ) {
        let token = UUID()
        // The same token a start waiting on layout uses: a newer start, a pause or a stop
        // clears it and wins over an analysis still in flight.
        ttsStartLayoutRequest = token
        if ttsCoordinator.playbackState == .playing {
            ttsCoordinator.pause()
        }
        announceTTSPreparation()
        ttsLog("[TTS][Reader] start waits for AI dialogue analysis chapter=\(chapterIndex) offset=\(startCharOffset)")
        let aliases = activeTTSRoleAliases()
        let started = SourcePerfTrace.now
        Task { @MainActor in
            let dialogue: TTSStartDialogue
            do {
                switch try await AIDialogueCastService.shared.analyzeOpening(request, from: startCharOffset, knownAliases: aliases) {
                case .chapter: dialogue = .lookUp
                case let .opening(opening, analysedThrough): dialogue = .opening(opening, analysedThrough: analysedThrough)
                case .nothingToAsk: dialogue = .withoutAnalysis
                }
            } catch is CancellationError {
                dialogue = .opening(nil, analysedThrough: startCharOffset)
            } catch {
                // Not fatal to listening: the opening is read with the prose's speakers, and
                // the whole chapter's analysis, already running, is switched to if it succeeds.
                AppLogger.error(
                    "[TTS] AI 多角色開頭分析失敗，先用敘述判斷說話人",
                    error: error,
                    context: ["chapter": chapterIndex],
                    level: .warning
                )
                dialogue = .opening(nil, analysedThrough: startCharOffset)
            }
            ttsCoordinator.setPreparationNotice(nil)
            // FB-192: how long the reader waited for the AI before the first word.
            SourcePerfTrace.record(
                "ai.dialogue.startWait",
                "chapter=\(chapterIndex) offset=\(startCharOffset)",
                since: started,
                thresholdMs: 0,
                mainThreadStallBreadcrumb: false
            )
            guard ttsStartLayoutRequest == token else {
                ttsLog("[TTS][Reader] start for chapter=\(chapterIndex) superseded during analysis")
                return
            }
            startTTSChapter(
                chapterIndex,
                syncReader: syncReader,
                startCharOffset: startCharOffset,
                layoutAwaited: true,
                dialogue: dialogue
            )
        }
    }

    /// A chapter started on its opening's analysis: once the whole chapter's lands, narration
    /// restarts on it at the next sentence, so every later line gets the AI's speaker.
    ///
    /// Waits for the sentence being spoken to end — a restart then begins the sentence that
    /// was about to start rather than repeating one. Paused narration switches once it resumes
    /// and moves on a sentence. A stop, a new start or reaching the next chapter ends the wait.
    func switchToWholeChapterAnalysis(_ request: AIDialogueCastService.Request, chapterIndex: Int) {
        let aliases = activeTTSRoleAliases()
        ttsWholeChapterSwitch = Task { @MainActor in
            do {
                try await AIDialogueCastService.shared.analyze(request, knownAliases: aliases)
            } catch {
                // Logged by the analysis' own caller (the prefetch); the opening's speakers and
                // the prose's stay for the rest of the chapter.
                return
            }
            for await _ in ttsCoordinator.$currentSegmentIndex.dropFirst().values {
                guard !Task.isCancelled, ttsChapterIndex == chapterIndex else { return }
                if ttsCoordinator.playbackState == .playing { break }
            }
            guard !Task.isCancelled, ttsChapterIndex == chapterIndex,
                  ttsCoordinator.playbackState == .playing,
                  ttsDialogueRequest(chapterIndex: chapterIndex, text: narrationForTTSChapter(chapterIndex).text)?.key == request.key
            else { return }
            ttsWholeChapterSwitch = nil
            ttsLog("[TTS][Reader] whole-chapter analysis landed; switching chapter=\(chapterIndex)")
            reapplyTTSRoleCast()
        }
    }

    /// The engine is holding the session open at a chapter boundary; the analysis completing
    /// is what releases it.
    func awaitTTSDialogue(for target: Int, request: AIDialogueCastService.Request) {
        announceTTSPreparation()
        let aliases = activeTTSRoleAliases()
        let started = SourcePerfTrace.now
        Task { @MainActor in
            await runTTSDialogueAnalysis(request, knownAliases: aliases)
            // FB-192: how long narration stood still at the boundary for the AI.
            SourcePerfTrace.record(
                "ai.dialogue.boundaryWait",
                "chapter=\(target) key=\(request.key.prefix(8))",
                since: started,
                thresholdMs: 0,
                mainThreadStallBreadcrumb: false
            )
            guard ttsPendingChapterIndex == target else { return }
            finishWaitingTTSChapter(target, narration: narrationForTTSChapter(target))
        }
    }

    /// Runs one analysis. A failure is not fatal to listening: the chapter is then read with
    /// speakers taken from the prose, as without AI — the service remembers the failure for this
    /// text, so playback does not ask again and again. The precise trigger is the AI request
    /// failing (network, key, quota, malformed answer); the cast screen offers a retry.
    private func runTTSDialogueAnalysis(_ request: AIDialogueCastService.Request, knownAliases: [String: String]) async {
        do {
            try await AIDialogueCastService.shared.analyze(request, knownAliases: knownAliases)
        } catch is CancellationError {
            // Superseded; the caller's token check decides what happens next.
        } catch {
            AppLogger.error(
                "[TTS] AI 多角色分析失敗，本章改用敘述判斷說話人",
                error: error,
                context: ["chapter": request.chapterIndex],
                level: .warning
            )
        }
        ttsCoordinator.setPreparationNotice(nil)
    }

    private func announceTTSPreparation() {
        let notice = localized("AI 正在分析本章角色與語氣…")
        ttsCoordinator.setPreparationNotice(notice)
        UIAccessibility.post(notification: .announcement, argument: notice)
    }

    /// Analyses a chapter ahead of narration reaching it.
    func prefetchTTSDialogue(for chapterIndex: Int) {
        let narration = narrationForTTSChapter(chapterIndex)
        let request = ttsDialogueRequest(chapterIndex: chapterIndex, text: narration.text)
        // FB-192: a `nil` request here means the next chapter is not analysed ahead of time.
        AppLogger.render(
            "⟐ [TTS][AI] prefetch chapter=\(chapterIndex) contentAvailable=\(isChapterContentAvailable(at: chapterIndex))"
                + " chars=\(narration.text.count) request=\(request.map { String($0.key.prefix(8)) } ?? "nil")"
                + " state=\(request.map { String(describing: AIDialogueCastService.shared.readiness($0)).prefix(20) } ?? "-")",
            level: .notice
        )
        guard let request else { return }
        AIDialogueCastService.shared.prefetch(request, knownAliases: activeTTSRoleAliases())
    }

    /// Gives characters without a voice an automatic one, then hands the cast to the narrator.
    func refreshTTSRoleCast(sampleText: String) {
        let settings = GlobalSettings.shared
        if settings.ttsMultiRoleEnabled, settings.ttsAutoCastEnabled {
            let family = TTSVoiceFamily.active()
            if family == .azure { AzureTTSVoiceCatalog.shared.loadIfNeeded() }
            AIDialogueCastService.shared.assignAutoVoices(
                forBook: bookId,
                family: family,
                explicit: TTSRoleVoiceCast.cast(forBook: bookId, in: settings.ttsRoleVoices),
                pool: TTSVoiceCandidates.make(family: family, sampleText: sampleText)
            )
        }
        ttsCoordinator.roleVoices = activeTTSRoleVoices()
        ttsCoordinator.roleAliases = activeTTSRoleAliases()
    }

    /// The cast changed while listening: re-read the current chapter from the segment being
    /// spoken, so the change is heard now rather than from the next chapter. Paused narration
    /// only picks the cast up for what comes next — restarting would make it speak.
    func reapplyTTSRoleCast() {
        guard ttsCoordinator.playbackState == .playing, let chapterIndex = ttsChapterIndex else {
            refreshTTSRoleCast(sampleText: ttsChapterIndex.map { narrationForTTSChapter($0).text } ?? "")
            return
        }
        let offset = expectedPlaybackChapterOffset()
            ?? currentTTSReaderPosition().map { $0.spineIndex == chapterIndex ? $0.charOffset : 0 }
            ?? 0
        ttsLog("[TTS][Reader] cast changed while playing; restarting chapter=\(chapterIndex) offset=\(offset)")
        startTTSChapter(chapterIndex, syncReader: false, startCharOffset: offset)
    }

    /// 預先分析: the chapter being listened to and the next `count`, in the background.
    func preAnalyzeTTSChapters(count: Int) {
        let base = ttsChapterIndex ?? currentChapterIndex
        var indices: [Int] = isVolumeSeparatorChapter(base) ? [] : [base]
        var cursor = base
        while indices.count < count + 1, let next = narratableTTSChapter(from: cursor, direction: 1) {
            indices.append(next)
            cursor = next
        }
        let aliases = activeTTSRoleAliases()
        AIDialogueCastService.shared.startBatch(bookID: bookId, chapters: indices, knownAliases: aliases) { index in
            await ttsDialogueRequestPreparingChapter(index)
        }
    }

    /// Lays a chapter out if needed and returns its analysis request. An online chapter not
    /// downloaded yet has no text and is skipped — it is analysed when narration reaches it.
    private func ttsDialogueRequestPreparingChapter(_ index: Int) async -> AIDialogueCastService.Request? {
        if isChapterContentAvailable(at: index), let engine = epubRenderer.engine, usesCoreTextEPUB {
            await engine.preloadChapter(at: index)
        }
        return ttsDialogueRequest(chapterIndex: index, text: narrationForTTSChapter(index).text)
    }

    /// What the 多角色朗讀 screen needs from the reader, recomputed when the chapter changes.
    func makeTTSRoleCastContext() -> TTSRoleCastContext {
        let chapterIndex = ttsChapterIndex ?? currentChapterIndex
        let text = spineChapters.indices.contains(chapterIndex) ? narrationForTTSChapter(chapterIndex).text : ""
        return TTSRoleCastContext(
            chapterIndex: chapterIndex,
            request: ttsDialogueRequest(chapterIndex: chapterIndex, text: text, whenEnabledOnly: false),
            heuristicSpeakers: detectedTTSSpeakers(),
            knownAliases: activeTTSRoleAliases()
        )
    }
}

/// The reader's half of the 多角色朗讀 screen.
struct TTSRoleCastContext: Equatable {
    let chapterIndex: Int
    /// The current chapter's analysis request; `nil` when the chapter has no text.
    let request: AIDialogueCastService.Request?
    /// Speakers read off the prose, for when the chapter has not been analysed.
    let heuristicSpeakers: [String]
    let knownAliases: [String: String]

    static let empty = TTSRoleCastContext(chapterIndex: 0, request: nil, heuristicSpeakers: [], knownAliases: [:])
}
