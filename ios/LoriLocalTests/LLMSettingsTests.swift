import XCTest
@testable import LoriLocal

/// Настройки провайдера живут в `UserDefaults`, поэтому тест обязан убирать за собой:
/// хост тестов — само приложение, и мусор остался бы в его настройках.
final class LLMSettingsTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: LLMSettings.baseURLKey)
        UserDefaults.standard.removeObject(forKey: LLMSettings.customModelKey)
        super.tearDown()
    }

    func testEmptySettingsMeanDeepSeek() {
        XCTAssertFalse(LLMSettings.isCustom)
        XCTAssertEqual(LLMSettings.baseURL.absoluteString, LLMSettings.defaultBaseURL)
        XCTAssertEqual(LLMSettings.chatCompletionsURL.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(LLMSettings.resolvedModel(picked: "deepseek-v4-flash"), "deepseek-v4-flash")
    }

    func testLocalProviderWithTrailingSlashAndPath() {
        UserDefaults.standard.set("http://192.168.1.10:1234/v1/", forKey: LLMSettings.baseURLKey)
        UserDefaults.standard.set("qwen3-32b", forKey: LLMSettings.customModelKey)

        XCTAssertTrue(LLMSettings.isCustom)
        XCTAssertEqual(
            LLMSettings.chatCompletionsURL.absoluteString,
            "http://192.168.1.10:1234/v1/chat/completions"
        )
        XCTAssertEqual(LLMSettings.resolvedModel(picked: "deepseek-v4-flash"), "qwen3-32b")
        XCTAssertEqual(LLMSettings.describedTarget, "192.168.1.10 · qwen3-32b")
    }

    func testGarbageAddressFallsBackToDeepSeek() {
        for garbage in ["мой сервер", "ftp://1.2.3.4", "localhost:1234", " "] {
            UserDefaults.standard.set(garbage, forKey: LLMSettings.baseURLKey)
            XCTAssertFalse(LLMSettings.isCustom, "адрес «\(garbage)» не должен считаться рабочим")
            XCTAssertEqual(LLMSettings.baseURL.absoluteString, LLMSettings.defaultBaseURL)
        }
    }

    func testAddressWithoutModelKeepsPickedModel() {
        UserDefaults.standard.set("https://api.example.com/v1", forKey: LLMSettings.baseURLKey)

        XCTAssertTrue(LLMSettings.isCustom)
        // Адрес указан, имя модели — нет: подставлять пустую строку нельзя,
        // остаётся выбранная в настройках.
        XCTAssertEqual(LLMSettings.resolvedModel(picked: "deepseek-v4-pro"), "deepseek-v4-pro")
        XCTAssertEqual(LLMSettings.describedTarget, "api.example.com")
    }
}
