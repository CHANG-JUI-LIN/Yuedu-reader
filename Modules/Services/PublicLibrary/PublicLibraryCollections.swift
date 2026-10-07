import Foundation

/// Editorial book lists, not live rankings. IDs and metadata come from the
/// recorded official Chinese feed and the linked Gutenberg book pages. No asset
/// or adjacent feed is downloaded to render the store home.
struct PublicLibraryCollection: Identifiable {
    let id: String
    let titleKey: String
    let books: [GutenbergBook]

    static let chinese = Self(id: "chinese", titleKey: "中文書籍", books: [
        .init(id: 24264, title: "紅樓夢", author: "曹雪芹"),
        .init(id: 23962, title: "西遊記", author: "吳承恩"),
        .init(id: 23950, title: "三國志演義", author: "羅貫中"),
        .init(id: 23863, title: "水滸傳", author: "施耐庵"),
        .init(id: 51828, title: "聊齋志異", author: "蒲松齡"),
        .init(id: 25271, title: "朝花夕拾", author: "魯迅"),
    ])
    static let fiction = Self(id: "fiction", titleKey: "小說與文學", books: [
        .init(id: 1342, title: "Pride and Prejudice", author: "Jane Austen"),
        .init(id: 84, title: "Frankenstein", author: "Mary Wollstonecraft Shelley"),
        .init(id: 1661, title: "The Adventures of Sherlock Holmes", author: "Arthur Conan Doyle"),
        .init(id: 27166, title: "吶喊", author: "魯迅"),
    ])
    static let children = Self(id: "children", titleKey: "兒童與青少年", books: [
        .init(id: 11, title: "Alice's Adventures in Wonderland", author: "Lewis Carroll"),
        .init(id: 902, title: "The Happy Prince, and Other Tales", author: "Oscar Wilde"),
    ])
    static let thought = Self(id: "thought", titleKey: "思想與歷史", books: [
        .init(id: 7337, title: "道德經", author: "老子"),
        .init(id: 23839, title: "論語", author: "孔子"),
        .init(id: 24226, title: "史記", author: "司馬遷"),
        .init(id: 25501, title: "易經", author: ""),
    ])
    static let all = [chinese, fiction, children, thought]
}
