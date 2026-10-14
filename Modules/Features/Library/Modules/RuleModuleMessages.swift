import Foundation

// What the import sheet says when a module file is refused (Phase 6e): each reason names the
// field, so whoever wrote the module knows what to change.

extension RuleModuleRejection {
    var message: String {
        switch self {
        case .tooLarge: localized("模組檔案超過 256 KB。")
        case .notJSON: localized("這不是模組檔案：無法讀成 JSON。")
        case .missingField(let field): String(format: localized("缺少欄位 %@。"), field)
        case .malformed(let field): String(format: localized("欄位 %@ 的格式不對。"), field)
        case .invalidID(let id): String(format: localized("代號「%@」只能用英文字母、數字、句點、底線和連字號。"), id)
        case .invalidVersion(let field, let value): String(format: localized("%1$@ 的「%2$@」不是數字版本。"), field, value)
        case .requiresNewerApp(let required, let running):
            String(format: localized("這個模組需要閱讀 %1$@ 以上的版本，目前是 %2$@。"), required, running)
        case .noEntries: localized("模組沒有任何清單。")
        case .tooManyEntries(let count): String(format: localized("模組有 %d 個清單，上限是 50 個。"), count)
        case .duplicateEntryID(let id): String(format: localized("清單代號「%@」重複。"), id)
        case .emptyRule(let field): String(format: localized("%@ 的規則是空的。"), field)
        case .javaScript(let field): String(format: localized("%@ 含有 JavaScript，模組不執行 JavaScript。"), field)
        case .variables(let field): String(format: localized("%@ 用到 @get 或 @put，模組不支援變數。"), field)
        case .undeclaredTemplate(let field, let name):
            String(format: localized("%1$@ 的 {{%2$@}} 不是宣告過的參數。"), field, name)
        case .unknownParamType(let field, let type): String(format: localized("%1$@ 的參數類型「%2$@」不支援。"), field, type)
        case .enumerationWithoutOptions(let field): String(format: localized("%@ 沒有列出選項。"), field)
        case .unsupportedMethod(let field, let method):
            String(format: localized("%1$@ 的「%2$@」不支援，只能用 GET 或 POST。"), field, method)
        case .invalidURL(let field): String(format: localized("%@ 不是 http 或 https 網址。"), field)
        case .urlOptions(let field): String(format: localized("%@ 帶有網址選項（,{…}）；方法、內容和標頭請寫在各自的欄位。"), field)
        case .hostNotAllowed(let field, let host): String(format: localized("%1$@ 連到 %2$@，但 hosts 沒有列出它。"), field, host)
        }
    }
}

extension RuleModuleStoreError {
    var message: String {
        switch self {
        case .rejected(let rejection): rejection.message
        case .alreadyInstalled(let id): String(format: localized("已經加入過這個模組（%@）。"), id)
        case .notInstalled: localized("找不到這個模組。")
        case .differentModule(_, let offered): String(format: localized("下載到的是另一個模組（%@）。"), offered)
        case .notNewer: localized("已是最新版本")
        }
    }
}
