import CryptoKit
import Foundation

/// Готовые части расшифровки, пережившие обрыв.
///
/// **Правило «оборвалось — считаем заново с нуля» было принято 1 сентября, и
/// тогда оно было верным:** облачная расшифровка укладывалась в один-два
/// запроса, терять было нечего, а чекпоинты по кускам стоили бы сложности ради
/// половины текста.
///
/// Считать заново перестало быть дёшево, когда запись поехала частями по десять
/// минут. Живой прогон записи 84:06: девять частей, шесть прошли и оплачены,
/// система забрала процесс на седьмой — и всё шесть ушло в никуда. Часть теперь
/// естественная граница: у неё свои секунды, свой ответ и своя цена.
///
/// **Черновик — не расшифровка.** Он лежит в `Application Support`, а не в
/// рабочей папке: в «Файлах» человеку нужен готовый текст, а не половина.
/// Пропадёт черновик — расшифровка просто пойдёт с нуля, как раньше.
enum TranscriptCheckpoint {
    /// Готовая реплика: текст и участок записи, который он покрывает.
    struct Piece: Codable, Equatable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let isApproximate: Bool
    }

    struct Snapshot: Codable, Equatable {
        /// Отпечаток условий. Совпал — черновик наш; не совпал — он про другую
        /// работу, и продолжать по нему нельзя.
        let fingerprint: String
        /// Сколько записи уже разобрано: отсюда пойдёт следующая часть.
        var cursor: TimeInterval
        var pieces: [Piece]
        /// Замечания по уже разобранным частям. Их нельзя терять вместе с
        /// обрывом: «модель начала повторяться на 1:12:30» — это про запись,
        /// а не про сеанс работы, и в готовом файле оно обязано остаться.
        var warnings: [String]
        var saved: Date

        var isEmpty: Bool { pieces.isEmpty }
    }

    /// Черновики старше недели не поднимаем: за неделю человек уже забыл, что
    /// расшифровка обрывалась, и продолжение старого ответа его удивит сильнее,
    /// чем честный пересчёт.
    static let maximumAge: TimeInterval = 7 * 24 * 3600

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Lori", directoryHint: .isDirectory)
            .appending(path: "Черновики", directoryHint: .isDirectory)
    }

    /// Отпечаток условий расшифровки.
    ///
    /// Сюда входит всё, из-за чего продолжать старый черновик было бы неверно:
    /// сам файл (размер и время правки — запись могли перезаписать), движок и
    /// модель, режим, длина части и словарь. Поменяли словарь — прошлые части
    /// считались без него, и склеивать их с новыми значит выдать смесь за
    /// цельную расшифровку.
    static func fingerprint(
        audio: URL,
        engine: String,
        model: String,
        mode: String,
        partSeconds: TimeInterval,
        vocabulary: [String]
    ) -> String {
        // Через `FileManager`, а не через `URL.resourceValues`: тот **кэширует**
        // значения на самом объекте URL, и перезаписанная запись возвращала бы
        // старые размер и дату. Поймано тестом: файл переписали, а отпечаток не
        // изменился — то есть черновик от прошлого звука подошёл бы к новому.
        let attributes = try? FileManager.default.attributesOfItem(atPath: audio.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let source = [
            audio.lastPathComponent,
            String(size),
            String(format: "%.0f", modified),
            engine,
            model,
            mode,
            String(format: "%.0f", partSeconds),
            vocabulary.joined(separator: "\u{1}"),
        ].joined(separator: "\u{2}")
        return digest(of: source)
    }

    static func url(for fingerprint: String) -> URL {
        directory.appending(path: "\(fingerprint).json")
    }

    /// Черновик под эти условия — или пустой, если его нет, он устарел или он
    /// про другую работу.
    static func load(fingerprint: String, now: Date = Date()) -> Snapshot {
        let fresh = Snapshot(fingerprint: fingerprint, cursor: 0, pieces: [], warnings: [], saved: now)
        guard let data = try? Data(contentsOf: url(for: fingerprint)),
              let stored = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return fresh
        }
        guard stored.fingerprint == fingerprint else { return fresh }
        guard now.timeIntervalSince(stored.saved) <= maximumAge else {
            drop(fingerprint: fingerprint)
            return fresh
        }
        return stored
    }

    static func save(_ snapshot: Snapshot, now: Date = Date()) {
        var stored = snapshot
        stored.saved = now
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: snapshot.fingerprint), options: .atomic)
    }

    /// Работа сошлась — черновик больше не нужен. Оставлять его нельзя: при
    /// следующей расшифровке той же записи тем же движком он поднялся бы и
    /// подменил новую работу старым текстом.
    static func drop(fingerprint: String) {
        try? FileManager.default.removeItem(at: url(for: fingerprint))
    }

    /// Уборка заброшенных черновиков. Зовётся на запуске: записи удаляют,
    /// движки меняют, и файл под отпечаток, который больше никогда не совпадёт,
    /// иначе лежит вечно.
    ///
    /// Возраст берётся из самого снимка, а не из времени файла: по этой же дате
    /// решает `load`, и два разных мерила давности разошлись бы — файл, который
    /// `load` уже считает устаревшим, `prune` мог бы держать вечно. Нечитаемый
    /// снимок удаляется: поднять его всё равно нечем.
    static func prune(now: Date = Date()) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let stored = try? JSONDecoder().decode(Snapshot.self, from: data) else {
                try? manager.removeItem(at: file)
                continue
            }
            guard now.timeIntervalSince(stored.saved) > maximumAge else { continue }
            try? manager.removeItem(at: file)
        }
    }

    private static func digest(of source: String) -> String {
        SHA256.hash(data: Data(source.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
