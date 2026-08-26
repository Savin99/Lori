import XCTest

/// Карточка записи с переключателем «Важное ↔ Расшифровка».
///
/// Тесту нужен засеянный набор: запись, её дословная расшифровка и обработанная
/// заметка в тематической папке. В симуляторе ни расшифровку, ни обработку получить
/// нельзя — нет ни моделей распознавания, ни ключа модели, — поэтому набор кладётся
/// с хоста: `design/qa/seed-digest.sh`. Без него тест пропускается.
@MainActor
final class DigestCardUITests: XCTestCase {
    func testCardShowsImportantAndSwitchesToVerbatim() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "UI sample")).firstMatch
        try XCTSkipUnless(
            card.waitForExistence(timeout: 5),
            "в рабочей папке нет набора «UI sample» — прогони design/qa/seed-digest.sh"
        )
        scroll(to: card, in: app)
        card.tap()

        // По умолчанию открыто «Важное»: человек хочет читать выжимку, а не стену речи.
        let important = segment("Важное", in: app)
        XCTAssertTrue(important.waitForExistence(timeout: 5), "в карточке нет переключателя вида")
        XCTAssertTrue(important.isSelected, "по умолчанию должно быть выбрано «Важное»")

        XCTAssertTrue(
            app.staticTexts["Планёрка по найму"].waitForExistence(timeout: 3),
            "в «Важном» должен быть заголовок обработанной заметки"
        )
        XCTAssertTrue(app.staticTexts["Важное"].exists || app.staticTexts["Решения"].exists,
                      "в «Важном» должны быть разделы выжимки")
        XCTAssertTrue(app.staticTexts["Тема · Работа"].exists, "не видно, в какую папку легла заметка")
        XCTAssertTrue(app.buttons["Открыть заметку"].exists, "из карточки должна открываться заметка")
        // Оговорки из дословного текста в выжимке остаться не должны.
        XCTAssertFalse(contains("Значит смотри", in: app), "в «Важном» показан дословный текст")

        save(XCUIScreen.main.screenshot(), named: "digest-important")

        segment("Расшифровка", in: app).tap()
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Значит смотри")).firstMatch
                .waitForExistence(timeout: 3),
            "переключатель не показал дословный текст"
        )
        save(XCUIScreen.main.screenshot(), named: "digest-verbatim")

        // Кнопка ведёт в саму заметку, а не в файл расшифровки.
        segment("Важное", in: app).tap()
        // Ждём кнопку, а не считаем переключение мгновенным: у карточки есть анимации,
        // и тап по ещё не доехавшему элементу достаётся тому, что под ним.
        let openNote = app.buttons["Открыть заметку"]
        XCTAssertTrue(openNote.waitForExistence(timeout: 5), "действие «Открыть заметку» не появилось")
        openNote.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "заметка должна открыться в редакторе")
        XCTAssertTrue(
            (editor.value as? String)?.contains("Важное") == true,
            "открылся не тот файл: в заметке нет раздела «Важное»"
        )
        save(XCUIScreen.main.screenshot(), named: "digest-note")

        app.buttons["Готово"].tap()
    }

    /// Сегмент переключателя. Отдельно от `app.buttons`: у сегмента есть `isSelected`,
    /// и по нему видно, что открыто по умолчанию.
    private func segment(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let inControl = app.segmentedControls.buttons[title]
        return inControl.exists ? inControl : app.buttons[title]
    }

    private func contains(_ needle: String, in app: XCUIApplication) -> Bool {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", needle)).firstMatch.exists
    }

    /// Лента уходит под композер, и `isHittable` перекрытой карточки всё равно true:
    /// тап в этом месте достаётся композеру.
    private func scroll(to element: XCUIElement, in app: XCUIApplication) {
        let composer = app.textFields.firstMatch
        guard composer.exists else { return }
        var attempts = 0
        while element.frame.maxY > composer.frame.minY - 8, attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
    }

    /// Панели симулятора у агента нет, поэтому снимок кладётся ещё и в tmp раннера.
    private func save(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
