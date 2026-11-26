import Foundation

/// What the paywall says, grouped the way readers weigh it: four benefits, each carried by
/// a few concrete things Pro does. Keys only — the view localizes them.
///
/// A row names a `PremiumFeature` so the paywall can mark the one that was tapped; the AI
/// feature is one entitlement but four rows, because 問書, 翻譯, 查詞 and 整理書架 are four
/// reasons to pay, not one.
enum PremiumPillar: String, CaseIterable, Identifiable {
    case understanding
    case comfort
    case habits
    /// 新增模組 (maintainer, 2026-11-15: its own group, not a row of 照你的習慣讀).
    case modules

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .understanding: return "AI 讀懂一本書"
        case .comfort: return "讀得更舒服"
        case .habits: return "照你的習慣讀"
        case .modules: return "接上更多內容"
        }
    }

    var iconName: String {
        switch self {
        case .understanding: return "sparkles"
        case .comfort: return "paintpalette"
        case .habits: return "hand.tap"
        case .modules: return "puzzlepiece.extension"
        }
    }

    /// What a buyer should know before paying for this pillar, or nil.
    var noteKey: String? {
        switch self {
        // Said up front: finding out after paying that AI needs your own key is a refund.
        case .understanding: return "AI 功能用你自己的 AI 服務金鑰，支援 DeepSeek、OpenAI、Claude、Gemini 等。"
        case .comfort, .habits: return nil
        // Said up front, as the AI key is: what was free before the gate stays free.
        case .modules: return "官方模組、已安裝的模組和它們的更新，不需要 Pro。"
        }
    }

    var benefits: [PremiumBenefit] {
        switch self {
        case .understanding:
            return [
                PremiumBenefit(feature: .aiReading, iconName: "bubble.left.and.text.bubble.right",
                               titleKey: "問書助手", detailKey: "看不懂就問，答案附原文出處，只根據你讀過的部分回答"),
                PremiumBenefit(feature: .aiReading, iconName: "translate",
                               titleKey: "整章翻譯", detailKey: "整章排成雙語對照，或只看譯文"),
                PremiumBenefit(feature: .aiReading, iconName: "character.book.closed",
                               titleKey: "AI 查詞", detailKey: "選一個詞，看它在這一句裡的意思"),
                PremiumBenefit(feature: .paragraphNote, iconName: "note.text",
                               titleKey: "段落筆記", detailKey: "在劃線旁寫下想法，筆記跟著原文走"),
                PremiumBenefit(feature: .aiReading, iconName: "books.vertical",
                               titleKey: "AI 整理書架", detailKey: "幫整架書分好組，你確認了才套用"),
            ]
        case .comfort:
            return [
                PremiumBenefit(feature: .readingStyles, iconName: "rectangle.stack",
                               titleKey: "閱讀樣式", detailKey: "內建多套排版，也能把自己的設定存成樣式"),
                PremiumBenefit(feature: .readerThemePacks, iconName: "paintpalette",
                               titleKey: "外觀主題", detailKey: "App 與閱讀配色、頁面背景，都能自己調"),
                PremiumBenefit(feature: .readerBackgroundImport, iconName: "photo.on.rectangle.angled",
                               titleKey: "自訂閱讀背景", detailKey: "用自己的圖片當書頁背景"),
                PremiumBenefit(feature: .customFonts, iconName: "f.cursive",
                               titleKey: "字體匯入", detailKey: "匯入喜歡的字體，閱讀和介面都能用"),
                PremiumBenefit(feature: .dialogueHighlight, iconName: "text.bubble",
                               titleKey: "對話氣泡與高亮", detailKey: "對白排成聊天氣泡，重點按規則自動上色"),
                PremiumBenefit(feature: .commentStyles, iconName: "quote.bubble",
                               titleKey: "氣泡設定", detailKey: "段評氣泡、本章說與作者說卡片，換成你的樣式"),
            ]
        case .habits:
            return [
                PremiumBenefit(feature: .touchZoneEditor, iconName: "hand.tap",
                               titleKey: "翻頁區塊", detailKey: "畫面分成 3×3，每一格點了做什麼由你決定"),
                PremiumBenefit(feature: .layoutPresetImport, iconName: "slider.horizontal.3",
                               titleKey: "排版備份", detailKey: "整套排版匯出匯入，也能讀 Legado 的設定檔"),
                PremiumBenefit(feature: .bottomBarCustomization, iconName: "square.grid.2x2",
                               titleKey: "底部分頁", detailKey: "自訂底部 Tab 的頁面、大小與圖示"),
                PremiumBenefit(feature: .launchScreen, iconName: "app.dashed",
                               titleKey: "啟動圖", detailKey: "換上你自己的開屏畫面"),
            ]
        case .modules:
            // One entitlement, three reasons, as AI is: the way in, the repository, what a
            // module brings.
            return [
                PremiumBenefit(feature: .moduleImport, iconName: "doc.badge.plus",
                               titleKey: "新增模組", detailKey: "從網址、檔案或剪貼簿加入第三方模組"),
                PremiumBenefit(feature: .moduleImport, iconName: "shippingbox",
                               titleKey: "模組倉庫", detailKey: "訂閱一個倉庫，裡面的模組選了就裝"),
                PremiumBenefit(feature: .moduleImport, iconName: "books.vertical",
                               titleKey: "書單、搜尋與評論", detailKey: "模組把榜單、搜尋結果和讀者評論帶進探索與詳情頁"),
            ]
        }
    }

    /// The pillar a feature is sold under.
    static func pillar(for feature: PremiumFeature) -> PremiumPillar? {
        allCases.first { pillar in pillar.benefits.contains { $0.feature == feature } }
    }

    /// Every pillar, the tapped feature's first: the reason they opened the paywall leads.
    static func ordered(leading feature: PremiumFeature?) -> [PremiumPillar] {
        guard let feature, let lead = pillar(for: feature) else { return allCases }
        return [lead] + allCases.filter { $0 != lead }
    }
}

