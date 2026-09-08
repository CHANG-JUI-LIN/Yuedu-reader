import XCTest
import StoreKitTest

/// Opt-in local Simulator driver for reproducible, human-paced reader profiling.
/// Commands and captures stay outside the repository, including login inputs.
/// XCTest supplies real taps, drags, typing and accessibility snapshots.
final class LocalReaderProfilingUITests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/yuedu-reader-profiling", isDirectory: true)
    private var storeKitSession: SKTestSession?

    struct StoreKitScenario: Decodable {
        let configurationPath: String
        let productID: String
    }

    struct Command: Decodable {
        let action: String
        var label: String?
        var text: String?
        var x: Double?
        var y: Double?
        var endX: Double?
        var endY: Double?
        var duration: Double?
    }

    @MainActor
    func testLocalReadingSession() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.appendingPathComponent("enabled").path), "Local profiling is opt-in")
        continueAfterFailure = false
        executionTimeAllowance = 3600
        let storeKitFile = directory.appendingPathComponent("storekit.json")
        if FileManager.default.fileExists(atPath: storeKitFile.path) {
            let scenario = try JSONDecoder().decode(StoreKitScenario.self, from: Data(contentsOf: storeKitFile))
            let session = try SKTestSession(contentsOf: URL(fileURLWithPath: scenario.configurationPath))
            session.disableDialogs = true
            if session.allTransactions().isEmpty {
                try session.buyProduct(productIdentifier: scenario.productID)
            }
            storeKitSession = session
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
        app.launch()
        try capture(app, sequence: 0)
        for sequence in 1...1000 {
            let file = directory.appendingPathComponent("command-\(sequence).json")
            let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: file.path)
            }, object: nil)
            guard XCTWaiter.wait(for: [expected], timeout: 300) == .completed else {
                XCTFail("No next profiling command received"); return
            }
            let command = try JSONDecoder().decode(Command.self, from: Data(contentsOf: file))
            switch command.action {
            case "stop": try capture(app, sequence: sequence); return
            case "snapshot": break
            case "waitForPage":
                let expectedPage = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    app.descendants(matching: .any)
                        .matching(NSPredicate(format: "label == %@", "本章頁碼"))
                        .allElementsBoundByIndex.contains { element in
                            (element.value as? String)?.contains("/") == true
                        }
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [expectedPage], timeout: command.duration ?? 90), .completed,
                               "The requested chapter must display a numbered page")
            case "tapButton":
                let element = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", command.label ?? "", command.label ?? "")).firstMatch
                XCTAssertTrue(element.waitForExistence(timeout: command.duration ?? 15), "Requested button should exist")
                element.tap()
            case "tap":
                if let label = command.label {
                    let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label)).firstMatch
                    XCTAssertTrue(element.waitForExistence(timeout: command.duration ?? 15), "Requested control should exist")
                    element.tap()
                } else {
                    app.coordinate(withNormalizedOffset: CGVector(dx: command.x ?? 0.5, dy: command.y ?? 0.5)).tap()
                }
            case "type": app.typeText(command.text ?? "")
            case "typeSecure":
                let field = app.secureTextFields.firstMatch
                XCTAssertTrue(field.waitForExistence(timeout: 15), "Password input must be a secure field")
                field.tap()
                field.typeText(command.text ?? "")
            case "drag":
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: command.x ?? 0.85, dy: command.y ?? 0.6))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: command.endX ?? 0.15, dy: command.endY ?? 0.6))
                start.press(forDuration: command.duration ?? 0.08, thenDragTo: end)
            case "longPress":
                app.coordinate(withNormalizedOffset: CGVector(dx: command.x ?? 0.5, dy: command.y ?? 0.5)).press(forDuration: command.duration ?? 0.7)
            case "waitFor":
                let element = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR identifier == %@", command.label ?? "", command.label ?? "")).firstMatch
                XCTAssertTrue(element.waitForExistence(timeout: command.duration ?? 60), "Requested state should become visible")
            default: XCTFail("Unknown profiling action"); return
            }
            try capture(app, sequence: sequence)
        }
    }

    @MainActor
    private func capture(_ app: XCUIApplication, sequence: Int) throws {
        let base = directory.appendingPathComponent("capture-\(sequence)")
        try app.debugDescription.write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: base.appendingPathExtension("png"), options: .atomic)
        try String(ProcessInfo.processInfo.systemUptime).write(to: base.appendingPathExtension("ready"), atomically: true, encoding: .utf8)
    }
}
