import re

file_path = "yuedu app/yuedu_appApp.swift"
with open(file_path, "r") as f:
    content = f.read()

old_block = """        await withTaskGroup(of: Void.self) { group in
            for book in onlineBooks {
                group.addTask {
                    await refreshBook(book: book, bookStore: bookStore)
                }
            }
        }"""

new_block = """        // Limit concurrency to avoid network request storms on startup that trigger Rate Limiting/Cloudflare
        let maxConcurrentTasks = 3
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<min(maxConcurrentTasks, onlineBooks.count) {
                group.addTask {
                    await refreshBook(book: onlineBooks[i], bookStore: bookStore)
                }
            }
            
            var index = maxConcurrentTasks
            for await _ in group {
                if index < onlineBooks.count {
                    let nextBook = onlineBooks[index]
                    group.addTask {
                        await refreshBook(book: nextBook, bookStore: bookStore)
                    }
                    index += 1
                }
            }
        }"""

if old_block in content:
    content = content.replace(old_block, new_block)
    with open(file_path, "w") as f:
        f.write(content)
    print("Replaced successfully.")
else:
    print("String not found in file.")
