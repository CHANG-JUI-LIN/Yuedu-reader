import re

file_path = "yuedu app/Models/Models.swift"
with open(file_path, "r") as f:
    content = f.read()

# adding import OSLog
if "import OSLog" not in content:
    content = content.replace("import Foundation", "import Foundation\nimport OSLog")

replacements = [
    (
        "            try? FileManager.default.removeItem(at: destURL)",
        "            do {\n                try FileManager.default.removeItem(at: destURL)\n            } catch {\n                Logger(subsystem: \"com.yuedu.app\", category: \"BookStore\").error(\"Failed to remove item at \\(destURL): \\(error)\")\n            }"
    ),
    (
        "                    try? FileManager.default.removeItem(at: coverURL)",
        "                    do {\n                        try FileManager.default.removeItem(at: coverURL)\n                    } catch {\n                        Logger(subsystem: \"com.yuedu.app\", category: \"BookStore\").error(\"Failed to remove cover image at \\(coverURL): \\(error)\")\n                    }"
    ),
    (
        "                    try? jpegData.write(to: coverURL)",
        "                    do {\n                        try jpegData.write(to: coverURL)\n                    } catch {\n                        Logger(subsystem: \"com.yuedu.app\", category: \"BookStore\").error(\"Failed to write cover image at \\(coverURL): \\(error)\")\n                    }"
    ),
    (
        "        try? rawText.write(to: fileURL, atomically: true, encoding: .utf8)",
        "        do {\n            try rawText.write(to: fileURL, atomically: true, encoding: .utf8)\n        } catch {\n            Logger(subsystem: \"com.yuedu.app\", category: \"BookStore\").error(\"Failed to write raw text chapter to \\(fileURL): \\(error)\")\n        }"
    ),
    (
        "                try? FileManager.default.removeItem(at: cacheDir)",
        "                do {\n                    try FileManager.default.removeItem(at: cacheDir)\n                } catch {\n                    Logger(subsystem: \"com.yuedu.app\", category: \"BookStore\").error(\"Failed to remove cache directory \\(cacheDir): \\(error)\")\n                }"
    ),
    (
        "                try? FileManager.default.removeItem(at: documentsURL(for: book.contentFilename))",
        "                do {\n                    let fileUrl = documentsURL(for: book.contentFilename)\n                    try FileManager.default.removeItem(at: fileUrl)\n                } catch {\n                    Logger(subsystem: \"com.yuedu.app\", category: \"BookStore\").error(\"Failed to remove document file \\(book.contentFilename): \\(error)\")\n                }"
    ),
    (
        "                    try? FileManager.default.removeItem(at: documentsURL(for: assetsDir))",
        "                    do {\n                        let assetsUrl = documentsURL(for: assetsDir)\n                        try FileManager.default.removeItem(at: assetsUrl)\n                    } catch {\n                        Logger(subsystem: \"com.yuedu.app\", category: \"BookStore\").error(\"Failed to remove assets directory \\(assetsDir): \\(error)\")\n                    }"
    ),
    (
        "        try? FileManager.default.removeItem(at: cacheDir)",
        "        do {\n            try FileManager.default.removeItem(at: cacheDir)\n        } catch {\n            Logger(subsystem: \"com.yuedu.app\", category: \"BookStore\").error(\"Failed to remove cache directory \\(cacheDir): \\(error)\")\n        }"
    )
]

for old, new in replacements:
    content = content.replace(old, new)

with open(file_path, "w") as f:
    f.write(content)

print("Replacements done.")
