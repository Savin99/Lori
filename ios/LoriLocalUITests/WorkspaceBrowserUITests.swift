import XCTest

/// Браузер папки. Раньше это был системный `List` с разделителями и заголовком 17pt
/// в навигационной панели — он выпадал из кремового языка главной.
@MainActor
final class WorkspaceBrowserUITests: XCTestCase {
    func testFolderOpensAsCardListWithHeroHeader() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Transcripts")).firstMatch
        try XCTSkipUnless(folder.waitForExistence(timeout: 5), "в рабочей папке нет Transcripts")
        folder.tap()

        let ask = app.buttons["Спросить про папку"]
        XCTAssertTrue(ask.waitForExistence(timeout: 5), "браузер папки должен открыться")
        XCTAssertTrue(
            app.staticTexts["Transcripts"].exists,
            "открыться должна выбранная папка, а не корень рабочей папки"
        )
        save(XCUIScreen.main.screenshot(), named: "browser")

        // Из вложенной папки первая кнопка — «Назад» к корню, и только там «Готово».
        app.buttons["Назад"].tap()
        let done = app.buttons["Готово"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "из корня браузер закрывается «Готово»")

        save(XCUIScreen.main.screenshot(), named: "browser-root")

        done.tap()
        XCTAssertTrue(ask.waitForNonExistence(timeout: 5))
    }

    /// Настройки — второй лист, который вешается на `ContentView`, а не на список.
    /// Он падал ровно там же, где браузер: плашка записи не находила рекордера в окружении.
    func testSettingsOpenAndClose() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        app.buttons["Настройки"].tap()
        XCTAssertTrue(app.staticTexts["Рабочая папка"].waitForExistence(timeout: 5), "настройки должны открыться")
        save(XCUIScreen.main.screenshot(), named: "settings")
        app.buttons["Готово"].tap()
        XCTAssertTrue(app.buttons["Настройки"].waitForExistence(timeout: 5))
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
