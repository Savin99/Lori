import XCTest

/// Запись в фоне, островок и экран блокировки — на микрофоне-заглушке Lori QA.
///
/// У симулятора нет звукового входа (`AVAudioRecorder.record()` отвечает «нет»), поэтому
/// тест запускает Lori QA с `--ui-stub-recorder`: заглушка пишет настоящий m4a тихим
/// тоном ровно той длины, что «записано», а всё остальное — куски, пауза, склейка,
/// Live Activity — настоящее. Расшифровка выключена (`-autoTranscribe NO`): движка в
/// симуляторе нет, и проверяется именно запись.
@MainActor
final class RecordingUITests: XCTestCase {
    /// Запись → пауза → продолжить → стоп: в списке одна новая запись, без кусков.
    func testStubRecordingPausesResumesAndSavesOneRecord() throws {
        continueAfterFailure = false
        let app = launch()
        let firstBefore = cards(in: app).firstMatch.waitForExistence(timeout: 3)
            ? cards(in: app).firstMatch.label : ""

        tap(app.buttons["recordButton"])
        let pause = app.buttons["Поставить на паузу"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "запись началась на заглушке")
        sleep(2)
        pause.tap()
        let resume = app.buttons["Продолжить запись"]
        XCTAssertTrue(resume.waitForExistence(timeout: 3))
        save("app-paused")
        resume.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
        sleep(1)
        tap(app.buttons["stopButton"])

        XCTAssertTrue(app.buttons["recordButton"].waitForExistence(timeout: 10), "панель вернулась в покой")
        let first = cards(in: app).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let deadline = Date().addingTimeInterval(5)
        while first.label == firstBefore, Date() < deadline { _ = first.waitForExistence(timeout: 0.3) }
        XCTAssertNotEqual(first.label, firstBefore, "сверху — новая запись")
        XCTAssertTrue(first.label.contains("0:0"), "длина склеенной записи — секунды, а не куски: \(first.label)")
        save("app-saved")
    }

    /// Плашка записи над открытым листом. Диктофон теперь приходит в окружение из
    /// `LoriLocalApp`, а не из `ContentView`, — лист обязан его получить, иначе плашка
    /// роняет приложение. Тот же сценарий, что `testRecordingBannerIsVisibleOverAnOpenSheet`,
    /// но на заглушке: без неё в симуляторе он пропускается.
    func testBannerOverSettingsWithStubRecorder() throws {
        continueAfterFailure = false
        let app = launch()
        tap(app.buttons["recordButton"])
        let pause = app.buttons["Поставить на паузу"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))

        app.buttons["Настройки"].tap()
        let banner = app.buttons["Идёт запись"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "над открытым листом должна висеть плашка записи")
        save("banner-over-settings")
        banner.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "плашка возвращает к панели записи")

        tap(app.buttons["Отмена"])
        XCTAssertTrue(app.buttons["recordButton"].waitForExistence(timeout: 5), "отменённая запись уходит в корзину")
    }

    /// Снимки островка и экрана блокировки в симуляторе: свёрнутый, развёрнутый,
    /// пауза кнопкой из островка, карточка в центре уведомлений.
    func testZZ4RecordingIslandScreenshots() throws {
        continueAfterFailure = false
        let app = launch()
        tap(app.buttons["recordButton"])
        XCTAssertTrue(app.buttons["Поставить на паузу"].waitForExistence(timeout: 5))
        sleep(3)

        XCUIDevice.shared.press(.home)
        sleep(2)
        save("island-compact-recording")

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.025)).press(forDuration: 1.5)
        sleep(1)
        save("island-expanded-recording")

        let pauseInIsland = springboard.buttons["Поставить запись на паузу"]
        if pauseInIsland.waitForExistence(timeout: 3) {
            pauseInIsland.tap()
            sleep(2)
            save("island-expanded-after-pause")
        }
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).tap()
        sleep(1)
        save("island-compact-after-pause")

        // Центр уведомлений показывает ту же карточку, что экран блокировки.
        let from = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.002))
        from.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.7)))
        sleep(2)
        // iOS 26 один раз спрашивает, показывать ли Live Activity на экране блокировки.
        let allow = springboard.buttons["Разрешить"]
        if allow.waitForExistence(timeout: 2) {
            save("lockscreen-permission")
            allow.tap()
            sleep(1)
        }
        save("lockscreen-light")
        XCUIDevice.shared.appearance = .dark
        sleep(2)
        save("lockscreen-dark")
        XCUIDevice.shared.appearance = .light

        // Назад в Lori и стоп: запись сохраняется, островок уходит.
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 5)
        if app.buttons["Продолжить запись"].waitForExistence(timeout: 3) || app.buttons["Поставить на паузу"].exists {
            tap(app.buttons["stopButton"])
        }
        XCTAssertTrue(app.buttons["recordButton"].waitForExistence(timeout: 10))
    }

    // MARK: - Помощники

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-stub-recorder", "--forget-attachments", "-autoTranscribe", "NO", "-titlesHintDismissed", "YES"]
        app.launch()
        return app
    }

    private func cards(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "recordingCard")
    }

    private func tap(_ element: XCUIElement, timeout: TimeInterval = 5) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "нет элемента для нажатия")
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
