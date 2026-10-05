import AppIntents
import Foundation

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

    // MARK: - Приём

    /// Переносит пришедший файл в промежуточную папку и отдаёт новый адрес.
    ///
    /// Копия обязательна во всех случаях. Из `Documents/Inbox` — потому что папка
    /// видна в «Файлах» и обязана оставаться пустой. Из «Файлов» — потому что
    /// доступ к чужому файлу живёт, пока держат security scope, а между выбором
    /// и нажатием «Расшифровать» проходит сколько угодно времени.
    @discardableResult
    static func stage(_ source: URL) throws -> URL {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let destination = free(named: source.lastPathComponent)

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        // Из Inbox файл именно переносится: он уже наш, и копия оставила бы
        // оригинал лежать на виду в «Файлах».
        if source.path.hasPrefix(systemInbox.path) {
            try FileManager.default.moveItem(at: source, to: destination)
        } else {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return destination
    }

    /// Тот же приём для Быстрых команд: файл приходит данными, а не адресом.
    @discardableResult
    static func stage(_ file: IntentFile) throws -> URL {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let destination = free(named: file.filename)
        try file.data.write(to: destination, options: .atomic)
        return destination
    }

    /// Всё, что система успела положить в `Documents/Inbox` мимо `onOpenURL` —
    /// например, пока приложение было закрыто.
    ///
    /// Папка после разбора удаляется целиком, а не просто пустеет: `Documents`
    /// виден в «Файлах», и «Inbox — 0 объектов» стоял бы там рядом с рабочей
    /// папкой как след служебной кухни. Система заведёт её заново, когда
    /// в следующий раз что-нибудь принесут.
    @discardableResult
    static func drainSystemInbox() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: systemInbox,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let taken = files.compactMap { try? stage($0) }
        try? FileManager.default.removeItem(at: systemInbox)
        return taken
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

    /// Два «Новая запись.m4a» подряд не должны затирать друг друга.
    private static func free(named name: String) -> URL {
        let candidate = staging.appending(path: name.isEmpty ? "Запись.m4a" : name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let base = candidate.deletingPathExtension().lastPathComponent
        let suffix = candidate.pathExtension
        for index in 2...99 {
            let next = staging.appending(path: suffix.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(suffix)")
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        return staging.appending(path: "\(base) \(UUID().uuidString).\(suffix)")
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
