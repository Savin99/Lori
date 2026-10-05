import XCTest
@testable import LoriLocal

/// Настройки ассистента живут в `UserDefaults.standard`, поэтому тест сам их и
/// убирает: иначе адрес протёк бы в соседний тест.
final class AssistantSettingsTests: XCTestCase {
    private let keys = [AssistantSettings.baseURLKey, AssistantSettings.modelKey]

    override func setUp() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    func testDefaultsPointAtOpenAI() {
        XCTAssertEqual(AssistantSettings.baseURL.absoluteString, AssistantSettings.defaultBaseURL)
        XCTAssertEqual(AssistantSettings.chatCompletionsURL.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(AssistantSettings.modelsURL.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(AssistantSettings.model, ModelCatalog.chatSuggestions[0].id)
    }

    /// Совместимый сервис — обычная настройка: DeepSeek отвечает по тому же пути.
    func testCustomBaseURLIsUsedForBothEndpoints() {
        UserDefaults.standard.set("https://api.deepseek.com/v1/", forKey: AssistantSettings.baseURLKey)
        XCTAssertEqual(AssistantSettings.chatCompletionsURL.absoluteString, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(AssistantSettings.modelsURL.absoluteString, "https://api.deepseek.com/v1/models")
    }

    func testBrokenAddressFallsBackToDefault() {
        for junk in ["", "   ", "мусор", "ftp://example.com", "https://"] {
            UserDefaults.standard.set(junk, forKey: AssistantSettings.baseURLKey)
            XCTAssertEqual(
                AssistantSettings.baseURL.absoluteString,
                AssistantSettings.defaultBaseURL,
                "адрес «\(junk)» не должен приниматься"
            )
        }
    }

    func testModelIsTrimmedAndFallsBack() {
        UserDefaults.standard.set("   ", forKey: AssistantSettings.modelKey)
        XCTAssertEqual(AssistantSettings.model, AssistantSettings.defaultModel, "пробелы — это не имя модели")
        UserDefaults.standard.set(" deepseek-chat ", forKey: AssistantSettings.modelKey)
        XCTAssertEqual(AssistantSettings.model, "deepseek-chat")
    }

    /// Ключ ассистента отдельный: он не должен затирать ключ расшифровки.
    func testAssistantHasItsOwnKeychainAccount() {
        XCTAssertEqual(KeychainAccount.assistant.rawValue, "assistant-api-key")
        XCTAssertEqual(KeychainAccount.assistant.title, "Ассистент")
        XCTAssertEqual(
            Set(KeychainAccount.allCases.map(\.rawValue)).count,
            KeychainAccount.allCases.count,
            "аккаунты Keychain не должны совпадать"
        )
        XCTAssertEqual(
            TranscriptionError.missingKey(.assistant).errorDescription,
            "Ключ Ассистент не сохранён. Настройки → «Ассистент» → вставь ключ."
        )
    }

    /// Фильтр чат-моделей чёрным списком: распознаватели и эмбеддинги в выбор
    /// не попадают, а незнакомое имя — попадает.
    func testChatModelsDropWhatCannotAnswer() {
        let listed = ModelCatalog.chatModels([
            "gpt-5.1", "text-embedding-3-large", "whisper-1", "gpt-transcribe",
            "tts-1", "dall-e-3", "omni-moderation-latest", "deepseek-chat",
            "gpt-realtime", "какая-то-новая-модель",
        ]).map(\.id)

        XCTAssertEqual(listed, ["deepseek-chat", "gpt-5.1", "какая-то-новая-модель"])
    }

    /// Тексты для человека пишутся одной строкой: склейка многострочных
    /// литералов уже протаскивала в интерфейс дорожку пробелов.
    func testHumanTextsHaveNoStrayWhitespace() {
        var texts = [AssistantSettings.describedTarget, AssistantProviderScreen.help]
        texts += [AssistantError.noSources, .emptyQuestion, .emptyAnswer].compactMap(\.errorDescription)
        texts.append(AssistantService.instructions)
        for text in texts {
            XCTAssertFalse(text.contains("  "), "лишние пробелы: \(text)")
            XCTAssertFalse(text.contains(" \n"), "пробел перед переводом строки: \(text)")
        }
    }
}
