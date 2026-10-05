import Foundation

/// Личные ключи добавляет сборочный скрипт из файла вне Git.
/// Это удобство переустановки, а не защита секрета: ресурс извлекается из IPA.
enum BundledAPIKeys {
    static func key(for account: KeychainAccount) -> String? {
        #if targetEnvironment(simulator)
        return nil
        #else
        // Даже случайно скопированный ресурс не включает личные ключи в QA.
        guard Bundle.main.bundleIdentifier == "ru.ilyaqa.lori.local",
              allowsBundledKey(for: account, at: destination(for: account)),
              let url = Bundle.main.url(forResource: "PrivateAPIKeys", withExtension: "plist"),
              let data = try? Data(contentsOf: url) else { return nil }
        return key(for: account, in: data)
        #endif
    }

    // Сохранённый адрес другого провайдера не должен получить новый встроенный
    // ключ после обновления. Для своего прокси ключ задаётся вручную в настройках.
    static func allowsBundledKey(for account: KeychainAccount, at url: URL) -> Bool {
        let host: String
        switch account {
        case .openAI: host = "api.openai.com"
        case .gemini: host = "generativelanguage.googleapis.com"
        case .elevenLabs: host = "api.elevenlabs.io"
        }
        return url.scheme?.lowercased() == "https" && url.host?.lowercased() == host
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    private static func destination(for account: KeychainAccount) -> URL {
        switch account {
        case .openAI: TranscriptionSettings.openAIBaseURL
        case .gemini: TranscriptionSettings.geminiHost
        case .elevenLabs: TranscriptionSettings.elevenLabsBaseURL
        }
    }

    static func key(for account: KeychainAccount, in data: Data) -> String? {
        guard let keys = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let value = keys[account.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
