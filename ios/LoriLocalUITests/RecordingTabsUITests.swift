import XCTest

/// Только синтетические записи seed-glass-tabs.py и HTTP-заглушка на localhost.
@MainActor
final class RecordingTabsUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }
    override func tearDown() async throws { XCUIDevice.shared.appearance = .light }

    private func launch(configured: Bool = true, category: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-gatewayBaseURL", configured ? "http://127.0.0.1:18891/gateway" : "",
                               "-annotationSource", "local", "--forget-attachments"]
        if let category { app.launchArguments += ["-UIPreferredContentSizeCategoryName", category] }
        app.launch()
        return app
    }

    private func open(_ name: String, in app: XCUIApplication) {
        let predicate = name == "Glass Empty QA"
            ? NSPredicate(format: "label CONTAINS 'Без расшифровки' AND (label CONTAINS '0:52' OR label CONTAINS '0:53')")
            : NSPredicate(format: "label CONTAINS %@ OR (label CONTAINS 'Проверка подписки Gemini' AND (label CONTAINS '1:00' OR label CONTAINS '0:59'))", name)
        let card = app.descendants(matching: .any).matching(identifier: "recordingCard")
            .matching(predicate).firstMatch
        for _ in 0..<8 {
            if card.exists && card.frame.maxY < app.buttons["recordButton"].frame.minY - 8 { break }
            app.swipeUp()
        }
        XCTAssertTrue(card.exists, "нужен seed-glass-tabs.py: \(name)")
        card.tap()
        XCTAssertTrue(app.buttons["recordingTab.transcript"].waitForExistence(timeout: 5))
    }

    private func select(_ tab: String, in app: XCUIApplication) {
        let button = app.buttons["recordingTab." + tab]
        for _ in 0..<6 where !button.isHittable { app.swipeDown() }
        button.tap()
        XCTAssertEqual(button.value as? String, "Выбрана")
        XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        XCTAssertTrue(app.descendants(matching: .any)["floatingPlayer"].exists)
    }

    private func configure(_ app: XCUIApplication) {
        app.buttons["Настройки"].tap()
        app.buttons["settingsGateway"].tap()
        let token = app.secureTextFields["gatewayToken"]
        XCTAssertTrue(token.waitForExistence(timeout: 5))
        token.tap(); token.typeText("fixture-gateway")
        app.buttons["gatewaySaveToken"].tap()
        XCTAssertTrue(app.staticTexts["Токен сохранён"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Готово"].tap()
    }

    func testTabsTaskPlaybackAndBothAppearances() {
        let app = launch()
        configure(app)
        open("Три вкладки", in: app)
        select("summary", in: app)
        if app.staticTexts["summaryEmpty"].exists { app.buttons["makeRecordingSummary"].tap() }
        let task = app.buttons["summaryTask.0"]
        XCTAssertTrue(task.waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)["recordDescription"].exists)
        if task.value as? String == "Выполнено" { task.tap() }
        task.tap()
        XCTAssertEqual(task.value as? String, "Выполнено")
        saveBoth("summary", app: app)
        select("report", in: app)
        if app.buttons["makeReport"].exists { app.buttons["makeReport"].tap() }
        XCTAssertTrue(app.descendants(matching: .any)["reportMarkdown"].waitForExistence(timeout: 20))
        XCTAssertFalse(task.exists)
        XCTAssertFalse(app.buttons["lineTime"].exists)
        XCTAssertTrue(app.buttons["refreshReport"].exists)
        saveBoth("report", app: app)
        app.buttons["reportShare"].tap()
        XCTAssertTrue(app.buttons["PDF"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Markdown (.md)"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7)).tap()
        select("transcript", in: app)
        XCTAssertTrue(app.staticTexts["Последняя реплика должна оставаться выше плеера."].exists)
        XCTAssertFalse(task.exists)
        XCTAssertFalse(app.descendants(matching: .any)["reportMarkdown"].exists)
        let time = app.buttons.matching(identifier: "lineTime").element(boundBy: 1)
        XCTAssertEqual(time.label, "0:30")
        time.tap()
        XCTAssertTrue(app.buttons["Пауза"].waitForExistence(timeout: 3))
        app.buttons["Пауза"].tap()
        let position = app.sliders["Позиция в записи"].value as? String ?? ""
        XCTAssertTrue(position.hasPrefix("0:3"), "таймкод перематывает общий плеер: \(position)")
        let last = app.staticTexts["Последняя реплика должна оставаться выше плеера."]
        app.swipeUp()
        XCTAssertLessThan(last.frame.maxY, app.descendants(matching: .any)["floatingPlayer"].frame.minY)
        app.swipeDown()
        saveBoth("transcript", app: app)
        select("summary", in: app)
        XCTAssertEqual(task.value as? String, "Выполнено")
        app.buttons["Записи"].tap()
        open("Три вкладки", in: app)
        XCTAssertEqual(app.buttons["recordingTab.summary"].value as? String, "Выбрана", "с итогом стартует Итог")
    }

    func testEmptyTabsWithAndWithoutGateway() {
        for configured in [false, true] {
            let app = launch(configured: configured)
            if configured { configure(app) }
            open("Glass Empty QA", in: app)
            XCTAssertEqual(app.buttons["recordingTab.transcript"].value as? String, "Выбрана", "без итога стартует Расшифровка")
            XCTAssertTrue(app.buttons["transcribeAction"].exists)
            select("summary", in: app)
            XCTAssertTrue(app.staticTexts["summaryEmpty"].exists)
            if configured {
                XCTAssertTrue(app.buttons["makeRecordingSummary"].exists)
                XCTAssertFalse(app.buttons["makeRecordingSummary"].isEnabled, "сначала нужен текст")
            } else {
                XCTAssertTrue(app.staticTexts["recordingGatewayDirections"].exists)
                XCTAssertFalse(app.buttons["makeRecordingSummary"].exists)
            }
            select("report", in: app)
            XCTAssertTrue(app.staticTexts["reportEmpty"].exists)
            if configured { XCTAssertFalse(app.buttons["makeReport"].isEnabled) }
            else { XCTAssertTrue(app.staticTexts["recordingGatewayDirections"].exists) }
            save(configured ? "empty-configured" : "empty-no-gateway")
            app.terminate()
        }
    }

    func testLargeTextTabsAndPlayer() {
        for (category, shot) in [
            ("UICTContentSizeCategoryXXXL", "transcript-extra-large-text-light"),
            ("UICTContentSizeCategoryAccessibilityL", "transcript-large-text-light")
        ] {
            let app = launch(category: category)
            open("Три вкладки", in: app)
            select("transcript", in: app)
            XCTAssertTrue(app.buttons["Скорость воспроизведения"].isHittable)
            XCTAssertTrue(app.sliders["Позиция в записи"].isHittable)
            for tab in ["summary", "report", "transcript"] {
                XCTAssertGreaterThanOrEqual(app.buttons["recordingTab." + tab].frame.height, 44)
                XCTAssertLessThanOrEqual(app.buttons["recordingTab." + tab].frame.maxX, app.frame.width)
            }
            save(shot)
            if category == "UICTContentSizeCategoryAccessibilityL" {
                let last = app.scrollViews["recordingScroll"].staticTexts["Последняя реплика должна оставаться выше плеера."]
                let player = app.descendants(matching: .any)["floatingPlayer"]
                for _ in 0..<5 {
                    if last.exists && last.frame.maxY < player.frame.minY { break }
                    app.scrollViews["recordingScroll"].swipeUp()
                }
                XCTAssertTrue(last.isHittable)
                XCTAssertLessThan(last.frame.maxY, player.frame.minY, "конец текста выходит из-под капсулы и на крупном шрифте")
                save("transcript-large-text-scrolled-light")
            }
            app.terminate()
        }
    }

    private func saveBoth(_ name: String, app: XCUIApplication) {
        for dark in [false, true] {
            XCUIDevice.shared.appearance = dark ? .dark : .light
            Thread.sleep(forTimeInterval: 1)
            save(name + (dark ? "-dark" : "-light"))
            let player = XCTAttachment(screenshot: app.descendants(matching: .any)["floatingPlayer"].screenshot())
            player.name = "player-" + name + (dark ? "-dark" : "-light")
            player.lifetime = .keepAlways
            add(player)
        }
        XCUIDevice.shared.appearance = .light
    }
    private func save(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
