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
    /// Сколько раз модель подряд не справилась с записью (`SummaryRunner`).
    var failuresURL: URL { url.deletingPathExtension().appendingPathExtension("failures.json") }

    /// Файл заголовков есть, но не прочитался — например, до первой разблокировки
    /// после перезагрузки. Пока так, хранилище знает не все заголовки, и решать по
    /// нему, чьё имя защищено, нельзя: бегунок модели в это время ничего не берёт.
    var isUnreadable: Bool { unreadable }

    /// Перечитать файл, если в прошлый раз он не прочитался. Зовётся перед каждой
    /// правкой и при возвращении в приложение: защита данных снимается после
    /// разблокировки, и с этого момента решения принимаются по настоящим записям,
    /// а не по пустой памяти.
    @discardableResult
    func retryLoadIfNeeded() -> Bool {
        guard unreadable else { return true }
        guard let data = try? Data(contentsOf: url) else { return false }
        unreadable = false
        if let stored = decode(data) {
            entries = Self.merge(stored: stored, current: entries)
        }
        guard !unreadable else { return false }
        Diagnostics.note("заголовки: \(url.lastPathComponent) снова читается — сохранённое и сделанное с запуска сведены")
        return true
    }

    /// Сведение файла с тем, что сделано с запуска. Новое побеждает — кроме
    /// одного случая: запись не от человека не заменяет ручное имя из файла.
    /// Пока файл не читался, хранилище об этом имени не знало, и ответ модели,
    /// пришедший тогда, тоже: раньше он молча затирал имя человека.
    static func merge(stored: [String: Entry], current: [String: Entry]) -> [String: Entry] {
        stored.merging(current) { stored, current in
            stored.manual && !current.manual ? stored : current
        }
    }

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
        // Защиту ручного имени решаем по файлу, а не по пустой памяти.
        retryLoadIfNeeded()
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
        retryLoadIfNeeded()
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
        retryLoadIfNeeded()
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
        // Не прочитав файл, не узнать, есть ли у записи имя от человека.
        guard retryLoadIfNeeded() else { return false }
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
        retryLoadIfNeeded()
        guard var entry = entries[relativePath], entry.summarized, !entry.stale else { return false }
        entry.stale = true
        entries[relativePath] = entry
        save()
        return true
    }

    /// Текст записи стал слишком коротким для модели или пустым. Модель по такому
    /// тексту не пишет, значит любой её прежний ответ — про другой текст, и
    /// сверять отпечаток незачем. Заголовок модели уходит совсем — дальше
    /// работают правила первой фразы; при ручном имени снимается только описание.
    /// Раньше старый заголовок оставался навсегда, а «Придумать заголовок» тем
    /// временем отвечал «заголовком служит первая фраза» — неправду.
    @discardableResult
    func dropGenerated(_ relativePath: String) -> Bool {
        retryLoadIfNeeded()
        guard var entry = entries[relativePath] else { return false }
        if entry.origin == .generated {
            entries.removeValue(forKey: relativePath)
        } else {
            guard entry.summarized || entry.stale || entry.source != nil || !entry.detail.isEmpty else { return false }
            entry.detail = ""
            entry.summarized = false
            entry.source = nil
            entry.stale = false
            entries[relativePath] = entry
        }
        save()
        return true
    }

    /// Переименование файла меняет ключ: запись не должна терять заголовок.
    func move(from old: String, to new: String) {
        retryLoadIfNeeded()
        guard old != new, let entry = entries.removeValue(forKey: old) else { return }
        entries[new] = entry
        save()
    }

    func forget(_ relativePath: String) {
        retryLoadIfNeeded()
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
            // Происхождение старых записей зависит от пути (`Entry.legacy`), а путь —
            // это ключ словаря, и разбору одной записи он не виден.
            let stored = try JSONDecoder().decode([String: Entry.Stored].self, from: data)
            return Dictionary(uniqueKeysWithValues: stored.map { path, record in
                (path, Entry(stored: record, path: path))
            })
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
        // Файл мог стать доступным: защита данных снимается после разблокировки.
        // Тогда сохранённое раньше — основа, а сделанное с запуска — поверх.
        guard retryLoadIfNeeded() else {
            Diagnostics.fault("заголовки: \(url.lastPathComponent) всё ещё не читается — не сохраняю, чтобы не затереть")
            return false
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

extension SummaryStore.Entry: Encodable {
    private enum CodingKeys: String, CodingKey {
        case title, detail, manual, origin, summarized, source, stale, replaceManual
    }

    /// Запись так, как она лежит в файле: у старых сборок там только заголовок,
    /// описание и «ручное».
    struct Stored: Decodable {
        let title: String
        let detail: String?
        let manual: Bool?
        let origin: String?
        let summarized: Bool?
        let source: String?
        let stale: Bool?
        let replaceManual: Bool?
    }

    init(stored: Stored, path: String) {
        let detail = stored.detail ?? ""
        // Незнакомое значение из будущей сборки не роняет разбор всего файла.
        let known = stored.origin.flatMap(SummaryStore.Origin.init(rawValue:))
        let (origin, summarized) = known.map { ($0, stored.summarized ?? false) }
            ?? Self.legacy(title: stored.title, detail: detail, manual: stored.manual ?? false, path: path)
        self.init(
            title: stored.title,
            detail: detail,
            origin: origin,
            summarized: summarized,
            source: stored.source,
            stale: stored.stale ?? false,
            replaceManual: stored.replaceManual ?? false
        )
    }

    /// Происхождение для файла старой сборки, где были только заголовок,
    /// описание и признак «ручное».
    ///
    /// Описание бывало только от модели, поэтому непустое значит «модель уже
    /// отвечала». Ручное имя, которое на деле служебное («Новая запись 5»), у
    /// принесённой записи — это импорт: до `setImported` имена принесённых файлов
    /// помечались ручными, и такое имя навсегда побеждало заголовок модели.
    ///
    /// Но только вне `Recordings/`: записи самой Lori (диктофон) импортом не
    /// бывали никогда, и служебное на вид имя там — «Звонок», «12.09», «1:1»,
    /// «Q3 2026» — набрал человек. Понизить его значило бы отдать модели.
    static func legacy(title: String, detail: String, manual: Bool, path: String) -> (SummaryStore.Origin, Bool) {
        if manual {
            let ownRecording = path.hasPrefix("Recordings/")
            if !ownRecording, RecordTitle.isGenericName(title) { return (.imported, false) }
            return (.manual, !detail.isEmpty)
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
