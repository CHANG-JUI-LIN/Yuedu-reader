import Foundation
import Testing
@testable import yuedu_app

// Live reproduction of the on-device "Fetched empty content" for 听书 (audiobook)
// chapters on the 光遇聚合 aggregate source. Walks the exact player chain:
// search (听书 mode) → detail → toc → fetchChapterPackage, logging every stage so
// the failing hop is unambiguous. Hits real servers — run manually:
//   xcodebuild test ... -only-testing:'yuedu appTests/AudiobookChapterSmokeTests'
@Suite("AudiobookChapterSmoke", .serialized)
struct AudiobookChapterSmokeTests {

    static var jsonPath: String {
        ProcessInfo.processInfo.environment["AUDIO_SOURCE_JSON"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_AUDIO_SOURCE_JSON"]
            ?? "/Users/zhangruilin/Desktop/Test document/RULE/光遇聚合26.5.30.json"
    }

    static var searchKeyword: String {
        ProcessInfo.processInfo.environment["AUDIO_SOURCE_QUERY"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_AUDIO_SOURCE_QUERY"]
            ?? "斗罗大陆"
    }

    static let resultPath = "/tmp/yuedu_audio_smoke.txt"

    @Test("live 听书 search → detail → toc → chapter content")
    func smokeAudiobookChapterContent() async {
        var out = ""
        func log(_ s: String) {
            out += s + "\n"
            print(s)
            try? out.write(toFile: Self.resultPath, atomically: true, encoding: .utf8)
        }

        guard let data = FileManager.default.contents(atPath: Self.jsonPath),
              let source = (try? JSONDecoder().decode([BookSource].self, from: data))?.first
        else {
            print("⏭️  Skipping audiobook smoke: \(Self.jsonPath) not found / decode failed")
            return
        }
        log("========== 听书 CHAPTER SMOKE (\(source.bookSourceName), query=\(Self.searchKeyword)) ==========")

        // Force 听书 search mode the same way the in-app filter does: merge it into the
        // source's persisted runtime variables (read by the source's searchUrl JS).
        let store = BookSourceRuntimeStateStore.shared
        let previousJSON = store.sourceVariableJSON(for: source.bookSourceUrl)
        defer { store.setSourceVariableJSON(previousJSON, for: source.bookSourceUrl) }

        var dict: [String: Any] = [:]
        if let json = previousJSON, let d = json.data(using: .utf8),
           let existing = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            dict = existing
        }
        var more = (dict["更多设置"] as? [String: Any]) ?? [:]
        more["搜索模式"] = "听书"
        more["听书"] = (more["听书"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "全部"
        dict["更多设置"] = more
        dict["发现页类型"] = "听书"
        // Optional line override (the server rate-limits anonymous use per host, so
        // switching lines resets the quota during repeated debugging runs).
        if let line = ProcessInfo.processInfo.environment["AUDIO_SOURCE_LINE"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_AUDIO_SOURCE_LINE"] {
            dict["线路"] = line
        }
        if let merged = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: merged, encoding: .utf8) {
            store.setSourceVariableJSON(json, for: source.bookSourceUrl)
        }
        log("variables: 搜索模式=听书 听书=\(more["听书"] ?? "?")")

        let fetcher = BookSourceFetcher.shared

        // 1. SEARCH in 听书 mode
        var first: OnlineBook?
        do {
            let books = try await fetcher.search(query: Self.searchKeyword, in: source)
            first = books.first
            log("🔎 search → \(books.count) results")
            if let b = first {
                log("   first.name=\(b.name) | author=\(b.author)")
                log("   first.bookUrl=\(String(b.bookUrl.prefix(200)))")
                log("   first.runtimeVars=\(b.runtimeVariables ?? [:])")
                let kind = b.inferredContentKind(source: source)
                log("   inferredContentKind=\(kind)")
            }
        } catch {
            log("🔎 search → ERROR: \(error)")
            return
        }
        guard let book = first, !book.bookUrl.isEmpty else {
            log("⏭️  no usable search result — stop")
            return
        }

        // 2. DETAIL
        var tocURL = book.bookUrl
        var runtimeVars = book.runtimeVariables
        do {
            let pkg = try await fetcher.fetchBookInfoPackage(
                url: book.bookUrl, source: source, runtimeVariables: runtimeVars)
            runtimeVars = pkg.runtimeVariables
            if !pkg.tocUrl.isEmpty { tocURL = pkg.tocUrl }
            log("📖 detail → name=\(pkg.name) | tocUrl=\(String(pkg.tocUrl.prefix(160)))")
            log("   detail.runtimeVars=\(pkg.runtimeVariables ?? [:])")
        } catch {
            log("📖 detail → ERROR: \(error)")
        }

        // 3. TOC
        var chapters: [OnlineChapterRef] = []
        do {
            let tocPkg = try await fetcher.fetchTOCPackage(
                tocUrl: tocURL, source: source, runtimeVariables: runtimeVars)
            chapters = tocPkg.chapters
            runtimeVars = tocPkg.runtimeVariables ?? runtimeVars
            let sample = chapters.prefix(3).map { $0.title }.joined(separator: " / ")
            log("📑 toc → \(chapters.count) chapters · \(sample)")
            log("   toc.runtimeVars=\(tocPkg.runtimeVariables ?? [:])")
            if let c0 = chapters.first {
                log("   ch0.url=\(String(c0.url.prefix(260)))")
                log("   ch0.runtimeVars=\(c0.runtimeVariables ?? [:])")
            }
        } catch {
            log("📑 toc → ERROR: \(error)")
            return
        }
        guard var ref = chapters.first else {
            log("⏭️  empty toc — stop")
            return
        }

        // 4. CHAPTER CONTENT — mirror OnlineReadingPipeline.fetchChapter's runtime merge:
        // the book-level variables (which the shelf book carries) merged under the
        // chapter's own, exactly like the live code path.
        if let bookRuntime = runtimeVars, !bookRuntime.isEmpty {
            var merged = bookRuntime
            for (k, v) in ref.runtimeVariables ?? [:] { merged[k] = v }
            ref.runtimeVariables = merged
        }
        do {
            let pkg = try await fetcher.fetchChapterPackage(
                ref: ref, bookId: UUID(), source: source)
            let content = pkg.content
            log("🎧 chapter → contentLen=\(content.count)")
            log("   head=\(String(content.prefix(400)).replacingOccurrences(of: "\n", with: "⏎"))")
            log("   looksAudio=\(DirectChapterAudioResolver.looksLikeAudioContent(content))")
            log("   audioURL=\(DirectChapterAudioResolver.request(from: content)?.url?.absoluteString ?? "nil")")
        } catch {
            log("🎧 chapter → ERROR: \(error)")
        }

        log("========== 听书 SMOKE DONE ==========")
    }

    static let debugResultPath = "/tmp/yuedu_audio_jsdebug.txt"

    /// Staged probe of the content-rule JS for a 听书 chapter: runs the same jsLib +
    /// bridges the live engine uses, but evaluates the script in pieces so the exact
    /// dying expression (and `lastError`) is visible instead of a silent "".
    @Test("debug 听书 content JS stage by stage")
    func debugAudioContentJS() {
        var out = ""
        func log(_ s: String) {
            out += s + "\n"
            print(s)
            try? out.write(toFile: Self.debugResultPath, atomically: true, encoding: .utf8)
        }

        guard let data = FileManager.default.contents(atPath: Self.jsonPath),
              let source = (try? JSONDecoder().decode([BookSource].self, from: data))?.first
        else {
            print("⏭️  Skipping JS debug: \(Self.jsonPath) not found")
            return
        }
        log("========== 听书 CONTENT JS DEBUG ==========")

        // The hex body the engine receives for ch0 (bodyForDataURI output):
        // gycontent payload JSON, hex-encoded.
        let payload = #"{"book_id":"NzA4ODU4MDI4MTk2MzE4NzIxNA","item_id":"7088926490901122078","title":"终极斗罗 0001 那是什么","sources":"番茄","tab":"听书","url":""}"#
        let hexBody = Data(payload.utf8).map { String(format: "%02x", $0) }.joined()

        let engine = JSCoreEngine()
        engine.bookSource = source
        var vars: [String: Any] = ["更多设置": ["搜索模式": "听书", "听书": "全部"], "发现页类型": "听书"]
        engine.sourceBridge.getVariableHandler = {
            (try? JSONSerialization.data(withJSONObject: vars))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
        engine.sourceBridge.setVariableHandler = { json in
            if let d = json?.data(using: .utf8),
               let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { vars = m }
        }
        engine.setBookBridge(LegadoBookBridge(
            durChapterIndex: 0, order: 0, type: 32,
            name: "斗罗大陆4：终极斗罗", author: "唐家三少"))
        engine.setChapterBridge(LegadoChapterBridge(
            index: 0, title: "终极斗罗 0001 那是什么", order: 0, url: "data:..."))

        _ = engine.evaluate(source.jsLib, bindings: ["baseUrl": source.bookSourceUrl])
        log("jsLib error: \(engine.lastError ?? "nil")")

        // Stage probes
        let probes: [(String, String)] = [
            ("typeofs", "[typeof getVariable, typeof request, typeof BaseUrl, typeof checkEnv, typeof getToken, typeof localVersion].join(',')"),
            ("hexDecode", "String(java.hexDecodeToString('\(hexBody)')).slice(0, 120)"),
            ("checkEnv", "String(checkEnv())"),
            ("BaseUrl", "String(BaseUrl())"),
            ("getToken", "'tok=' + String(getToken())"),
            ("moreSettings", "JSON.stringify(getVariable('更多设置'))"),
            ("book.getVariable", "'custom=' + String(book.getVariable('custom'))"),
            ("request /content",
             """
             (function(){
               try {
                 var r = request('/content','POST',{html:'',item_id:'7088926490901122078',source:'番茄',tab:'听书',tone_id:'4',variable:JSON.stringify({custom:''}),version:String(localVersion)});
                 return 'TYPE=' + (typeof r) + ' HEAD=' + String(r).slice(0,300);
               } catch(e) { return 'THROW: ' + e; }
             })()
             """)
        ]
        for (name, js) in probes {
            let value = engine.evaluate(js, bindings: ["result": hexBody, "baseUrl": source.bookSourceUrl])
            log("▸ \(name) → \(value ?? "nil")\(engine.lastError.map { " [err: \($0)]" } ?? "")")
        }

        // Full content rule JS, exactly as the live engine would run it.
        let rule = source.ruleContent.content
        if let start = rule.range(of: "<js>"), let end = rule.range(of: "</js>") {
            let js = String(rule[start.upperBound..<end.lowerBound])
            let value = engine.evaluate(js, bindings: ["result": hexBody, "baseUrl": source.bookSourceUrl])
            log("▸ FULL content JS → \(String(describing: value).prefix(400))")
            log("  lastError: \(engine.lastError ?? "nil")")
        }

        // ── The decisive probe ──
        // `request(url, method, body, req=false)` returns the EXACT `url,{options}`
        // string java.ajax would receive, without sending it. Feed that to AnalyzeUrl
        // (what the live analyzeUrlHandler does) and dump the resulting URLRequest;
        // then actually send it. Compare against the known-good curl shape.
        let urla = engine.evaluate(
            """
            request('/content','POST',{html:'',item_id:'7088926490901122078',source:'番茄',tab:'听书',tone_id:'4',variable:JSON.stringify({custom:''}),version:String(localVersion)},false)
            """,
            bindings: ["baseUrl": source.bookSourceUrl]
        ) ?? ""
        log("▸ urla = \(urla.prefix(500))")

        let analyzeUrl = AnalyzeUrl(ruleUrl: urla, baseUrl: source.bookSourceUrl)
        if let request = analyzeUrl.toURLRequest() {
            log("▸ URLRequest:")
            log("   method=\(request.httpMethod ?? "?") url=\(request.url?.absoluteString ?? "?")")
            log("   headers=\(request.allHTTPHeaderFields ?? [:])")
            log("   body=\(request.httpBody.flatMap { String(data: $0, encoding: .utf8) }?.prefix(400) ?? "nil")")

            let sem = DispatchSemaphore(value: 0)
            var responseBody = ""
            var statusCode = -1
            URLSession.shared.dataTask(with: request) { data, response, error in
                statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                responseBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(error: \(error?.localizedDescription ?? "nil"))"
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 30)
            log("▸ live send → status=\(statusCode) body=\(responseBody.prefix(400))")
        } else {
            log("▸ toURLRequest() returned NIL — AnalyzeUrl rejected the url,{options} form")
        }
        log("========== JS DEBUG DONE ==========")
    }

    static let replayResultPath = "/tmp/yuedu_audio_replay.txt"

    /// Offline replay of the downstream pipeline with the server's known-good audio
    /// response, isolating which stage eats the audio URL (no network, no rate limit):
    /// content-rule JS result → `$.content` extraction → `resolveContent` sanitize.
    @Test("offline replay: audio URL through rule extraction + resolveContent")
    func offlineAudioURLReplay() async {
        var out = ""
        func log(_ s: String) {
            out += s + "\n"
            print(s)
            try? out.write(toFile: Self.replayResultPath, atomically: true, encoding: .utf8)
        }

        guard let data = FileManager.default.contents(atPath: Self.jsonPath),
              var source = (try? JSONDecoder().decode([BookSource].self, from: data))?.first
        else {
            print("⏭️  Skipping offline replay: \(Self.jsonPath) not found")
            return
        }
        log("========== OFFLINE AUDIO REPLAY ==========")

        // The exact /content response captured from the live server (curl) for ch0.
        let audioURL = "https://v5-ex-novelapp.fqnovelvod.com/1a409e5bb93d06d864bd670dc57562ef/6a2d5360/video/tos/cn/tos-cn-v-710116/056d517d10fd46d29ea6c776d33df5ab/?a=1967&ch=0&cr=0&dr=0&er=3&cd=0%7C0%7C0%7C0&br=250&bt=250&ds=5&ft=7Ck-HDDhNFkVXMM6BMfusznFK8ySYiRxlMCThbLfK&mime_type=audio_mpeg&qs=13&rc=MzxvNTU6ZmdqPDMzNDk8M0BpMzxvNTU6ZmdqPDMzNDk8M0A1aXJecjRnX2RgLS1kXy9zYSM1aXJecjRnX2RgLS1kXy9zcw%3D%3D&btag=c0000e00038000&dy_q=1781268193&l=20260612204313D39F4F9E3549091FD894\n"
        let serverJSON = "{\"content\":\(String(data: try! JSONEncoder().encode(audioURL), encoding: .utf8)!)}"
        log("serverJSON head=\(serverJSON.prefix(120))")

        // Stage 1: `$.content` extraction alone, on the final JSON the content JS produces.
        // Use a rule that skips the JS (no network) and just extracts.
        var extractOnly = source
        extractOnly.ruleContent.content = "$.content"
        do {
            let bridge = ModernParserBridge(source: extractOnly)
            let parsed = try bridge.parseChapterResult(
                html: serverJSON, baseURL: source.bookSourceUrl, source: extractOnly)
            log("▸ $.content alone → len=\(parsed.content.count) head=\(parsed.content.prefix(140))")
        } catch {
            log("▸ $.content alone → THREW \(error)")
        }

        // Stage 2: <js>…</js>$.content with a stub JS returning the JSON (engine chaining).
        var jsChained = source
        jsChained.ruleContent.content = "<js>result;</js>$.content"
        var stage2Content = ""
        do {
            let bridge = ModernParserBridge(source: jsChained)
            let parsed = try bridge.parseChapterResult(
                html: serverJSON, baseURL: source.bookSourceUrl, source: jsChained)
            stage2Content = parsed.content
            log("▸ <js>result</js>$.content → len=\(parsed.content.count) head=\(parsed.content.prefix(140))")
        } catch {
            log("▸ <js>result</js>$.content → THREW \(error)")
        }

        // Stage 3: resolveContent sanitize on the raw audio URL.
        let payload = ChapterParsePayload(
            content: audioURL, title: "终极斗罗 0001 那是什么", sourceMatched: true, isPay: false)
        let resolved = await ChapterFetcher.shared.resolveContent(
            parsed: payload,
            replaceRules: source.ruleContent.replaceRegex,
            sourceUrl: "data:;base64,xxx",
            fetchViaJS: { nil },
            fetchBySelectors: { nil }
        )
        log("▸ resolveContent(rawURL) → len=\(resolved.count) head=\(resolved.prefix(140))")

        // Stage 4: resolveContent on whatever stage 2 produced (full downstream).
        if !stage2Content.isEmpty {
            let payload2 = ChapterParsePayload(
                content: stage2Content, title: "终极斗罗 0001 那是什么", sourceMatched: true, isPay: false)
            let resolved2 = await ChapterFetcher.shared.resolveContent(
                parsed: payload2,
                replaceRules: source.ruleContent.replaceRegex,
                sourceUrl: "data:;base64,xxx",
                fetchViaJS: { nil },
                fetchBySelectors: { nil }
            )
            log("▸ resolveContent(stage2) → len=\(resolved2.count) head=\(resolved2.prefix(140))")
        }
        log("========== OFFLINE REPLAY DONE ==========")
    }
}
