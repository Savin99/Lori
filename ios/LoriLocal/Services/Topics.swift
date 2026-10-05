import Foundation

/// Темы записей.
///
/// Темы — плоский список, а не дерево папок: записей десятки, и раскладывание по
/// вложенным папкам скатывается в «Новая запись 47» внутри «Разное». Привязка живёт
/// в метаданных, а не в структуре файлов: иначе переименование темы ломает пути
/// к расшифровкам.
@MainActor
final class TopicStore: ObservableObject {
    /// Все известные темы, в порядке добавления.
    @Published private(set) var topics: [String] = []
    /// Путь записи → тема.
    @Published private(set) var assigned: [String: String] = [:]

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
        load()
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Lori", directoryHint: .isDirectory)
            .appending(path: "topics.json")
    }

    func topic(for relativePath: String) -> String? {
        assigned[relativePath]
    }

    /// Сколько записей в теме — для чипа и для экрана хранилища.
    func count(of topic: String) -> Int {
        assigned.values.filter { $0 == topic }.count
    }

    @discardableResult
    func add(_ name: String) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 40 else { return nil }
        if let existing = topics.first(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            return existing
        }
        topics.append(clean)
        save()
        return clean
    }

    func assign(_ topic: String?, to relativePath: String) {
        if let topic, let known = add(topic) {
            assigned[relativePath] = known
        } else {
            assigned.removeValue(forKey: relativePath)
        }
        save()
    }

    func rename(_ topic: String, to name: String) {
        guard let index = topics.firstIndex(of: topic), let clean = add(name) else { return }
        topics.remove(at: index)
        for (path, value) in assigned where value == topic {
            assigned[path] = clean
        }
        save()
    }

    func remove(_ topic: String) {
        topics.removeAll { $0 == topic }
        for (path, value) in assigned where value == topic {
            assigned.removeValue(forKey: path)
        }
        save()
    }

    /// Записи, которые больше не существуют, в метаданных не нужны.
    func forget(_ relativePath: String) {
        assigned.removeValue(forKey: relativePath)
        save()
    }

    /// Тема, которую стоит предложить: расшифровка уже есть, и по словам из неё
    /// видно, о чём запись. Человек только подтверждает.
    func suggestion(for text: String, vocabulary: [String] = TranscriptionSettings.vocabulary) -> String? {
        guard !text.isEmpty else { return nil }
        let haystack = text.lowercased()

        // Прямое совпадение с названием темы — самый надёжный признак.
        if let direct = topics.first(where: { haystack.contains($0.lowercased()) }) {
            return direct
        }
        // Слова из словаря часто и есть названия тем: MCP, Думатель, BIOS.
        for term in vocabulary where haystack.contains(term.lowercased()) {
            if let topic = topics.first(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
                return topic
            }
        }
        return nil
    }

    // MARK: - Хранение

    private struct Payload: Codable {
        var topics: [String]
        var assigned: [String: String]
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        topics = payload.topics
        assigned = payload.assigned
    }

    private func save() {
        let payload = Payload(topics: topics, assigned: assigned)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
