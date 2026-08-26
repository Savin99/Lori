import XCTest

/// Запись начинается ровно из одного места — «+» → «Записать».
///
/// Кнопку микрофона в композере убрали намеренно: на главной она означала «записать
/// материал», а в чате — «продиктовать вопрос», и по кнопке это было не отличить.
@MainActor
final class RecordingEntryUITests: XCTestCase {
    func testRecordingStartsOnlyFromAddMenu() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        // На главной микрофона нет.
        XCTAssertFalse(app.buttons["Записать голосом"].exists, "в композере главной остался микрофон")

        app.buttons["Добавить заметку или файл"].tap()
        XCTAssertTrue(app.buttons["Записать"].waitForExistence(timeout: 3), "в «+» нет пункта «Записать»")
        XCTAssertTrue(app.buttons["Новая заметка"].exists)
        XCTAssertTrue(app.buttons["Выбрать файл"].exists)
        // Лист действий закрываем перезапуском, а не тапом по «Отмена»: в дереве
        // элементов диалога её нет, а тапать «Записать» здесь нельзя — начнётся запись.
        app.terminate()
        app.launch()

        // В чате микрофона нет тоже, а главная кнопка только отправляет.
        let composer = app.textFields.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        save(XCUIScreen.main.screenshot(), named: "recording-entry-home")
        composer.typeText("проверка композера\n")

        XCTAssertTrue(app.buttons["Закрыть чат"].waitForExistence(timeout: 5), "чат не открылся")
        XCTAssertFalse(app.buttons["Записать голосом"].exists, "в композере чата остался микрофон")
        XCTAssertEqual(
            app.buttons["chatPrimaryButton"].label,
            "Отправить",
            "главная кнопка чата должна только отправлять"
        )
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
