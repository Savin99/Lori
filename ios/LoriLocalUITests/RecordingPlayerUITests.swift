import XCTest

/// Экран записи. До него прослушать собственную запись было нечем:
/// тап по аудио сразу запускал распознавание.
///
/// Тесту нужен засеянный файл в рабочей папке приложения — симулятор не пишет
/// с микрофона сам. Засеять: `design/qa/seed-audio.sh` (кладёт «UI sample.m4a»
/// в корень `Documents/Lori/Workspace`). Без него тест пропускается.
@MainActor
final class RecordingPlayerUITests: XCTestCase {
    func testAudioCardOpensPlayerInsteadOfStartingTranscription() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        save(XCUIScreen.main.screenshot(), named: "home")

        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "UI sample")).firstMatch
        try XCTSkipUnless(
            card.waitForExistence(timeout: 5),
            "в рабочей папке нет записи «UI sample» — прогони design/qa/seed-audio.sh"
        )

        scroll(to: card, in: app)
        card.tap()

        let play = app.buttons["Слушать"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "тап по записи должен открывать плеер")
        XCTAssertTrue(
            app.buttons["Назад на 15 секунд"].waitForExistence(timeout: 3),
            "у плеера должна быть перемотка"
        )
        save(XCUIScreen.main.screenshot(), named: "recording-player")
        // Текст записи показывает `TranscriptCard`, и его состояния проверяет
        // `DigestCardUITests`. Здесь важно другое: тап открыл плеер,
        // а распознавание само не началось.

        play.tap()
        XCTAssertTrue(app.buttons["Пауза"].waitForExistence(timeout: 3), "кнопка должна переключиться в паузу")

        save(XCUIScreen.main.screenshot(), named: "recording-player-playing")

        app.buttons["Готово"].tap()
        XCTAssertTrue(play.waitForNonExistence(timeout: 5), "«Готово» закрывает экран записи")
    }

    /// Плашка записи над листом. Пилюля рекордера живёт в композере главного экрана
    /// и под открытым листом не видна: без плашки человек редактирует заметку,
    /// не зная, что диктофон пишет.
    ///
    /// Микрофон надо разрешить заранее, иначе тест упрётся в системный диалог:
    /// `xcrun simctl privacy booted grant microphone ru.ilyaqa.lori.local`.
    func testRecordingBannerIsVisibleOverAnOpenSheet() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        // Заметка создаётся заранее: во время записи «+» уступает место пилюле.
        let title = "Banner \(UUID().uuidString.prefix(6))"
        app.buttons["Добавить заметку или файл"].tap()
        app.buttons["Новая заметка"].tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("\(title)\nтекст")
        app.buttons["Готово"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForNonExistence(timeout: 5))

        // Запись начинается из «+»: кнопки микрофона в композере больше нет.
        app.buttons["Добавить заметку или файл"].tap()
        app.buttons["Записать"].tap()
        let pause = app.buttons["Поставить на паузу"]
        try XCTSkipUnless(
            pause.waitForExistence(timeout: 5),
            "запись не началась — вероятно, не выдан доступ к микрофону"
        )

        save(XCUIScreen.main.screenshot(), named: "home-recording")

        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        scroll(to: card, clearOf: pause, in: app)
        card.tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5), "заметка должна открыться")

        let banner = app.buttons["Идёт запись"]
        XCTAssertTrue(banner.waitForExistence(timeout: 3), "над открытым листом должна висеть плашка записи")
        save(XCUIScreen.main.screenshot(), named: "recording-banner")

        banner.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "плашка возвращает к пилюле записи")

        // Убираем за собой: отменённая запись и тестовая заметка уезжают в корзину Lori.
        app.buttons["Отмена"].tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
        scroll(to: card, clearOf: app.textFields.firstMatch, in: app)
        card.press(forDuration: 1.2)
        app.buttons["В корзину Lori"].tap()
        app.buttons["Перенести в корзину Lori"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
    }

    /// Лента уходит под композер, и `isHittable` перекрытой карточки всё равно true:
    /// тап в этом месте достаётся композеру.
    private func scroll(to element: XCUIElement, in app: XCUIApplication) {
        scroll(to: element, clearOf: app.textFields.firstMatch, in: app)
    }

    /// Во время записи поля ввода в композере нет, поэтому нижнюю границу
    /// приходится брать от того элемента, который его занял.
    private func scroll(to element: XCUIElement, clearOf composer: XCUIElement, in app: XCUIApplication) {
        guard composer.exists else { return }
        let composerTop = composer.frame.minY
        var attempts = 0
        while element.frame.maxY > composerTop - 8, attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
    }

    /// Снимок кладётся и в отчёт, и в tmp раннера: панели симулятора у агента нет,
    /// и забрать картинку можно только из контейнера.
    private func save(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
