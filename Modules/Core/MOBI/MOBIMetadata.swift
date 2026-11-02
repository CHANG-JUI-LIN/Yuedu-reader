// Ported from foliate-js `mobi.js` (MIT, Copyright (c) 2022 John Factotum).
// The full licence is in foliate-js-LICENSE.txt beside this file.

import Foundation
import SwiftSoup

/// A MOBI file's bibliographic metadata, from EXTH with the MOBI header as the
/// fallback the format itself defines (foliate's `getMetadata`).
///
/// Strings are as stored. Kindle tools sometimes write HTML entities into EXTH
/// (`&amp;`); the converters decode them (`entitiesDecoded()`) before the values
/// become OPF text.
struct MOBIMetadata: Sendable, Equatable {
    var identifier: String
    var title: String?
    var authors: [String]
    var publisher: String?
    /// BCP 47: EXTH 524, else the MOBI header's locale.
    var language: String?
    var published: String?
    var description: String?
    var subjects: [String]
    var rights: String?
    var contributors: [String]
    var isbn: String?
    var asin: String?
    /// Resource index of the cover: EXTH 201, else the thumbnail (202).
    var coverResource: Int?
    var fixedLayout: Bool
    /// `"<width>x<height>"` of a fixed-layout book's pages.
    var originalResolution: String?
    var pageProgressionDirection: String?
    var primaryWritingMode: String?

    init(_ file: MOBIFile) {
        let headers = file.headers
        let exth = headers.exth
        identifier = String(headers.uniqueID)
        title = Self.nonEmpty(exth?.string(.title)) ?? Self.nonEmpty(headers.fullName)
        authors = exth?.strings(.creator) ?? []
        publisher = exth?.string(.publisher)
        language = exth?.string(.language) ?? Self.language(locale: headers.locale)
        published = exth?.string(.date)
        description = exth?.string(.description)
        subjects = exth?.strings(.subject) ?? []
        rights = exth?.string(.rights)
        contributors = exth?.strings(.contributor) ?? []
        isbn = exth?.string(.isbn)
        asin = exth?.string(.asin)
        coverResource = (exth?.number(.coverOffset) ?? exth?.number(.thumbnailOffset)).map(Int.init)
        fixedLayout = exth?.string(.fixedLayout) == "true"
        originalResolution = exth?.string(.originalResolution)
        pageProgressionDirection = exth?.string(.pageProgressionDirection)
        primaryWritingMode = exth?.string(.primaryWritingMode)
    }

    /// The text fields with the HTML entities Kindle tools write into EXTH strings decoded.
    func entitiesDecoded() throws -> MOBIMetadata {
        func clean(_ value: String?) throws -> String? {
            try value.map { try Entities.unescape($0) }
        }
        var result = self
        result.title = try clean(title)
        result.authors = try authors.map { try Entities.unescape($0) }
        result.publisher = try clean(publisher)
        result.description = try clean(description)
        result.subjects = try subjects.map { try Entities.unescape($0) }
        result.rights = try clean(rights)
        result.contributors = try contributors.map { try Entities.unescape($0) }
        return result
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.isEmpty else { return nil }
        return string
    }

    /// The locale field's language id (low byte) and region id (bits 10–15),
    /// through foliate's `MOBI_LANG` table: the region picks a tag from the
    /// language's list, the list's first tag when there is none for it.
    static func language(locale: UInt32) -> String? {
        guard let tags = languageTable[Int(locale & 0xFF)] else { return nil }
        let region = Int(locale >> 10 & 0x3F)
        if region < tags.count, let tag = tags[region] { return tag }
        return tags.first ?? nil
    }

    private static let languageTable: [Int: [String?]] = [
        1: ["ar", "ar-SA", "ar-IQ", "ar-EG", "ar-LY", "ar-DZ", "ar-MA", "ar-TN", "ar-OM",
            "ar-YE", "ar-SY", "ar-JO", "ar-LB", "ar-KW", "ar-AE", "ar-BH", "ar-QA"],
        2: ["bg"], 3: ["ca"], 4: ["zh", "zh-TW", "zh-CN", "zh-HK", "zh-SG"], 5: ["cs"],
        6: ["da"], 7: ["de", "de-DE", "de-CH", "de-AT", "de-LU", "de-LI"], 8: ["el"],
        9: ["en", "en-US", "en-GB", "en-AU", "en-CA", "en-NZ", "en-IE", "en-ZA",
            "en-JM", nil, "en-BZ", "en-TT", "en-ZW", "en-PH"],
        10: ["es", "es-ES", "es-MX", nil, "es-GT", "es-CR", "es-PA", "es-DO",
             "es-VE", "es-CO", "es-PE", "es-AR", "es-EC", "es-CL", "es-UY", "es-PY",
             "es-BO", "es-SV", "es-HN", "es-NI", "es-PR"],
        11: ["fi"], 12: ["fr", "fr-FR", "fr-BE", "fr-CA", "fr-CH", "fr-LU", "fr-MC"],
        13: ["he"], 14: ["hu"], 15: ["is"], 16: ["it", "it-IT", "it-CH"],
        17: ["ja"], 18: ["ko"], 19: ["nl", "nl-NL", "nl-BE"], 20: ["no", "nb", "nn"],
        21: ["pl"], 22: ["pt", "pt-BR", "pt-PT"], 23: ["rm"], 24: ["ro"], 25: ["ru"],
        26: ["hr", nil, "sr"], 27: ["sk"], 28: ["sq"], 29: ["sv", "sv-SE", "sv-FI"],
        30: ["th"], 31: ["tr"], 32: ["ur"], 33: ["id"], 34: ["uk"], 35: ["be"],
        36: ["sl"], 37: ["et"], 38: ["lv"], 39: ["lt"], 41: ["fa"], 42: ["vi"],
        43: ["hy"], 44: ["az"], 45: ["eu"], 46: ["hsb"], 47: ["mk"], 48: ["st"],
        49: ["ts"], 50: ["tn"], 52: ["xh"], 53: ["zu"], 54: ["af"], 55: ["ka"],
        56: ["fo"], 57: ["hi"], 58: ["mt"], 59: ["se"], 62: ["ms"], 63: ["kk"],
        65: ["sw"], 67: ["uz", nil, "uz-UZ"], 68: ["tt"], 69: ["bn"], 70: ["pa"],
        71: ["gu"], 72: ["or"], 73: ["ta"], 74: ["te"], 75: ["kn"], 76: ["ml"],
        77: ["as"], 78: ["mr"], 79: ["sa"], 82: ["cy", "cy-GB"], 83: ["gl", "gl-ES"],
        87: ["kok"], 97: ["ne"], 98: ["fy"],
    ]
}

extension MOBIFile {
    var metadata: MOBIMetadata { MOBIMetadata(self) }

    /// The cover image's bytes, when the file names one.
    func cover() throws -> Data? {
        guard let index = metadata.coverResource else { return nil }
        return try resource(index)
    }
}
