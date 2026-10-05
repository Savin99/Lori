import XCTest

/// Интерфейс транскрибатора: список записей, экран записи с плеером и текстом,
/// настройки с выбором движка и словарём.
///
/// Симулятор не пишет с микрофона и не имеет системных моделей распознавания,
/// поэтому запись для проверок сеется с хоста: `design/qa/seed-audio.sh`.
@MainActor
final class TranscriptionUITests: XCTestCase {
    /// Темы не раздвигают шапку и не требуют горизонтального свайпа:
    /// и выбор фильтра, и создание темы живут в одном нативном меню.
    func testTopicFilterOpensAsMenu() throws {
        continueAfterFailure = false
        let app = launch()

        let menu = app.descendants(matching: .any)["topicMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "в шапке должна быть одна кнопка фильтра тем")
        XCTAssertFalse(app.descendants(matching: .any)["topicChips"].exists, "горизонтальной ленты тем больше нет")
        save(XCUIScreen.main.screenshot(), named: "topic-menu-closed")

        tap(menu)
        XCTAssertTrue(app.buttons["Все записи"].waitForExistence(timeout: 5), "общий список выбирается из меню")
        XCTAssertTrue(app.buttons["Новая тема"].exists, "создание темы не потерялось вместе с кнопкой плюс")
        save(XCUIScreen.main.screenshot(), named: "topic-menu")

        app.buttons["Новая тема"].tap()
        XCTAssertTrue(app.textFields["Название темы"].waitForExistence(timeout: 5))
        app.buttons["Отмена"].tap()
    }

    /// Панель: движок и режим — два чипа, у движка без режимов чип исчезает.
    func testPanelShowsEngineAndModeChips() throws {
        continueAfterFailure = false
        let app = launch()

        let engineChip = app.descendants(matching: .any)["engineChip"]
        XCTAssertTrue(engineChip.waitForExistence(timeout: 5), "движок виден прямо в панели")
        XCTAssertTrue(app.descendants(matching: .any)["modeChip"].exists, "рядом — режим движка")
        XCTAssertTrue(app.buttons["recordButton"].exists)
        XCTAssertTrue(app.buttons["importButton"].exists, "импорт — рядом, а не в меню")
        save(XCUIScreen.main.screenshot(), named: "panel")

        engineChip.tap()
        XCTAssertTrue(
            app.staticTexts["На телефоне"].waitForExistence(timeout: 5),
            "шит делит движки по тому, где считается расшифровка"
        )
        XCTAssertTrue(app.staticTexts["В облаке"].exists)
        save(XCUIScreen.main.screenshot(), named: "engine-picker")

        // У движка Apple режимов нет — строка должна схлопнуться.
        // Ищем именно кнопку: идентификатор на строке списка достаётся и
        // контейнеру, а тап по контейнеру уходит мимо.
        let apple = app.buttons["engineRow.apple"].exists
            ? app.buttons["engineRow.apple"]
            : app.staticTexts["Движок Apple"]
        XCTAssertTrue(apple.waitForExistence(timeout: 5))
        apple.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["modeChip"].waitForNonExistence(timeout: 5),
            "у движка без режимов чипа режима быть не должно"
        )
        XCTAssertTrue(engineChip.exists, "сам движок остаётся виден")
    }

    func testRecordingOpensPlayerWithTranscriptCard() throws {
        continueAfterFailure = false
        let app = launch()

        save(XCUIScreen.main.screenshot(), named: "home")

        // Карточку больше не ищут по имени файла: заголовок берётся из расшифровки,
        // а пока её нет — из времени записи. Поэтому anchor — сама карточка.
        let card = app.descendants(matching: .any).matching(identifier: "recordingCard").firstMatch
        try XCTSkipUnless(
            card.waitForExistence(timeout: 5),
            "в рабочей папке нет записей — прогони design/qa/seed-audio.sh"
        )
        card.tap()

        let play = app.buttons["Слушать"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "тап по записи должен открывать экран записи")
        XCTAssertTrue(
            app.buttons["Скорость воспроизведения"].exists,
            "скорость важнее перемотки: расшифровку слушают на 1.5–2×"
        )
        XCTAssertTrue(app.buttons["Расшифровки"].exists, "видно, куда возвращает кнопка")
        XCTAssertTrue(
            app.descendants(matching: .any)["topicChip"].exists,
            "тема назначается прямо с экрана записи"
        )
        save(XCUIScreen.main.screenshot(), named: "transcript-screen")

        app.buttons["Расшифровки"].tap()
        XCTAssertTrue(play.waitForNonExistence(timeout: 5), "кнопка возврата закрывает экран записи")
    }

