import XCTest

/// Запускается с design/qa/mock-gateway.py; данные — только синтетический посев.
@MainActor
final class GatewayUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false; XCUIDevice.shared.appearance = .light }

    private func launch(address: String = "http://127.0.0.1:18891/gateway", initialEngine: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-gatewayBaseURL", address, "-annotationSource", "local", "--forget-attachments"]
        if let initialEngine { app.launchArguments += ["-transcriptionEngine", initialEngine] }
        app.launchArguments += ["-geminiSubscriptionPartMinutes", "5"]
        app.launch()
        return app
    }

    private func configure(_ app: XCUIApplication) {
        app.buttons["Настройки"].tap()
        let link = app.buttons["settingsGateway"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        let token = app.secureTextFields["gatewayToken"]
        XCTAssertTrue(token.waitForExistence(timeout: 5))
        token.tap()
        token.typeText("fixture-gateway")
        XCTAssertEqual((token.value as? String)?.count, 15, "ввод токена не обрывается при обновлении формы")
        let save = app.buttons["gatewaySaveToken"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.tap()
        XCTAssertTrue(app.staticTexts["Токен сохранён"].waitForExistence(timeout: 3))
        // Поле после сохранения пустое: ключ не появляется в интерфейсе вновь.
        XCTAssertFalse((token.value as? String ?? "").contains("fixture-gateway"))
    }

    func testConnection() {
        let app = launch()
        configure(app)
        app.buttons["gatewayCheck"].tap()
        let status = app.staticTexts["gatewayStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("Подключение работает · неделя 96%, 5 часов 98%"))
        save("gateway-connection")
    }

    func testSummaryAndReport() {
        let app = launch()
        configure(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Готово"].tap()
        openSummaryRecord(app)
        let summary = app.buttons["makeRecordingSummary"]
        reveal(summary, in: app)
        summary.tap()
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["makeRecordingSummary"].exists && app.buttons["makeRecordingSummary"].isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 15), .completed)
        XCTAssertTrue(app.staticTexts["Проверка подписки Gemini"].waitForExistence(timeout: 5), "тот же annotate даёт и заголовок")
        XCTAssertTrue(app.buttons["summaryTask.0"].exists)
        XCTAssertFalse(app.staticTexts["Итог устарел: текст расшифровки изменился."].exists)
        let brief = app.staticTexts["Анна проверит качество записи завтра."]
        XCTAssertTrue(brief.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Решения"].exists, "пустой раздел скрыт")
        app.scrollViews.firstMatch.swipeDown()
        save("gateway-recording-summary")
        let report = app.buttons["noteReport"]
        reveal(report, in: app)
        report.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reportMarkdown"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Обсудили выпуск Лори."].exists)
        // Повторный прогон открывает прежний файл: просим новый отчёт у заглушки.
        app.buttons["reportShare"].tap()
        app.buttons["Сделать заново"].tap()
        XCTAssertTrue(app.staticTexts["1. Записать проверку."].waitForExistence(timeout: 15))
        let task = app.staticTexts["• Анна проверит качество завтра."]
        let questions = app.descendants(matching: .any)["reportMarkdown"].staticTexts["Открытые вопросы"]
        XCTAssertTrue(task.exists, "Markdown-маркер списка превращается в типографскую точку")
        XCTAssertFalse(app.staticTexts["- Анна проверит качество завтра."].exists)
        let ordered = app.staticTexts["1. Записать проверку."]
        let nested = app.staticTexts["• Сохранить образец."]
        XCTAssertTrue(ordered.exists)
        XCTAssertTrue(nested.exists)
        XCTAssertGreaterThan(ordered.frame.minX, task.frame.minX, "нумерованный пункт вложен")
        XCTAssertGreaterThan(nested.frame.minX, ordered.frame.minX, "маркированный пункт вложен ещё глубже")
        XCTAssertLessThan(task.frame.maxY, questions.frame.minY, "разделы отчёта не перекрываются")
        XCTAssertTrue(app.buttons["reportShare"].exists)
        save("gateway-report-sheet")
        app.buttons["reportShare"].tap()
        XCTAssertTrue(app.buttons["PDF"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Markdown (.md)"].exists)
    }

    func testSubscriptionEngineRequiresConfiguredGatewayInQuickPicker() {
        let app = launch(address: "", initialEngine: "apple")
        app.buttons["engineChip"].tap()
        XCTAssertTrue(app.buttons["engineSettingsLink"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["engineRow.gemini-subscription"].exists, "без адреса движок не готов и скрыт из быстрого выбора")
        app.buttons["engineSettingsLink"].tap()
        let unavailable = app.buttons["engineRow.gemini-subscription"]
        for _ in 0..<5 where !unavailable.isHittable { app.swipeUp() }
        XCTAssertTrue(unavailable.exists, "полный список настроек всегда содержит движок")
        XCTAssertTrue(unavailable.label.contains("Настрой подписку"))
        app.terminate()

        let configured = launch()
        configure(configured)
        configured.navigationBars.buttons.element(boundBy: 0).tap()
        configured.buttons["Готово"].tap()
        configured.buttons["engineChip"].tap()
        let ready = configured.buttons["engineRow.gemini-subscription"]
        XCTAssertTrue(ready.waitForExistence(timeout: 5))
        if !ready.isHittable { configured.swipeUp() }
        XCTAssertFalse(ready.label.contains("Настрой подписку"))
        ready.tap()
        XCTAssertTrue(configured.buttons["engineChip"].label.contains("Gemini (подписка)"))
        configured.buttons["modeChip"].tap()
        XCTAssertTrue(configured.buttons["Дословно"].waitForExistence(timeout: 5))
        configured.buttons["С говорящими"].tap()
        XCTAssertTrue(configured.buttons["modeChip"].label.contains("С говорящими"))
        save("gateway-subscription-engine")
    }

    func testSubscriptionTranscriptionUsesChunkTimeAndEngineName() {
        let app = launch(initialEngine: "gemini-subscription")
        configure(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Готово"].tap()
        openSummaryRecord(app)
        app.buttons["transcriptMenu"].tap()
        app.buttons["Расшифровать заново"].tap()
        let engine = app.buttons["Gemini (подписка)"]
        XCTAssertTrue(engine.waitForExistence(timeout: 5))
        engine.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "может пересказывать и пропускать")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Расшифровать заново"].tap()
        let toggle = app.buttons["toggleTranscript"]
        if toggle.waitForExistence(timeout: 3) {
            reveal(toggle, in: app)
            if toggle.value as? String == "Свёрнуто" { toggle.tap() }
        }
        // Вся запись короче одной части. Время 09:59 из fixture не становится перемоткой.
        app.scrollViews.firstMatch.swipeUp()
        let chunk = app.buttons.matching(identifier: "lineTime").matching(NSPredicate(format: "label == %@", "Примерно 0:00")).firstMatch
        XCTAssertTrue(chunk.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["9:59"].exists)
        app.scrollViews.firstMatch.swipeDown()
        app.buttons["transcriptMenu"].tap()
        let provenance = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Расшифровано в облаке: Gemini (подписка)")).firstMatch
        XCTAssertTrue(provenance.waitForExistence(timeout: 5))
        save("gateway-subscription-transcript-menu")
    }

    func testNoteTaskPersistsAndTranscriptExpandsInPlace() {
        let app = launch()
        configure(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Готово"].tap()
        openSummaryRecord(app)
        let refresh = app.buttons["makeRecordingSummary"]
        reveal(refresh, in: app)
        refresh.tap()
        let task = app.buttons["summaryTask.0"]
        let annotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            refresh.exists && refresh.isEnabled && task.label.contains("Проверить качество записи — Анна, завтра")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [annotated], timeout: 20), .completed)
        reveal(task, in: app)
        XCTAssertTrue(task.label.contains("Проверить качество записи — Анна, завтра"))
        if task.value as? String == "Выполнено" { task.tap() }
        XCTAssertEqual(task.value as? String, "Не выполнено")
        task.tap()
        XCTAssertEqual(task.value as? String, "Выполнено")
        saveBoth("note-task-completed")
        app.terminate()
        let reloaded = launch()
        openSummaryRecord(reloaded)
        let restored = reloaded.buttons["summaryTask.0"]
        reveal(restored, in: reloaded)
        XCTAssertEqual(restored.value as? String, "Выполнено")
        let toggle = reloaded.buttons["toggleTranscript"]
        reveal(toggle, in: reloaded)
        XCTAssertEqual(toggle.value as? String, "Свёрнуто")
        XCTAssertFalse(reloaded.descendants(matching: .any)["transcriptLines"].exists)
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "Развёрнуто")
        reloaded.swipeUp()
        XCTAssertTrue(reloaded.descendants(matching: .any)["transcriptLines"].waitForExistence(timeout: 5))
        save("note-transcript-expanded-light")
        reveal(toggle, in: reloaded, down: true)
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "Свёрнуто")
        reloaded.swipeDown()
        saveBoth("note")
    }

    func testSlowPartFailureAndRetryOnlyMissingPart() {
        let app = launch(address: "http://127.0.0.1:18892/gateway", initialEngine: "gemini-subscription")
        configure(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Готово"].tap()
        let card = app.descendants(matching: .any).matching(identifier: "recordingCard")
            .matching(NSPredicate(format: "label CONTAINS '11:59' OR label CONTAINS '12:00'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8), "нужен seed-note-progress.py")
        card.tap()
        app.buttons["transcriptMenu"].tap()
        app.buttons["Расшифровать заново"].tap()
        app.buttons["Gemini (подписка)"].tap()
        app.buttons["Расшифровать заново"].tap()
        let slow = app.staticTexts["Слушает часть 2 из 3"]
        XCTAssertTrue(slow.waitForExistence(timeout: 40))
        XCTAssertTrue(app.descendants(matching: .any)["partsProgress"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Расшифровываю · 50%")).firstMatch.exists)
        saveBoth("progress-slow-record")
        app.buttons["Записи"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["composerPartsProgress"].waitForExistence(timeout: 5))
        save("progress-home-queue-light")
        card.tap()
        let retry = app.buttons["retryPart.1"]
        XCTAssertTrue(retry.waitForExistence(timeout: 45))
        XCTAssertTrue(app.staticTexts["Готово, кроме части 2"].exists)
        saveBoth("progress-failed")
        retry.tap()
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !app.descendants(matching: .any)["partsProgress"].exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 30), .completed)
        XCTAssertFalse(app.staticTexts["Готово, кроме части 2"].exists)
        XCTAssertFalse(app.buttons["retryPart.0"].exists)
        save("progress-retried-light")
    }

    private func openSummaryRecord(_ app: XCUIApplication) {
        let named = app.descendants(matching: .any).matching(identifier: "recordingCard")
            .matching(NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS '11:59' AND NOT label CONTAINS '12:00'", "Проверка подписки Gemini")).firstMatch
        let durationReady = app.descendants(matching: .any).matching(identifier: "recordingCard")
            .matching(NSPredicate(format: "label CONTAINS '11:59' OR label CONTAINS '12:00'")).firstMatch
        _ = durationReady.waitForExistence(timeout: 5)
        if named.waitForExistence(timeout: 3) { named.tap(); return }
        let card = app.descendants(matching: .any).matching(identifier: "recordingCard")
            .matching(NSPredicate(format: "(label CONTAINS %@ OR label CONTAINS %@) AND NOT label CONTAINS '12:00' AND NOT label CONTAINS '11:59'", "Сегодня обсуждали выпуск Лори", "Проверка подписки Gemini")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, down: Bool = false) {
        for _ in 0..<7 {
            if element.exists && element.isHittable { return }
            if down { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.exists && element.isHittable, "элемент должен быть доступен после прокрутки: \(element)")
    }

    private func saveBoth(_ name: String) {
        save(name + "-light")
        XCUIDevice.shared.appearance = .dark
        Thread.sleep(forTimeInterval: 1)
        save(name + "-dark")
        XCUIDevice.shared.appearance = .light
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func save(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
