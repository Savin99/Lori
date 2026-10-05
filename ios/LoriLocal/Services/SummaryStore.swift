import Combine
import CryptoKit
import Foundation

/// Заголовки и описания записей: и придуманные моделью, и заданные человеком.
///
/// Живёт рядом с темами — отдельным файлом, а не внутри расшифровки: имя
/// записи меняется чаще, чем текст, и переписывать из-за этого markdown незачем.
@MainActor
final class SummaryStore: ObservableObject {
    /// Откуда взялся заголовок записи. От этого зависит, кто вправе его заменить
    /// и какое место он занимает среди источников (`RecordTitle`).
    enum Origin: String, Codable, Sendable {
        /// Задал человек. Модель его не трогает — иначе переименование молча
        /// откатывалось бы после следующей расшифровки.
        case manual
        /// Имя принесённого файла: временное, модель вправе его заменить.
        case imported
        /// Придумала модель.
        case generated
    }

    struct Entry: Equatable, Sendable {
        var title: String
        var detail: String
        var origin: Origin
        /// Модель уже ответила по этой записи: заголовком, а при ручном имени —
        /// описанием. Пустое описание тоже ответ: раньше признаком служило само
        /// описание, и запись с пустым запускала модель на каждом возвращении в Lori.
        var summarized: Bool
        /// Отпечаток текста, по которому писала модель (`fingerprint(of:)`).
        /// nil — неизвестен: так у записей из старых сборок.
        var source: String?
        /// Расшифровку переписали после ответа модели. Старый заголовок остаётся
        /// на экране, пока не придёт новый.
        var stale: Bool
        /// Человек нажал «Придумать заголовок» поверх своего имени. Имя остаётся
        /// защищённым, пока модель не ответила: раньше защиту снимали заранее, и
        /// неудачная попытка оставляла имя человека беззащитным перед автоматом.
        var replaceManual: Bool

        /// Имя задал человек.
        var manual: Bool { origin == .manual }

        init(
            title: String,
            detail: String,
            origin: Origin,
            summarized: Bool = false,
            source: String? = nil,
            stale: Bool = false,
            replaceManual: Bool = false
        ) {
            self.title = title
            self.detail = detail
            self.origin = origin
            self.summarized = summarized
            self.source = source
            self.stale = stale
            self.replaceManual = replaceManual
        }
    }

    @Published private(set) var entries: [String: Entry] = [:]

    private let url: URL
    /// Файл есть, но прочитать его не вышло. Писать поверх нельзя: это стёрло бы
    /// все заголовки разом. Запись ждёт, пока файл снова прочитается.
    private var unreadable = false

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

    /// Сохранённый заголовок любого происхождения. Что показать на экране,
    /// решает `RecordTitle.resolve` — служебное имя файла там уступает тексту.
    func title(for relativePath: String) -> String? {
        let title = entries[relativePath]?.title
        return (title?.isEmpty ?? true) ? nil : title
    }

    func detail(for relativePath: String) -> String? {
        let detail = entries[relativePath]?.detail
        return (detail?.isEmpty ?? true) ? nil : detail
    }

    /// Нужен ли этой записи ответ модели: его нет совсем, у записи только имя
    /// файла или ручное имя без описания, либо расшифровку переписали.
    func needsSummary(for relativePath: String) -> Bool {
        guard let entry = entries[relativePath] else { return true }
        return entry.stale || !entry.summarized
    }

    /// Ответ модели есть и написан по этому же тексту. Отпечатка у записей из
    /// старых сборок нет — тогда ответ считается годным: перегенерировать всё
    /// подряд без причины хуже, чем оставить прежний заголовок.
    func isUpToDate(_ relativePath: String, fingerprint: String) -> Bool {
        guard let entry = entries[relativePath], entry.summarized, !entry.stale else { return false }
        return entry.source == nil || entry.source == fingerprint
    }

    /// Ответ модели. Ручное имя сохраняется — кроме случая, когда человек сам
    /// попросил «Придумать заголовок» (`allowGeneratedTitle`) и это его запрос
    /// (`force`). Описание при ручном имени обновляется, если его не было,
    /// текст поменялся или попросили явно.
    @discardableResult
    func store(title: String, detail: String, for relativePath: String, force: Bool = false, source: String? = nil) -> Bool {
        let previous = entries[relativePath]
        var entry: Entry
        if var existing = previous, existing.manual, !(force && existing.replaceManual) {
            if force || existing.stale || !existing.summarized || existing.detail.isEmpty {
                existing.detail = detail
            }
            entry = existing
        } else {
            entry = Entry(title: title, detail: detail, origin: .generated)
        }
        entry.summarized = true
        entry.stale = false
        entry.source = source
        entries[relativePath] = entry
        guard save() else { entries[relativePath] = previous; return false }
        return true
    }

    /// Имя от человека. Ответ модели (описание) остаётся: он про ту же запись.
    func setManual(title: String, for relativePath: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var entry = entries[relativePath] ?? Entry(title: clean, detail: "", origin: .manual)
        entry.title = clean
        entry.origin = .manual
        // Новое слово человека отменяет его прежнюю просьбу заменить имя.
        entry.replaceManual = false
        entries[relativePath] = entry
        save()
    }

    /// Имя принесённого файла видно сразу, но это не ручное переименование в Lori.
    /// Иначе «Новая запись 5» навсегда побеждала заголовок, который модель уже создала.
    func setImported(title: String, for relativePath: String) {
        guard entries[relativePath] == nil else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        entries[relativePath] = Entry(title: clean, detail: "", origin: .imported)
        if !save() { entries[relativePath] = nil }
    }

