file_path = "yuedu app/Views/ReaderView.swift"
with open(file_path, "r") as f:
    text = f.read()

old_code = """    private func speculativePreLayoutNextChapter() {
        Task { @MainActor in
            guard currentChapterIndex + 1 < chapters.count else { return }
            // 利用 currentEngine.warmUpNext 排版下一章
            currentEngine.warmUpNext(currentGlobalPage: currentPage + 1)
        }
    }"""

new_code = """    private func speculativePreLayoutNextChapter() {
        Task { @MainActor in
            guard currentChapterIndex + 1 < chapters.count else { return }
            // 利用 engine.warmUpNext 排版下一章
            epubRenderer.engine?.warmUpNext(currentGlobalPage: currentPage + 1)
        }
    }"""

text = text.replace(old_code, new_code)
with open(file_path, "w") as f:
    f.write(text)
print("done")
