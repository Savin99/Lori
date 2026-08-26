import XCTest

/// Вложение в ленте чата: принесённая запись показана карточкой, из неё видно
/// состояние и можно уйти в карточку записи.
///
/// Выбор файла идёт через системный документный выбор, который из теста не подсунуть,
/// поэтому вложение сеется прямо в историю чата: `design/qa/seed-digest.sh`.
@MainActor
final class ChatAttachmentUITests: XCTestCase {
    func testAttachedRecordingIsShownAsCardInChat() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        // Пустая отправка открывает чат, ничего не спрашивая у модели.
        let composer = app.textFields.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("\n")

        app.buttons["История чатов"].tap()
        let saved = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "вот запись")
        ).firstMatch
        try XCTSkipUnless(
            saved.waitForExistence(timeout: 5),
            "нет засеянной истории с вложением — прогони design/qa/seed-digest.sh"
        )
        saved.tap()

        // Карточка вложения: имя, состояние и действие.
        XCTAssertTrue(
            app.staticTexts["UI live"].waitForExistence(timeout: 5),
            "вложение не показано карточкой"
        )
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "Расшифровка готова")
            ).firstMatch.exists || app.staticTexts["Расшифровываю…"].exists,
            "в карточке не видно состояния расшифровки"
        )
        save(XCUIScreen.main.screenshot(), named: "chat-attachment")

        let open = app.buttons["Открыть запись"]
        XCTAssertTrue(open.exists, "из карточки нельзя открыть запись")
        open.tap()
        XCTAssertTrue(app.buttons["Слушать"].waitForExistence(timeout: 5), "карточка записи не открылась")
        XCTAssertTrue(app.buttons["Важное"].exists || app.segmentedControls.firstMatch.exists,
                      "в открытой записи нет переключателя вида")
        app.buttons["Готово"].tap()
        XCTAssertTrue(app.buttons["Закрыть чат"].waitForExistence(timeout: 5), "не вернулись в чат")
    }

    private func save(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
