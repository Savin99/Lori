import AVFoundation
import Foundation

/// Почему запись стоит на паузе. Слова — для островка и строки в приложении:
/// «Пауза · звонок». Причина не прячется: запись, вставшая сама, без объяснения
/// выглядела бы поломкой.
enum RecordingPauseReason: String, Codable, Sendable, Equatable {
    /// Нажал человек — объяснять нечего.
    case user
    /// Звонок: по телефону, FaceTime, мессенджеру — у iOS это одно и то же прерывание.
    case call
    /// Звук забрало другое приложение (будильник, Siri, чужая запись).
    case otherApp
    /// Пропал вход: отключились наушники с микрофоном, закрыт чехол iPad.
    case microphoneLost
    /// «Продолжить» не вышло: микрофон занят (обычно звонок ещё идёт).
    case microphoneBusy
    /// Сбой звуковой системы или кодировщика.
    case audioFailure
    /// Процесс Lori умер посреди записи, а при запуске запись поднята с диска.
    case relaunch

    /// Слова после «Пауза · ». `nil` — паузу поставил человек.
    var words: String? {
        switch self {
        case .user: nil
        case .call: "звонок"
        case .otherApp: "другое приложение"
        case .microphoneLost: "микрофон отключён"
        case .microphoneBusy: "микрофон занят"
        case .audioFailure: "сбой звука"
        case .relaunch: "приложение перезапускалось"
        }
    }

    /// Слова, когда прерывание кончилось, а запись по решению владельца ждёт
    /// «Продолжить»: островок говорит, что продолжать уже можно.
    var endedWords: String? {
        switch self {
        case .call: "звонок закончился"
        case .otherApp: "звук освободился"
        default: words
        }
    }
}

/// Незаконченная запись на диске: куски, состояние, причина паузы.
///
/// Запись идёт кусками: каждый непрерывный отрезок между паузами — свой файл, и он
/// закрывается (`AVAudioRecorder.stop()` дописывает оглавление m4a) при любой паузе.
/// Кусок, брошенный открытым, — это m4a без `moov`, его не прочитает ничто. Поэтому
/// запись, прерванная звонком, а потом убитая системой в фоне, переживает это целиком:
/// все её куски уже закрыты.
///
/// Файл лежит в `Application Support/Lori/Recording`, а не в рабочей папке: в
/// «Файлах» и в списке записей не должно быть недописанных кусков. В список запись
/// попадает целиком, когда её закончили.
struct RecordingSession: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case recording
        case paused
    }

    struct Chunk: Codable, Equatable, Sendable {
        /// Имя файла в папке сессии.
        var file: String
        /// Длительность закрытого куска по самому файлу.
        var duration: TimeInterval
    }

    var id: UUID
    /// Начало записи — из него имя файла в `Recordings/`, как и раньше.
    var startedAt: Date
    var state: State
    var reason: RecordingPauseReason?
    /// Прерывание кончилось — можно продолжать (запись при этом ждёт человека).
    var interruptionEnded: Bool
    /// Закрытые куски по порядку.
    var chunks: [Chunk]
    /// Кусок, который пишется сейчас. Записывается в файл **до** начала записи: убитый
    /// процесс оставит след, и при запуске будет ясно, какой файл был открыт.
    var active: String?
    /// Запись поднята с диска после перезапуска Lori.
    var restored: Bool
    /// Сколько кусков пришлось отложить в корзину нечитаемыми (процесс умер посреди
    /// куска). Нужен, чтобы сказать об этом словами, а не молча.
    var lostChunks: Int

    init(id: UUID = UUID(), startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
        state = .recording
        reason = nil
        interruptionEnded = false
        chunks = []
        active = nil
        restored = false
        lostChunks = 0
    }

    /// Длительность закрытых кусков. Идущий кусок прибавляет рекордер.
    var recorded: TimeInterval { chunks.reduce(0) { $0 + $1.duration } }

    /// Имя следующего куска: номера не повторяются, даже если кусок отложен в корзину.
    var nextChunkName: String {
        "part-\(chunks.count + lostChunks + 1).m4a"
    }

    /// Слова причины для островка и приложения.
    var reasonWords: String? {
        guard let reason else { return nil }
        return interruptionEnded ? reason.endedWords : reason.words
    }
}

/// Файл сессии и её куски.
struct RecordingSessionStore: Sendable {
    let directory: URL

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Lori", directoryHint: .isDirectory)
            .appending(path: "Recording", directoryHint: .isDirectory)
    }

    init(directory: URL = RecordingSessionStore.defaultDirectory) {
        self.directory = directory
    }

    var sessionURL: URL { directory.appending(path: "session.json") }

    func url(for chunk: String) -> URL { directory.appending(path: chunk) }

    func load() -> RecordingSession? {
        guard let data = try? Data(contentsOf: sessionURL) else { return nil }
        return try? JSONDecoder.recording.decode(RecordingSession.self, from: data)
    }

    /// Пишется атомарно и с защитой «до первой разблокировки»: запись идёт и на
    /// запертом телефоне, а файл с защитой `complete` на запертом не открылся бы.
    func save(_ session: RecordingSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.recording.encode(session)
        try data.write(to: sessionURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Убирает папку сессии целиком — после того, как куски переехали в список или в корзину.
    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Остатки прерванной склейки: временный файл, который не успел стать записью.
    func removeLeftovers() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(RecordingAssembler.temporaryPrefix) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}

private extension JSONEncoder {
    static var recording: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var recording: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Длительность аудиофайла по самому файлу, или `nil`, если файл не читается.
///
/// Это же — проверка, закрыт ли кусок: у m4a без оглавления `AVAudioFile` не
/// открывается вовсе. Открытие читает только заголовок, для часовой записи это дёшево.
enum RecordingAudio {
    static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }
}
