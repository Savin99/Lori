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

        // Запись с расшифровкой, а не первая попавшаяся: сверху может стоять свежая
        // запись без текста, и тест пропускался бы, не проверив ничего.
        let card = quietCard(in: app)
        try XCTSkipUnless(
            card.waitForExistence(timeout: 5),
            "в рабочей папке нет записей с расшифровкой — прогони design/qa/seed-home.py"
        )
        card.tap()

        let share = app.buttons["shareMenu"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), "кнопка «Поделиться» на экране записи")
        // Кнопка включается, когда экран дочитал расшифровку, — это доля секунды
        // после появления. Проверка сразу же пропускала тест на записи с текстом.
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: share)
        try XCTSkipUnless(
            XCTWaiter().wait(for: [enabled], timeout: 5) == .completed,
            "у записи нет расшифровки — делиться нечем"
        )
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
        if !pause.waitForExistence(timeout: 5) {
            // Симулятор без звукового входа запись не начинает. Снимок показывает почему,
            // а алерт закрывается: тест не должен оставлять за собой ничего на экране.
            save(XCUIScreen.main.screenshot(), named: "record-not-started")
            let alert = app.alerts["Lori"]
            if alert.exists { alert.buttons["OK"].tap() }
            throw XCTSkip("запись не началась: нет доступа к микрофону или у симулятора нет звукового входа")
        }
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

    // MARK: - Главный экран

    /// Карточка: заголовок, описание, время с длительностью. Даты на карточке нет —
    /// она в заголовке дня над ней.
    func testHomeCardReadsAsTitleDescriptionAndTime() throws {
        continueAfterFailure = false
        let app = launch()

        let card = firstCard(in: app)
        try XCTSkipUnless(card.waitForExistence(timeout: 5), "нет записей — прогони design/qa/seed-home.py")
        XCTAssertTrue(card.isHittable)
        XCTAssertNotNil(
            card.label.range(of: #"\d{2}:\d{2}"#, options: .regularExpression),
            "на карточке есть время записи: \(card.label)"
        )
        XCTAssertFalse(card.label.contains("Сегодня"), "день назван над карточкой, а не на ней")
        XCTAssertFalse(card.label.contains("вчера,"), "и не «вчера, 09:10»")
        XCTAssertTrue(app.staticTexts["Сегодня"].exists || app.staticTexts["Вчера"].exists, "записи разложены по дням")
    }

    /// Удаление всегда переспрашивает — и «Отмена» оставляет запись на месте.
    func testDeleteAsksForConfirmationFirst() throws {
        continueAfterFailure = false
        let app = launch()

        let card = firstCard(in: app)
        try XCTSkipUnless(card.waitForExistence(timeout: 5), "нет записей — прогони design/qa/seed-home.py")
        let label = card.label
        let count = cards(in: app).count
        card.swipeLeft()
        tap(app.buttons["Удалить"])

        XCTAssertTrue(app.staticTexts["Удалить запись?"].waitForExistence(timeout: 5), "без подтверждения не удаляем")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Аудио и расшифровка переедут в корзину Lori")).firstMatch.exists,
            "диалог говорит, куда денется запись"
        )
        save(XCUIScreen.main.screenshot(), named: "home-delete-confirm")
        dismissDialog(in: app)

        XCTAssertTrue(app.staticTexts["Удалить запись?"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(cards(in: app).count, count, "после «Отмена» запись на месте")
        XCTAssertTrue(cards(in: app).matching(NSPredicate(format: "label == %@", label)).firstMatch.exists)
    }

    /// Поле переименования начинается с того заголовка, что виден на карточке, а
    /// не с имени файла: «Готово» без правки ничего не меняет.
    func testRenameStartsFromTheVisibleTitle() throws {
        continueAfterFailure = false
        let app = launch()

        let card = quietCard(in: app)
        try XCTSkipUnless(card.waitForExistence(timeout: 5), "нет записей — прогони design/qa/seed-home.py")
        let label = card.label
        card.swipeLeft()
        tap(app.buttons["Переименовать"])

        let field = app.alerts["Переименовать"].textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let value = try XCTUnwrap(field.value as? String)
        XCTAssertFalse(value.isEmpty)
        XCTAssertTrue(label.hasPrefix(value), "в поле — видимый заголовок «\(value)», карточка: «\(label)»")
        XCTAssertFalse(value.hasPrefix("Новая запись"), "не имя файла")
        app.alerts["Переименовать"].buttons["Отмена"].tap()
    }

    /// Долгое нажатие собирает все действия с записью, а не только выбор темы.
    func testLongPressOffersEveryRecordAction() throws {
        continueAfterFailure = false
        let app = launch()

        let card = quietCard(in: app)
        try XCTSkipUnless(card.waitForExistence(timeout: 5), "нет записей с расшифровкой — прогони design/qa/seed-home.py")
        card.press(forDuration: 1.2)

        for action in ["Поделиться", "Переименовать", "Тема", "Отправить в Obsidian", "Удалить"] {
            XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5), "в меню нет «\(action)»")
        }
        save(XCUIScreen.main.screenshot(), named: "home-context-menu")
        app.buttons["Поделиться"].tap()
        XCTAssertTrue(app.buttons["PDF"].waitForExistence(timeout: 5), "«Поделиться» раскрывается форматами")
        XCTAssertTrue(app.buttons["Markdown (.md)"].exists)
    }

    /// «Поделиться» — главный глагол: свайп вправо и выбор формата теми же словами,
    /// что на Маке.
    func testLeadingSwipeSharesWithFormatChoice() throws {
        continueAfterFailure = false
        let app = launch()

        let card = quietCard(in: app)
        try XCTSkipUnless(card.waitForExistence(timeout: 5), "нет записей с расшифровкой — прогони design/qa/seed-home.py")
        card.swipeRight()
        // Полный свайп сразу открывает выбор формата; короткий — показывает кнопку.
        let share = app.buttons["Поделиться"]
        if share.waitForExistence(timeout: 2), !app.staticTexts["Поделиться расшифровкой"].exists {
            tap(share)
        }

        XCTAssertTrue(app.staticTexts["Поделиться расшифровкой"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["PDF · Удобно читать и отправлять"].exists)
        XCTAssertTrue(app.buttons["Markdown (.md) · Текст для дальнейшей работы"].exists)
        save(XCUIScreen.main.screenshot(), named: "home-share-format")
        dismissDialog(in: app)
        XCTAssertTrue(app.staticTexts["Поделиться расшифровкой"].waitForNonExistence(timeout: 5))
    }

    /// Кнопка на карточке ставит запись в очередь и не открывает её; блок очереди
    /// появляется сверху, а «Остановить» сначала переспрашивает.
    func testInlineTranscribeStartsQueueAndStopAsksFirst() throws {
        continueAfterFailure = false
        let app = launch(stub: true, stubSeconds: 30)

        let action = app.buttons.matching(identifier: "cardAction").matching(NSPredicate(format: "label == %@", "Расшифровать")).firstMatch
        try XCTSkipUnless(action.waitForExistence(timeout: 5), "нет записи без расшифровки — прогони design/qa/seed-home.py")
        tap(action)

        let queue = app.descendants(matching: .any)["queueBlock"]
        XCTAssertTrue(queue.waitForExistence(timeout: 5), "блок очереди появляется над списком")
        XCTAssertTrue(queue.label.hasPrefix("Расшифровка"), queue.label)
        XCTAssertFalse(app.buttons["Слушать"].exists, "кнопка на карточке не открывает запись")
        XCTAssertTrue(
            cards(in: app).matching(NSPredicate(format: "label CONTAINS %@", "Расшифровываю")).firstMatch.waitForExistence(timeout: 5),
            "карточка говорит, что идёт работа"
        )
        save(XCUIScreen.main.screenshot(), named: "home-queue-single")

        tap(app.buttons["stopQueueButton"])
        XCTAssertTrue(app.staticTexts["Остановить расшифровку?"].waitForExistence(timeout: 5), "остановка переспрашивает")
        XCTAssertTrue(app.staticTexts["Записи останутся — расшифровку можно запустить снова."].exists)
        save(XCUIScreen.main.screenshot(), named: "home-stop-confirm")
        tap(dialogButton("Остановить", in: app))
        XCTAssertTrue(queue.waitForNonExistence(timeout: 10), "после остановки блок очереди уходит")
    }

    /// Тап по блоку очереди открывает ту запись, что считается.
    func testQueueBlockOpensTheCurrentRecord() throws {
        continueAfterFailure = false
        let app = launch(stub: true, stubSeconds: 30)

        let action = app.buttons.matching(identifier: "cardAction").matching(NSPredicate(format: "label == %@", "Расшифровать")).firstMatch
        try XCTSkipUnless(action.waitForExistence(timeout: 5), "нет записи без расшифровки — прогони design/qa/seed-home.py")
        tap(action)
        let queue = app.descendants(matching: .any)["queueBlock"]
        XCTAssertTrue(queue.waitForExistence(timeout: 5))
        queue.tap()
        XCTAssertTrue(app.buttons["Слушать"].waitForExistence(timeout: 5), "блок открывает запись")
        tap(app.buttons["Расшифровки"])

        tap(app.buttons["stopQueueButton"])
        tap(dialogButton("Остановить", in: app))
        XCTAssertTrue(queue.waitForNonExistence(timeout: 10))
    }

    /// Меню `+` без «Настроек»: шестерёнка в шапке — единственный вход туда.
    func testPlusMenuHasNoSettings() throws {
        continueAfterFailure = false
        let app = launch()

        tap(app.buttons["importButton"])
        XCTAssertTrue(app.buttons["Аудио из Файлов"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Вставить")).firstMatch.exists,
            "вставка из буфера на месте"
        )
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label == %@", "Настройки")).count, 1,
            "настройки — только шестерёнкой в шапке"
        )
    }

    // MARK: - Снимки главного экрана

    /// Пять файлов из «Поделиться» → Lori: список в панели, «Расшифровать 5», очередь,
    /// строка ошибки и список после пачки — в светлой и тёмной теме.
    ///
    /// Нужен посев: `python3 design/qa/seed-home.py <udid> --inbox-only` — файлы ждут в
    /// `Documents/Inbox`, и запуск без `--forget-attachments` прикрепляет их к панели.
    func testZZ1AttachedPanelAndQueueScreenshots() throws {
        continueAfterFailure = false
        let app = launch(stub: true, stubSeconds: 12, forgetAttachments: false)

        let panel = app.descendants(matching: .any)["attachedFile"]
        try XCTSkipUnless(panel.waitForExistence(timeout: 8), "нет файлов в Documents/Inbox — прогони seed-home.py --inbox-only")
        let transcribe = app.buttons["transcribeButton"]
        XCTAssertTrue(transcribe.waitForExistence(timeout: 5))
        XCTAssertTrue(transcribe.label.hasPrefix("Расшифровать"), transcribe.label)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "в облако · примерно")).firstMatch.waitForExistence(timeout: 5), "оценка времени видна до нажатия")
        sleep(1)
        shoot(named: "home-attached")

        tap(transcribe)
        let queue = app.descendants(matching: .any)["queueBlock"]
        XCTAssertTrue(queue.waitForExistence(timeout: 15), "пачка ушла в очередь")
        XCTAssertTrue(panel.waitForNonExistence(timeout: 10), "ушедшие в работу файлы сняты с панели")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Расшифровка · 1 из")).firstMatch.exists
                      || queue.label.contains("из 5"), "счётчик пачки: \(queue.label)")
        sleep(4)
        shoot(named: "home-queue")

        let failed = cards(in: app).matching(NSPredicate(format: "label CONTAINS %@", "Нет связи с сервисом")).firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout: 90), "файл с «fail» в имени показывает ошибку на карточке")
        sleep(2)
        shoot(named: "home-failed")

        XCTAssertTrue(queue.waitForNonExistence(timeout: 120), "пачка доходит до конца")
        sleep(2)
        shoot(named: "home-list")
        app.swipeUp()
        sleep(1)
        shoot(named: "home-list-more")
    }

    /// Строка подсказки про модель заголовков и тихий список — без очереди.
    func testZZ2ListScreenshots() throws {
        continueAfterFailure = false
        let app = launch(stub: true)

        let card = firstCard(in: app)
        try XCTSkipUnless(card.waitForExistence(timeout: 5), "нет записей — прогони design/qa/seed-home.py")
        XCTAssertTrue(app.descendants(matching: .any)["titlesHint"].waitForExistence(timeout: 5), "без модели заголовков есть подсказка")
        sleep(1)
        shoot(named: "home-titles-hint")
    }

    // MARK: - Помощники

    /// Запуск с заданным состоянием. Выбор движка живёт в `UserDefaults` и
    /// переживает запуск, поэтому один тест влиял на другой: после проверки
    /// движка без режимов у следующего теста не было чипа режима. Аргументы
    /// командной строки читаются `UserDefaults` поверх сохранённого — и прогон
    /// перестаёт зависеть от того, чем всё кончилось в прошлый раз.
    ///
    /// `stub` — проверочный движок Lori QA (`--ui-stub-engine`): симулятор не
    /// расшифровывает, а очередь и полосы иначе не увидеть.
    private func launch(
        engine: String = "gigaam",
        stub: Bool = false,
        stubSeconds: Int = 24,
        forgetAttachments: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-transcriptionEngine", stub ? "elevenlabs" : engine, "-titlesHintDismissed", "NO"]
        if forgetAttachments { app.launchArguments.append("--forget-attachments") }
        if stub { app.launchArguments += ["--ui-stub-engine", "--ui-stub-seconds", String(stubSeconds)] }
        app.launch()
        return app
    }

    private func cards(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "recordingCard")
    }

    private func firstCard(in app: XCUIApplication) -> XCUIElement {
        cards(in: app).firstMatch
    }

    /// Тихая карточка: расшифровка есть, и с записью ничего не происходит — ей
    /// доступны все действия, от «Поделиться» до «Переименовать».
    private func quietCard(in app: XCUIApplication) -> XCUIElement {
        let busy = ["Без расшифровки", "Нет связи", "В очереди", "Расшифровываю", "Прервано"]
        let predicate = NSCompoundPredicate(notPredicateWithSubpredicate: NSCompoundPredicate(
            orPredicateWithSubpredicates: busy.map { NSPredicate(format: "label CONTAINS %@", $0) }
        ))
        return cards(in: app).matching(predicate).firstMatch
    }

    /// Диалог подтверждения на iOS 26 — поповер без «Отмены»: он закрывается тапом
    /// мимо. На системах, где кнопка есть, нажимаем её.
    private func dismissDialog(in app: XCUIApplication) {
        let cancel = app.buttons["Отмена"]
        if cancel.exists, cancel.isHittable {
            cancel.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.42)).tap()
        }
    }

    /// Кнопка диалога подтверждения. Одноимённая кнопка («Остановить», «Удалить»)
    /// есть и под диалогом — в блоке очереди или в свайпе, — поэтому ищем в листе.
    private func dialogButton(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let inSheet = app.sheets.buttons[label]
        if inSheet.waitForExistence(timeout: 2) { return inSheet }
        return app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", label, "stopQueueButton"
        )).firstMatch
    }

    /// Снимок в светлой и тёмной теме подряд: приложение перекрашивается на лету.
    private func shoot(named name: String) {
        XCUIDevice.shared.appearance = .light
        sleep(1)
        save(XCUIScreen.main.screenshot(), named: "\(name)-light")
        XCUIDevice.shared.appearance = .dark
        sleep(1)
        save(XCUIScreen.main.screenshot(), named: "\(name)-dark")
        XCUIDevice.shared.appearance = .light
    }

    /// Лист уезжает с анимацией, и в это время кнопка под ним уже «существует»,
    /// но точки нажатия у неё ещё нет: тап уходит в никуда. Ждём доступности.

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
