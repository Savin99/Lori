import XCTest

/// Источники создаёт make-format-fixtures.sh и кладёт safe-container.py в QA Models/Formats.
/// Здесь настоящий системный пикер и общий импорт, без подмены форматов или файлового сервиса.
@MainActor
final class FormatImportUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-stub-engine", "--ui-stub-seconds", "1", "--forget-attachments", "-transcriptionEngine", "apple", "-gatewayBaseURL", "", "-annotationSource", "local", "-gatewayAutoSummary", "NO"]
        app.launch()
        return app
    }
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func folder(_ name: String, in app: XCUIApplication) {
        let cell = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 8), app.debugDescription)
        // В режиме значков подпись — отдельная область; открываем сам значок папки.
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
    }
    func testFilesPickerImportsOggAndVideoAndPlaysTranscripts() throws {
        let app = launch()
        for name in ["Telegram QA 13.11.2026", "Video QA 13.11.2026"] {
            app.buttons["importButton"].tap()
            app.buttons["Аудио из Файлов"].tap()
            // Пикер запоминает предыдущую папку: если нужный файл уже виден, не уходим.
            if !app.collectionViews["File View"].staticTexts[name].waitForExistence(timeout: 3) {
                let browse = app.buttons["Обзор"]
                if browse.exists { browse.tap() }
                if !app.staticTexts["Lori QA"].exists {
                    let onPhone = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "iPhone")).firstMatch
                    XCTAssertTrue(onPhone.waitForExistence(timeout: 5), app.debugDescription)
                    onPhone.tap()
                }
                folder("Lori QA", in: app)
                folder("Lori", in: app)
                folder("Models", in: app)
                folder("Formats", in: app)
            }
            let file = app.collectionViews["File View"].staticTexts[name]
            XCTAssertTrue(file.waitForExistence(timeout: 5), app.debugDescription)
            let fileCell = app.collectionViews["File View"].cells.matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
            XCTAssertTrue(fileCell.waitForExistence(timeout: 5), app.debugDescription)
            fileCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            let open = app.buttons["Открыть"]
            if open.exists { open.tap() }
            let transcribe = app.buttons["transcribeButton"]
            XCTAssertTrue(transcribe.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.staticTexts[name].exists, "временный заголовок без исходного расширения")
            snapshot("format-attachment-" + name)
            transcribe.tap()
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "recordingCard", name)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
            row.tap()
            let play = app.buttons["Слушать"]
            XCTAssertTrue(play.waitForExistence(timeout: 5))
            XCTAssertTrue(play.isEnabled)
            play.tap()
            XCTAssertTrue(app.buttons["Пауза"].waitForExistence(timeout: 2), "переведённый файл играет")
            if app.buttons["Пауза"].exists { app.buttons["Пауза"].tap() }
            let transcript = app.buttons["recordingTab.transcript"]
            if transcript.exists { transcript.tap() }
            XCTAssertTrue(app.descendants(matching: .any)["transcriptLines"].waitForExistence(timeout: 10), app.debugDescription)
            snapshot("format-transcript-" + name)
            app.buttons["Записи"].tap()
        }
    }
}
