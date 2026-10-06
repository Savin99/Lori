import XCTest

/// Плашки «Пропуск A–B», уже лежащие в файлах расшифровок, сверяются со звуком
/// записи: над тишиной со щелчками и кашлем плашки нет, над речью, которой нет в
/// тексте, — есть. Повод — запись владельца 43:28, где старое правило назвало
/// пропусками две минуты настоящей тишины.
///
/// Набор — `design/redesign-2026-10-05/seed-silence.py`: две записи с одинаковой
/// раскладкой «речь — минута — речь» и строкой `> Пропуск …` на эту минуту.
/// Без набора тест пропускается. Снимки — `record-silence-*.png` в той же папке.
@MainActor
final class SilentGapUITests: XCTestCase {
    /// Заголовки карточек — первые фразы расшифровок набора.
    private let silent = "Давайте начнём с отчёта по затратам"
    private let spoken = "Проверяем плашку пропуска"

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        XCUIDevice.shared.appearance = .light
    }

    func testGapStripFollowsTheSound() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-transcriptionEngine", "gigaam", "--forget-attachments"]
        app.launch()
        let strip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Пропуск"))
            .firstMatch

        // Сначала запись, где плашка настоящая: так видно, что сверка работает и
        // успевает, а не что плашек нет вообще.
        try open(spoken, in: app)
        XCTAssertTrue(strip.waitForExistence(timeout: 15), "над речью без текста плашка остаётся")
        settle()
        save("record-silence-speech-kept")
        close(app)

        try open(silent, in: app)
        XCTAssertFalse(strip.waitForExistence(timeout: 15), "над тишиной со щелчками и кашлем плашки нет")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "расходы выросли")).firstMatch.exists,
            "текст записи на месте — спрятана только плашка"
        )
        save("record-silence-hidden")
    }

    // MARK: - Помощники

    private func card(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "recordingCard")
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    /// Список ленивый: карточки ниже края экрана в дереве ещё нет, и до неё докручивают.
    private func open(_ title: String, in app: XCUIApplication) throws {
        let target = card(containing: title, in: app)
        var attempts = 0
        while !target.waitForExistence(timeout: attempts == 0 ? 8 : 1), attempts < 8 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
            attempts += 1
        }
        try XCTSkipUnless(target.exists, "нет записи «\(title)» — прогони design/redesign-2026-10-05/seed-silence.py")
        tap(target)
        XCTAssertTrue(
            app.descendants(matching: .any)["recordTitle"].waitForExistence(timeout: 5),
            "тап по карточке открывает экран записи"
        )
    }

    private func close(_ app: XCUIApplication) {
        tap(app.buttons["Записи"])
        XCTAssertTrue(app.descendants(matching: .any)["recordTitle"].waitForNonExistence(timeout: 5))
    }

    /// Лист уезжает с анимацией: у кнопки под ним точки нажатия ещё нет.
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 5) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "нет элемента для нажатия: \(element)")
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isHittable, Date() < deadline {
            _ = element.waitForExistence(timeout: 0.2)
        }
        element.tap()
    }

    private func settle() {
        Thread.sleep(forTimeInterval: 1.0)
    }

    private func save(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
