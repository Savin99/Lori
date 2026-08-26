import XCTest

/// Сквозная проверка против настоящего HTTP: обработка расшифровки, поиск по заметкам
/// и память гоняются через подставной сервер с API как у OpenAI.
///
/// Юнит-тесты подменяют `ChatCompleting`, поэтому в них не участвуют ни сеть, ни разбор
/// ответа, ни настройки провайдера — а именно там ломается всё интересное.
/// Ключ владельца для этого не нужен и не используется.
///
/// Перед прогоном:
///   python3 design/qa/mock-llm.py 8765 &
///   ./design/qa/seed-digest.sh <udid>
/// Без сервера или без набора файлов тест пропускается, а не падает.
@MainActor
final class LiveModelUITests: XCTestCase {
    private static let baseURL = "http://127.0.0.1:8765/v1"
    private static let model = "mock-local"
    /// Ключ подставной: локальному серверу важно только, что он есть.
    private static let key = "mock-key"

    /// Режим определяется по факту: поднята заглушка — работаем против неё,
    /// не поднята — против того провайдера, который настроил владелец.
    /// Через переменную окружения не выйдет: `TEST_RUNNER_…` до раннера не доезжает,
    /// и прогон молча уходил к заглушке, притворяясь настоящим.
    private static let usesMock = mockIsRunning()
    private static var usesRealProvider: Bool { !usesMock }

    override func setUp() async throws {
        // Режим печатается в лог: иначе прогон против заглушки легко принять
        // за прогон против настоящего провайдера, и наоборот.
        print("LiveModelUITests: провайдер — \(Self.usesRealProvider ? "настоящий, из настроек приложения" : "подставной \(Self.baseURL)")")
    }

    func testModelTurnsTranscriptIntoNoteInThemeFolder() throws {
        continueAfterFailure = false
        let app = launch()
        try setUpKey(in: app)

        // «UI live» — запись с расшифровкой, но без обработанной заметки.
        let card = try row(startingWith: "UI live", in: app, "нет записи «UI live» — прогони design/qa/seed-digest.sh")
        scroll(to: card, in: app)
        card.tap()

        let process = app.buttons["Обработать"]
        try XCTSkipUnless(
            process.waitForExistence(timeout: 5),
            "у «UI live» уже есть обработанная заметка — прогони design/qa/seed-digest.sh заново"
        )
        process.tap()

        // Ответ идёт по сети, поэтому ожидание щедрое.
        XCTAssertTrue(
            app.buttons["Открыть заметку"].waitForExistence(timeout: 25),
            "обработка не завершилась: заметка не создана"
        )
        // Заголовок и тему придумывает модель, поэтому берём их с экрана,
        // а не сверяем с заранее известным текстом.
        let title = app.staticTexts["digestTitle"]
        XCTAssertTrue(title.exists, "в «Важном» нет заголовка из ответа модели")
        let noteTitle = title.label
        let themeLine = app.staticTexts
            .containing(NSPredicate(format: "label BEGINSWITH %@", "Тема · ")).firstMatch
        XCTAssertTrue(themeLine.exists, "не видно, в какую тему легла заметка")
        let theme = String(themeLine.label.dropFirst("Тема · ".count))
        if Self.usesMock {
            XCTAssertEqual(noteTitle, "Оффер до пятницы")
            XCTAssertEqual(theme, "Работа")
        }
        save(XCUIScreen.main.screenshot(), named: "live-digest")

        // Переключатель обязан оставить дословный текст доступным.
        segment("Расшифровка", in: app).tap()
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Так, по найму")).firstMatch
                .waitForExistence(timeout: 3),
            "после обработки пропал дословный текст"
        )

        app.buttons["Готово"].tap()

        // Заметка должна появиться в своей теме, а не в корне.
        // Через шторку папок сюда идти нельзя: под её затемнением остаётся такая же
        // строка с главного экрана, тап достаётся затемнению, и шторка просто
        // закрывается. Открываем папку прямо из раздела «Папки» на главной.
        // Лента осталась прокрученной после карточки: раздел «Папки» живёт наверху,
        // и в ленивом списке его строк в дереве элементов просто нет.
        scrollToTop(app)
        // Здесь листа поверх экрана нет, поэтому фильтр по `isHittable` только мешает:
        // строка может быть ещё под композером, и её достаточно домотать.
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", theme)).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5), "тематической папки «\(theme)» нет")
        scroll(to: folder, in: app)
        folder.tap()
        XCTAssertTrue(app.buttons["Назад"].waitForExistence(timeout: 5), "браузер папки не открылся")
        // В имени файла нет символов, недопустимых в пути: заголовок «Тема: смысл»
        // становится файлом «Тема смысл». Строка списка показывает имя файла.
        let fileTitle = Self.asFileName(noteTitle)
        let created = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", fileTitle)).firstMatch
        let appeared = created.waitForExistence(timeout: 5)
        // Снимок до проверки: при провале после неё его уже не будет.
        save(XCUIScreen.main.screenshot(), named: "live-theme-folder")
        XCTAssertTrue(appeared, "созданной заметки «\(fileTitle)» нет в папке «\(theme)»")

