import XCTest

/// Вики: вход из шторки папок, темы и теги, страница связей.
///
/// Тесту нужен засеянный набор `design/qa/seed-digest.sh` — в нём есть обработанная
/// заметка с темой «Работа» и тегами. Без него тест пропускается.
@MainActor
final class WikiUITests: XCTestCase {
    func testWikiOpensFromFolderDrawerAndShowsThemes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        app.buttons["Открыть папки"].tap()
        let entry = app.buttons["Вики: темы и связи"]
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "в шторке папок нет входа в вики")
        entry.tap()

        XCTAssertTrue(app.staticTexts["Вики"].waitForExistence(timeout: 5), "вики не открылась")
        try XCTSkipUnless(
            app.staticTexts["Темы"].exists,
            "в рабочей папке нет тематических заметок — прогони design/qa/seed-digest.sh"
        )

        // Тема — это папка первого уровня; счётчик показывает, сколько в ней заметок.
        let theme = try row(startingWith: "Работа", in: app, "тема «Работа» не попала в вики")
        save(XCUIScreen.main.screenshot(), named: "wiki-root")

        theme.tap()
        let note = try row(startingWith: "Планёрка по найму", in: app, "в теме не видно её заметок")
        note.tap()

        // Страница заметки: путь, теги и действие. Связей у засеянной заметки нет,
        // и вики должна честно это сказать, а не показывать пустой список.
        XCTAssertTrue(app.buttons["Открыть заметку"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "#найм")).firstMatch.exists,
            "теги заметки не показаны"
        )
        save(XCUIScreen.main.screenshot(), named: "wiki-note")

        app.buttons["Открыть заметку"].tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "из вики должна открываться сама заметка")
        app.buttons["Готово"].tap()
    }

    /// Кнопку надо искать среди доступных для тапа: под открытым листом остаются
    /// элементы шторки папок с теми же названиями, и `firstMatch` цепляет их —
    /// тап тогда падает с «Failed to not hittable».
    private func row(
        startingWith prefix: String,
        in app: XCUIApplication,
        _ message: String
    ) throws -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 3), message)
        let hittable = matches.allElementsBoundByIndex.first { $0.isHittable }
        return try XCTUnwrap(hittable, message)
    }

    private func save(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
