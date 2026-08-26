import XCTest

@MainActor
final class LoriLocalUITests: XCTestCase {
    func testFolderButtonOpensFolderDrawer() throws {
        let app = launchApp()
        app.buttons["Открыть папки"].tap()

        XCTAssertTrue(app.buttons["Создать новую папку"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Папки"].exists)
    }

    func testAddButtonOffersNoteAndFileInsteadOfOpeningChat() throws {
        let app = launchApp()
        app.buttons["Добавить заметку или файл"].tap()

        XCTAssertTrue(app.buttons["Новая заметка"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Выбрать файл"].exists)
        XCTAssertFalse(app.staticTexts["Привет, Илья"].exists)
    }

    /// Полный цикл заметки: создать в редакторе, увидеть на главной, открыть,
    /// дописать, перенести в корзину. Имя уникально, чтобы прогоны не мешали друг другу.
    func testNoteEditorCreatesEditsAndDeletesNote() throws {
        let app = launchApp()
        let title = "UI note \(UUID().uuidString.prefix(6))"

        app.buttons["Добавить заметку или файл"].tap()
        app.buttons["Новая заметка"].tap()

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "редактор заметки должен открыться")
        editor.tap()
        editor.typeText("\(title)\nfirst line")
        closeEditor(app)

        // Карточка ищется по кнопке: список может быть длинным, поэтому до тапа её нужно домотать.
        // Имя в карточке теперь без расширения, а подпись — дата правки.
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "заметка должна появиться на главной с именем из первой строки")

        tap(card, in: app)
        let reopened = app.textViews.firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 5), "заметка должна открываться в редакторе")
        XCTAssertEqual(reopened.value as? String, "\(title)\nfirst line", "редактор должен показать сохранённый текст")
        reopened.tap()
        reopened.typeText("\nsecond line")
        closeEditor(app)

        tap(card, in: app)
        let afterEdit = app.textViews.firstMatch
        XCTAssertTrue(afterEdit.waitForExistence(timeout: 5))
        XCTAssertTrue((afterEdit.value as? String)?.contains("second line") == true, "правка должна сохраниться")
        closeEditor(app)

        scroll(to: card, in: app)
        card.press(forDuration: 1.2)
        app.buttons["В корзину Lori"].tap()
        app.buttons["Перенести в корзину Lori"].tap()

        XCTAssertTrue(card.waitForNonExistence(timeout: 5), "после переноса в корзину заметка исчезает с главной")
    }

    /// Лента уходит под композер, и `isHittable` для перекрытой карточки всё ещё true:
    /// тап в этом месте достаётся композеру. Поэтому мотаем до тех пор,
    /// пока карточка не окажется выше поля ввода.
    private func scroll(to element: XCUIElement, in app: XCUIApplication) {
        let composerTop = app.textFields.firstMatch.frame.minY
        var attempts = 0
        while element.frame.maxY > composerTop - 8, attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        scroll(to: element, in: app)
        element.tap()
    }

    /// «Готово» закрывает лист с анимацией; без ожидания следующий тап уходит в подложку.
    private func closeEditor(_ app: XCUIApplication) {
        app.buttons["Готово"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForNonExistence(timeout: 5), "редактор должен закрыться")
    }

    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        return app
    }
}
