import XCTest

/// Запускается с design/qa/mock-gateway.py; данные — только синтетический посев.
@MainActor
final class GatewayUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-gatewayBaseURL", "http://127.0.0.1:18891/gateway", "-annotationSource", "local", "--forget-attachments"]
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
            .matching(NSPredicate(format: "label CONTAINS %@", "Сегодня обсуждали выпуск Лори")).firstMatch
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
        let task = app.staticTexts["• Анна проверит качество завтра."]
        let questions = app.descendants(matching: .any)["reportMarkdown"].staticTexts["Открытые вопросы"]
        XCTAssertTrue(task.exists, "Markdown-маркер списка превращается в типографскую точку")
        XCTAssertFalse(app.staticTexts["- Анна проверит качество завтра."].exists)
        XCTAssertLessThan(task.frame.maxY, questions.frame.minY, "разделы отчёта не перекрываются")
        XCTAssertTrue(app.buttons["reportShare"].exists)
        save("gateway-report-sheet")
        app.buttons["reportShare"].tap()
        XCTAssertTrue(app.buttons["PDF"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Markdown (.md)"].exists)
    }

    private func save(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
