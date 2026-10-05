import Combine
import Foundation

/// Заголовки и описания записей: и придуманные моделью, и заданные человеком.
///
/// Живёт рядом с темами — отдельным файлом, а не внутри расшифровки: имя
/// записи меняется чаще, чем текст, и переписывать из-за этого markdown незачем.
@MainActor
final class SummaryStore: ObservableObject {
    struct Entry: Codable, Equatable {
        var title: String
        var detail: String
        /// Имя задал человек. Такое имя модель не трогает — иначе переименование
        /// молча откатывалось бы после следующей расшифровки.
        var manual: Bool
    }

    @Published private(set) var entries: [String: Entry] = [:]

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
        load()
    }

    var pendingQueueURL: URL { url.deletingPathExtension().appendingPathExtension("pending.json") }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Lori", directoryHint: .isDirectory)
            .appending(path: "summaries.json")
    }

    func entry(for relativePath: String) -> Entry? { entries[relativePath] }

    func title(for relativePath: String) -> String? {
        let title = entries[relativePath]?.title
        return (title?.isEmpty ?? true) ? nil : title
    }

    func detail(for relativePath: String) -> String? {
        let detail = entries[relativePath]?.detail
        return (detail?.isEmpty ?? true) ? nil : detail
    }

    /// Нужен ли этой записи заголовок от модели.
    func needsSummary(for relativePath: String) -> Bool {
        guard let entry = entries[relativePath] else { return true }
        return entry.detail.isEmpty || (!entry.manual && entry.title.isEmpty)
    }

    /// Повторная генерация обновляет описание, ручное имя сохраняется.
    @discardableResult
    func store(title: String, detail: String, for relativePath: String, force: Bool = false) -> Bool {
        let previous = entries[relativePath]
        if let existing = entries[relativePath], existing.manual {
            entries[relativePath] = Entry(title: existing.title,
                detail: force || existing.detail.isEmpty ? detail : existing.detail, manual: true)
        } else {
            entries[relativePath] = Entry(title: title, detail: detail, manual: false)
        }
        guard save() else { entries[relativePath] = previous; return false }
        return true
    }

    func setManual(title: String, for relativePath: String) {
        let clean = title.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        entries[relativePath] = Entry(title: clean, detail: entries[relativePath]?.detail ?? "", manual: true)
        save()
    }

    /// Имя принесённого файла видно сразу, но это не ручное переименование в Lori.
    /// Иначе «Новая запись 5» навсегда побеждала заголовок, который модель уже создала.
    func setImported(title: String, for relativePath: String) {
        guard entries[relativePath] == nil else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        entries[relativePath] = Entry(title: clean, detail: "", manual: false)
        if !save() { entries[relativePath] = nil }
    }

    /// Только явная команда «Придумать заголовок» снимает защиту ручного имени.
    /// Само название остаётся на месте до успешного ответа модели.
    @discardableResult
    func allowGeneratedTitle(for relativePath: String) -> Bool {
        guard let previous = entries[relativePath], previous.manual else { return true }
        entries[relativePath] = Entry(title: previous.title, detail: previous.detail, manual: false)
        guard save() else { entries[relativePath] = previous; return false }
        return true
    }

    /// Переименование файла меняет ключ: запись не должна терять заголовок.
    func move(from old: String, to new: String) {
        guard let entry = entries.removeValue(forKey: old) else { return }
        entries[new] = entry
        save()
    }

    func forget(_ relativePath: String) {
        guard entries.removeValue(forKey: relativePath) != nil else { return }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = stored
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }
}