struct PremiumBenefit: Identifiable, Equatable {
    let feature: PremiumFeature
    let iconName: String
    let titleKey: String
    let detailKey: String

    var id: String { titleKey }
}

/// The paywall's opening line: about what the reader just tapped, or about Pro as a whole
/// when they came from the Pro row.
struct PremiumPitch: Equatable {
    let headlineKey: String
    let pitchKey: String

    static func pitch(for feature: PremiumFeature?) -> PremiumPitch {
        switch feature {
        case .aiReading?:
            return .init(headlineKey: "讀不懂的地方，問 AI 就好",
                         pitchKey: "問書、整章翻譯、查詞都附原文出處，只根據你讀過的部分回答。")
        case .paragraphNote?:
            return .init(headlineKey: "在劃線旁寫下你的想法",
                         pitchKey: "筆記跟著原文段落走，隨時翻回來都看得到。")
        case .customFonts?:
            return .init(headlineKey: "用你喜歡的字體讀書",
                         pitchKey: "匯入字體檔，閱讀正文和 App 介面都能換上。")
        case .touchZoneEditor?:
            return .init(headlineKey: "翻頁照你的手感",
                         pitchKey: "把畫面分成 3×3 區塊，每一格點了做什麼由你決定。")
        case .dialogueHighlight?:
            return .init(headlineKey: "對白和重點一眼就看到",
                         pitchKey: "對話排成聊天氣泡，關鍵字依規則自動上色。")
        case .layoutPresetImport?:
            return .init(headlineKey: "整套排版一鍵帶走",
                         pitchKey: "字級、行距、標題樣式與高亮一起匯出匯入，也能讀 Legado 的設定檔。")
        case .readerBackgroundImport?:
            return .init(headlineKey: "把喜歡的圖片變成書頁",
                         pitchKey: "匯入圖片當閱讀背景。")
        case .bottomBarCustomization?:
            return .init(headlineKey: "底部分頁照你的順序",
                         pitchKey: "自訂底部 Tab 的頁面、大小與圖示。")
        case .readerThemePacks?:
            return .init(headlineKey: "整個 App 換成你的顏色",
                         pitchKey: "自訂 App 與閱讀配色，還有每一頁的背景。")
        case .launchScreen?:
            return .init(headlineKey: "打開 App，先看到你的畫面",
                         pitchKey: "換上自己的開屏圖片。")
        case .readingStyles?:
            return .init(headlineKey: "一鍵換上整套排版",
                         pitchKey: "依語言調好的內建樣式，還能把你調好的設定存成自己的樣式。")
        case .commentStyles?:
            return .init(headlineKey: "段評和評論卡片，照你的樣子畫",
                         pitchKey: "段評氣泡、本章說、作者說和神評論卡片換上自己的樣式，評論列表的外觀也能調。")
        case .moduleImport?:
            return .init(headlineKey: "用模組接上更多內容",
                         pitchKey: "從網址、檔案或模組倉庫加入第三方模組，榜單、搜尋和評論跟著進來。")
        case .alternateAppIcons?, nil:
            return .init(headlineKey: "每一本書，都讀得更懂、更舒服",
                         pitchKey: "AI 讀書助手、外觀與字體、你的閱讀習慣、第三方模組，一次解鎖。")
        }
    }
}

/// Price framing for the plan cards.
enum PaywallPricing {
    /// How many months of the monthly plan the lifetime price equals, to the nearest half
    /// month — "約 7.5 個月的月費" — or nil when either price is missing or not positive.
    static func lifetimeInMonths(lifetime: Decimal, monthly: Decimal) -> Decimal? {
        guard lifetime > 0, monthly > 0 else { return nil }
        let months = NSDecimalNumber(decimal: lifetime / monthly).doubleValue
        guard months.isFinite, months >= 1 else { return nil }
        return Decimal((months * 2).rounded() / 2)
    }
}
