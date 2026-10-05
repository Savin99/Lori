import Foundation

/// Отправка расшифровки в Obsidian.
///
/// Хранилище у Obsidian своё, и попасть в него можно только через его же схему
/// `obsidian://new`. Имя хранилища знает только человек — оно в настройках.
enum ObsidianExport {
    static let vaultKey = "obsidianVault"

    static var vault: String {
        (UserDefaults.standard.string(forKey: vaultKey) ?? "").trimmingCharacters(in: .whitespaces)
    }

    static var isConfigured: Bool { !vault.isEmpty }

    /// Ссылка на создание заметки. Содержимое уходит параметром, поэтому длинную
    /// расшифровку приходится обрезать: у схемы URL есть предел длины, и лучше
    /// отдать начало текста, чем не отдать ничего.
    static let contentLimit = 8000

    static func url(title: String, text: String, vault: String = ObsidianExport.vault) -> URL? {
        let vaultName = vault.trimmingCharacters(in: .whitespaces)
        guard !vaultName.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "new"
        components.queryItems = [
            URLQueryItem(name: "vault", value: vaultName),
            URLQueryItem(name: "name", value: title),
            URLQueryItem(name: "content", value: String(text.prefix(contentLimit))),
        ]
        return components.url
    }
}
