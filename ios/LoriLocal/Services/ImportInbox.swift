import AppIntents
import Foundation
import UniformTypeIdentifiers

/// Приём аудио, пришедшего снаружи: из «Поделиться», из «Файлов», из Быстрых команд.
///
/// Share Extension здесь намеренно нет. Расширение обязано класть файл в общий
/// контейнер App Group, а App Groups бесплатная команда разработчика не
/// подписывает — сборка падала бы на провижининге. Вместо расширения приложение
/// объявляет типы документов (`CFBundleDocumentTypes`): тогда в Диктофоне,
/// Telegram и почте «Поделиться» → Lori работает без единой строки в другом
/// процессе, а система сама кладёт копию файла в `Documents/Inbox`.
///
/// Всё, что пришло, стекается в одну промежуточную папку. Это осознанно: точек
/// входа три, и без общего места каждая тянула бы свой путь до панели, а при
/// холодном старте ещё и гонку — кто первым доберётся до интерфейса.
enum ImportInbox {
    /// Куда система кладёт файл, переданный через «Поделиться».
    static var systemInbox: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Inbox", directoryHint: .isDirectory)
    }

    /// Промежуточная папка. Лежит в `tmp`, а не в `Documents`: рабочая папка
    /// видна в «Файлах», и складывать туда ещё не подтверждённое — значит
    /// показывать человеку мусор, которого он не создавал.
    static var staging: URL {
        FileManager.default.temporaryDirectory
            .appending(path: "Принесённое", directoryHint: .isDirectory)
    }

    // MARK: - Форматы

    /// Что приложение умеет расшифровывать, — для текста отказа. Так, как это назвал бы
    /// человек, а не как лежит множество расширений: `WorkspaceEntry.audioExtensions`
    /// хранит «aif» и «aiff» порознь, а человеку это один формат. Что список не
    /// расходится с множеством, проверяет тест.
    static let supportedFormatsTitle = "M4A, MP3, WAV, AAC, CAF, AIFF, MP4 и MOV"

    /// Годится ли файл для расшифровки — по расширению, как и список записей.
    ///
    /// Расширение, а не содержимое, потому что именно оно решает судьбу файла дальше:
    /// запись, которой нет в `audioExtensions`, не попадёт в список, и расшифровать её
    /// нечем — «Расшифровать можно только аудиофайл». Раньше такой файл (`.ogg`, `.opus`,
    /// `.flac`) спокойно копировался в рабочую папку и оттуда уже не виден, а человек
    /// узнавал об этом, не найдя запись. Теперь отказ случается на входе, и с пояснением.
    static func isSupported(fileName: String) -> Bool {
        WorkspaceEntry.audioExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    static func isSupported(_ url: URL) -> Bool {
        isSupported(fileName: url.lastPathComponent)
    }

    // MARK: - Приём

    /// Переносит пришедший файл в промежуточную папку и отдаёт новый адрес.
    ///
    /// Копия обязательна во всех случаях. Из `Documents/Inbox` — потому что папка
    /// видна в «Файлах» и обязана оставаться пустой. Из «Файлов» — потому что
    /// доступ к чужому файлу живёт, пока держат security scope, а между выбором
    /// и нажатием «Расшифровать» проходит сколько угодно времени.
    ///
    /// Формат проверяется **до** копирования: негодный файл не нужно ни тащить, ни потом
    /// за ним прибирать. Исключение — копия из `Documents/Inbox`: она не чужая, система
    /// положила её для нас, и оставить отвергнутый файл на виду в «Файлах» нельзя.
    @discardableResult
    static func stage(_ source: URL) throws -> URL {
        guard isSupported(source) else {
            if isInSystemInbox(source) { try? FileManager.default.removeItem(at: source) }
            Diagnostics.note("импорт: «\(source.lastPathComponent)» отклонён, формат не поддерживается")
            throw ImportError.unsupportedFormat(fileName: source.lastPathComponent)
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let destination = free(named: source.lastPathComponent)

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        // Из Inbox файл именно переносится: он уже наш, и копия оставила бы
        // оригинал лежать на виду в «Файлах».
        if isInSystemInbox(source) {
            try FileManager.default.moveItem(at: source, to: destination)
        } else {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return destination
    }

    /// Тот же приём для Быстрых команд: файл приходит данными, а не адресом.
    ///
    /// Имя у такого файла бывает без расширения («Recording», тип — m4a): после проверки
    /// формата это значило бы отказ хорошему файлу, поэтому расширение достраивается по
    /// типу, который команда передала вместе с данными.
    @discardableResult
    static func stage(_ file: IntentFile) throws -> URL {
        let name = completingExtension(of: file.filename, with: file.type)
        guard isSupported(fileName: name) else {
            Diagnostics.note("импорт: «\(name)» из Быстрых команд отклонён, формат не поддерживается")
            throw ImportError.unsupportedFormat(fileName: name)
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let destination = free(named: name)
        try file.data.write(to: destination, options: .atomic)
        return destination
    }

    /// Имя с расширением: своё, если оно есть, иначе — предпочтительное для типа.
    static func completingExtension(of name: String, with type: UTType?) -> String {
        guard (name as NSString).pathExtension.isEmpty,
              let suffix = type?.preferredFilenameExtension else { return name }
        return "\(name.isEmpty ? "Запись" : name).\(suffix)"
    }

    /// Что вышло при приёме нескольких файлов: принятые — в том порядке, в каком пришли,
    /// и отказанные — с причиной для человека.
    struct StagingReport: Equatable, Sendable {
        var staged: [URL] = []
        var rejected: [Rejection] = []

        struct Rejection: Equatable, Sendable {
            let name: String
            let message: String
        }
    }

    /// Принимает файлы **по одному**: негодный не отменяет остальных. Раньше выбор из
    /// пяти файлов, где один оказался `.ogg`, падал целиком, а четыре уже скопированных
    /// оставались лежать в промежуточной папке и всплывали при следующем открытии.
    @discardableResult
    static func stageAll(_ sources: [URL]) -> StagingReport {
        var report = StagingReport()
        for source in sources {
            do {
                report.staged.append(try stage(source))
            } catch {
                report.rejected.append(.init(name: source.lastPathComponent, message: error.localizedDescription))
            }
        }
        return report
    }

    /// Всё, что система успела положить в `Documents/Inbox` мимо `onOpenURL` —
    /// например, пока приложение было закрыто, — вместе с тем, что пришлось отвергнуть.
    ///
    /// Папка после разбора удаляется целиком, а не просто пустеет: `Documents`
    /// виден в «Файлах», и «Inbox — 0 объектов» стоял бы там рядом с рабочей
    /// папкой как след служебной кухни. Система заведёт её заново, когда
    /// в следующий раз что-нибудь принесут.
    ///
    /// Кроме одного случая: файл, который принять не вышло по причине, не связанной с
    /// форматом (нет места, сбой диска), остаётся там, где лежал, и вместе с ним папка —
    /// это лучше, чем тихо стереть то, что человек отправил в Lori. Следующий разбор
    /// попробует снова.
    static func collectSystemInbox() -> StagingReport {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: systemInbox,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var report = StagingReport()
        var keepFolder = false
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                report.staged.append(try stage(file))
            } catch {
                if !(error is ImportError) { keepFolder = true }
                report.rejected.append(.init(name: file.lastPathComponent, message: error.localizedDescription))
            }
        }
        if !keepFolder { try? FileManager.default.removeItem(at: systemInbox) }
        return report
    }

    /// То же, но без отчёта об отказанных: прежний вызов интерфейса. Причины отказа при
    /// этом не теряются бесследно — они пишутся в журнал работы.
    @discardableResult
    static func drainSystemInbox() -> [URL] {
        collectSystemInbox().staged
    }

    /// Что ждёт прикрепления к панели, от старого к новому.
    static func waiting() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.sorted { left, right in
            (modified(left) ?? .distantPast) < (modified(right) ?? .distantPast)
        }
    }

    // MARK: - Уборка

    /// Файл больше не нужен: его либо отправили в работу, либо человек снял
    /// крестиком. Чужие адреса не трогаются — удаляется только своё.
    static func forget(_ url: URL) {
        guard url.path.hasPrefix(staging.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func isStaged(_ url: URL) -> Bool {
        url.path.hasPrefix(staging.path)
    }

    private static func isInSystemInbox(_ url: URL) -> Bool {
        url.path.hasPrefix(systemInbox.path)
    }

    /// Чистый старт для UI-тестов. Принесённый файл намеренно переживает
    /// перезапуск — его же принесли, пока приложение было закрыто, — но тест
    /// обязан начинать с известного состояния, иначе прикреплённое с прошлого
    /// прогона поднимает панель в другое состояние, и падает половина набора.
    static var isResetRequested: Bool {
        RecoveryProbe.allowsDiagnostics(in: Bundle.main.bundleIdentifier)
            && ProcessInfo.processInfo.arguments.contains("--forget-attachments")
    }

    static func forgetEverything() {
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.removeItem(at: systemInbox)
    }

    // MARK: - Имена

    /// Свободное имя в промежуточной папке: два «Новая запись.m4a» подряд не должны
    /// затирать друг друга. Общее для всех входов — и для вставки из буфера тоже:
    /// раньше она называла файлы по секундам, и несколько вставленных за одну секунду
    /// сливались в один.
    ///
    /// Имя берётся как дано, с одной чисткой: «/» в нём превратился бы во вложенную
    /// папку, а точка в начале сделала бы файл скрытым — такой не попал бы в список.
    static func free(named name: String) -> URL {
        let cleaned = cleanFileName(name)
        let candidate = staging.appending(path: cleaned.isEmpty ? "Запись.m4a" : cleaned)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let base = candidate.deletingPathExtension().lastPathComponent
        let suffix = candidate.pathExtension
        for index in 2...99 {
            let next = staging.appending(path: suffix.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(suffix)")
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        return staging.appending(path: "\(base) \(UUID().uuidString).\(suffix)")
    }

    static func cleanFileName(_ raw: String) -> String {
        var name = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return name
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

/// Отказ при приёме файла. Тексты — для человека: они показываются прямо в панели.
enum ImportError: LocalizedError, Equatable, Sendable {
    /// Формата нет среди тех, что приложение расшифровывает.
    case unsupportedFormat(fileName: String)
    /// Файл принят, но очередь расшифровки сохранить не удалось (нет места, файл закрыт
    /// защитой данных). Импорт при этом откатывается: запись не остаётся «Без расшифровки».
    case queueUnavailable(fileName: String)

    var errorDescription: String? {
        switch self {
        case let .queueUnavailable(fileName):
            return "«\(fileName)» не поставлена в очередь: не удалось сохранить очередь. Освободи место на телефоне и попробуй снова — файл остался прикреплённым."
        case let .unsupportedFormat(fileName):
            let suffix = (fileName as NSString).pathExtension.lowercased()
            let what = suffix.isEmpty
                ? "У файла «\(fileName)» нет расширения, и по нему не понять, что это за запись."
                : "Формат «.\(suffix)» (файл «\(fileName)») Lori не расшифровывает."
            return "\(what) Поддерживаются: \(ImportInbox.supportedFormatsTitle). Пересохрани запись в одном из них и добавь снова."
        }
    }
}
