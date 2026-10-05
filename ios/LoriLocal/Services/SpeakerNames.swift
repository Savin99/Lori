import Foundation

/// Имена говорящих.
///
/// «S1» и «S2» — это всё, что даёт движок: он различает голоса, но не знает,
/// кого как зовут. Знает человек, и одного долгого тапа достаточно, чтобы вся
/// запись перестала быть разговором двух безымянных меток.
///
/// Имена живут отдельным файлом, а не в самой расшифровке. Формат `.md` — это
/// текст записи, и подменять в нём «S1:» на «Лёша:» значит терять связь с тем,
/// что сказал движок: перерасшифровка вернула бы «S1», а правка имени задним
/// числом переписывала бы файл целиком. Здесь же переименование — это одна
/// строка в JSON, и оно переживает любую перерасшифровку.
@MainActor
final class SpeakerNames: ObservableObject {
    /// Путь записи → метка говорящего → имя.
    @Published private(set) var names: [String: [String: String]] = [:]

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
        load()
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Lori", directoryHint: .isDirectory)
            .appending(path: "speakers.json")
    }

    /// Имя говорящего или сама метка, если имени ещё не дали.
    func name(of label: String, in relativePath: String) -> String {
        names[relativePath]?[label] ?? label
    }

    func isNamed(_ label: String, in relativePath: String) -> Bool {
        names[relativePath]?[label] != nil
    }

    func rename(_ label: String, to name: String, in relativePath: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var forRecord = names[relativePath] ?? [:]
        if clean.isEmpty || clean.count > 40 {
            // Пустое имя — это возврат к метке, а не имя из пустой строки.
            forRecord.removeValue(forKey: label)
        } else {
            forRecord[label] = clean
        }
        names[relativePath] = forRecord.isEmpty ? nil : forRecord
        save()
    }

    /// Запись переехала или удалена — имена не должны оставаться сиротами.
    func move(from old: String, to new: String) {
        guard let stored = names[old] else { return }
        names[new] = stored
        names[old] = nil
        save()
    }

    func forget(_ relativePath: String) {
        guard names[relativePath] != nil else { return }
        names[relativePath] = nil
        save()
    }

    /// Метки в тексте заменяются на имена — для «Скопировать», шаринга и
    /// Obsidian: снаружи приложения кружков нет, а «S1» без Lori ничего не значит.
    func applied(to text: String, in relativePath: String) -> String {
        guard let forRecord = names[relativePath], !forRecord.isEmpty else { return text }
        var result = text
        for (label, name) in forRecord {
            result = result.replacingOccurrences(of: "\(label): ", with: "\(name): ")
        }
        return result
    }

    // MARK: - Хранение

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return }
        names = stored
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(names) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
