import Foundation

enum LegadoSourceJSONParser {
    /// Parse a Legado-format RSS subscription JSON array into RSSSource objects.
    static func parse(data: Data) throws -> [RSSSource] {
        let raw = try JSONSerialization.jsonObject(with: data)
        let array: [Any]
        if let dict = raw as? [String: Any] {
            array = [dict]
        } else if let arr = raw as? [Any] {
            array = arr
        } else {
            throw ParseError.invalidFormat
        }

        return array.compactMap { item -> RSSSource? in
            guard let json = item as? [String: Any] else { return nil }
            return parseSource(from: json)
        }
    }

    /// Export RSSSource objects to Legado-format JSON array data.
    static func export(sources: [RSSSource]) throws -> Data {
        let array = sources.map { exportJSON(from: $0) }
        return try JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - Private

    private static func parseSource(from json: [String: Any]) -> RSSSource? {
        guard let url = json["sourceUrl"] as? String, !url.isEmpty,
              let name = json["sourceName"] as? String, !name.isEmpty else {
            return nil
        }

        let existingID = json["_id"] as? String
        let id = existingID ?? UUID().uuidString

        return RSSSource(
            id: id,
            name: name,
            url: url,
            faviconURL: json["sourceIcon"] as? String,
            sortOrder: json["customOrder"] as? Int ?? 0,
            enabled: json["enabled"] as? Bool ?? true,
            sourceGroup: json["sourceGroup"] as? String,
            sourceIcon: json["sourceIcon"] as? String,
            ruleArticles: json["ruleArticles"] as? String,
            ruleTitle: json["ruleTitle"] as? String,
            ruleLink: json["ruleLink"] as? String,
            ruleDescription: json["ruleDescription"] as? String,
            ruleContent: json["ruleContent"] as? String,
            rulePubDate: json["rulePubDate"] as? String,
            ruleImage: json["ruleImage"] as? String,
            header: json["header"] as? String,
            sortUrl: json["sortUrl"] as? String,
            articleStyle: json["articleStyle"] as? Int ?? 0,
            customOrder: json["customOrder"] as? Int ?? 0,
            enableJs: json["enableJs"] as? Bool ?? true,
            enabledCookieJar: json["enabledCookieJar"] as? Bool ?? false,
            lastUpdateTime: json["lastUpdateTime"] as? Double ?? 0,
            loadWithBaseUrl: json["loadWithBaseUrl"] as? Bool ?? true,
            // Legado's RssSource default is false; the old `?? true` here broke
            // web-page detection for every source that omitted the field.
            singleUrl: json["singleUrl"] as? Bool ?? false,
            ruleNextPage: json["ruleNextPage"] as? String,
            sourceComment: json["sourceComment"] as? String,
            variableComment: json["variableComment"] as? String,
            concurrentRate: json["concurrentRate"] as? String,
            loginUrl: json["loginUrl"] as? String,
            loginUi: json["loginUi"] as? String,
            loginCheckJs: json["loginCheckJs"] as? String,
            coverDecodeJs: json["coverDecodeJs"] as? String,
            jsLib: json["jsLib"] as? String,
            style: json["style"] as? String,
            injectJs: json["injectJs"] as? String,
            contentWhitelist: json["contentWhitelist"] as? String,
            contentBlacklist: json["contentBlacklist"] as? String,
            shouldOverrideUrlLoading: json["shouldOverrideUrlLoading"] as? String,
            importedFromLegado: true
        )
    }

    private static func exportJSON(from source: RSSSource) -> [String: Any] {
        var json: [String: Any] = [
            "sourceName": source.name,
            "sourceUrl": source.url,
            "enabled": source.enabled,
            "articleStyle": source.articleStyle,
            "customOrder": source.customOrder,
            "enableJs": source.enableJs,
            "enabledCookieJar": source.enabledCookieJar,
            "lastUpdateTime": source.lastUpdateTime,
            "loadWithBaseUrl": source.loadWithBaseUrl,
            "singleUrl": source.singleUrl
        ]

        if let v = source.sourceGroup { json["sourceGroup"] = v }
        if let v = source.displayFaviconURL { json["sourceIcon"] = v }
        if let v = source.ruleArticles { json["ruleArticles"] = v }
        if let v = source.ruleTitle { json["ruleTitle"] = v }
        if let v = source.ruleLink { json["ruleLink"] = v }
        if let v = source.ruleDescription { json["ruleDescription"] = v }
        if let v = source.ruleContent { json["ruleContent"] = v }
        if let v = source.rulePubDate { json["rulePubDate"] = v }
        if let v = source.ruleImage { json["ruleImage"] = v }
        if let v = source.header { json["header"] = v }
        if let v = source.sortUrl { json["sortUrl"] = v }
        if let v = source.ruleNextPage { json["ruleNextPage"] = v }
        if let v = source.sourceComment { json["sourceComment"] = v }
        if let v = source.variableComment { json["variableComment"] = v }
        if let v = source.concurrentRate { json["concurrentRate"] = v }
        if let v = source.loginUrl { json["loginUrl"] = v }
        if let v = source.loginUi { json["loginUi"] = v }
        if let v = source.loginCheckJs { json["loginCheckJs"] = v }
        if let v = source.coverDecodeJs { json["coverDecodeJs"] = v }
        if let v = source.jsLib { json["jsLib"] = v }
        if let v = source.style { json["style"] = v }
        if let v = source.injectJs { json["injectJs"] = v }
        if let v = source.contentWhitelist { json["contentWhitelist"] = v }
        if let v = source.contentBlacklist { json["contentBlacklist"] = v }
        if let v = source.shouldOverrideUrlLoading { json["shouldOverrideUrlLoading"] = v }

        return json
    }
}

enum ParseError: LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return localized("無效的 Legado 訂閱源格式")
        }
    }
}
