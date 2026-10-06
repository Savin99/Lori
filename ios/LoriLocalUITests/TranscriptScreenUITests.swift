import XCTest

/// Экран записи по замыслу 5–6 октября 2026: заголовок и описание, дата с темой,
/// плеер, блок состояния и текст, в котором перематывает таймкод, а реплику можно
/// выделить. «Поделиться» и «Скопировать» — одной группой в панели навигации рядом
/// с «…», а чем расшифровано — первой строкой «…».
///
/// Обычные проверки идут на записи из `design/qa/seed-audio.sh` — «UI sample»:
/// две реплики с таймкодами и меткой говорящего. Снимки состояний — на наборе
/// `design/redesign-2026-10-05/seed-record-states.sh`: он живёт в отдельном корне
/// и открывается запуском с `--recovery-probe`; без набора снимки пропускаются.
@MainActor
final class TranscriptScreenUITests: XCTestCase {
    /// Заголовок «UI sample» — первая фраза расшифровки без точки.
    private let sample = "Проверка плеера записи"

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        // Тёмную тему тест включает сам — и обязан вернуть светлую, иначе
        // следующий тест и снимки соседей пойдут в тёмной.
        XCUIDevice.shared.appearance = .light
    }

    func testOpensSeededRecord() throws {
        let app = launch()
        try open(sample, in: app)

        let title = app.descendants(matching: .any)["recordTitle"]
        XCTAssertEqual(title.label, sample, "заголовок — первая фраза расшифровки")
        let meta = app.descendants(matching: .any)["recordingMeta"]
        XCTAssertTrue(meta.label.contains("2026"), "дата полная, а не «сегодня»: \(meta.label)")
        XCTAssertTrue(app.buttons["Слушать"].exists, "плеер на экране")
        XCTAssertTrue(app.buttons["Скорость воспроизведения"].exists, "скорость рядом с плеером")

        // «Поделиться» и «Скопировать» — одной группой в панели навигации, рядом с
        // «…», а не капсулами под плеером (владелец, 6 октября 2026).
        let bar = app.navigationBars.firstMatch
        let share = bar.buttons["shareMenu"]
        let copy = bar.buttons["copyTranscript"]
        let more = bar.buttons["transcriptMenu"]
        XCTAssertTrue(share.isEnabled, "с расшифровкой «Поделиться» доступна — в панели навигации")
        XCTAssertTrue(copy.isEnabled, "«Скопировать» рядом и доступна")
        XCTAssertEqual(share.label, "Поделиться")
        XCTAssertEqual(copy.label, "Скопировать")
        XCTAssertEqual(app.buttons.matching(identifier: "shareMenu").count, 1, "«Поделиться» одна — без дубля под плеером")
        XCTAssertEqual(app.buttons.matching(identifier: "copyTranscript").count, 1, "«Скопировать» одна")
        XCTAssertLessThan(share.frame.maxX, copy.frame.minX, "сначала «Поделиться», за ней «Скопировать»")
        XCTAssertLessThan(copy.frame.maxX, more.frame.minX, "«…» — у самого края")
        XCTAssertLessThan(share.frame.maxY, title.frame.minY, "кнопки над заголовком, а не под плеером")

        // Строки «чем расшифровано» под заголовком больше нет — она первой строкой «…».
        XCTAssertFalse(app.descendants(matching: .any)["transcriptEngine"].exists, "строка движка ушла из шапки")
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Расшифровано")).firstMatch.exists,
            "пока «…» закрыта, движка на экране нет"
        )
        // Дата с длительностью и тема — одной строкой, раз вместе влезают.
        let chip = app.buttons["topicChip"]
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "topicChip").count, 1,
            "тема назначается прямо с экрана записи"
        )
        XCTAssertEqual(meta.frame.midY, chip.frame.midY, accuracy: 2, "дата и тема — одной строкой")
        XCTAssertFalse(
            app.descendants(matching: .any)["transcriptionStatus"].exists,
            "у расшифрованной записи блока состояния нет"
        )

        // Реплику выделяют, а не нажимают: кнопка — только её таймкод.
        let line = "Раз, два, три, четыре, пять."
        XCTAssertTrue(app.staticTexts[line].exists, "текст реплики на экране")
        XCTAssertFalse(app.buttons[line].exists, "текст реплики не кнопка")
        XCTAssertEqual(app.buttons.matching(identifier: "lineTime").count, 2, "у каждой реплики таймкод-кнопка")

        let back = app.buttons["Записи"]
        XCTAssertTrue(back.exists, "видно, куда возвращает кнопка")
        back.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "«Записи» закрывает экран записи")
    }

    /// Формат выбирается каждый раз, словами веб-интерфейса.
    func testShareMenuOffersPDFAndMarkdown() throws {
        let app = launch()
        try open(sample, in: app)

        let share = app.buttons["shareMenu"]
        XCTAssertTrue(share.isEnabled)
        share.tap()

        let pdf = app.buttons["PDF"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 5), "формат выбирают в меню")
        XCTAssertTrue(app.buttons["Markdown (.md)"].exists)
        // Подписи «Удобно читать и отправлять» и «Текст для дальнейшей работы»
        // меню в дерево доступности отдельно не выставляет — они видны на снимке.
        save("record-share-menu")

        // Файл собирается и уходит в системный лист.
        app.buttons["Markdown (.md)"].tap()
        XCTAssertTrue(pdf.waitForNonExistence(timeout: 5), "меню закрылось")
        _ = app.otherElements.firstMatch.waitForExistence(timeout: 3)
        save("record-share-sheet")
    }

    /// Таймкод — кнопка: тап перематывает и включает звук.
    func testTimestampStartsPlayback() throws {
        let app = launch()
        try open(sample, in: app)

        let stamps = app.buttons.matching(identifier: "lineTime")
        XCTAssertEqual(stamps.count, 2)
        let second = stamps.element(boundBy: 1)
        XCTAssertEqual(second.label, "0:02", "таймкод второй реплики")
        second.tap()
        XCTAssertTrue(app.buttons["Пауза"].waitForExistence(timeout: 3), "тап по таймкоду включает звук")
    }

    /// Реплику выделяют долгим нажатием, как любой текст, — и копируют.
    func testReplicaTextIsSelectable() throws {
        let app = launch()
        try open(sample, in: app)

        // Та же фраза стоит сниппетом на карточке списка под листом — берём
        // последнюю: лист в дереве идёт после списка.
        let matches = app.staticTexts.matching(NSPredicate(format: "label == %@", "Раз, два, три, четыре, пять."))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 5))
        matches.element(boundBy: matches.count - 1).press(forDuration: 1.2)
        // «Скопировать» из меню текста, а не одноимённая кнопка панели.
        let copy = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND identifier != %@", "Скопировать", "copyTranscript"))
            .firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 3), "долгое нажатие на реплику даёт меню текста")
        save("record-text-selection")
    }

    /// В «…» только то, что работает; «Скопировать» и «Поделиться» стоят рядом с ней
    /// в панели. Первой строкой «…» — чем расшифровано: подпись, а не пункт.
    func testMoreMenuListsRecordActions() throws {
        let app = launch()
        try open(sample, in: app)

        app.buttons["transcriptMenu"].tap()
        // «UI sample» расшифрован GigaAM на телефоне — место сказано словами.
        let engine = app.staticTexts["Расшифровано на этом iPhone: GigaAM v3 CTC (int8)"]
        XCTAssertTrue(engine.waitForExistence(timeout: 3), "движок — первой строкой «…»")
        XCTAssertFalse(app.buttons[engine.label].exists, "строка движка не нажимается")
        for item in ["Придумать заголовок и описание", "Править текст", "Тема", "Отправить в Obsidian", "Расшифровать заново"] {
            XCTAssertTrue(app.buttons[item].waitForExistence(timeout: 3), "в «…» нет пункта «\(item)»")
        }
        XCTAssertLessThan(
            engine.frame.maxY, app.buttons["Придумать заголовок и описание"].frame.minY,
            "строка движка — над пунктами"
        )
        save("record-more-menu")

        // Подменю движков: только готовые — то же правило, что у шита из панели, —
        // и иконка говорит, уйдёт ли запись с телефона. Системный движок готов
        // всегда, а ключа ElevenLabs в Lori QA нет (на этом стоит и
        // testCaptureRecordStates: облачный движок без ключа даёт ошибку).
        app.buttons["Расшифровать заново"].tap()
        XCTAssertTrue(app.buttons["Apple, на устройстве"].waitForExistence(timeout: 3), "готовый движок на выбор")
        XCTAssertFalse(app.buttons["ElevenLabs Scribe API"].exists, "движка без ключа в подменю нет")
    }

    /// Расшифровка заново заменяет текст — без подтверждения она не начинается.
    func testRetranscribeAsksBeforeReplacingText() throws {
        let app = launch()
        try open(sample, in: app)

        app.buttons["transcriptMenu"].tap()
        tap(app.buttons["Расшифровать заново"])
        tap(app.buttons["Apple, на устройстве"])

        let question = app.staticTexts["Расшифровать заново?"]
        XCTAssertTrue(question.waitForExistence(timeout: 5), "сначала спрашивает")
        XCTAssertTrue(exists(containing: "правки руками пропадут", in: app), "и говорит, что текст заменится")
        XCTAssertTrue(app.buttons["Расшифровать заново"].exists, "подтверждение — отдельной кнопкой")
        save("record-retranscribe-confirm")

        // В iOS 26 вопрос встаёт поповером без кнопки «Отмена»: отказ — тап мимо.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        XCTAssertTrue(question.waitForNonExistence(timeout: 5))
        XCTAssertFalse(
            app.descendants(matching: .any)["transcriptionStatus"].exists,
            "отмена ничего не запустила"
        )
    }

    /// Переименование заполняет поле тем, что человек видит, а не именем файла:
    /// иначе «Сохранить» без правки сделало бы «UI sample» ручным заголовком.
    /// Пункт есть, только когда список передал экрану `onRename`.
    func testRenameIsPrefilledWithVisibleTitle() throws {
        let app = launch()
        try open(sample, in: app)

        let title = app.buttons["recordTitle"]
        try XCTSkipUnless(title.exists, "список ещё не передал экрану onRename — заголовок не кнопка")
        title.tap()
        let field = app.textFields["Название"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "тап по заголовку открывает переименование")
        XCTAssertEqual(field.value as? String, sample, "в поле — видимый заголовок")
        save("record-rename")
        tap(app.buttons["Отмена"])

        app.buttons["transcriptMenu"].tap()
        XCTAssertTrue(app.buttons["Переименовать"].waitForExistence(timeout: 3), "и пункт в «…»")
    }

    /// «Удалить запись» в «…» — только когда список передал `onDelete`: удаляет и
    /// подтверждает он. Здесь пункт не нажимается.
    func testDeleteIsOfferedWhenListAllowsIt() throws {
        let app = launch()
        try open(sample, in: app)

        app.buttons["transcriptMenu"].tap()
        XCTAssertTrue(app.buttons["Тема"].waitForExistence(timeout: 3))
        try XCTSkipUnless(app.buttons["Удалить запись"].exists, "список ещё не передал экрану onDelete")
        save("record-more-menu-full")
    }

    /// Прерванную запись не переименовать: переименование через `forget` сняло бы
    /// её сохранённое задание. Пункта нет ни в меню долгого нажатия, ни в свайпе, а
    /// на экране записи заголовок — не кнопка и «Переименовать» в «…» выключено.
    /// «Продолжить» тест не нажимает: прерванная запись набора нужна снимкам.
    func testInterruptedRecordCannotBeRenamed() throws {
        let app = launch(engine: "elevenlabs", extra: ["--recovery-probe"])
        let card = find("Прервано", in: app)
        try XCTSkipUnless(
            card.exists,
            "нет прерванной записи — прогони design/redesign-2026-10-05/seed-record-states.sh"
        )
        reveal(card, in: app)

        card.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Тема"].waitForExistence(timeout: 5), "меню долгого нажатия открылось")
        XCTAssertTrue(app.buttons["Удалить"].exists)
        XCTAssertFalse(app.buttons["Переименовать"].exists, "у прерванной записи в меню нет «Переименовать»")
        // Меню закрывается тапом мимо — у самого края, вне карточки.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.42)).tap()
        XCTAssertTrue(app.buttons["Тема"].waitForNonExistence(timeout: 5))

        try openCard(withStatus: "Прервано", in: app)
        XCTAssertFalse(app.buttons["recordTitle"].exists, "заголовок прерванной записи — не кнопка переименования")
        app.buttons["transcriptMenu"].tap()
        let rename = app.buttons["Переименовать"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3), "пункт в «…» виден")
        XCTAssertFalse(rename.isEnabled, "но выключен")
        // Мимо меню — в пустой низ экрана, подальше от «Продолжить».
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.88)).tap()
        XCTAssertTrue(rename.waitForNonExistence(timeout: 5))
        close(app)

        reveal(card, in: app)
        card.swipeLeft()
        XCTAssertTrue(app.buttons["Удалить"].waitForExistence(timeout: 5), "свайп открыл действия")
        XCTAssertFalse(app.buttons["Переименовать"].exists, "и в свайпе «Переименовать» нет")
    }

    /// У короткой записи заголовок — первая фраза; просьба придумать другой
    /// отвечает словами и в очередь модели ничего не ставит.
    func testShortRecordKeepsFirstPhraseAsTitle() throws {
        let app = launch()
        try open(sample, in: app)

        app.buttons["transcriptMenu"].tap()
        tap(app.buttons["Придумать заголовок и описание"])
        XCTAssertTrue(
            app.staticTexts["Запись короткая — заголовком служит первая фраза."].waitForExistence(timeout: 5),
            "короткой записи объясняют, почему заголовка от модели не будет"
        )
        tap(app.alerts.firstMatch.buttons["OK"])
    }

    /// Без модели заголовков её предлагают скачать на месте. Набор снимков живёт в
    /// своём корне со своей очередью заголовков (`--recovery-probe`), поэтому
    /// оставленная там просьба не трогает обычную очередь. «Скачать» не нажимается.
    func testTitleRequestOffersModelDownload() throws {
        let app = launch(extra: ["--recovery-probe"])
        try XCTSkipUnless(
            find("Совещание по бюджету", in: app).exists,
            "нет набора снимков — прогони design/redesign-2026-10-05/seed-record-states.sh"
        )
        try open("Совещание по бюджету", in: app)

        app.buttons["transcriptMenu"].tap()
        tap(app.buttons["Придумать заголовок и описание"])
        let offer = app.staticTexts["Заголовок придумывает модель на этом iPhone"]
        try XCTSkipIf(
            !offer.waitForExistence(timeout: 5) && app.staticTexts["Модель уже скачивается"].exists,
            "модель уже скачивается — предлагать нечего"
        )
        XCTAssertTrue(offer.exists, "без модели предлагают скачать её на месте")
        let download = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Скачать ")).firstMatch
        XCTAssertTrue(download.exists, "кнопка называет модель и размер")
        XCTAssertTrue(download.label.contains("ГБ"), "размер на кнопке: \(download.label)")
        save("record-title-model-offer")
        // Отказ — тап мимо поповера, как у любого вопроса из «…».
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        XCTAssertTrue(offer.waitForNonExistence(timeout: 5))
    }

    /// Пока текста нет, «Поделиться» и «Скопировать» нет вовсе — ни выключенными, ни
    /// пустым стеклом в панели; нет и строки движка в «…». Тест ничего не нажимает:
    /// запись без расшифровки нужна тестам очереди.
    func testUntranscribedRecordHasNoShareOrCopy() throws {
        let app = launch()
        try openCard(withStatus: "Без расшифровки", in: app)
        XCTAssertTrue(app.buttons["transcribeAction"].waitForExistence(timeout: 5), "это запись без расшифровки")
        XCTAssertFalse(app.buttons["shareMenu"].exists, "без текста «Поделиться» нет")
        XCTAssertFalse(app.buttons["copyTranscript"].exists, "без текста «Скопировать» нет")

        app.buttons["transcriptMenu"].tap()
        XCTAssertTrue(app.buttons["Тема"].waitForExistence(timeout: 3), "«…» открылась")
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Расшифровано")).firstMatch.exists,
            "без расшифровки нет и строки движка"
        )
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.88)).tap()
        XCTAssertTrue(app.buttons["Тема"].waitForNonExistence(timeout: 5))
    }

    /// Точка нажатия пунктов панели — вся стеклянная кнопка 44 pt, а не рамка значка
    /// 36 pt, которую видит XCUITest. Так бывает, когда пункт системный — из `Label`;
    /// «…» с голой `Image` ловила нажатие только рамкой 28 × 36. Тапы — у краёв
    /// стекла, за рамкой пункта: на 3 точки выше, на 2 ниже, на 4 левее.
    func testToolbarButtonsAreHitAcrossTheirGlass() throws {
        let app = launch()
        try open(sample, in: app)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        func outside(_ element: XCUIElement, dx: CGFloat = 0, dy: CGFloat) -> XCUICoordinate {
            let frame = element.frame
            let x = dx < 0 ? frame.minX + dx : frame.midX
            let y = dy < 0 ? frame.minY + dy : (dy > 0 ? frame.maxY + dy : frame.midY)
            return origin.withOffset(CGVector(dx: x, dy: y))
        }
        let away = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.88))

        outside(app.buttons["shareMenu"], dy: -3).tap()
        XCTAssertTrue(app.buttons["PDF"].waitForExistence(timeout: 3), "«Поделиться» нажимается у верхнего края стекла")
        away.tap()
        XCTAssertTrue(app.buttons["PDF"].waitForNonExistence(timeout: 5))

        let copy = app.buttons["copyTranscript"]
        outside(copy, dy: 2).tap()
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Скопировано"), object: copy)
        XCTAssertEqual(XCTWaiter().wait(for: [copied], timeout: 1.5), .completed, "«Скопировать» нажимается у нижнего края стекла")

        let more = app.buttons["transcriptMenu"]
        for point in [outside(more, dy: -3), outside(more, dx: -4, dy: 0)] {
            point.tap()
            XCTAssertTrue(app.buttons["Тема"].waitForExistence(timeout: 3), "«…» нажимается у края стекла")
            away.tap()
            XCTAssertTrue(app.buttons["Тема"].waitForNonExistence(timeout: 5))
        }
    }

    // MARK: - Снимки состояний

    /// Снимки экрана записи в светлой и тёмной теме — для глаз, а не для проверок.
    /// Вынимаются из результата прогона: `xcrun xcresulttool export attachments`.
    func testCaptureRecordStates() throws {
        let app = launch(engine: "elevenlabs", extra: ["--recovery-probe"])
        try XCTSkipUnless(
            find("Совещание по бюджету", in: app).exists,
            "нет набора снимков — прогони design/redesign-2026-10-05/seed-record-states.sh"
        )

        try open("Совещание по бюджету", in: app)
        assignTopic("Работа", in: app)
        nameFirstSpeaker("Марина", in: app)
        shoot("record-transcript", in: app)
        close(app)

        try open("Созвон с подрядчиком", in: app)
        shoot("record-long-title", in: app)
        close(app)

        // Заголовок этой записи — её первая фраза, а не имя файла.
        try open("Главное со встречи", in: app)
        shoot("record-no-timecodes", in: app)
        close(app)

        try openCard(withStatus: "Прервано", in: app)
        shoot("record-interrupted", in: app)
        close(app)

        // Ошибку даёт сам прогон: облачный движок без ключа. Она переживает
        // перезапуск, и при следующем прогоне запись просто открывается. Одна
        // запись без расшифровки всегда остаётся — для снимка этого состояния.
        // Карточка с ошибкой говорит её первой фразой: «Ключ ElevenLabs не сохранён».
        let untranscribed = app.descendants(matching: .any)
            .matching(identifier: "recordingCard")
            .matching(NSPredicate(format: "label CONTAINS %@", "Без расшифровки"))
        if untranscribed.count >= 2 || !card(containing: failedCard, in: app).exists {
            try openCard(withStatus: "Без расшифровки", in: app)
            tap(app.buttons["transcribeAction"])
            // Ошибка записи — строкой на этом экране. Алерт списка про неё больше не
            // встаёт и лист не закрывает (`ContentView.activeError`).
            XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 3), "ошибка записи — не алертом поверх листа")
        }
        if !app.descendants(matching: .any)["recordTitle"].exists {
            try openCard(withStatus: failedCard, in: app)
        }
        let failure = app.staticTexts["Не получилось расшифровать"]
        XCTAssertTrue(failure.waitForExistence(timeout: 15), "облачный движок без ключа даёт ошибку")
        XCTAssertTrue(app.buttons["Повторить"].exists, "рядом с ошибкой — «Повторить»")
        shoot("record-failed", in: app)
        close(app)

        try openCard(withStatus: "Без расшифровки", in: app)
        shoot("record-untranscribed", in: app)
        close(app)
    }

    /// Панель после 6 октября — снимки для глаз: запись с текстом, «…» со строкой
    /// движка и запись без расшифровки, в светлой и тёмной теме. Запись без
    /// расшифровки только открывается: снимкам состояний она нужна такой.
    func testCaptureToolbar() throws {
        let app = launch(engine: "elevenlabs", extra: ["--recovery-probe"])
        try XCTSkipUnless(
            find("Совещание по бюджету", in: app).exists,
            "нет набора снимков — прогони design/redesign-2026-10-05/seed-record-states.sh"
        )
        try open("Совещание по бюджету", in: app)
        shoot("record-toolbar-transcript", in: app)

        let engine = app.staticTexts["Расшифровано в облаке: ElevenLabs · scribe_v2 · Дословно"]
        for dark in [false, true] {
            XCUIDevice.shared.appearance = dark ? .dark : .light
            settle(app)
            tap(app.buttons["transcriptMenu"])
            XCTAssertTrue(engine.waitForExistence(timeout: 3), "облачный движок — первой строкой «…», с местом")
            Thread.sleep(forTimeInterval: 0.8)
            save("record-toolbar-menu-\(dark ? "dark" : "light")")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.88)).tap()
            XCTAssertTrue(engine.waitForNonExistence(timeout: 5))
        }
        XCUIDevice.shared.appearance = .light
        close(app)

        try openCard(withStatus: "Без расшифровки", in: app)
        XCTAssertFalse(app.buttons["shareMenu"].exists, "без текста «Поделиться» нет")
        XCTAssertFalse(app.buttons["copyTranscript"].exists, "без текста «Скопировать» нет")
        shoot("record-toolbar-untranscribed", in: app)
        close(app)
    }

    /// Крупный текст: ничего не режется и не вылезает за край.
    func testCaptureLargeText() throws {
        let app = launch(
            engine: "elevenlabs",
            extra: ["--recovery-probe", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        )
        try XCTSkipUnless(
            find("Совещание по бюджету", in: app).exists,
            "нет набора снимков — прогони design/redesign-2026-10-05/seed-record-states.sh"
        )
        try open("Совещание по бюджету", in: app)
        save("record-large-text-light")
        app.swipeUp()
        save("record-large-text-scrolled-light")
    }

    // MARK: - Помощники

    /// Первая фраза ошибки облачного движка без ключа — так её пишет карточка.
    private let failedCard = "не сохранён"

    /// Запуск с заданным движком: выбор живёт в `UserDefaults` и иначе переживал бы
    /// прогон — один тест влиял бы на другой.
    private func launch(engine: String = "gigaam", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-transcriptionEngine", engine, "--forget-attachments"] + extra
        app.launch()
        return app
    }

    /// Карточку ищут по заголовку, а не по имени файла: заголовок — то, что видит
    /// человек. Список ленивый: карточки ниже края экрана в дереве ещё нет, и до
    /// неё докручивают.
    private func find(_ text: String, in app: XCUIApplication) -> XCUIElement {
        let target = card(containing: text, in: app)
        var attempts = 0
        while !target.waitForExistence(timeout: attempts == 0 ? 8 : 1), attempts < 8 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            from.press(forDuration: 0.05, thenDragTo: to)
            attempts += 1
        }
        return target
    }

    private func card(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "recordingCard")
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    private func open(_ title: String, in app: XCUIApplication) throws {
        let card = find(title, in: app)
        try XCTSkipUnless(card.exists, "нет записи «\(title)» — прогони посев из design/")
        reveal(card, in: app)
        tap(card)
        XCTAssertTrue(
            app.descendants(matching: .any)["recordTitle"].waitForExistence(timeout: 5),
            "тап по карточке открывает экран записи"
        )
    }

    private func openCard(withStatus status: String, in app: XCUIApplication) throws {
        let card = find(status, in: app)
        try XCTSkipUnless(card.exists, "нет карточки «\(status)»")
        reveal(card, in: app)
        tap(card)
        XCTAssertTrue(app.descendants(matching: .any)["recordTitle"].waitForExistence(timeout: 5))
    }

    /// Лента уходит под нижнюю панель, и `isHittable` перекрытой карточки всё
    /// равно true: тап в этом месте достаётся панели. Докручиваем до видимого.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let panel = app.buttons["recordButton"]
        guard panel.exists else { return }
        var attempts = 0
        while element.frame.maxY > panel.frame.minY - 8, attempts < 8 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            from.press(forDuration: 0.05, thenDragTo: to)
            attempts += 1
        }
    }

    private func close(_ app: XCUIApplication) {
        tap(app.buttons["Записи"])
        XCTAssertTrue(app.descendants(matching: .any)["recordTitle"].waitForNonExistence(timeout: 5))
    }

    private func assignTopic(_ topic: String, in app: XCUIApplication) {
        let chip = app.buttons["topicChip"]
        guard chip.waitForExistence(timeout: 3), !chip.label.contains(topic) else { return }
        tap(chip)
        let existing = app.buttons[topic]
        if existing.waitForExistence(timeout: 3) {
            tap(existing)
        } else {
            tap(app.buttons["addTopic"])
            let field = app.textFields["newTopicField"]
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            field.typeText(topic + "\n")
        }
        XCTAssertTrue(app.descendants(matching: .any)["newTopicField"].waitForNonExistence(timeout: 5))
        _ = chip.waitForExistence(timeout: 3)
    }

    private func nameFirstSpeaker(_ name: String, in app: XCUIApplication) {
        let dot = app.descendants(matching: .any).matching(identifier: "speakerDot").firstMatch
        guard dot.waitForExistence(timeout: 3), !dot.label.contains(name) else { return }
        dot.press(forDuration: 0.8)
        let field = app.textFields["Имя"]
        guard field.waitForExistence(timeout: 3) else { return }
        field.typeText(name)
        tap(app.buttons["Сохранить"])
    }

    /// Один и тот же экран в светлой и тёмной теме.
    private func shoot(_ name: String, in app: XCUIApplication) {
        XCUIDevice.shared.appearance = .light
        settle(app)
        save("\(name)-light")
        XCUIDevice.shared.appearance = .dark
        settle(app)
        save("\(name)-dark")
        XCUIDevice.shared.appearance = .light
        settle(app)
    }

    /// Смена темы и закрытие листов идут с анимацией.
    private func settle(_ app: XCUIApplication) {
        _ = app.descendants(matching: .any)["recordTitle"].waitForExistence(timeout: 2)
        Thread.sleep(forTimeInterval: 1.0)
    }

    private func exists(containing text: String, in app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
            .waitForExistence(timeout: 3)
    }

    /// Лист уезжает с анимацией, и кнопка под ним уже «существует», но точки
    /// нажатия у неё ещё нет: тап уходит в никуда. Ждём доступности.
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 5) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "нет элемента для нажатия: \(element)")
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isHittable, Date() < deadline {
            _ = element.waitForExistence(timeout: 0.2)
        }
        element.tap()
    }

    private func save(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