        // Вики собирается из файлов на открытие, значит новая заметка и её теги
        // должны появиться там сразу, без перезапуска.
        // Из вложенной папки лист закрывается в два шага: «Назад» — к корню
        // рабочей папки, и только там появляется «Готово». Одним тапом наружу
        // из вложенной папки не выйти (человек ещё может смахнуть лист вниз).
        app.buttons["Назад"].tap()
        app.buttons["Готово"].tap()
        app.buttons["Открыть папки"].tap()
        app.buttons["Вики: темы и связи"].tap()
        XCTAssertTrue(app.staticTexts["Вики"].waitForExistence(timeout: 5), "вики не открылась")
        // Ищем заметку через её тему: в «Все заметки» она может быть далеко внизу,
        // а в ленивом списке таких строк в дереве элементов просто нет.
        XCTAssertTrue(app.staticTexts["Теги"].exists, "у новой заметки нет ни одного тега")
        // Вики — лист поверх главной, и под ним осталась одноимённая строка папки:
        // берём только доступную для тапа, иначе тап уходит в невидимую.
        let themeRow = try row(startingWith: theme, in: app, "темы «\(theme)» нет в вики")
        save(XCUIScreen.main.screenshot(), named: "live-wiki-after-digest")
        themeRow.tap()

        let inWiki = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", noteTitle)).firstMatch
        XCTAssertTrue(inWiki.waitForExistence(timeout: 5), "новая заметка не попала в вики")
    }

    func testChatSearchesNotesAndRemembersFact() throws {
        continueAfterFailure = false
        let app = launch()
        try setUpKey(in: app)

        // Вопрос про содержание записей: модель обязана сходить в search_notes.
        let composer = app.textFields.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("что я говорил про оффер\n")

        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "ищу по заметкам")).firstMatch
                .waitForExistence(timeout: 25),
            "в чате не видно, что агент искал по заметкам"
        )
        // Признак пришедшего ответа — действие «Скопировать»: оно есть только под
        // ответом модели. Проверять по тексту нельзя, слова у настоящей модели свои,
        // а слово «заметк» находится и в строке «ищу по заметкам».
        let copy = app.buttons["Скопировать"]
        XCTAssertTrue(copy.waitForExistence(timeout: 90), "ответ по результату поиска не пришёл")
        if Self.usesMock {
            XCTAssertTrue(
                app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Нашёл в заметках"))
                    .firstMatch.exists
            )
        }
        save(XCUIScreen.main.screenshot(), named: "live-chat-search")

        // В композере должно стоять имя модели, к которой запрос действительно уходит.
        // Раньше там горело «V4 Flash» независимо от провайдера.
        if !Self.usesRealProvider {
            let chip = app.staticTexts["chatModelName"]
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "в композере не видно модели")
            XCTAssertEqual(chip.label, Self.model, "композер показывает не ту модель, к которой уходит запрос")
        }

        // Память: просьба запомнить должна дойти до файла «Память Lori».
        // Факт делается уникальным нарочно: если он уже в памяти, модель видит его
        // в системной инструкции и честно отвечает без вызова инструмента.
        let secret = "код проекта \(UUID().uuidString.prefix(4))"
        let chatField = chatComposer(in: app)
        chatField.tap()
        chatField.typeText("запомни, что \(secret)")
        app.buttons["chatPrimaryButton"].tap()

        // Инструмент памяти виден строкой работы, а сам ответ — вторым «Скопировать».
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "запоминаю")).firstMatch
                .waitForExistence(timeout: 90),
            "агент не вызвал инструмент памяти"
        )
        let answered = expectation(description: "второй ответ")
        let poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if app.buttons.matching(identifier: "Скопировать").count >= 2 {
                timer.invalidate()
                answered.fulfill()
            }
        }
        wait(for: [answered], timeout: 90)
        poll.invalidate()
        save(XCUIScreen.main.screenshot(), named: "live-chat-memory")

        app.buttons["Закрыть чат"].tap()
        let memory = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Память Lori")).firstMatch
        XCTAssertTrue(memory.waitForExistence(timeout: 5), "заметка «Память Lori» не появилась в списке")
    }

    /// Модель ответила прозой вместо JSON. Приложение обязано сказать об этом
    /// и ничего не сохранить: мусорная заметка хуже отсутствия заметки.
    func testBadAnswerIsReportedAndNoNoteIsSaved() throws {
        try XCTSkipUnless(Self.usesMock, "управляемый сбой умеет только подставная модель — запусти design/qa/mock-llm.py")
        continueAfterFailure = false
        let app = launch()
        try setUpKey(in: app)

        let card = try row(startingWith: "UI fail", in: app, "нет записи «UI fail» — прогони design/qa/seed-digest.sh")
        scroll(to: card, in: app)
        card.tap()

        let process = app.buttons["Обработать"]
        try XCTSkipUnless(process.waitForExistence(timeout: 5), "у «UI fail» уже есть заметка — пересей набор")
        process.tap()

        let complaint = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "не тем форматом")).firstMatch
        let shown = complaint.waitForExistence(timeout: 25)
        save(XCUIScreen.main.screenshot(), named: "live-bad-answer")
        XCTAssertTrue(shown, "сбой обработки не показан человеку")
        // Действие осталось прежним — значит заметки нет и попробовать можно снова.
        XCTAssertTrue(app.buttons["Обработать"].exists, "после сбоя пропала возможность повторить")
        XCTAssertFalse(app.buttons["Открыть заметку"].exists, "после сбоя появилась заметка из мусора")
    }

    /// Провайдер ответил HTTP 500. Текст ошибки должен доходить до человека,
    /// а не превращаться в молчание.
    func testProviderFailureIsShown() throws {
        try XCTSkipUnless(Self.usesMock, "управляемый сбой умеет только подставная модель — запусти design/qa/mock-llm.py")
        continueAfterFailure = false
        let app = launch()
        try setUpKey(in: app)

        let card = try row(startingWith: "UI err", in: app, "нет записи «UI err» — прогони design/qa/seed-digest.sh")
        scroll(to: card, in: app)
        card.tap()

        let process = app.buttons["Обработать"]
        try XCTSkipUnless(process.waitForExistence(timeout: 5), "у «UI err» уже есть заметка — пересей набор")
        process.tap()

        let complaint = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "сломалось")).firstMatch
        let shown = complaint.waitForExistence(timeout: 25)
        save(XCUIScreen.main.screenshot(), named: "live-provider-error")
        XCTAssertTrue(shown, "ошибка провайдера не показана человеку")
        XCTAssertFalse(app.buttons["Открыть заметку"].exists, "после ошибки появилась заметка")
    }

    /// Модель зовёт инструмент по кругу. Приложение должно упереться в свой предел
    /// и вернуть управление человеку, а не ходить бесконечно.
    func testToolLoopStopsAtTheLimit() throws {
        try XCTSkipUnless(Self.usesMock, "управляемый сбой умеет только подставная модель — запусти design/qa/mock-llm.py")
        continueAfterFailure = false
        let app = launch()
        try setUpKey(in: app)

        let composer = app.textFields.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("ЦИКЛ\n")

        let limit = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "Остановился после")).firstMatch
        let stopped = limit.waitForExistence(timeout: 60)
        save(XCUIScreen.main.screenshot(), named: "live-tool-limit")
        XCTAssertTrue(stopped, "агент не сообщил, что упёрся в предел обращений")
        // После предела интерфейс должен снова принимать ввод.
        XCTAssertTrue(chatComposer(in: app).isHittable, "после предела композер недоступен")
    }

    // MARK: - Обвязка

    /// Настройки провайдера передаются аргументами запуска: они попадают в домен
    /// аргументов `UserDefaults` и перебивают всё остальное, поэтому в реальных
    /// настройках приложения после теста ничего не остаётся.
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-loriMemory", "1"]
        if !Self.usesRealProvider {
            app.launchArguments += [
                "-llmBaseURL", Self.baseURL,
                "-llmCustomModel", Self.model,
            ]
        }
        app.launch()
        return app
    }

    /// Ключ нужен настоящий по форме, но не по содержанию: локальный сервер проверяет
    /// только наличие заголовка. После теста ключ удаляется, чтобы не мешать другим прогонам.
    private func setUpKey(in app: XCUIApplication) throws {
        app.buttons["Настройки"].tap()
        let field = app.secureTextFields["apiKeyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "в настройках нет поля ключа")

        // С настоящим провайдером ключ уже сохранён владельцем. Своего не вводим,
        // чужого не читаем и не удаляем — только проверяем, что подключение живо.
        if Self.usesRealProvider {
            let check = app.buttons["Проверить подключение"]
            try XCTSkipUnless(check.exists, "ключ не сохранён в приложении — вбей его в настройках вручную")
            check.tap()
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 30), "проверка подключения не ответила")
            let message = alert.staticTexts.element(boundBy: 1).label
            alert.buttons["OK"].tap()
            XCTAssertTrue(message.contains("Подключение работает"), "провайдер не принял ключ: \(message)")
            app.buttons["Готово"].tap()
            return
        }

        // Признак сохранённого ключа — появившаяся кнопка проверки, а не строка статуса:
        // `LabeledContent` отдаёт один элемент с составной подписью, и поиск по тексту
        // значения его не находит.
        let check = app.buttons["Проверить подключение"]
        // Чужой ключ в подставном режиме использовать нельзя: он ушёл бы в локальный
        // сервер. Свой мы удаляем в teardown, поэтому обычно тут пусто.
        try XCTSkipIf(
            check.exists,
            "в приложении уже сохранён ключ — удали его в настройках или останови заглушку, чтобы прогнать против настоящего провайдера"
        )
        if !check.exists {
            field.tap()
            field.typeText(Self.key)
            app.buttons["Сохранить в Keychain"].tap()
            let saved = app.alerts.firstMatch
            XCTAssertTrue(saved.waitForExistence(timeout: 5), "сохранение ключа не ответило")
            let text = saved.staticTexts.element(boundBy: 1).label
            save(XCUIScreen.main.screenshot(), named: "live-key-saved")
            saved.buttons["OK"].tap()
            XCTAssertTrue(text.contains("сохранён"), "ключ не сохранился: \(text)")
            XCTAssertTrue(check.waitForExistence(timeout: 3), "после сохранения нет проверки подключения")
        }

        // Проверка подключения заодно доказывает, что запросы уходят к своему провайдеру.
        check.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "проверка подключения не ответила")
        let message = alert.staticTexts.element(boundBy: 1).label
        XCTAssertTrue(
            message.contains("Подключение работает"),
            "свой провайдер не принял ключ: \(message)"
        )
        XCTAssertTrue(message.contains("127.0.0.1"), "запрос ушёл не к своему провайдеру: \(message)")
        alert.buttons["OK"].tap()

        addTeardownBlock { @MainActor in
            let settings = XCUIApplication()
            if settings.buttons["Удалить ключ"].exists {
                settings.buttons["Удалить ключ"].tap()
                settings.alerts.firstMatch.buttons["OK"].tap()
            }
        }
        app.buttons["Готово"].tap()
    }

    private func chatComposer(in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["Спроси о своих заметках"]
        if field.waitForExistence(timeout: 5) { return field }
        return app.textViews["Спроси о своих заметках"]
    }

    private func segment(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let inControl = app.segmentedControls.buttons[title]
        return inControl.exists ? inControl : app.buttons[title]
    }

    /// Под открытым листом остаются кнопки с теми же названиями, и `firstMatch`
    /// цепляет невидимую — тап тогда падает с «Failed to not hittable».
    private func row(
        startingWith prefix: String,
        in app: XCUIApplication,
        _ message: String
    ) throws -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
        try XCTSkipUnless(matches.firstMatch.waitForExistence(timeout: 5), message)
        return try XCTUnwrap(matches.allElementsBoundByIndex.first { $0.isHittable }, message)
    }

    /// Повторяет `NoteDigest.sanitizeName`: модуль приложения в UI-тест не импортируется,
    /// поэтому правило приходится держать в двух местах — зато тест ловит и его поломку.
    private static func asFileName(_ title: String) -> String {
        var name = title
        for forbidden in ["/", "\\", ":", "\r", "\n", "\t", "*", "?", "\"", "<", ">", "|"] {
            name = name.replacingOccurrences(of: forbidden, with: " ")
        }
        while name.contains("  ") { name = name.replacingOccurrences(of: "  ", with: " ") }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Возврат к началу списка: без него верхние строки не попадают в дерево элементов.
    private func scrollToTop(_ app: XCUIApplication) {
        let header = app.staticTexts["Мои заметки"]
        var attempts = 0
        while !header.exists, attempts < 8 {
            app.swipeDown()
            attempts += 1
        }
    }

    private func scroll(to element: XCUIElement, in app: XCUIApplication) {
        let composer = app.textFields.firstMatch
        guard composer.exists else { return }
        var attempts = 0
        while element.frame.maxY > composer.frame.minY - 8, attempts < 10 {
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

    /// Сервер поднимается на хосте; симулятор ходит в его сеть, поэтому 127.0.0.1 — это Mac.
    private static func mockIsRunning() -> Bool {
        guard let url = URL(string: "\(baseURL)/models") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        var alive = false
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            alive = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return alive
    }
}
