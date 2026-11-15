import Foundation

/// A work's reviews as one module's site gave them, as the module's cache keeps them.
struct RuleModuleReviewPage: Codable, Equatable, Sendable {
    var reviews: [WorkReview]
    var rating: WorkRating?
    var fetchedAt: Date
    /// The module version whose rules read it, as `RuleModulePage.version`.
    var version: String?
}

extension RuleModuleClient {
    /// The cache name of a work's reviews. `~` is in no entry id (`RuleModuleValidator.isFileSafe`),
    /// so it is never an entry's own page.
    static let reviewsCacheName = "~reviews"
    /// Reviews kept per record.
    nonisolated static let reviewLimit = 100

    /// A work's reviews as last read, if this version of the module read them within the
    /// block's `cacheDuration`. `key` names the work as the module was asked about it.
    func cachedReviews(_ reviews: RuleModule.Reviews, key: [String: String], in module: RuleModule) -> RuleModuleReviewPage? {
        let duration = TimeInterval(max(reviews.cacheDuration ?? 0, 0))
        guard duration > 0,
              let cached = cached(RuleModuleReviewPage.self, at: cacheFile(module: module.id, entry: Self.reviewsCacheName, values: Self.reviewsCacheKey(key, in: module))),
              cached.version == module.version, now().timeIntervalSince(cached.fetchedAt) < duration else { return nil }
        return cached
    }

    /// Keeps a work's reviews, an empty answer too (a book nobody reviewed is not asked about at
    /// every opening), when the block sets a `cacheDuration`.
    func saveReviews(_ found: [WorkReview], rating: WorkRating?, by reviews: RuleModule.Reviews, key: [String: String],
                     in module: RuleModule) {
        guard (reviews.cacheDuration ?? 0) > 0 else { return }
        save(RuleModuleReviewPage(reviews: found, rating: rating, fetchedAt: now(), version: module.version),
             to: cacheFile(module: module.id, entry: Self.reviewsCacheName, values: Self.reviewsCacheKey(key, in: module)))
    }

    /// The work's key with the module's global values, which change what the site answers.
    nonisolated static func reviewsCacheKey(_ key: [String: String], in module: RuleModule) -> [String: String] {
        module.globalValues(language: nil).reduce(into: key) { $0["global.\($1.key)"] = $1.value }
    }

