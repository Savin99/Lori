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
            URLQueryItem(name: "name", value: noteName(from: title)),
            URLQueryItem(name: "content", value: String(text.prefix(contentLimit))),
        ]
        return components.url
    }

    /// Предел длины имени заметки: имя становится файлом в хранилище.
    static let nameLimit = 120

    /// Имя заметки из заголовка записи.
    ///
    /// `name` у `obsidian://new` — имя файла заметки, и заголовок «Запись 21:46»
    /// туда не годится: двоеточие запрещено в именах файлов, а ещё ломает ссылки
    /// `[[…]]`. Справка Obsidian («Internal links»): ссылкой может не работать
    /// строка с `# | ^ : %% [[ ]]`; «/», «\» и «:» файловые системы не примут.
    /// Хранилища синхронизируют и на Windows, где запрещены ещё `* " < > | ?`.
    /// Разделители времени и дат («:», «/», «\») становятся «-» — «Запись
    /// 21-46» читается, остальное снимается.
    static func noteName(from title: String) -> String {
        let replaced = title.map { character -> String in
            if ":/\\".contains(character) { return "-" }
            if "*\"<>|?#^[]".contains(character) { return " " }
            if character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return " " }
            return String(character)
        }.joined()
        var name = replaced
            .replacingOccurrences(of: "%%", with: "%")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        // Точка в начале делает файл скрытым.
        while let first = name.first, first == "." || first.isWhitespace { name.removeFirst() }
        name = String(name.prefix(nameLimit)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Запись" : name
    }
}
