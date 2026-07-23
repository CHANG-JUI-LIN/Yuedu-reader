import Foundation
import Testing
@testable import yuedu_app

// MARK: - BookSourceImportDeepLinkTests

// System-level deep-link parsing for book-source imports. Covers the three
// shapes supported by `BookSourceImportDeepLink.sourceURL(from:)`, which is the
// single path shared by the in-app WebView interceptor and the App entry
// `.onOpenURL` handler. Mirrors the assertions previously living inline in
// `BookSourceLoginTests` `WebView 導入按鈕解析 …` cases, now against the
// shared parser.

@Suite("BookSourceImportDeepLink")
struct BookSourceImportDeepLinkTests {

    @Test("解析 yuedu://booksource/importOnline?src=URL（舊自有格式）")
    func parsesLegacyYueduImport() throws {
        let url = try #require(URL(
            string: "yuedu://booksource/importOnline?src=https%3A%2F%2Fskybook.qzz.io%2Ffile%2Fjson%2F25AT8sH6EQOSEKxXfLPd0D.json"
        ))
        let sourceURL = try #require(BookSourceImportDeepLink.sourceURL(from: url))
        #expect(sourceURL.scheme == "https")
        #expect(sourceURL.absoluteString == "https://skybook.qzz.io/file/json/25AT8sH6EQOSEKxXfLPd0D.json")
    }

    @Test("解析 yuedu://import/bookSource?src=URL（Legado 風格套在 yuedu scheme）")
    func parsesYueduLegadoStyleImport() throws {
        let url = try #require(URL(
            string: "yuedu://import/bookSource?src=https%3A%2F%2Fskybook.qzz.io%2Ffile%2Fjson%2F25AT8sH6EQOSEKxXfLPd0D.json"
        ))
        let sourceURL = try #require(BookSourceImportDeepLink.sourceURL(from: url))
        #expect(sourceURL.scheme == "https")
        #expect(sourceURL.absoluteString == "https://skybook.qzz.io/file/json/25AT8sH6EQOSEKxXfLPd0D.json")
    }

    @Test("解析 legado://import/auto?src=URL（Legado 自有 scheme）")
    func parsesLegadoImport() throws {
        let url = try #require(URL(
            string: "legado://import/auto?src=https%3A%2F%2Fqd.doubi.tk%2Fsource%2Fapi%2Fdownload%2Fsource.json%3Fkey%3DKsJR74bFLwC8chgi"
        ))
        let sourceURL = try #require(BookSourceImportDeepLink.sourceURL(from: url))
        #expect(sourceURL.scheme == "https")
        #expect(sourceURL.absoluteString == "https://qd.doubi.tk/source/api/download/source.json?key=KsJR74bFLwC8chgi")
    }

    @Test("接受 ?url= 而不是 ?src= query item")
    func ParsesUrlQueryItem() throws {
        let url = try #require(URL(
            string: "yuedu://import/bookSource?url=https%3A%2F%2Fexample.com%2Fsource.json"
        ))
        let sourceURL = try #require(BookSourceImportDeepLink.sourceURL(from: url))
        #expect(sourceURL.absoluteString == "https://example.com/source.json")
    }

    @Test("非 import deep link 回傳 nil")
    func rejectsUnrelatedYueduURL() throws {
        let url = try #require(URL(string: "yuedu://something/else?src=https://example.com"))
        #expect(BookSourceImportDeepLink.sourceURL(from: url) == nil)
    }

    @Test("缺 src/url query item 回傳 nil")
    func rejectsMissingSourceQueryItem() throws {
        let url = try #require(URL(string: "yuedu://import/bookSource"))
        #expect(BookSourceImportDeepLink.sourceURL(from: url) == nil)
    }

    @Test("src 為空字串回傳 nil")
    func rejectsEmptySourceQueryItem() throws {
        let url = try #require(URL(string: "yuedu://import/bookSource?src="))
        #expect(BookSourceImportDeepLink.sourceURL(from: url) == nil)
    }
}