    /// Whether `item` has every key the request names: a record without its `id` is not asked.
    nonisolated static func canAskReviews(of item: RuleListItem, by reviews: RuleModule.Reviews) -> Bool {
        let request = reviews.request
        let names = Set(RuleModuleValidator.templateNames(
            in: request.url + (request.body ?? "") + (request.headers ?? [:]).values.joined()))
        func has(_ value: String?) -> Bool { !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return (!names.contains("id") || has(item.id)) && (!names.contains("url") || has(item.bookUrl))
    }

    /// One record's reviews: the block's request with the record's `{{id}}` and `{{url}}`, then
    /// its rules on a bare engine. `{{url}}` is as it is at the start of the address,
    /// percent-encoded anywhere else, as `detail` has it.
    func reviews(of item: RuleListItem, by reviews: RuleModule.Reviews,
                 in module: RuleModule) async throws -> (reviews: [WorkReview], rating: WorkRating?) {
        let values = module.withGlobalValues(["id": item.id ?? "", "url": item.bookUrl], language: nil)
        let started = SourcePerfTrace.now
        let page = try await perform(reviews.request, values: values, ofRecord: true, in: module)
        let read = await Self.readReviews(page.text, baseURL: page.baseURL, by: reviews, scripts: module.scripts)
        SourcePerfTrace.record("module.reviews", "module=\(module.id) reviews=\(read.reviews.count)", since: started, thresholdMs: 0)
        return read
    }

    /// The page's reviews and rating. Off the caller's actor: a page of a hundred reviews is a
    /// hundred HTML-to-text passes.
    @concurrent
    nonisolated static func readReviews(_ text: String, baseURL: String, by reviews: RuleModule.Reviews,
                                        scripts: RuleModuleScriptRuntime? = nil) async -> (reviews: [WorkReview], rating: WorkRating?) {
        let engine = RuleModuleScriptRuntime.engine(scripts)
        let scale = reviews.ratingScale ?? Double(WorkRating.stars)
        let found = readList(reviews.list, in: text, baseURL: baseURL, scale: scale, engine: engine)
        var rating: WorkRating?
        if let summary = reviews.rating {
            engine.setContent(text, baseUrl: baseURL)
            if let score = stars(engine.getString(ruleStr: summary.score), outOf: scale) {
                let count = summary.count.flatMap { Int(engine.getString(ruleStr: $0).trimmingCharacters(in: .whitespaces)) }
                let bars = summary.distribution.map { engine.getStringList(ruleStr: $0).map { Int($0.trimmingCharacters(in: .whitespaces)) } } ?? []
                // A bar per star, or none: a site's four or ten buckets are not five stars'.
                let distribution = bars.count == WorkRating.stars ? bars.compactMap { $0 }.filter { $0 >= 0 } : []
                rating = WorkRating(score: score, count: count.flatMap { $0 > 0 ? $0 : nil },
                                    distribution: distribution.count == WorkRating.stars ? distribution : nil)
            }
        }
        return (found, rating)
    }

    /// The page's reviews, or a chapter's comments (`comments.chapter.list`): one rule set reads both.
    nonisolated static func readList(_ rules: RuleModule.ReviewRules, in text: String, baseURL: String, scale: Double,
                                     engine: ModernRuleEngine) -> [WorkReview] {
        engine.setContent(text, baseUrl: baseURL)
        var found: [WorkReview] = []
        for element in engine.getElements(ruleStr: rules.items) {
            guard found.count < reviewLimit else { break }
            engine.setContent(element, baseUrl: baseURL)
            let body = plainText(engine.getString(ruleStr: rules.text), limit: WorkReview.textLimit)
            guard !body.isEmpty else { continue }
            func line(_ rule: String?, limit: Int) -> String? {
                guard let rule, !rule.isEmpty else { return nil }
                let value = OPDSClient.plainMetadata(engine.getString(ruleStr: rule), limit: limit)
                return value.isEmpty ? nil : value
            }
            found.append(WorkReview(
                title: line(rules.title, limit: WorkReview.titleLimit),
                text: body,
                author: line(rules.author, limit: WorkReview.authorLimit),
                date: line(rules.date, limit: 40).flatMap(date(from:)),
                rating: line(rules.rating, limit: 20).flatMap { stars($0, outOf: scale) },
                likes: line(rules.likes, limit: 20).flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }))
        }
        return found
    }

    /// A site's number as stars out of `WorkRating.stars`; nil for no number, zero (unrated), or
    /// one outside the scale.
    nonisolated static func stars(_ text: String, outOf scale: Double) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite, value > 0,
              scale > 0, value <= scale else { return nil }
        return value / scale * Double(WorkRating.stars)
    }

    /// Plain text, one line per paragraph: the site's HTML blocks and its own line breaks.
    nonisolated static func plainText(_ raw: String, limit: Int) -> String {
        let broken = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: OPDSClient.paragraphBreak)
        return OPDSClient.plainParagraphs(broken, limit: limit)
    }

    /// A date as sites write one: seconds (or milliseconds) since 1970, ISO 8601, or
    /// `yyyy-MM-dd[ HH:mm:ss]`, read as UTC. Only its day is shown, so a site's own zone moves it
    /// a day at most.
    nonisolated static func date(from text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Double(text) {
            switch text.count {
            case 9...10: return Date(timeIntervalSince1970: number)
            case 12...13: return Date(timeIntervalSince1970: number / 1_000)
            default: return nil
            }
        }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