    /// Только явная команда «Придумать заголовок» разрешает заменить ручное имя.
    /// Само имя и его защита остаются до успешного ответа модели: снимает их
    /// `store(…, force: true)`, и только он.
    @discardableResult
    func allowGeneratedTitle(for relativePath: String) -> Bool {
        guard var entry = entries[relativePath], entry.manual, !entry.replaceManual else { return true }
        let previous = entry
        entry.replaceManual = true
        entries[relativePath] = entry
        guard save() else { entries[relativePath] = previous; return false }
        return true
    }

    /// Расшифровку переписали — перерасшифровкой или правкой. Ответ модели
    /// устарел, но остаётся на экране, пока модель не напишет новый.
    @discardableResult
    func markStale(_ relativePath: String) -> Bool {
        guard var entry = entries[relativePath], entry.summarized, !entry.stale else { return false }
        entry.stale = true
        entries[relativePath] = entry
        save()
        return true
    }

    /// Переименование файла меняет ключ: запись не должна терять заголовок.
    func move(from old: String, to new: String) {
        guard old != new, let entry = entries.removeValue(forKey: old) else { return }
        entries[new] = entry
        save()
    }

    func forget(_ relativePath: String) {
        guard entries.removeValue(forKey: relativePath) != nil else { return }
        save()
    }

    /// Отпечаток текста расшифровки: по нему видно, что модель писала по другому
    /// тексту. Пробелы и переносы не в счёт — текст из файла и текст из памяти
    /// склеены по-разному, а слова те же.
    nonisolated static func fingerprint(of text: String) -> String {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return SHA256.hash(data: Data(normalized.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Хранение

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Например, защита данных до первой разблокировки после перезагрузки.
            unreadable = true
            Diagnostics.fault("заголовки: \(url.lastPathComponent) не читается (\(error.localizedDescription)) — сохранять поверх не буду")
            return
        }
        entries = decode(data) ?? [:]
    }

    /// Разбор файла. Испорченный файл не сбрасывается молча: сначала копия
    /// рядом, потом запись в журнал. Без копии писать поверх нельзя вовсе.
    private func decode(_ data: Data) -> [String: Entry]? {
        do {
            return try JSONDecoder().decode([String: Entry].self, from: data)
        } catch {
            let stamp = Self.backupStamp.string(from: Date())
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
            do {
                try data.write(to: backup, options: .atomic)
                Diagnostics.fault("заголовки: \(url.lastPathComponent) не разобран (\(error.localizedDescription)); копия — \(backup.lastPathComponent), начинаю с пустого")
            } catch {
                unreadable = true
                Diagnostics.fault("заголовки: \(url.lastPathComponent) не разобран, и копию сохранить не вышло (\(error.localizedDescription)) — сохранять поверх не буду")
            }
            return nil
        }
    }

    private static let backupStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    @discardableResult
    private func save() -> Bool {
        if unreadable {
            // Файл мог стать доступным: защита данных снимается после разблокировки.
            // Тогда сохранённое раньше — основа, а сделанное с запуска — поверх.
            guard let data = try? Data(contentsOf: url) else {
                Diagnostics.fault("заголовки: \(url.lastPathComponent) всё ещё не читается — не сохраняю, чтобы не затереть")
                return false
            }
            unreadable = false
            if let stored = decode(data) {
                entries = stored.merging(entries) { _, current in current }
            }
            guard !unreadable else { return false }
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            Diagnostics.fault("заголовки: не удалось сохранить \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Формат файла

extension SummaryStore.Entry: Codable {
    private enum CodingKeys: String, CodingKey {
        case title, detail, manual, origin, summarized, source, stale, replaceManual
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        let manual = try container.decodeIfPresent(Bool.self, forKey: .manual) ?? false
        source = try container.decodeIfPresent(String.self, forKey: .source)
        stale = try container.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        replaceManual = try container.decodeIfPresent(Bool.self, forKey: .replaceManual) ?? false
        // Незнакомое значение из будущей сборки не роняет разбор всего файла.
        if let raw = try container.decodeIfPresent(String.self, forKey: .origin),
           let origin = SummaryStore.Origin(rawValue: raw) {
            self.origin = origin
            summarized = try container.decodeIfPresent(Bool.self, forKey: .summarized) ?? false
        } else {
            (origin, summarized) = Self.legacy(title: title, detail: detail, manual: manual)
        }
    }

    /// Происхождение для файла старой сборки, где были только заголовок,
    /// описание и признак «ручное».
    ///
    /// Описание бывало только от модели, поэтому непустое значит «модель уже
    /// отвечала». Ручное имя, которое на деле служебное («Новая запись 5»), —
    /// это импорт: до `setImported` имена принесённых файлов помечались ручными,
    /// и такое имя навсегда побеждало заголовок модели. Человек так запись не
    /// назовёт, а модели ответить заново стоит одного запуска.
    static func legacy(title: String, detail: String, manual: Bool) -> (SummaryStore.Origin, Bool) {
        if manual {
            return RecordTitle.isGenericName(title) ? (.imported, false) : (.manual, !detail.isEmpty)
        }
        return detail.isEmpty ? (.imported, false) : (.generated, true)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(detail, forKey: .detail)
        // Старые сборки читают только эти три поля, и «ручное» им по-прежнему нужно.
        try container.encode(manual, forKey: .manual)
        try container.encode(origin.rawValue, forKey: .origin)
        try container.encode(summarized, forKey: .summarized)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encode(stale, forKey: .stale)
        try container.encode(replaceManual, forKey: .replaceManual)
    }
}