    /// «Поделиться» спрашивает формат, а не отдаёт что попало: PDF человеку,
    /// Markdown в свой редактор. Системный лист сюда не входит — он живёт
    /// снаружи приложения.
    func testShareOffersPDFAndMarkdown() throws {
        continueAfterFailure = false
        let app = launch()

        let card = app.descendants(matching: .any).matching(identifier: "recordingCard").firstMatch
        try XCTSkipUnless(
            card.waitForExistence(timeout: 5),
            "в рабочей папке нет записей — прогони design/qa/seed-audio.sh"
        )
        card.tap()

        let share = app.buttons["shareMenu"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), "кнопка «Поделиться» на экране записи")
        try XCTSkipUnless(share.isEnabled, "у записи нет расшифровки — делиться нечем")
        share.tap()

        XCTAssertTrue(app.buttons["PDF"].waitForExistence(timeout: 5), "формат выбирают в меню")
        XCTAssertTrue(app.buttons["Markdown (.md)"].exists)
        save(XCUIScreen.main.screenshot(), named: "share-menu")
    }

    /// Настройки — пять строк, а не бесконечный скролл: конфиги живут в своих
    /// экранах, и корень виден целиком.
    func testSettingsAreSplitIntoScreens() throws {
        continueAfterFailure = false
        let app = launch()

        app.buttons["Настройки"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["settingsEngine"].waitForExistence(timeout: 20),
            "корень настроек — строка «Движок»"
        )
        for row in ["settingsTranscription", "settingsVocabulary", "settingsStorage"] {
            XCTAssertTrue(exists(row, in: app), "нет строки \(row)")
        }
        save(XCUIScreen.main.screenshot(), named: "settings-root")

        // Движок: тот же список, что в шите панели, и конфиг только выбранного.
        tap(app.descendants(matching: .any)["settingsEngine"])
        XCTAssertTrue(exists("engineRow.gigaam", in: app), "движок выбирается тем же списком, что и в панели")
        XCTAssertTrue(app.staticTexts["На телефоне"].exists, "деление по локальности одно на оба места")
        XCTAssertTrue(exists("engineStatus", in: app), "состояние движка должно быть видно")
        XCTAssertTrue(
            exists("downloadModels", in: app) || exists("removeModels", in: app),
            "модель ставится и удаляется кнопкой"
        )
        save(XCUIScreen.main.screenshot(), named: "settings-engine")
    }

    /// Тумблеры честные: у движка Apple таймкоды и говорящие недоступны — оба
    /// выключены и не нажимаются, а не притворяются работающими.
    func testTogglesAreDisabledForAppleEngine() throws {
        continueAfterFailure = false
        let app = launch(engine: "apple")

        app.buttons["Настройки"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["settingsTranscription"].waitForExistence(timeout: 20),
            "корень настроек — строка «Расшифровка»"
        )
        tap(app.descendants(matching: .any)["settingsTranscription"])

        // Переключатель в `Form` не ищется как `switch` — только как элемент
        // без типа (та же ловушка, что у кнопок в `Form`, см. CLAUDE.md).
        let timecodes = app.descendants(matching: .any)["timecodesToggle"].firstMatch
        XCTAssertTrue(timecodes.waitForExistence(timeout: 10), "тумблер таймкодов на месте")
        XCTAssertFalse(timecodes.isEnabled, "Apple не отдаёт таймкодов — тумблер выключен")
        let speakers = app.descendants(matching: .any)["speakersToggle"].firstMatch
        XCTAssertTrue(speakers.waitForExistence(timeout: 5))
        XCTAssertFalse(speakers.isEnabled, "и говорящих тоже")
        save(XCUIScreen.main.screenshot(), named: "settings-transcription-apple")
    }

    /// Словарь — отдельный экран со списком слов, а не сырой текст в общем скролле.
    func testVocabularyIsItsOwnScreenWithList() throws {
        continueAfterFailure = false
        let app = launch()

        app.buttons["Настройки"].tap()
        XCTAssertTrue(exists("settingsVocabulary", in: app))
        tap(app.descendants(matching: .any)["settingsVocabulary"])

        let field = app.textFields["vocabularyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "слово добавляется полем, а не правкой текста")
        let word = "Кайрос\(UUID().uuidString.prefix(4))"
        tap(field)
        field.typeText(word)
        app.buttons["Добавить"].tap()

        XCTAssertTrue(
            app.staticTexts[word].waitForExistence(timeout: 5),
            "добавленное слово должно появиться в списке"
        )
        save(XCUIScreen.main.screenshot(), named: "settings-vocabulary")
    }

    /// Плашка записи над листом: под открытыми настройками пилюлю рекордера не видно,
    /// и без плашки человек не знает, что диктофон всё ещё пишет.
    ///
    /// Микрофон надо разрешить заранее, иначе тест упрётся в системный диалог:
    /// `xcrun simctl privacy booted grant microphone ru.ilyaqa.lori.local`.
    func testRecordingBannerIsVisibleOverAnOpenSheet() throws {
        continueAfterFailure = false
        let app = launch()

        app.buttons["Записать"].tap()
        let pause = app.buttons["Поставить на паузу"]
        try XCTSkipUnless(
            pause.waitForExistence(timeout: 5),
            "запись не началась — вероятно, не выдан доступ к микрофону"
        )
        save(XCUIScreen.main.screenshot(), named: "home-recording")

        app.buttons["Настройки"].tap()
        let banner = app.buttons["Идёт запись"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "над открытым листом должна висеть плашка записи")
        save(XCUIScreen.main.screenshot(), named: "recording-banner")

        banner.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "плашка возвращает к пилюле записи")

        // Убираем за собой: отменённая запись уезжает в корзину Lori.
        tap(app.buttons["Отмена"])
        XCTAssertTrue(app.buttons["Записать"].waitForExistence(timeout: 5))
    }

    /// Лист уезжает с анимацией, и в это время кнопка под ним уже «существует»,
    /// но точки нажатия у неё ещё нет: тап уходит в никуда. Ждём доступности.
    /// Запуск с заданным состоянием. Выбор движка живёт в `UserDefaults` и
    /// переживает запуск, поэтому один тест влиял на другой: после проверки
    /// движка без режимов у следующего теста не было чипа режима. Аргументы
    /// командной строки читаются `UserDefaults` поверх сохранённого — и прогон
    /// перестаёт зависеть от того, чем всё кончилось в прошлый раз.
    private func launch(engine: String = "gigaam") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-transcriptionEngine", engine, "--forget-attachments"]
        app.launch()
        return app
    }

    private func tap(_ element: XCUIElement, timeout: TimeInterval = 5) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "нет элемента для нажатия")
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isHittable, Date() < deadline {
            _ = element.waitForExistence(timeout: 0.2)
        }
        element.tap()
    }

    /// Ищет элемент по идентификатору, доскролливая экран: в `Form` строки ниже
    /// видимой части ещё не отрисованы и через `exists` не находятся.
    private func exists(_ identifier: String, in app: XCUIApplication, attempts: Int = 10) -> Bool {
        let element = app.descendants(matching: .any)[identifier]
        if element.waitForExistence(timeout: 4) { return true }
        for _ in 0..<attempts {
            scrollDown(app)
            if element.exists { return true }
        }
        return false
    }

    /// Прокрутка тянется от правого края: обычный `swipeUp()` бьёт в центр экрана,
    /// где может оказаться поле ввода или колесо `Picker`, и форма не двигается вовсе.
    private func scrollDown(_ app: XCUIApplication) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.8))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.25))
        from.press(forDuration: 0.05, thenDragTo: to)
    }

    /// Лента уходит под композер, и `isHittable` перекрытой карточки всё равно true:
    /// тап в этом месте достаётся композеру.
    private func scroll(to element: XCUIElement, in app: XCUIApplication) {
        let composer = app.buttons["Записать"]
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
