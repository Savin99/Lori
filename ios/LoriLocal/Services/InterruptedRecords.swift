import Foundation

/// Записи, чью расшифровку оборвала система, и чем именно их считали.
///
/// Оборвать может перегрев, нехватка памяти, сам планировщик (задача, которая долго не
/// показывает движения, снимается принудительно) или человек — смахнув приложение из
/// переключателя задач: фоновая задача при этом снимается вместе с процессом.
///
/// **Движок хранится вместе с путём, и это не мелочь.** Первая версия держала только
/// пути и ставила запись заново «текущим движком из настроек». На живом прогоне это
/// значило вот что: запись, прерванная на GigaAM, при следующем запуске ушла в Gemini,
/// потому что в настройках к тому моменту стоял он. То есть приложение молча подменило
/// движок и отправило 22 МБ звука в облако без единого нажатия — ровно то, что
/// `AGENTS.md` запрещает прямым текстом.
///
/// Список лежит **файлом**, а не в `UserDefaults`: настройки доживают до диска только
/// при уходе в фон, и при жёстком завершении процесса последняя запись пропадает — то
/// есть ровно в том случае, ради которого этот список и заведён.
enum InterruptedRecords {
    static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appending(path: "Lori", directoryHint: .isDirectory)
            .appending(path: "interrupted.json")
    }

    private struct Archive: Codable {
        let jobs: [String: TranscriptionJob]
        let legacy: [String: TranscriptionEngineKind]
    }

    /// Путь записи → движок, которым её считали.
    static func load(from url: URL = InterruptedRecords.url) -> [String: TranscriptionEngineKind] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if let archive = try? JSONDecoder().decode(Archive.self, from: data) {
            return archive.legacy.merging(archive.jobs.mapValues(\.kind)) { _, new in new }
        }
        if let jobs = try? JSONDecoder().decode([String: TranscriptionJob].self, from: data) {
            return jobs.mapValues(\.kind)
        }
        guard let stored = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return stored.compactMapValues(TranscriptionEngineKind.init(rawValue:))
    }

    static func jobs(from url: URL) -> [String: TranscriptionJob] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if let archive = try? JSONDecoder().decode(Archive.self, from: data) { return archive.jobs }
        return (try? JSONDecoder().decode([String: TranscriptionJob].self, from: data)) ?? [:]
    }

    static func saveJobs(_ jobs: [String: TranscriptionJob], legacy: [String: TranscriptionEngineKind] = [:], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Archive(jobs: jobs, legacy: legacy)).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Пустой список стирает файл: пустой JSON в Application Support — это мусор,
    /// который потом читают и не понимают, что он значит.
    static func save(_ records: [String: TranscriptionEngineKind], to url: URL = InterruptedRecords.url) {
        guard !records.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(records.mapValues(\.rawValue)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
