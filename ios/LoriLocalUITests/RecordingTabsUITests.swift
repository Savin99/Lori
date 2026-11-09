import XCTest

/// Синтетический макет из seed-granola.py. Ни сети, ни личных записей/ключей.
@MainActor
final class RecordingTabsUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false; XCUIDevice.shared.appearance = .light }
    override func tearDown() async throws { XCUIDevice.shared.appearance = .light }

    private func launch(category: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-gatewayBaseURL", "", "-annotationSource", "local", "--forget-attachments"]
        if let category { app.launchArguments += ["-UIPreferredContentSizeCategoryName", category] }
        app.launch()
        let card = app.descendants(matching: .any).matching(identifier: "recordingCard")
            .matching(NSPredicate(format: "label CONTAINS %@", "Перенос релиза Лори")).firstMatch
        for _ in 0..<10 {
            if card.exists && card.isHittable && card.frame.maxY < app.buttons["recordButton"].frame.minY - 8 { break }
            app.swipeUp()
        }
        XCTAssertTrue(card.exists, "нужен seed-granola.py")
        card.tap()
        XCTAssertTrue(app.buttons["recordingTab.summary"].waitForExistence(timeout: 5))
        return app
    }
    private func top(_ app: XCUIApplication) {
        let tab = app.buttons["recordingTab.summary"]
        for _ in 0..<10 {
            if tab.isHittable && app.descendants(matching: .any)["recordTitle"].isHittable { break }
            app.scrollViews["recordingScroll"].swipeDown()
        }
    }
    private func select(_ name: String, _ app: XCUIApplication) {
        top(app)
        let tab = app.buttons["recordingTab." + name]
        tab.tap()
        XCTAssertEqual(tab.value as? String, "Выбрана")
        XCTAssertGreaterThanOrEqual(tab.frame.height, 44)
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        let player = app.descendants(matching: .any)["floatingPlayer"]
        for _ in 0..<12 {
            if element.exists && element.isHittable && element.frame.maxY < player.frame.minY - 4 { break }
            app.scrollViews["recordingScroll"].swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
    func testCardsTasksAndPersistentCompletion() {
        let app = launch()
        XCTAssertEqual(app.buttons["recordingTab.summary"].value as? String, "Выбрана")
        XCTAssertTrue(app.staticTexts["Суть записи"].exists)
        XCTAssertFalse(app.staticTexts["Главное"].exists)
        XCTAssertTrue(app.staticTexts["Решения"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["recordDescription"].exists)
        let task = app.buttons["summaryTask.0"]
        reveal(task, app)
        if task.value as? String == "Выполнено" { task.tap() }
        task.tap(); XCTAssertEqual(task.value as? String, "Выполнено")
        XCTAssertTrue(app.staticTexts["2 из 3 сделано"].exists)
        app.buttons["Записи"].tap()
        app.terminate()
        let reopened = launch()
        let persisted = reopened.buttons["summaryTask.0"]
        reveal(persisted, reopened)
        XCTAssertEqual(persisted.value as? String, "Выполнено")
        persisted.tap() // вернуть утверждённое состояние макета
        XCTAssertEqual(persisted.value as? String, "Не выполнено")
        let questions = reopened.staticTexts["Открытые вопросы"]
        reveal(questions, reopened)
        XCTAssertTrue(reopened.buttons["makeRecordingSummary"].exists)
        XCTAssertGreaterThanOrEqual(persisted.frame.height, 44)
    }
    func testReportAndTranscriptSeekTheSamePlayer() {
        let app = launch()
        select("report", app)
        XCTAssertTrue(app.descendants(matching: .any)["reportMarkdown"].exists)
        XCTAssertFalse(app.buttons["reportShare"].exists, "в отчёте нет второго экспорта")
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'reportTime.'")).firstMatch
        reveal(chip, app)
        XCTAssertEqual(chip.label, "Слушать с 0:42")
        chip.tap()
        XCTAssertTrue(app.buttons["Пауза"].waitForExistence(timeout: 3))
        app.buttons["Пауза"].tap()
        let reportPosition = app.sliders["Позиция в записи"].value as? String ?? ""
        XCTAssertTrue(reportPosition.hasPrefix("0:4"), "фактическая позиция после чипа: \(reportPosition)")
        select("transcript", app)
        XCTAssertFalse(app.textFields["Найти в расшифровке"].exists)
        XCTAssertEqual(app.descendants(matching: .any)["speakerShare.S1"].label, "Анна · 62%")
        XCTAssertEqual(app.descendants(matching: .any)["speakerShare.S2"].label, "Борис · 38%")
        let stamp = app.buttons.matching(identifier: "lineTime").element(boundBy: 2)
        reveal(stamp, app)
        XCTAssertEqual(stamp.label, "4:12")
        stamp.tap()
        XCTAssertTrue(app.buttons["Пауза"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["transcriptLine.playing"].exists)
        XCTAssertTrue(app.staticTexts["Анна · сейчас звучит"].exists)
        app.buttons["Скорость воспроизведения"].tap()
        XCTAssertEqual(app.buttons["Скорость воспроизведения"].value as? String, "1,5×")
        select("summary", app)
        XCTAssertTrue(app.buttons["Пауза"].exists, "выбор вкладки не останавливает звук")
        app.buttons["Пауза"].tap()
        let beforeScrub = app.sliders["Позиция в записи"].value as? String
        app.sliders["Позиция в записи"].adjust(toNormalizedSliderPosition: 0.5)
        let scrubbed = app.sliders["Позиция в записи"].value as? String ?? ""
        // XCTest двигает приблизительно: у тонкого UISlider реальная позиция
        // может отличаться от 50%. Проверяем перемотку и общий счётчик времени.
        XCTAssertNotEqual(scrubbed, beforeScrub)
        XCTAssertTrue(app.staticTexts["Прошло " + scrubbed].exists)
    }
    func testToolbarExportsAndCopiesTheOpenTab() {
        let app = launch()
        for (tab, title) in [("summary", "Итог — Перенос релиза Лори"), ("report", "Отчёт — Перенос релиза Лори"), ("transcript", "Перенос релиза Лори")] {
            select(tab, app)
            XCTAssertEqual(app.buttons.matching(identifier: "shareMenu").count, 1)
            app.buttons["copyTranscript"].tap()
            XCTAssertEqual(app.buttons["copyTranscript"].label, "Скопировано")
            for format in ["PDF", "Markdown (.md)"] {
                app.buttons["shareMenu"].tap()
                XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'PDF'")).firstMatch.waitForExistence(timeout: 5))
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", format)).firstMatch.tap()
                let filename = app.descendants(matching: .any).matching(identifier: "LP.CaptionBar.TopCaption").matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
                XCTAssertTrue(filename.waitForExistence(timeout: 10), "файл выбранной вкладки: \(title)")
                save("export-" + tab + (format == "PDF" ? "-pdf" : "-md"))
                app.buttons["header.closeButton"].tap()
                XCTAssertTrue(app.buttons["recordingTab." + tab].waitForExistence(timeout: 5))
            }
        }
    }
    func testApprovedScreenshotsInBothThemes() {
        for dark in [false, true] {
            XCUIDevice.shared.appearance = dark ? .dark : .light
            let app = launch()
            let suffix = dark ? "-dark" : "-light"
            for tab in ["summary", "report", "transcript"] {
                select(tab, app)
                if tab == "transcript" {
                    let stamp = app.buttons.matching(identifier: "lineTime").element(boundBy: 2)
                    reveal(stamp, app); stamp.tap(); top(app)
                }
                save(tab + suffix)
                let player = XCTAttachment(screenshot: app.descendants(matching: .any)["floatingPlayer"].screenshot())
                player.name = "player-" + tab + suffix; player.lifetime = .keepAlways; add(player)
                if app.buttons["Пауза"].exists { app.buttons["Пауза"].tap() }
                app.scrollViews["recordingScroll"].swipeUp()
                save(tab + "-end" + suffix)
            }
            app.terminate()
        }
    }
    func testEmptyTabsHaveNoOutgoingActions() {
        let app = XCUIApplication()
        app.launchArguments = ["-gatewayBaseURL", "", "-annotationSource", "local", "--forget-attachments"]
        app.launch()
        let card = app.descendants(matching: .any).matching(identifier: "recordingCard")
            .matching(NSPredicate(format: "label CONTAINS 'Без расшифровки' AND (label CONTAINS '0:52' OR label CONTAINS '0:53')")).firstMatch
        for _ in 0..<10 {
            if card.isHittable && card.frame.maxY < app.buttons["recordButton"].frame.minY - 8 { break }
            app.swipeUp()
        }
        XCTAssertTrue(card.exists, "нужен seed-glass-tabs.py")
        card.tap()
        XCTAssertTrue(app.buttons["recordingTab.transcript"].waitForExistence(timeout: 5))
        for tab in ["summary", "report", "transcript"] {
            select(tab, app)
            XCTAssertFalse(app.buttons["shareMenu"].exists)
            XCTAssertFalse(app.buttons["copyTranscript"].exists)
            if tab != "transcript" {
                XCTAssertTrue(app.staticTexts[tab == "summary" ? "summaryEmpty" : "reportEmpty"].exists)
                XCTAssertTrue(app.staticTexts["recordingGatewayDirections"].exists)
            } else { XCTAssertTrue(app.buttons["transcribeAction"].exists) }
            save("empty-" + tab + "-light")
        }
    }
    func testLargeTextEveryTabAndEndAbovePlayer() {
        for dark in [false, true] {
            XCUIDevice.shared.appearance = dark ? .dark : .light
            let app = launch(category: "UICTContentSizeCategoryAccessibilityL")
            for tab in ["summary", "report", "transcript"] {
                select(tab, app)
                XCTAssertTrue(app.buttons["Скорость воспроизведения"].isHittable)
                XCTAssertTrue(app.sliders["Позиция в записи"].isHittable)
                for name in ["summary", "report", "transcript"] {
                    XCTAssertGreaterThanOrEqual(app.buttons["recordingTab." + name].frame.height, 44)
                    XCTAssertLessThanOrEqual(app.buttons["recordingTab." + name].frame.maxX, app.frame.maxX)
                }
                save(tab + "-large" + (dark ? "-dark" : "-light"))
            }
            let last = app.scrollViews["recordingScroll"].staticTexts["И вопрос: нам вообще нужен отчёт в PDF, или Markdown хватит?"]
            reveal(last, app)
            XCTAssertLessThan(last.frame.maxY, app.descendants(matching: .any)["floatingPlayer"].frame.minY)
            save("transcript-large-end" + (dark ? "-dark" : "-light"))
            app.terminate()
        }
    }
    private func save(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
