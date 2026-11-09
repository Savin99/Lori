import XCTest

/// Запускается с design/qa/mock-gateway.py; данные — только синтетический посев.
@MainActor
final class GatewayUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(address: String = "http://127.0.0.1:18891/gateway", initialEngine: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-gatewayBaseURL", address, "-annotationSource", "local", "--forget-attachments"]
        if let initialEngine { app.launchArguments += ["-transcriptionEngine", initialEngine] }
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
        let card = app.descendants(matching: .any).matching(identifier: "recordingCard")
            .matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Сегодня обсуждали выпуск Лори", "Проверка подписки Gemini")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8), "нужен посев seed-gateway.py")
        card.tap()
        let summary = app.buttons["makeRecordingSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        summary.tap()
        let brief = app.staticTexts["Анна проверит качество записи завтра."]
        XCTAssertTrue(brief.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Решения"].exists, "пустой раздел скрыт")
        app.scrollViews.firstMatch.swipeDown()
        save("gateway-recording-summary")
        app.buttons["transcriptMenu"].tap()
        let report = app.buttons["Отчёт"]
        XCTAssertTrue(report.waitForExistence(timeout: 5))
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
        let card = app.descendants(matching: .any).matching(identifier: "recordingCard")
            .matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Сегодня обсуждали выпуск Лори", "Проверка подписки Gemini")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.tap()
        app.buttons["transcriptMenu"].tap()
        app.buttons["Расшифровать заново"].tap()
        let engine = app.buttons["Gemini (подписка)"]
        XCTAssertTrue(engine.waitForExistence(timeout: 5))
        engine.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "может пересказывать и пропускать")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Расшифровать заново"].tap()
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

    private func save(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
