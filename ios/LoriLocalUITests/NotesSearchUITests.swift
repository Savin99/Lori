import XCTest

/// Поиск по заметкам. До него найти что-либо было нечем: главная показывает
/// только корень рабочей папки, а всё вложенное с неё вообще не видно.
@MainActor
final class NotesSearchUITests: XCTestCase {
    func testSearchFindsANoteByTextInsideIt() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        // Слово ищется только в теле заметки — заголовком становится первая строка.
        let marker = "кайрос\(UUID().uuidString.prefix(4))"
        let title = "Поиск \(UUID().uuidString.prefix(6))"

        app.buttons["Добавить заметку или файл"].tap()
        app.buttons["Новая заметка"].tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("\(title)\nвстреча про \(marker) во вторник")
        app.buttons["Готово"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForNonExistence(timeout: 5))

        app.buttons["Поиск"].tap()
        let field = app.textFields["Поиск по заметкам"]
        XCTAssertTrue(field.waitForExistence(timeout: 3), "поиск должен открывать поле ввода")
        field.tap()
        field.typeText(marker)

        let hit = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5), "заметка должна находиться по слову внутри текста")

        save(XCUIScreen.main.screenshot(), named: "search")

        hit.tap()
        let opened = app.textViews.firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 5), "находка должна открываться в редакторе")
        XCTAssertTrue((opened.value as? String)?.contains(marker) == true)
        app.buttons["Готово"].tap()

        app.buttons["Отмена"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 3), "«Отмена» закрывает поиск")

        // Убираем за собой: иначе заметки копятся и уводят карточки под композер.
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        scroll(to: card, in: app)
        card.press(forDuration: 1.2)
        app.buttons["В корзину Lori"].tap()
        app.buttons["Перенести в корзину Lori"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
    }

    private func scroll(to element: XCUIElement, in app: XCUIApplication) {
        let composer = app.textFields["Спросить Lori"]
        guard composer.exists else { return }
        let composerTop = composer.frame.minY
        var attempts = 0
        while element.frame.maxY > composerTop - 8, attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
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
