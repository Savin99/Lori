import Foundation

/// Куда Lori обращается за моделью.
///
/// По умолчанию это DeepSeek. Владелец может указать любой сервис с таким же
/// API, как у OpenAI, — включая модель, поднятую на своём компьютере в локальной
/// сети. Тогда ни расшифровка, ни переписка не уходят наружу дальше домашней сети.
///
/// Ключ доступа при этом всё равно берётся из Keychain: у локального сервера
/// он обычно любой непустой.
enum LLMSettings {
    static let baseURLKey = "llmBaseURL"
    static let customModelKey = "llmCustomModel"
    static let defaultBaseURL = "https://api.deepseek.com"

    /// Что записано в настройках, без разбора. Пусто — значит DeepSeek.
    static var storedBaseURL: String {
        UserDefaults.standard.string(forKey: baseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var storedCustomModel: String {
        UserDefaults.standard.string(forKey: customModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Свой провайдер включён, только если адрес разобрался в URL.
    /// Мусор в поле не должен молча ломать чат — тогда работает DeepSeek.
    static var isCustom: Bool { url(from: storedBaseURL) != nil }

    static var baseURL: URL {
        url(from: storedBaseURL) ?? URL(string: defaultBaseURL)!
    }

    static var chatCompletionsURL: URL { baseURL.appending(path: "chat/completions") }
    static var modelsURL: URL { baseURL.appending(path: "models") }

    /// Имя модели: у своего провайдера оно своё, у DeepSeek — выбранное в настройках.
    static func resolvedModel(picked: String) -> String {
        guard isCustom, !storedCustomModel.isEmpty else { return picked }
        return storedCustomModel
    }

    /// Человекочитаемая строка для настроек: куда именно уходят запросы.
    static var describedTarget: String {
        guard isCustom else { return "DeepSeek (api.deepseek.com)" }
        let host = baseURL.host() ?? baseURL.absoluteString
        return storedCustomModel.isEmpty ? host : "\(host) · \(storedCustomModel)"
    }

    /// Только http и https, только с хостом. `URL(string:)` принимает почти любую
    /// строку, поэтому проверки обязательны: иначе запрос уйдёт в никуда.
    static func url(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var text = trimmed
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }
}
