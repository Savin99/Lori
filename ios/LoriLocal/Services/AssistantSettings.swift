import Foundation

/// Настройки ассистента по расшифровкам: адрес совместимого сервиса и модель.
///
/// Отдельно от `TranscriptionSettings` намеренно. Расшифровка и вопросы к архиву —
/// разные задачи и часто разные сервисы: расшифровывать удобнее у OpenAI или на
/// самом телефоне, а отвечать дешевле у DeepSeek. Ключ здесь тоже свой,
/// см. `KeychainAccount.assistant`.
enum AssistantSettings {
    static let baseURLKey = "assistantBaseURL"
    static let modelKey = "assistantModel"

    /// Совместимый по форме `POST /chat/completions` сервис. По умолчанию OpenAI,
    /// но адрес — обычная настройка: тот же протокол понимают DeepSeek, Groq и
    /// прокси в поддерживаемом регионе.
    static let defaultBaseURL = "https://api.openai.com/v1"

    /// Порог «охват влезает целиком». Считается в знаках, а не в токенах:
    /// токенизатора на телефоне нет, а для русского текста знак к токену идёт
    /// примерно четыре к одному. 120 тысяч — это около тридцати тысяч токенов:
    /// столько отдаётся один раз и дальше берётся из кэша, а помещается в них
    /// архив из десятков расшифровок целиком.
    ///
    /// Пока охват влезает, отбирать нечего, и лучший отбор здесь — тот, который
    /// не запускался: он режет разговор на куски и теряет связь между ними.
    static let contextCharacters = 120_000

    /// Потолок на весь разговор: сколько текста расшифровок тред вправе набрать.
    /// Упор в него — не повод молча обрезать, а повод сказать об этом.
    static let threadCharacters = 200_000

    /// Сколько знаков отводится оглавлению. Оно идёт в контекст всегда, в том
    /// числе когда сами тексты не поместились: без него «в записях этого нет» —
    /// не вывод из архива, а следствие незнания о нём.
    static let outlineCharacters = 8_000

    /// Готовые адреса, чтобы не вспоминать их по памяти. Это подсказка для поля,
    /// а не скрытое переключение: адрес всегда виден целиком.
    struct Preset: Identifiable, Sendable, Equatable {
        let title: String
        let baseURL: String

        var id: String { baseURL }
    }

    static let presets: [Preset] = [
        Preset(title: "OpenAI", baseURL: defaultBaseURL),
        Preset(title: "DeepSeek", baseURL: "https://api.deepseek.com/v1"),
    ]

    /// Проверка адреса та же, что у расшифровки: только http и https, только с
    /// хостом. `URL(string:)` принимает почти любую строку, и без проверки
    /// запрос уходил бы в никуда.
    static var baseURL: URL {
        TranscriptionSettings.url(from: UserDefaults.standard.string(forKey: baseURLKey) ?? "")
            ?? URL(string: defaultBaseURL)!
    }

    /// Модель по умолчанию — первая из подсказок: список приложение всё равно
    /// забирает у самого сервиса, как только ключ сохранён.
    static var model: String {
        let stored = (UserDefaults.standard.string(forKey: modelKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? defaultModel : stored
    }

    static var defaultModel: String {
        ModelCatalog.chatSuggestions.first?.id ?? "gpt-5.1"
    }

    static var chatCompletionsURL: URL { baseURL.appending(path: "chat/completions") }
    static var modelsURL: URL { baseURL.appending(path: "models") }

    static var hasKey: Bool { KeychainStore.hasKey(for: .assistant) }

    /// Куда уходит вопрос — строка для настроек и для предупреждения о приватности.
    static var describedTarget: String {
        "\(baseURL.host() ?? "сервис") · \(model)"
    }
}
