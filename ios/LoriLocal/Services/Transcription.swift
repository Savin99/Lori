import AVFoundation
import Foundation
import Speech

enum TranscriptionError: LocalizedError, Equatable {
    case notAudio
    case localeUnavailable(String)
    case emptyResult
    case engineNotInstalled(String)
    case permissionDenied
    case assetsUnavailable
    case modelsMissing
    /// Модель Whisper не лежит в Lori/Models. Отдельно от `modelsMissing`:
    /// у GigaAM есть кнопка «Скачать», а Whisper приносят руками.
    case whisperModelMissing
    /// Папка модели есть, но в ней не хватает файла — движок бы пошёл за ним в сеть.
    case modelIncomplete(String, String)
    case missingKey(KeychainAccount)
    case api(String)
    case badResponse(String)
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .notAudio:
            "Расшифровать можно только аудиофайл."
        case let .localeUnavailable(identifier):
            "Локальная модель распознавания для \(identifier) не установлена на этом устройстве. Скачай язык для диктовки в настройках iOS и повтори."
        case .emptyResult:
            "В файле не удалось распознать речь."
        case let .engineNotInstalled(name):
            "Движок «\(name)» пока не установлен в приложении."
        case .permissionDenied:
            "Разреши Lori распознавание речи в настройках iPhone."
        case .assetsUnavailable:
            "На этом устройстве нет моделей распознавания речи. В симуляторе iOS их нет вообще — расшифровка работает только на настоящем iPhone."
        case .modelsMissing:
            "Модель GigaAM ещё не скачана. Настройки → Движок → «Скачать модель», или выбери другой движок."
        case .whisperModelMissing:
            "Модель Whisper не найдена. Положи папку модели в «Файлы» → Lori → Models: приложение её не качает — это 632 МБ."
        case let .modelIncomplete(name, file):
            "Папке модели движка «\(name)» не хватает файла «\(file)». Без него расшифровка пошла бы за ним в сеть."
        case let .missingKey(account):
            "Ключ \(account.title) не сохранён. Настройки → Движок → Провайдер → вставь ключ в поле «Ключ API»."
        case let .api(message):
            message
        case let .badResponse(message):
            message
        case .exportFailed:
            "Не удалось нарезать длинную запись на части для отправки в API."
        }
    }
}

protocol Transcribing: Sendable {
    /// Показывается в настройках, чтобы было видно, чем именно расшифровано.
    var name: String { get }
    func isAvailable() async -> Bool
    /// `progress` вызывается по мере обработки кусков длинного файла.
    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript

    /// Готовая часть текста по ходу работы. Реализуют движки, которые идут
    /// кусками: у них текст можно показывать, не дожидаясь конца. Движку,
    /// который отвечает одним запросом, показывать нечего — отсюда значение
    /// по умолчанию, а не обязательный метод.
    func transcribe(
        audioURL: URL,
        progress: @Sendable (Int, Int) -> Void,
        partial: @Sendable (Transcript) -> Void
    ) async throws -> Transcript

    /// Чем движок занят прямо сейчас, словами. Нужен там, где до первого куска
    /// проходят минуты: Whisper готовит 618 МБ весов под Neural Engine, и всё это
    /// время «готовлю аудио» на экране выглядит как зависшее приложение — владелец
    /// на этом уже спотыкался. Реализуют только те, кому есть что сказать.
    func transcribe(
        audioURL: URL,
        progress: @Sendable (Int, Int) -> Void,
        partial: @Sendable (Transcript) -> Void,
        note: @Sendable (String) -> Void
    ) async throws -> Transcript
}

extension Transcribing {
    func transcribe(audioURL: URL) async throws -> Transcript {
        try await transcribe(audioURL: audioURL) { _, _ in }
    }

    func transcribe(
        audioURL: URL,
        progress: @Sendable (Int, Int) -> Void,
        partial: @Sendable (Transcript) -> Void
    ) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, progress: progress)
    }

    func transcribe(
        audioURL: URL,
        progress: @Sendable (Int, Int) -> Void,
        partial: @Sendable (Transcript) -> Void,
        note: @Sendable (String) -> Void
    ) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, progress: progress, partial: partial)
    }
}

/// Движок Apple. На iOS 26 это `SpeechAnalyzer` — он рассчитан на длинные файлы;
/// на более старых системах остаётся `SFSpeechURLRecognitionRequest` с его лимитом диктовки.
/// Аудио не покидает устройство ни в одном из путей.
struct AppleSpeechTranscriber: Transcribing {
    let locale: Locale

    init(locale: Locale = Locale(identifier: "ru_RU")) {
        self.locale = locale
    }

    var name: String {
        if #available(iOS 26.0, *) { return "Apple SpeechAnalyzer, на устройстве" }
        return "Apple Speech, на устройстве"
    }

    /// Движок выбирается по языку, а не по версии iOS. Замер на iPhone 17/iOS 26.5:
    /// `SpeechTranscriber` знает 30 локалей, и русского среди них нет, а
    /// `supportedLocale(equivalentTo:)` всё равно отвечает «ru-RU» — доверять ему нельзя,
    /// иначе приложение уходит качать несуществующий ассет `transcription.ru`.
    /// Русский умеет только классический `SFSpeechRecognizer`, зато прямо на устройстве.
    func isAvailable() async -> Bool {
        if #available(iOS 26.0, *), await Self.analyzerSupports(locale) { return true }
        guard await Self.authorize() else { return false }
        let recognizer = SFSpeechRecognizer(locale: locale)
        return recognizer?.isAvailable == true && recognizer?.supportsOnDeviceRecognition == true
    }

    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript {
        if #available(iOS 26.0, *), await Self.analyzerSupports(locale) {
            return Transcript(text: try await analyze(audioURL))
        }
        guard await Self.authorize() else { throw TranscriptionError.permissionDenied }
        return try await legacyRecognize(audioURL, progress: progress)
    }

    /// Проверка по фактическому списку локалей: сравниваем и полный тег, и язык целиком,
    /// чтобы `ru_RU` совпало с любым русским вариантом, если он когда-нибудь появится.
    @available(iOS 26.0, *)
    private static func analyzerSupports(_ locale: Locale) async -> Bool {
        let wanted = locale.identifier(.bcp47)
        let language = wanted.split(separator: "-").first.map(String.init) ?? wanted
        return await SpeechTranscriber.supportedLocales.contains { candidate in
            let identifier = candidate.identifier(.bcp47)
            return identifier == wanted || identifier.hasPrefix("\(language)-") || identifier == language
        }
    }

    @available(iOS 26.0, *)
    private func analyze(_ audioURL: URL) async throws -> String {
        guard await Self.analyzerSupports(locale),
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.localeUnavailable(locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)

        // Локаль нужно сначала зарезервировать: без этого система отвечает
        // «not subscribed to transcription.<язык>» и статус модели не проверить.
        let installed = await SpeechTranscriber.installedLocales.contains {
            $0.identifier(.bcp47) == supported.identifier(.bcp47)
        }
        if !installed {
            let reserved = await AssetInventory.reservedLocales.contains {
                $0.identifier(.bcp47) == supported.identifier(.bcp47)
            }
            if !reserved {
                guard try await AssetInventory.reserve(locale: supported) else {
                    throw TranscriptionError.localeUnavailable(supported.identifier)
                }
            }
            // Модель докачивает система, а не приложение.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: audioURL)

        // Чтение результатов должно идти параллельно разбору файла.
        let collected = Task {
            var text = AttributedString()
            for try await result in transcriber.results {
                text += result.text
            }
            return String(text.characters)
        }

        do {
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collected.cancel()
            throw error
        }

        let text = try await collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyResult }
        return text
    }

    /// Классический распознаватель рассчитан на короткую диктовку, поэтому длинный
    /// файл режется на куски по тишине и склеивается обратно.
    private func legacyRecognize(
        _ audioURL: URL,
        progress: @Sendable (Int, Int) -> Void
    ) async throws -> Transcript {
        let samples = try AudioSamples.load(from: audioURL)
        guard !samples.isEmpty else { throw TranscriptionError.emptyResult }

        let chunker = AudioChunker()
        let ranges = chunker.bounds(for: samples)
        if ranges.count <= 1 {
            progress(0, 1)
            let recognized = try await recognize(fileAt: audioURL)
            progress(1, 1)
            guard !recognized.text.isEmpty else { throw TranscriptionError.emptyResult }
            return recognized
        }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "lori-chunks-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let assembler = TranscriptAssembler()
        var parts: [String] = []
        var words: [TranscriptWord] = []
        var coveredUntil: TimeInterval = 0
        for (index, range) in ranges.enumerated() {
            progress(index, ranges.count)
            let chunkURL = directory.appending(path: "chunk-\(index).wav")
            try AudioChunker.write(
                samples: samples[range],
                sampleRate: AudioSamples.sampleRate,
                to: chunkURL
            )
            // Пустой кусок — это тишина, а не ошибка: продолжаем со следующим.
            guard let piece = try? await recognize(fileAt: chunkURL), !piece.text.isEmpty else {
                continue
            }
            // Время внутри куска сдвигается на его начало в исходном файле.
            let offset = Double(range.lowerBound) / AudioSamples.sampleRate
            let shifted = piece.words.map {
                TranscriptWord(start: $0.start + offset, end: $0.end + offset, text: $0.text)
            }
            if shifted.isEmpty {
                parts.append(piece.text)
            } else {
                assembler.merge(into: &words, words: shifted, coveredUntil: coveredUntil)
            }
            coveredUntil = max(coveredUntil, Double(range.upperBound) / AudioSamples.sampleRate)
        }
        progress(ranges.count, ranges.count)

        if !words.isEmpty {
            let assembled = assembler.transcript(from: words)
            guard !assembled.text.isEmpty else { throw TranscriptionError.emptyResult }
            return assembled
        }
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { throw TranscriptionError.emptyResult }
        return Transcript(text: joined)
    }

    private func recognize(fileAt audioURL: URL) async throws -> Transcript {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.localeUnavailable(locale.identifier)
        }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        let collector = RecognitionCollector()
        return try await withCheckedThrowingContinuation { continuation in
            collector.attach(continuation)
            // Задача держится коллектором: без сильной ссылки распознавание обрывается.
            collector.task = recognizer.recognitionTask(with: request, delegate: collector)
        }
    }

    private static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        }
    }
}

/// Собирает все результаты распознавания одного файла.
///
/// Распознаватель отдаёт не один финальный результат, а несколько — по репликам.
/// Раньше код завершался на первом и выбрасывал остальное: на записи в шесть минут
/// оставалось около сотни символов вместо всего текста.
private final class RecognitionCollector: NSObject, SFSpeechRecognitionTaskDelegate, @unchecked Sendable {
    var task: SFSpeechRecognitionTask?

    private let lock = NSLock()
    private var parts: [String] = []
    private var words: [TranscriptWord] = []
    private var continuation: CheckedContinuation<Transcript, Error>?
    private var finished = false

    func attach(_ continuation: CheckedContinuation<Transcript, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func speechRecognitionTask(
        _ task: SFSpeechRecognitionTask,
        didFinishRecognition result: SFSpeechRecognitionResult
    ) {
        let transcription = result.bestTranscription
        let text = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        lock.lock()
        // Результаты бывают накопительными: тогда новый включает предыдущий целиком.
        if let last = parts.last, text.hasPrefix(last) {
            parts[parts.count - 1] = text
            words.removeAll()
        } else {
            parts.append(text)
        }
        // У движка Apple каждый сегмент — это слово со временем.
        words.append(contentsOf: transcription.segments.compactMap { segment in
            let piece = segment.substring.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty, segment.duration > 0 else { return nil }
            return TranscriptWord(
                start: segment.timestamp,
                end: segment.timestamp + segment.duration,
                text: piece
            )
        })
        lock.unlock()
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
        finish(error: successfully ? nil : task.error)
    }

    func speechRecognitionTaskWasCancelled(_ task: SFSpeechRecognitionTask) {
        finish(error: task.error)
    }

    private func finish(error: Error?) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Если движок не дал таймингов, отдаём только текст.
        let transcript = words.isEmpty
            ? Transcript(text: joined)
            : TranscriptAssembler().transcript(from: words)
        lock.unlock()

        // Пустой результат при отсутствии ошибки — это тишина, а не сбой.
        if let error, joined.isEmpty {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: transcript)
        }
    }
}

/// Что с записью прямо сейчас — одним значением.
///
/// Раньше карточка собирала это из пяти коллекций сервиса (`running`, `queued`,
/// `interrupted`, `failed`, `waitingForMemory`), и между «вышла из очереди» и «вошла в
/// работу» у записи не было ни одной отметки: на секунды она числилась нигде, и
/// карточка мигала «Без расшифровки». Здесь у этого промежутка есть имя — `starting`.
enum TranscriptionRecordState: Equatable, Sendable {
    /// Ни в очереди, ни в работе, ни с пометкой.
    case idle
    /// Ждёт своей очереди. `position` считается с единицы: 1 — пойдёт следующей.
    case queued(position: Int, waitsForMemory: Bool)
    /// Взята из очереди, но в работу ещё не вошла: сервис освобождает память от модели
    /// заголовков и проверяет, на месте ли движок.
    case starting
    case running
    /// Облачная запись одним запросом, и тело запроса сейчас уходит: доля — сколько его
    /// отправила система (`TransferPhase.sentShare`; nil — объём системе неизвестен).
    /// Это **не** доля расшифровки, поэтому отдельное состояние, а не `running` с
    /// процентами: «Расшифровываю · 100%» в конце загрузки было бы враньём.
    case sending(Double?)
    /// Запись у сервиса — тело ушло целиком, — и ждём его ответ. Сюда же попадает
    /// облачная запись, которую оставили ждать, когда фоновое время кончилось: запрос
    /// у системной передачи, ответ разбудит приложение (`interruptEverything`).
    case awaitingService
    /// Работу оборвала система; запись встанет в очередь заново при возвращении.
    case interrupted
    /// Последняя попытка кончилась ошибкой; текст — для человека.
    case failed(String)

    /// Запись занята: ждёт, запускается или считается. На такой карточке нельзя
    /// показывать «Без расшифровки» и предлагать «Расшифровать».
    var isActive: Bool {
        switch self {
        case .queued, .starting, .running, .sending, .awaitingService: true
        case .idle, .interrupted, .failed: false
        }
    }
}

/// Итог одной пачки: от первой поставленной записи до момента, когда очередь опустела.
///
/// Нужен двум читателям. Фоновой задаче — чтобы сказать системе «успешно или нет» по
/// **этой** пачке: раньше она смотрела на общий словарь ошибок, который никто не
/// чистил, и одна старая ошибка делала неудачной каждую следующую пачку. Экрану — чтобы
/// сказать человеку итог: «4 из 5, одна не удалась».
struct TranscriptionBatchOutcome: Equatable, Sendable {
    /// Сколько записей вошло в пачку за всё время (с учётом поставленных по ходу).
    var total = 0
    var succeeded: [String] = []
    /// Пути записей, на которых расшифровка кончилась ошибкой; текст — в `error(for:)`.
    var failed: [String] = []
    /// Записи, которые оборвала система (или связь); они встанут в очередь заново.
    var interrupted: [String] = []
    /// Записи, которые человек снял сам, — ни успех, ни ошибка.
    var cancelled = 0

    /// Без ошибок и без обрывов. Отмена человеком сюда не входит: это не сбой.
    var isClean: Bool { failed.isEmpty && interrupted.isEmpty }
}

/// Состояние расшифровки для интерфейса: какие файлы в работе и чем расшифровываем.
///
/// Движок берётся из настроек и **не подменяется молча**: если выбран GigaAM, а моделей
/// нет, приложение говорит об этом, а не отправляет запись в облако за спиной человека.
///
/// Записи идут **по одной**: `TranscriptionSettings.concurrency` по умолчанию единица,
/// остальные ждут в очереди. Настройкой предел поднимается до трёх — тогда считается
/// сразу несколько **разных** записей. Разрезать одну запись между локальными движками
/// смысла нет: они делят один процессор, и сумма времени от этого не уменьшается.
///
/// Несколько записей сразу безопасны по памяти только потому, что веса модели у них
/// общие (`EngineSessionCache`); перед запуском второй локальной проверяется, сколько
/// памяти осталось.
@MainActor
final class TranscriptionService: ObservableObject {
    @Published private(set) var running: Set<String> = []
    /// Записи, которые уже вышли из очереди, но ещё не вошли в `running`: перед
    /// расшифровкой сервис ждёт, пока освободят память от модели заголовков, и
    /// проверяет движок. Окно короткое, но видимое — без этой отметки запись на это
    /// время пропадала и из «В очереди», и из «Расшифровывается».
    @Published private(set) var starting: Set<String> = []
    /// Что ждёт своей очереди — либо свободного места, либо памяти.
    @Published private(set) var queued: [String] = []
    /// Записи, которые ждут именно памяти. «В очереди» и «жду память» — разные вещи:
    /// первое пройдёт само, второе может не пройти вовсе, и человек вправе это видеть.
    @Published private(set) var waitingForMemory: Set<String> = []
    /// Записи, чью работу оборвала система, а не движок и не человек. Переживают
    /// перезапуск и при следующем открытии встают в очередь заново.
    @Published private(set) var interrupted: Set<String> = []
    /// Последняя ошибка по записи: карточка должна показывать «Ошибка», а не пустоту.
    @Published private(set) var failed: [String: String] = [:]
    /// Человекочитаемый прогресс по пути файла: «3 из 7».
    @Published private(set) var progress: [String: String] = [:]
    /// Та же доля числом, от 0 до 1 — кольцу в интерфейсе нужна она, а не строка.
    /// Разбирать «3 из 7» обратно во вьюхе было бы ломко: строка ещё и локализованная.
    @Published private(set) var fraction: [String: Double] = [:]
    /// Текст, готовый на данный момент: экран записи показывает его сразу,
    /// не дожидаясь конца расшифровки.
    @Published private(set) var partial: [String: Transcript] = [:]
    /// Сколько ещё ждать. Считается по факту: сколько времени ушло на готовую
    /// долю работы — движки об этом ничего не знают.
    @Published private(set) var remaining: [String: TimeInterval] = [:]
    /// Последний удачный прогон: сколько длилась запись и сколько заняла работа.
    /// Сервис только меряет — куда это складывать, решает экран (`TranscriptionSpeed`).
    @Published private(set) var lastMeasure: SpeedMeasure?
    @Published var lastError: String?

    /// Сколько записей в нынешней пачке и сколько из них обработано — «2 из 5».
    ///
    /// Пачка начинается с первой поставленной записи и кончается, когда очередь
    /// опустела: тогда оба числа обнуляются, а итог остаётся в `lastBatch`. Записи,
    /// добавленные по ходу, входят в ту же пачку; снятые человеком и оборванные
    /// системой из счёта выходят — их «из» уже не ждёт. Обработанная — это и
    /// расшифрованная, и закончившаяся ошибкой: очередь прошла и мимо неё.
    @Published private(set) var batchTotal = 0
    @Published private(set) var batchDone = 0
    /// Итог последней законченной пачки. Живёт до следующей законченной, а не до
    /// начала новой: фоновая задача читает его уже после того, как очередь опустела,
    /// и в этот промежуток успевает вклиниться следующая пачка.
    @Published private(set) var lastBatch: TranscriptionBatchOutcome?
    /// Где сейчас запрос облачной записи — по счёту системной передачи
    /// (`BackgroundTranscriptionTransport.report`). Пусто — запроса нет: запись готовит
    /// аудио, разбирает ответ или считается на телефоне.
    @Published private(set) var transfer: [String: TransferPhase] = [:]

    private struct Job {
        let entry: WorkspaceEntry
        let configuration: TranscriptionJob
        var kind: TranscriptionEngineKind { configuration.kind }
        let workspace: WorkspaceStore
    }

    /// Можно ли брать запись в работу прямо сейчас.
    private enum Admission {
        case go
        /// Мест нет — пройдёт само, как только освободится.
        case lane
        /// Памяти не хватает на второй прогон. Может не пройти вовсе.
        case memory
    }

    private let engines: [TranscriptionEngineKind: any Transcribing]
    /// Сколько памяти ещё можно занять. Отдельным замыканием, потому что в тестах
    /// настоящее значение подделать нечем: в симуляторе лимита нет вовсе.
    private let availableMemory: @MainActor () -> UInt64
    private let interruptedStore: URL

    /// Фоновое сопровождение пачки. Слабая ссылка: полоса — это про показ, и сервис
    /// обязан считать одинаково хорошо и без неё (симулятор, iOS ниже 26, отказ системы).
    weak var runway: TranscriptionRunway?

    private var waiting: [Job] = []
    /// Была ли пачка. Нужно, чтобы «очередь опустела» случалось один раз на пачку,
    /// а не на каждый холостой вызов планировщика.
    private var busy = false
    /// По задаче на запись. Раньше задача была одна на весь сервис, и «Отменить» у
    /// одной записи снимало ту, что шла, — не обязательно ту, которую попросили.
    private var active: [String: Task<Void, Never>] = [:]
    /// Кого сняли не по просьбе человека, а потому что систему всё это перестало устраивать.
    private var interrupting: Set<String> = []
    /// Кто сейчас в работе и каким движком — в файле, а не только в памяти.
    ///
    /// Смахнули приложение из переключателя задач — обработчик истечения не зовут
    /// вовсе, процесса уже нет. Единственный способ узнать об этом потом: писать в
    /// файл на старте записи и стирать на её конце. Что осталось в файле — то и
    /// оборвалось.
    private var inFlight: [String: TranscriptionEngineKind] = [:]
    private var configurations: [String: TranscriptionJob] = [:]
    /// Уведомление после записи файла не зависит от существования SwiftUI-экрана.
    var didSaveTranscript: ((String, String) -> Void)?
    var didDrain: (() -> Void)?
    var willStart: (() async -> Void)?
    private var connectionRetries: [String: Int] = [:]
    private var foreground = true
    private weak var recoveryWorkspace: WorkspaceStore?
    private var resumeOnReturn: Set<String> = []
    private var drainWaiters: [CheckedContinuation<TranscriptionBatchOutcome?, Never>] = []
    /// Исходы нынешней пачки по мере накопления; `total` здесь — сколько вошло.
    private var batch = TranscriptionBatchOutcome()
    /// Записи пачки, у которых исхода ещё нет. Запись, снятая или оборванная до конца,
    /// отсюда уходит сразу — иначе её закончившаяся позже работа посчиталась бы дважды.
    private var batchLive: Set<String> = []
    /// Записи, которые сняли, пока их работа шла: задача отменена, но движок ещё
    /// сворачивается, и `active` держит место. Пока так, на эту же запись нельзя запустить
    /// вторую работу и нельзя считать её «прерванной системой».
    private var cancelling: Set<String> = []

    /// Просьба поставить запись заново, пришедшая, пока прежняя работа над ней
    /// сворачивается после отмены. Молча отказать значило бы потерять нажатие;
    /// запустить вторую работу поверх первой — перепутать их итоги. Поднимается, когда
    /// прежняя закончилась.
    private struct Restart {
        let entry: WorkspaceEntry
        let workspace: WorkspaceStore
        let kind: TranscriptionEngineKind?
    }
    private var restartAfterCancel: [String: Restart] = [:]

    /// Что сервис спрашивает у системной фоновой передачи. Отдельной структурой: тест
    /// подменяет её, не трогая настоящую фоновую сессию (подставной `URLProtocol` в неё
    /// не встаёт — «Only HTTP and HTTPS protocols are supported (no custom protocols)»).
    struct SystemTransfers {
        /// Лежит ли сейчас у системы запрос задания (по id задания).
        var holds: @MainActor (String) -> Bool = { BackgroundTranscriptionTransport.shared.holdsTransfer(forJob: $0) }
        /// Пришёл ли по заданию ответ, лежащий распиской.
        var hasAnswer: @MainActor (String) -> Bool = { BackgroundTranscriptionTransport.shared.hasAnswer(forJob: $0) }
        /// Отказался ли транспорт начать новую отправку в режиме «только готовые ответы».
        var takeDeferral: @MainActor (String) -> Bool = { BackgroundTranscriptionTransport.shared.takeDeferral(forJob: $0) }
    }

    private let transfers: SystemTransfers
    /// Облачные записи, которые оставили ждать ответ системы, когда фоновое время
    /// кончилось (`interruptEverything`). Их Swift-задача не отменена и спит вместе с
    /// процессом; разбудит её ответ сервиса.
    private var parked: Set<String> = []
    /// Записи, поднятые пробуждением системы после убитого процесса: доделываются только
    /// готовыми ответами, без новой отправки (`BackgroundTranscriptionTransport.answersOnly`).
    private var answersOnly: Set<String> = []
    /// Куски движка «done из total» как есть — доля для полосы фоновой задачи складывается
    /// из них и из фазы запроса текущего куска (`backgroundShare`).
    private var parts: [String: Parts] = [:]
    /// С какой минуты запрос в нынешней фазе: ожидание ответа меряется от конца загрузки.
    private var transferSince: [String: Date] = [:]

    struct Parts: Equatable, Sendable {
        let done: Int
        let total: Int
    }

    /// Все пять движков создаются сразу: они ничего не занимают до первой расшифровки,
    /// а тестам удобно подменять набор целиком.
    init(
        engines: [TranscriptionEngineKind: any Transcribing]? = nil,
        interruptedStore: URL = InterruptedRecords.url,
        availableMemory: @escaping @MainActor () -> UInt64 = { MemoryReport.availableBytes },
        transfers: SystemTransfers = SystemTransfers()
    ) {
        self.transfers = transfers
        self.engines = engines ?? [
            .gigaam: GigaAMTranscriber(),
            .whisper: WhisperKitTranscriber(),
            .apple: AppleSpeechTranscriber(),
            .openAI: OpenAITranscriber(),
            .gemini: GeminiTranscriber(),
            .elevenLabs: ElevenLabsTranscriber(),
        ]
        self.interruptedStore = interruptedStore
        self.availableMemory = availableMemory
        // Что осталось в файле с прошлого раза — то не досчиталось.
        configurations = InterruptedRecords.jobs(from: interruptedStore)
        inFlight = InterruptedRecords.load(from: interruptedStore)
        interrupted = Set(inFlight.keys)
        // Ошибки прошлых попыток тоже: после перезапуска запись, на которой расшифровка
        // не вышла, обязана выглядеть как «Ошибка», а не как нетронутая.
        failed = InterruptedRecords.failures(from: interruptedStore)
    }

    func engine(for kind: TranscriptionEngineKind) -> any Transcribing {
        engines[kind] ?? AppleSpeechTranscriber()
    }

    /// Название выбранного движка для настроек и карточки записи.
    var selectedName: String { engine(for: TranscriptionSettings.engine).name }

    func isRunning(_ relativePath: String) -> Bool { running.contains(relativePath) }

    func isQueued(_ relativePath: String) -> Bool { queued.contains(relativePath) }

    func isInterrupted(_ relativePath: String) -> Bool { interrupted.contains(relativePath) }

    /// Вышла из очереди, но в работу ещё не вошла — см. `starting`.
    func isStarting(_ relativePath: String) -> Bool { starting.contains(relativePath) }

    /// Запись занята: ждёт в очереди, запускается или считается. Это ровно то, что
    /// карточке нужно знать, чтобы не показать «Без расшифровки» посреди работы.
    func isActive(_ relativePath: String) -> Bool {
        running.contains(relativePath) || starting.contains(relativePath) || isQueued(relativePath)
    }

    /// Место записи в очереди, считая с единицы: 1 — пойдёт следующей. nil — запись не
    /// ждёт (идёт, запускается или вовсе не в очереди). Те, что ждут памяти, тоже
    /// стоят на своём месте: ждать «памяти» им, а не очереди.
    ///
    /// Читается из самой очереди, а не из опубликованного `queued`: это один и тот же
    /// порядок, но источник правды — она.
    func queuePosition(for relativePath: String) -> Int? {
        waiting.firstIndex { $0.entry.relativePath == relativePath }.map { $0 + 1 }
    }

    /// Состояние записи одним значением. Приоритет такой же, как был у карточки:
    /// то, что происходит с записью **сейчас**, важнее того, что случилось раньше —
    /// но «прервано» стоит выше «идёт»: оборванная запись ещё несколько мгновений
    /// сворачивает работу, и карточка не должна всё это время врать «расшифровывается».
    func state(for relativePath: String) -> TranscriptionRecordState {
        if interrupted.contains(relativePath) { return .interrupted }
        if running.contains(relativePath) { return runningState(for: relativePath) }
        if starting.contains(relativePath) { return .starting }
        if let position = queuePosition(for: relativePath) {
            return .queued(position: position, waitsForMemory: waitingForMemory.contains(relativePath))
        }
        if let message = failed[relativePath] { return .failed(message) }
        return .idle
    }

    /// Чем занята идущая запись. Фаза запроса видна только у записи одним запросом: у
    /// записи по частям своя полоса «часть 3 из 9», и метаться между «Отправляю» и
    /// «Расшифровываю» на каждой части она не должна. Оставленная ждать систему — всегда
    /// «жду ответ сервиса»: другого с ней сейчас не происходит.
    private func runningState(for path: String) -> TranscriptionRecordState {
        if parked.contains(path) { return .awaitingService }
        guard fraction[path] == nil else { return .running }
        switch transfer[path] {
        case let phase? where phase.isSending: return .sending(phase.sentShare)
        case .awaiting?: return .awaitingService
        default: return .running
        }
    }

    /// Какая запись считается сейчас: самая давно начатая из идущих и запускающихся.
    /// При одной записи за раз (умолчание) она единственная; при нескольких одновременных
    /// порядок задаёт время начала, а не алфавит — иначе в Dynamic Island название
    /// прыгало бы между записями по первой букве пути.
    var currentPath: String? {
        running.union(starting).min { lhs, rhs in
            let left = startedAt[lhs] ?? .distantFuture
            let right = startedAt[rhs] ?? .distantFuture
            return left == right ? lhs < rhs : left < right
        }
    }

    /// Номер записи, которая сейчас в работе, внутри пачки — «2» из «2 из 5».
    /// Ноль, когда пачки нет. Не выходит за итог: «6 из 5» человек читает как поломку.
    var batchPosition: Int {
        guard batchTotal > 0 else { return 0 }
        return min(batchDone + 1, batchTotal)
    }

    /// «2 из 5»: один и тот же текст в приложении и в Dynamic Island.
    nonisolated static func counter(done: Int, total: Int) -> String {
        "\(min(max(done, 0) + 1, max(total, 1))) из \(max(total, 1))"
    }

    /// Каким движком считали запись, когда её оборвали.
    ///
    /// Экрану это нужно не из любопытства: облачную расшифровку
    /// `resumeInterrupted` сознательно **не** поднимает сама, и сказать об этом
    /// человеку можно, только зная движок.
    func interruptedEngine(for relativePath: String) -> TranscriptionEngineKind? {
        inFlight[relativePath]
    }

    func error(for relativePath: String) -> String? { failed[relativePath] }

    /// Ничего не идёт и ничего не ждёт.
    var isIdle: Bool { active.isEmpty && waiting.isEmpty }

    /// Сколько записей в работе и в очереди — одним числом. Нужно и строке состояния,
    /// и системной полосе прогресса в фоне.
    var batchCount: Int { active.count + waiting.count }

    // MARK: - Очередь

    /// Ставит запись в очередь. Возвращается сразу: интерфейсу нужно показать
    /// «в очереди», а не ждать конца расшифровки.
    ///
    /// Возвращает `false` только тогда, когда запись **не** встала: очередь не
    /// удалось сохранить (нет места, файл закрыт защитой данных). Запись, которая уже
    /// идёт или ждёт, — это `true`: итог тот же, что и просили, она будет расшифрована.
    /// При отказе всё возвращается как было — и ошибка прошлой попытки, и пометка
    /// «Прервано»: человек видит запись такой, какой она и осталась.
    @discardableResult
    func enqueue(_ entry: WorkspaceEntry, in workspace: WorkspaceStore, using kind: TranscriptionEngineKind? = nil) -> Bool {
        recoveryWorkspace = workspace
        let path = entry.relativePath
        if active[path] != nil {
            // Её только что отменили, и движок ещё сворачивается: запомнить просьбу, а не
            // терять — `finish` поднимет запись, когда место освободится.
            if cancelling.contains(path) {
                restartAfterCancel[path] = Restart(entry: entry, workspace: workspace, kind: kind)
            }
            return true
        }
        guard !waiting.contains(where: { $0.entry.relativePath == path }) else { return true }

        let opensBatch = !busy
        let previous = configurations[path]
        let configuration = (kind == nil || previous?.kind == kind ? previous : nil)
            ?? TranscriptionJob.capture(kind: kind ?? TranscriptionSettings.engine)

        // Чтобы откатить при отказе: сохранение идёт раньше, чем запись встаёт в очередь,
        // а лежащее в файле собирается из этих же словарей.
        let priorFailure = failed[path]
        let wasInterrupted = interrupted.contains(path)
        let priorFlight = inFlight[path]
        failed[path] = nil
        forget(interrupted: path)
        configurations[path] = configuration
        inFlight[path] = configuration.kind
        guard persistJobs() else {
            failed[path] = priorFailure
            if wasInterrupted { interrupted.insert(path) }
            configurations[path] = previous
            inFlight[path] = priorFlight
            return false
        }

        busy = true
        batchEnrol(path)
        waiting.append(Job(entry: entry, configuration: configuration, workspace: workspace))
        admit()
        // Просить фон только на переходе «ничего не шло → пошло»: задача одна на всю
        // пачку, а записи, добавленные по ходу, входят в неё же. Исключение — задачу уже
        // закрыли на истечении, а пачка не опустела (облачная запись ждёт ответ системы):
        // тогда новой записи, поставленной по ходу, нужна новая заявка.
        if opensBatch || runway?.wantsSubmission == true { runway?.batchDidStart() }
        // Постановка из фона — «Расшифровать» в Dynamic Island, когда Lori не на экране.
        // `admit` выше ещё не видел запасного окна: его открывает только что `batchDidStart`,
        // и без второго захода запись простояла бы в очереди до возвращения в приложение,
        // а на истечении окна стала бы «Прервано», так и не отправившись. Второй заход —
        // только облачным: им окна хватает отдать запрос системе, а локальной записи
        // 30 секунд не хватит — она начала бы считать, чтобы тут же стать «Прервано»
        // (контракт: «для них приложение открывается»).
        if !foreground, !waiting.isEmpty { admit(cloudOnly: true) }
        return true
    }

    /// Отменяет расшифровку: и ту, что идёт, и ту, что ещё ждёт.
    func cancel(_ relativePath: String) {
        removeFromQueue(relativePath, persist: true)
        admit()
    }

    /// Снимает запись со всего, что её держало: очереди, запуска, «Прервано», сохранённого
    /// задания и счёта пачки. Планировщик не трогает — это забота вызывающего, чтобы
    /// «Отменить всё» не освобождало место на каждой записи по отдельности.
    private func removeFromQueue(_ relativePath: String, persist: Bool) {
        if let job = configurations.removeValue(forKey: relativePath) {
            GeminiTranscriber.cleanupRemoteFiles(for: job)
            BackgroundTranscriptionTransport.shared.cancel(jobID: job.id)
        }
        connectionRetries.removeValue(forKey: relativePath)
        resumeOnReturn.remove(relativePath)
        parked.remove(relativePath)
        answersOnly.remove(relativePath)
        waiting.removeAll { $0.entry.relativePath == relativePath }
        waitingForMemory.remove(relativePath)
        // Снятая запись обратно в «запускается» не вернётся: задача до работы не дойдёт.
        starting.remove(relativePath)
        forget(interrupted: relativePath)
        batchSettle(relativePath, as: .cancelled)
        // Новая отмена отменяет и просьбу «поставить заново», если она успела прийти.
        restartAfterCancel.removeValue(forKey: relativePath)
        if inFlight.removeValue(forKey: relativePath) != nil, persist {
            _ = persistJobs()
        }
        // Задача снимается, но из `active` её убирает сама завершившаяся работа:
        // иначе освободившееся место занял бы кто-то раньше, чем движок отпустил модель.
        if let task = active[relativePath] {
            cancelling.insert(relativePath)
            task.cancel()
        }
    }

    /// «Отменить всё»: снимает и то, что идёт, и то, что запускается, и то, что ждёт,
    /// и пометки «Прервано» — вместе с сохранённой очередью.
    ///
    /// Прерванные входят намеренно. Локальные из них поднялись бы сами при ближайшем
    /// возвращении в приложение, и «отменить всё» отменилось бы за спиной у человека.
    /// Ошибки прошлых попыток остаются: это не очередь, а память о том, что не вышло.
    ///
    /// Идущие записи сворачиваются не мгновенно — место за ними держится, пока движок
    /// не отпустит модель, и `isIdle` станет `true` только тогда. Это не помеха: новая
    /// запись, добавленная сразу после, встанет в очередь и пойдёт, как только место
    /// освободится.
    func cancelAll() {
        // Источник правды — сами коллекции, а не опубликованный `queued`.
        let paths = Set(waiting.map(\.entry.relativePath))
            .union(active.keys)
            .union(interrupted)
            .union(inFlight.keys)
        // Очередь пустеет целиком первой: иначе освободившееся место успевало бы занять
        // следующей ждущей — чтобы тут же её снять.
        waiting.removeAll()
        // Порядок снятия не важен для результата, но важен для воспроизводимости.
        for path in paths.sorted() { removeFromQueue(path, persist: false) }
        // Планировщик и сохранение — один раз на всё: пока снимается последняя запись, итог
        // пачки обязан уже знать про все предыдущие, иначе отчёт о пачке недосчитал бы снятых.
        if !paths.isEmpty { _ = persistJobs() }
        queued = []
        waitingForMemory = []
        admit()
    }

    /// Систему перестало устраивать, что мы работаем: процесс забирают.
    ///
    /// Это не отмена человеком и не ошибка движка, и путать их нельзя — иначе
    /// карточка скажет «Ошибка» там, где никто не ошибся. Прерванные переживают
    /// перезапуск; готовые части восстанавливаются, незаконченная считается заново.
    ///
    /// **Кроме облачной записи, чей запрос уже у системной передачи.** Её HTTP-запрос
    /// принадлежит фоновой `URLSession` и идёт в отдельном процессе системы, нашему
    /// фоновому времени он не подчиняется («A session configured with this object hands
    /// control of the transfers over to the system, which handles the transfers in a
    /// separate process», `URLSessionConfiguration.background(withIdentifier:)`). Раньше
    /// такая запись отменялась и становилась «Прервано»: ответ сервиса всё равно приходил
    /// распиской, но доделывалась запись только тогда, когда человек вернётся в Lori, — на
    /// телефоне это и выглядело как «вышел — и всё прекратилось». Теперь её Swift-задача
    /// не отменяется и спит вместе с процессом; ответ будит приложение
    /// (`sessionSendsLaunchEvents`), и запись доделывается в фоне
    /// (`TranscriptionRunway.systemWokeForTransfers`). Убьют процесс — запись остаётся в
    /// `interrupted.json` (задание сохранено на старте), и пробуждение доделает её по
    /// расписке (`finishAfterSystemWake`).
    ///
    /// Запись, которая готовит аудио или разбирает уже пришедший ответ, у системы ничего
    /// не держит — она прерывается как раньше: продолжение по расписке ничего не
    /// отправит заново. Локальные движки — как раньше: прерывание и чекпоинты.
    ///
    /// Возвращает оставленные ждать записи — для журнала и для фоновой задачи, которой
    /// при них нельзя ждать пустой очереди.
    @discardableResult
    func interruptEverything() -> [String] {
        for job in waiting {
            let path = job.entry.relativePath
            interrupted.insert(path)
            inFlight[path] = job.kind
            batchSettle(path, as: .interrupted)
        }
        // Снятые человеком, но ещё сворачивающиеся записи не трогаем: обрыв системой не
        // должен воскресить то, что человек отменил, — иначе при ближайшем запуске она
        // поднялась бы сама.
        var kept: [String] = []
        for path in active.keys.sorted() where !cancelling.contains(path) {
            if lane[path]?.leavesDevice == true, let job = configurations[path], transfers.holds(job.id) {
                parked.insert(path)
                kept.append(path)
                continue
            }
            // Оставленная ждать раньше запись могла с тех пор проснуться и пойти дальше —
            // готовить следующую часть, у системы ничего не держа. Тогда её прерываем, и
            // отметка «ждёт систему» снимается: иначе отмена ниже её бы пропустила, и
            // запись числилась бы «Прервано», продолжая работать.
            parked.remove(path)
            interrupted.insert(path)
            interrupting.insert(path)
            if inFlight[path] == nil { inFlight[path] = lane[path] }
            batchSettle(path, as: .interrupted)
        }
        waiting.removeAll()
        waitingForMemory.removeAll()
        _ = persistJobs()
        for (path, task) in active where !parked.contains(path) { task.cancel() }
        queued = []
        waitingForMemory = []
        signalDrainIfIdle()
        return kept
    }

    /// Что идёт и что ждёт — одной строкой для журнала: запись, движок, фаза. Без текста
    /// расшифровки и без ключей — журнал забирают с телефона целиком.
    func workSummary() -> String {
        let going = active.keys.sorted().map { path -> String in
            var words = ["«\(path)»", lane[path]?.rawValue ?? "?"]
            if parked.contains(path) { words.append("ждёт ответ системы") }
            if let phase = transfer[path] {
                words.append(phase.journalWord)
            } else if let piece = parts[path], piece.total > 1 {
                words.append("часть \(min(piece.done + 1, piece.total)) из \(piece.total)")
            } else if starting.contains(path) {
                words.append("запускается")
            }
            return words.joined(separator: " ")
        }
        return "шло: \(going.isEmpty ? "ничего" : going.joined(separator: "; ")); в очереди: \(waiting.count)"
    }

    /// Продолжаем исходное задание с зафиксированными настройками. Новые облачные
    /// задания уже запущены человеком; старые записи без снимка ждут ручного повтора.
    func resumeInterrupted(in workspace: WorkspaceStore) {
        pruneFailures(in: workspace)
        guard !inFlight.isEmpty else { return }
        for path in resumeOrder() {
            guard let kind = inFlight[path] else { continue }
            guard let entry = try? workspace.entry(at: path) else {
                // Записи могло уже не быть — её удалили, пока приложение не работало.
                forgetCompletely(path)
                continue
            }
            guard active[path] == nil, !waiting.contains(where: { $0.entry.relativePath == path }) else { continue }
            // Новые задания содержат исходные настройки и явный запуск пользователя.
            // Старые облачные записи без снимка нельзя автоматически повторять.
            guard !kind.leavesDevice || configurations[path] != nil else { continue }
            Journal.append("прерванная расшифровка «\(path)» поставлена заново движком \(kind.rawValue)")
            enqueue(entry, in: workspace, using: kind)
        }
    }

    /// В каком порядке поднимать прерванное: в том, в каком записи добавляли.
    ///
    /// Раньше шло по алфавиту пути, и пять файлов, поставленных в порядке «Планёрка,
    /// Интервью, Звонок», после перезапуска считались как «Звонок, Интервью, Планёрка»:
    /// очередь, начатая в одном порядке, заканчивалась в другом. Порядок добавления
    /// записан в снимке задания — `TranscriptionJob.created` ставится в момент
    /// `enqueue`, и повторная постановка тем же движком снимок не перезаписывает, так
    /// что порядок переживает и несколько перезапусков подряд.
    ///
    /// Записи без снимка (файл прежней версии, где хранился только движок) считать
    /// не по чему: они идут первыми и между собой — по пути, как и раньше. Равные
    /// даты разводятся тем же путём, чтобы порядок не зависел от словаря.
    private func resumeOrder() -> [String] {
        inFlight.keys.sorted { lhs, rhs in
            let left = configurations[lhs]?.created ?? .distantPast
            let right = configurations[rhs]?.created ?? .distantPast
            return left == right ? lhs < rhs : left < right
        }
    }

    private func forgetCompletely(_ path: String) {
        interrupted.remove(path)
        inFlight.removeValue(forKey: path)
        configurations.removeValue(forKey: path)
        failed.removeValue(forKey: path)
        _ = persistJobs()
    }

    /// Запись удалили (или она пропала, пока приложение не работало): ошибка её
    /// последней попытки больше никому не нужна. Вместе с ней уходят очередь и «Прервано».
    ///
    /// Ошибка сохраняется до тех пор, пока запись не поставят заново или не удалят, —
    /// других поводов забыть её нет. Поэтому экран, удаляющий запись, обязан сказать
    /// об этом здесь, как говорит `topics`, `summaries` и остальным хранилищам.
    func forget(_ relativePath: String) {
        let hadFailure = failed.removeValue(forKey: relativePath) != nil
        // `cancel` сам сохраняет очередь, если запись в ней была, — уже без ошибки; если
        // записи в очереди не было, а ошибка была, сохранить нужно отдельно.
        cancel(relativePath)
        if hadFailure { _ = persistJobs() }
    }

    /// Ошибки записей, которых больше нет на диске. Удаление через приложение
    /// (`forget`) их снимает сразу, а вот файл, убранный через «Файлы», узнаётся только
    /// по тому, что его нет, — и проверяется это там, где известна рабочая папка.
    private func pruneFailures(in workspace: WorkspaceStore) {
        let gone = failed.keys.filter { (try? workspace.fileURL(for: $0)) == nil }
        guard !gone.isEmpty else { return }
        for path in gone { failed.removeValue(forKey: path) }
        _ = persistJobs()
    }

    @discardableResult
    private func persistJobs() -> Bool {
        do {
            let all = configurations.filter { inFlight[$0.key] != nil }
            let legacy = inFlight.filter { all[$0.key] == nil }
            try InterruptedRecords.saveJobs(all, legacy: legacy, failures: failed, to: interruptedStore)
            return true
        } catch {
            lastError = "Не удалось сохранить очередь. Освободи место и повтори."
            return false
        }
    }

    func connectionBecameAvailable() {
        guard foreground, let recoveryWorkspace else { return }
        resumeInterrupted(in: recoveryWorkspace)
    }

    func applicationDidEnterBackground() { foreground = false }
    func applicationDidBecomeActive(in workspace: WorkspaceStore) {
        foreground = true
        // Оставленная ждать систему запись снова обычная: процесс на экране, и что с её
        // запросом, видно по живой фазе передачи.
        parked.removeAll()
        resumeOnReturn.formUnion(interrupted)
        // Поднятая пробуждением запись идёт без права на новую отправку; если ей понадобится
        // отправка, она станет «Прервано» — и тогда должна пойти заново, раз человек здесь.
        resumeOnReturn.formUnion(answersOnly.intersection(active.keys))
        recoveryWorkspace = workspace
        resumeInterrupted(in: workspace)
        admit()
    }

    /// Ждёт, пока очередь опустеет. Этим живёт фоновая задача: сама она ничего не
    /// считает, она держит процесс и ведёт системную полосу, пока работа идёт здесь.
    ///
    /// Возвращает итог пачки, которая только что кончилась: так вызывающий получает
    /// именно её исход, а не то, что успело накопиться к моменту, когда он проснулся.
    /// Если очередь и так пуста — последний известный итог.
    @discardableResult
    func waitForDrain() async -> TranscriptionBatchOutcome? {
        guard !isIdle else { return lastBatch }
        return await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
        }
    }

    // MARK: - Планировщик

    /// Берёт из очереди всё, чему хватает места, и запускает. Зовётся после каждого
    /// добавления и после каждого завершения — другого способа освободить полосу нет.
    private func admit(cloudOnly: Bool = false) {
        var held: [Job] = []
        var heldForMemory: Set<String> = []
        for job in waiting {
            guard !cloudOnly || job.kind.leavesDevice else {
                held.append(job)
                continue
            }
            switch admission(for: job) {
            case .go:
                start(job)
            case .lane:
                held.append(job)
            case .memory:
                heldForMemory.insert(job.entry.relativePath)
                held.append(job)
            }
        }
        waiting = held
        waitingForMemory = heldForMemory
        queued = held.map(\.entry.relativePath)
        signalDrainIfIdle()
    }

    private func admission(for job: Job) -> Admission {
        guard active.count < TranscriptionSettings.concurrency else { return .lane }
        let kind = job.kind
        guard foreground || runway?.canExecuteInBackground == true else { return .lane }
        guard !kind.leavesDevice else { return .go }
        // Первую запись пускаем всегда: отказать ей — значит не работать вовсе.
        // Память сторожим у второй и дальше, и только у локальных движков: облачным
        // считать нечем, у них работа в сети.
        guard deviceActive > 0 else { return .go }
        return hasHeadroom(for: kind) ? .go : .memory
    }

    private var deviceActive: Int {
        active.keys.filter { engineKind(for: $0)?.leavesDevice == false }.count
    }

    /// Когда запись взяли в работу. Нужно оценке доли для тех прогонов, где долей
    /// нет вовсе: облачный запрос идёт одним куском и о процентах не сообщает.
    private var startedAt: [String: Date] = [:]

    /// Каким движком идёт запись. Запоминается на запуске: настройку могли поменять,
    /// пока запись считается, и полоса от этого меняться не должна.
    private var lane: [String: TranscriptionEngineKind] = [:]

    private func engineKind(for path: String) -> TranscriptionEngineKind? { lane[path] }

    /// Хватит ли памяти на второй прогон. Ноль означает «система не сказала» —
    /// в симуляторе лимита нет вовсе, и запрещать там ничего нельзя.
    private func hasHeadroom(for kind: TranscriptionEngineKind) -> Bool {
        let available = availableMemory()
        guard available > 0 else { return true }
        return available >= kind.deviceHeadroomBytes
    }

    private func start(_ job: Job) {
        let path = job.entry.relativePath
        lane[path] = job.kind
        startedAt[path] = Date()
        // С этой минуты и до входа в `running` запись «запускается»: из очереди она уже
        // вышла, а в работу ещё нет, и показать это кроме как отдельной отметкой нечем.
        starting.insert(path)
        inFlight[path] = lane[path]
        _ = persistJobs()
        active[path] = Task { [weak self] in
            await self?.willStart?()
            let saved: String? = await TranscriptionJob.$current.withValue(job.configuration) {
                guard !Task.isCancelled else { return nil }
                return await self?.transcribe(job.entry, in: job.workspace, using: job.kind)
            }
            self?.finish(path, saved: saved != nil)
            if let self, self.foreground, self.resumeOnReturn.remove(path) != nil {
                self.resumeInterrupted(in: job.workspace)
            }
        }
    }

    private func finish(_ path: String, saved: Bool) {
        active[path] = nil
        lane[path] = nil
        startedAt[path] = nil
        starting.remove(path)
        cancelling.remove(path)
        if parked.remove(path) != nil {
            Journal.append("фон: оставленная ждать запись «\(path)» \(saved ? "доделана" : "не доделана")")
        }
        answersOnly.remove(path)
        // Прерванная запись остаётся в файле: её судьба решится при следующем запуске.
        if !interrupted.contains(path), inFlight.removeValue(forKey: path) != nil {
            connectionRetries.removeValue(forKey: path)
            if let job = configurations.removeValue(forKey: path) {
                GeminiTranscriber.cleanupRemoteFiles(for: job)
                BackgroundTranscriptionTransport.shared.cancel(jobID: job.id)
            }
            _ = persistJobs()
        }
        // Исход записи в пачке определяется здесь, по тому, чем кончилась работа: к этой
        // минуте `transcribe` уже вернул результат, а ошибка, обрыв и отмена оставили
        // каждая свой след.
        if saved {
            batchSettle(path, as: .succeeded)
        } else if interrupted.contains(path) {
            batchSettle(path, as: .interrupted)
        } else if failed[path] != nil {
            batchSettle(path, as: .failed)
        } else {
            batchSettle(path, as: .cancelled)
        }
        // Нажали «Расшифровать» на записи, пока её отменённая работа сворачивалась, — теперь
        // место свободно. Это до `admit`, а не после: пачка не должна успеть «опустеть».
        if let restart = restartAfterCancel.removeValue(forKey: path) {
            enqueue(restart.entry, in: restart.workspace, using: restart.kind)
        }
        admit()
    }

    // MARK: - Пачка

    private enum BatchResult { case succeeded, failed, interrupted, cancelled }

    /// Запись вошла в пачку. Каждая постановка — отдельная работа, даже если путь тот
    /// же: перерасшифровка записи, уже сделанной в этой пачке, — ещё одна работа.
    private func batchEnrol(_ path: String) {
        batch.total += 1
        batchLive.insert(path)
        publishBatch()
    }

    /// Записывает исход записи. Если исход уже записан (человек снял запись до того, как
    /// движок вернулся), второй раз не считается.
    private func batchSettle(_ path: String, as result: BatchResult) {
        guard batchLive.remove(path) != nil else { return }
        switch result {
        case .succeeded: batch.succeeded.append(path)
        case .failed: batch.failed.append(path)
        case .interrupted: batch.interrupted.append(path)
        case .cancelled: batch.cancelled += 1
        }
        publishBatch()
    }

    private func publishBatch() {
        // Снятые и оборванные из «из скольких» выходят: их место в очереди уже не ждёт.
        batchTotal = batch.total - batch.cancelled - batch.interrupted.count
        batchDone = batch.succeeded.count + batch.failed.count
    }

    /// Пачка кончилась: итог откладывается, счётчики обнуляются.
    private func closeBatch() -> TranscriptionBatchOutcome {
        let outcome = batch
        lastBatch = outcome
        batch = TranscriptionBatchOutcome()
        batchLive = []
        publishBatch()
        return outcome
    }

    private func signalDrainIfIdle() {
        guard isIdle else { return }
        // Итог собирается до того, как проснутся ждущие: они читают его уже готовым.
        let outcome = busy ? closeBatch() : lastBatch
        if !drainWaiters.isEmpty {
            let waiters = drainWaiters
            drainWaiters = []
            for waiter in waiters { waiter.resume(returning: outcome) }
        }
        guard busy else { return }
        busy = false
        runway?.batchDidFinish()
        // Пачка кончилась — веса локальных моделей держать больше незачем: следующая
        // загрузит заново, а 618 МБ Whisper в покое стоят дороже этой загрузки.
        Task {
            await EngineSessionCache.shared.dropIdle()
            didDrain?()
        }
    }

    private func forget(interrupted path: String) {
        interrupting.remove(path)
        interrupted.remove(path)
    }

    func progressText(for relativePath: String) -> String? { progress[relativePath] }

    /// Доля сделанной работы. nil — прогресс неизвестен: короткий файл идёт одним куском,
    /// и показывать проценты там нечем.
    func progressFraction(for relativePath: String) -> Double? { fraction[relativePath] }

    func partialTranscript(for relativePath: String) -> Transcript? { partial[relativePath] }

    func remainingTime(for relativePath: String) -> TimeInterval? { remaining[relativePath] }

    /// Грубая доля по прошедшему времени — для записей, у которых настоящей доли нет.
    ///
    /// Нужна не интерфейсу, а планировщику: он завершает фоновую задачу, которая не
    /// показывает движения, и облачный запрос одним куском попадал под это ровно так.
    /// Оценка честно упирается в потолок, не доходя до единицы: «готово» имеет право
    /// поставить только настоящее завершение.
    func elapsedShare(for relativePath: String, now: Date = Date()) -> Double {
        guard let started = startedAt[relativePath] else { return 0 }
        return Self.elapsedShare(seconds: now.timeIntervalSince(started))
    }

    /// Полчаса взяты как «дольше почти любой записи»: точность тут не нужна, нужна
    /// монотонность и то, чтобы доля не упёрлась в потолок на первой же минуте.
    ///
    /// Кривая `t / (t + 30 мин)`, а не прямая до потолка: прямая упиралась в 0,9 на 27-й
    /// минуте и дальше стояла — ровно то, за что планировщик снимает задачу. До 24 октября
    /// 2026 эту функцию не звал никто, и ошибка не была видна; тест
    /// `testBackgroundShareMeasuresTheUploadAndEstimatesTheAnswerBelowOne` держит, что
    /// доля движется и через три часа.
    nonisolated static func elapsedShare(seconds: TimeInterval, ceiling: Double = 0.9) -> Double {
        guard seconds > 0 else { return 0 }
        return ceiling * seconds / (seconds + 30 * 60)
    }

    // MARK: - Доля для полосы фоновой задачи

    /// Доля записи для системной полосы и откуда она взята.
    struct BackgroundShare: Equatable, Sendable {
        enum Source: String, Sendable {
            /// Куски движка: «3 из 9 готовы».
            case parts = "по частям движка"
            /// Тело запроса уходит — доля по байтам, которые отправила система.
            case upload = "по загрузке"
            /// Тело ушло, ответа ещё нет: сколько ждём — оценка по времени.
            case answer = "по оценке времени: ждём ответ сервиса"
            /// Измерять нечего (запись готовит аудио, движок одним куском).
            case estimate = "по оценке времени: доли нет"
        }

        let value: Double
        let source: Source
    }

    /// Какую часть куска занимает загрузка его тела. Сколько займёт ответ сервиса, не
    /// знает никто — ни мы, ни сервис заранее, — поэтому деление пополам: загрузка
    /// меряется честно, а вторая половина заполняется оценкой и до конца не доходит.
    nonisolated static let uploadWeight = 0.5
    /// Потолок идущей записи. Сотню ставит только настоящее завершение: запись входит в
    /// счёт «готово», когда сервис её сохранил. Это множитель, а не обрезка: обрезка
    /// останавливала бы оценку ожидания, как только та до неё дотянется (на 18-й минуте
    /// ожидания при `answerHalfTime` 120 с), а движение и есть смысл оценки.
    nonisolated static let inFlightCeiling = 0.95
    /// Через сколько секунд ожидания ответа закрыта половина остатка. Кривая
    /// `t / (t + T)` нарочно не упирается в потолок: она замедляется, но движется и через
    /// час — стоящую полосу планировщик снимает, а ответ на трёхчасовую запись идёт минуты.
    nonisolated static let answerHalfTime: TimeInterval = 120

    /// Доля одной идущей записи для полосы фоновой задачи — чистая функция.
    ///
    /// Контракт (`AGENTS.md`): записи без доли отдают оценку по времени, заведомо
    /// приблизительную и с потолком ниже единицы. Раньше `pump` брал только измеренное, и
    /// у ElevenLabs — вся запись одним запросом — доля была ноль всю загрузку и всё
    /// ожидание ответа: ровно то, что планировщик принимает за подвисшую задачу.
    ///
    /// - `parts`: куски движка как он их назвал (`progress(done, total)`); nil — не звал.
    /// - `transfer`: где запрос текущего куска (`TransferPhase`); nil — запроса нет.
    /// - `waited`: сколько длится нынешняя фаза запроса (для ожидания ответа).
    /// - `elapsed`: сколько идёт запись — для оценки, когда мерить нечего.
    nonisolated static func backgroundShare(
        parts: Parts?,
        transfer: TransferPhase?,
        waited: TimeInterval,
        elapsed: TimeInterval
    ) -> BackgroundShare {
        let total = max(parts?.total ?? 1, 1)
        let done = Double(min(max(parts?.done ?? 0, 0), total))
        // Доля от 0 до 1; единица — только «все части готовы». Потолок — множителем ниже.
        let whole: Double
        let source: BackgroundShare.Source
        switch transfer {
        case let phase? where phase.isSending:
            // Объём неизвестен — отправка считается начатой, а не сделанной.
            whole = (done + uploadWeight * (phase.sentShare ?? 0)) / Double(total)
            source = .upload
        case .awaiting?:
            let wait = max(0, waited)
            whole = (done + uploadWeight + (1 - uploadWeight) * wait / (wait + answerHalfTime)) / Double(total)
            source = .answer
        default:
            if let parts, parts.total > 1 || parts.done >= max(parts.total, 1) {
                // Движок режет на части — или сказал «1 из 1»: ответ уже в руках.
                whole = done / Double(total)
                source = .parts
            } else {
                // Своя кривая с потолком 0,9 — сюда её и берём как есть.
                return BackgroundShare(value: inFlightCeiling * elapsedShare(seconds: elapsed), source: .estimate)
            }
        }
        return BackgroundShare(value: inFlightCeiling * min(1, max(0, whole)), source: source)
    }

    /// Доля идущей записи сейчас — то, что фоновая задача складывает в свою полосу.
    func backgroundShare(for path: String, now: Date = Date()) -> BackgroundShare {
        Self.backgroundShare(
            parts: parts[path],
            transfer: transfer[path],
            waited: transferSince[path].map { now.timeIntervalSince($0) } ?? 0,
            elapsed: startedAt[path].map { now.timeIntervalSince($0) } ?? 0
        )
    }

    /// Фаза запроса записи сменилась (доклад транспорта, см. `transcribe`).
    ///
    /// Строку состояния меняет только у записи одним запросом: у записи по частям своя
    /// строка «часть 3 из 9, жду ответ», и сбивать её процентами текущей части незачем.
    /// В журнал — только смена фазы, а не каждый процент.
    func transferChanged(_ path: String, _ phase: TransferPhase) {
        guard running.contains(path) else { return }
        let previous = transfer[path]
        let now = Date()
        switch phase {
        case .answered:
            if previous == .awaiting, let since = transferSince[path] {
                Journal.append("передача «\(path)»: ответ сервиса через \(Int(now.timeIntervalSince(since))) с ожидания")
            }
            transfer[path] = nil
            transferSince[path] = nil
            return
        case .awaiting:
            if previous != .awaiting {
                let sent = previous?.isSending == true ? transferSince[path].map { " за \(Int(now.timeIntervalSince($0))) с" } ?? "" : ""
                Journal.append("передача «\(path)»: тело ушло целиком\(sent), жду ответ сервиса — полоса дальше по оценке времени")
                transferSince[path] = now
            }
        case let .sending(_, expected):
            if previous?.isSending != true {
                let size = expected > 0 ? ", \(max(1, expected / 1024 / 1024)) МБ" : ""
                Journal.append("передача «\(path)»: система отправляет запись\(size) — полоса по загрузке")
                transferSince[path] = now
            }
        }
        transfer[path] = phase
        guard fraction[path] == nil else { return }
        switch phase {
        case .sending: progress[path] = phase.sentShare.map { "отправляю запись · \(Int(($0 * 100).rounded(.down)))%" } ?? "отправляю запись"
        case .awaiting: progress[path] = "жду ответ сервиса"
        case .answered: break
        }
    }

    // MARK: - Пробуждение системой

    /// Что сделано по пробуждению системой — для журнала, человек этого не видит.
    struct SystemWakeReport: Equatable, Sendable {
        /// Записи, поднятые по готовому ответу (процесс убивали, ответ лежал распиской).
        var resumed: [String] = []
        /// Записи, которые к пробуждению ещё шли (процесс спал, их задача ждала ответ).
        var alive: [String] = []
        var outcome: TranscriptionBatchOutcome?
    }

    /// Система разбудила приложение событиями фоновой передачи: ответ сервиса пришёл.
    /// Возвращается, когда очередь опустела; окно пробуждения кончится раньше — фоновая
    /// задача ответит системе сама (`TranscriptionRunway.systemWokeForTransfers`).
    ///
    /// Два случая. Процесс спал — Swift-задача записи, оставленная ждать
    /// (`interruptEverything`), уже получила ответ от делегата сессии; здесь остаётся
    /// дождаться, пока она разберёт и сохранит. Она идёт своим обычным ходом: задание по
    /// частям может отправить следующую часть — это то же задание, начатое нажатием, и
    /// система будит приложение снова, когда придёт и её ответ. Процесс убивали — в памяти пусто, запись
    /// лежит в `interrupted.json` со снимком задания, а ответ — распиской: такая запись
    /// ставится заново тем же заданием и в режиме `answersOnly` — расписка подставит ответ,
    /// а запрос, на который ответа нет, в фоне не уйдёт (запись останется «Прервано» и
    /// продолжится при возвращении). Правила контракта те же, что у `resumeInterrupted`:
    /// облако — только со снимком задания; локальные движки здесь не поднимаются вовсе —
    /// окна пробуждения им не хватит, а с телефона они ничего не ждут.
    func finishAfterSystemWake(in workspace: WorkspaceStore?) async -> SystemWakeReport {
        var report = SystemWakeReport(alive: active.keys.sorted())
        if let workspace = workspace ?? recoveryWorkspace {
            for path in resumeOrder() {
                guard let kind = inFlight[path], kind.leavesDevice, let job = configurations[path],
                      active[path] == nil, !waiting.contains(where: { $0.entry.relativePath == path }),
                      transfers.hasAnswer(job.id) else { continue }
                guard let entry = try? workspace.entry(at: path) else { continue }
                answersOnly.insert(path)
                Journal.append("фон: «\(path)» — ответ сервиса уже лежит распиской, доделываю без новой отправки")
                if enqueue(entry, in: workspace, using: kind) {
                    report.resumed.append(path)
                } else {
                    answersOnly.remove(path)
                }
            }
        }
        guard !isIdle else {
            report.outcome = lastBatch
            return report
        }
        report.outcome = await waitForDrain()
        return report
    }

    /// Запись, поднятая пробуждением, упёрлась в запрос без ответа: в фоне его не шлём.
    /// Это не ошибка и не отмена человеком — запись «Прервано» и продолжится сама, как
    /// только Lori откроют (`applicationDidBecomeActive`: прерванные и поднятые
    /// пробуждением). Сразу заново её не ставим: без возвращения человека это была бы та
    /// самая новая отправка из фона, от которой режим и защищает.
    private func deferToReturn(_ path: String) -> String? {
        interrupted.insert(path)
        _ = persistJobs()
        Journal.append("фон: «\(path)» нужна новая отправка — в фоне её не начинаю, продолжу при возвращении в Lori")
        return nil
    }

    /// Оценка остатка: прошедшее время, поделённое на готовую долю. Пока сделано
    /// меньше пяти процентов, оценка врёт слишком сильно, чтобы её показывать.
    /// Длительность записи читается один раз за прогон: на фоне самой расшифровки
    /// это ничто, а без неё скорость движка не с чем сравнивать.
    private func measure(url: URL, kind: TranscriptionEngineKind, started: Date) async {
        guard let seconds = try? await AVURLAsset(url: url).load(.duration).seconds,
              seconds.isFinite, seconds > 1 else { return }
        lastMeasure = SpeedMeasure(
            engine: kind,
            mode: TranscriptionSettings.mode(for: kind)?.id,
            audio: seconds,
            spent: Date().timeIntervalSince(started)
        )
    }

    nonisolated static func estimate(elapsed: TimeInterval, fraction: Double) -> TimeInterval? {
        guard fraction >= 0.05, fraction < 1 else { return nil }
        let total = elapsed / fraction
        let left = total - elapsed
        return left > 1 ? left : nil
    }

    /// Доля **сделанного**, а не начатого.
    ///
    /// Раньше здесь стояло `done + 1`: движок сообщает номер куска, за который
    /// только берётся, и полоса засчитывала его как готовый. На записи из двух
    /// кусков это значило «100%» ровно с середины работы — и всё оставшееся время
    /// человек смотрел на заполненную полосу и решал, что всё зависло. На Whisper,
    /// где кусок считается минутами, так и вышло. Ноль в начале честнее сотни в
    /// середине; сотню ставит последний вызов `progress(total, total)`.
    nonisolated static func fraction(done: Int, total: Int) -> Double? {
        guard total > 1 else { return nil }
        return min(1, max(0, Double(done) / Double(total)))
    }

    /// Почему движок сейчас не сработает. nil — всё на месте.
    func unavailability(of kind: TranscriptionEngineKind) async -> TranscriptionError? {
        guard await engine(for: kind).isAvailable() == false else { return nil }
        switch kind {
        case .gigaam: return .modelsMissing
        case .whisper: return .whisperModelMissing
        case .apple: return .assetsUnavailable
        case .openAI: return .missingKey(.openAI)
        case .gemini: return .missingKey(.gemini)
        case .elevenLabs: return .missingKey(.elevenLabs)
        }
    }

    /// Готов ли движок принять пачку: nil — да, иначе текст для человека, почему нет.
    ///
    /// Спрашивается **один раз перед пачкой**, а не на каждой записи. Движок проверяется
    /// только когда запись берётся в работу, и пять файлов при пропавшем ключе давали пять
    /// строк «Ошибка» с одним и тем же текстом — человеку нужен один вопрос и один
    /// ответ, пока ничего ещё не импортировано и не поставлено в очередь.
    ///
    /// Не новая логика, а та самая, что остановит саму запись: `unavailability(of:)`.
    /// Облачный движок проверяется по ключу, GigaAM — по скачанной модели, Whisper — по
    /// папке модели; без `kind` берётся выбранный в настройках.
    func preflightProblem(for kind: TranscriptionEngineKind? = nil) async -> String? {
        await unavailability(of: kind ?? TranscriptionSettings.engine)?.errorDescription
    }

    /// Расшифровывает файл и сохраняет `Transcripts/<имя>.md`. Возвращает путь расшифровки.
    /// `kind` задаётся, когда человек попросил перерасшифровать конкретным движком;
    /// иначе берётся выбранный в настройках.
    @discardableResult
    func transcribe(
        _ entry: WorkspaceEntry,
        in workspace: WorkspaceStore,
        using kind: TranscriptionEngineKind? = nil
    ) async -> String? {
        if TranscriptionJob.current == nil {
            let snapshot = TranscriptionJob.capture(kind: kind ?? TranscriptionSettings.engine)
            return await TranscriptionJob.$current.withValue(snapshot) {
                await transcribe(entry, in: workspace, using: snapshot.kind)
            }
        }
        guard entry.isAudio else {
            lastError = TranscriptionError.notAudio.errorDescription
            return nil
        }
        guard !running.contains(entry.relativePath) else { return nil }
        let chosenKind = kind ?? TranscriptionSettings.engine
        let chosen = engine(for: chosenKind)
        if let reason = await unavailability(of: chosenKind) {
            failed[entry.relativePath] = reason.errorDescription
            lastError = reason.errorDescription
            return nil
        }

        // Переход «запускается» → «идёт» одним синхронным шагом: между ними нет ни одной
        // точки, где запись числилась бы нигде.
        running.insert(entry.relativePath)
        starting.remove(entry.relativePath)
        // Первая строка состояния появляется до начала работы: облачный запрос
        // может уйти на минуту, и всё это время экран не должен выглядеть мёртвым.
        progress[entry.relativePath] = chosenKind.leavesDevice ? "отправляю запись" : "готовлю аудио"
        defer {
            running.remove(entry.relativePath)
            progress[entry.relativePath] = nil
            fraction[entry.relativePath] = nil
            partial[entry.relativePath] = nil
            remaining[entry.relativePath] = nil
            transfer[entry.relativePath] = nil
            transferSince[entry.relativePath] = nil
            parts[entry.relativePath] = nil
        }

        // Пробуждение после убитого процесса: только готовые ответы, без новой отправки.
        let answersOnly = self.answersOnly.contains(entry.relativePath)
        let jobID = TranscriptionJob.current?.id
        // Транспорт отказал в новой отправке — значит, всё, что движок собрал без этого
        // ответа, сохранять нельзя (Gemini умеет продолжить после неудачного переспроса и
        // отдал бы неполный текст). Отметка ставится на очереди транспорта до того, как
        // движок получил отказ, поэтому проверка здесь детерминирована.
        func deferred() -> Bool {
            guard answersOnly, let jobID else { return false }
            return transfers.takeDeferral(jobID)
        }

        do {
            let url = try workspace.fileURL(for: entry.relativePath)
            let path = entry.relativePath
            let cloud = chosenKind.leavesDevice
            let started = Date()
            // Фазы запроса докладывает транспорт со своей очереди. `DispatchQueue.main`, а
            // не `Task { @MainActor }`: главная очередь отдаёт по порядку, и последняя
            // «отправка 99%» не обгонит «тело ушло» — иначе карточка так и стояла бы на
            // «Отправляю · 99%» всё ожидание ответа.
            let reporter: @Sendable (TransferPhase) -> Void = { [weak self] phase in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.transferChanged(path, phase) }
                }
            }
            let transcript = try await BackgroundTranscriptionTransport.$answersOnly.withValue(answersOnly) {
                try await BackgroundTranscriptionTransport.$report.withValue(reporter) {
                    try await chosen.transcribe(
                        audioURL: url,
                        progress: { done, total in
                            Task { @MainActor [weak self] in
                                self?.parts[path] = Parts(done: done, total: total)
                                self?.progress[path] = Self.note(done: done, total: total, cloud: cloud)
                                let share = Self.fraction(done: done, total: total)
                                self?.fraction[path] = share
                                self?.remaining[path] = share.flatMap {
                                    Self.estimate(elapsed: Date().timeIntervalSince(started), fraction: $0)
                                }
                            }
                        },
                        partial: { ready in
                            Task { @MainActor [weak self] in
                                self?.partial[path] = ready
                            }
                        },
                        note: { text in
                            Task { @MainActor [weak self] in
                                // Пока движок готовится, процентов ещё нет — и полосе тут
                                // взяться неоткуда, а строка состояния обязана жить.
                                guard self?.fraction[path] == nil else { return }
                                self?.progress[path] = text
                            }
                        }
                    )
                }
            }
            if deferred() { return deferToReturn(entry.relativePath) }
            failed[entry.relativePath] = nil
            await measure(url: url, kind: chosenKind, started: started)
            try Task.checkCancellation()
            let mode = TranscriptionSettings.hasCustomModel(for: chosenKind) ? nil : TranscriptionSettings.mode(for: chosenKind)?.title
            let saved = try await workspace.saveTranscriptAsync(transcript, for: url, engine: chosen.name, mode: mode)
            didSaveTranscript?(entry.relativePath, TranscriptDocument.parse(transcript.markdown(title: "")).plainText)
            return saved
        } catch is CancellationError {
            if deferred() { return deferToReturn(entry.relativePath) }
            // Отмену человек сделал сам: показывать её как ошибку незачем. А вот
            // обрыв системой — не отмена: там никто ничего не решал, и запись обязана
            // об этом сказать, иначе после возвращения в приложение её судьба неизвестна.
            if interrupting.remove(entry.relativePath) != nil {
                interrupted.insert(entry.relativePath)
            }
            return nil
        } catch {
            if deferred() { return deferToReturn(entry.relativePath) }
            if Task.isCancelled || interrupting.remove(entry.relativePath) != nil {
                return nil
            }
            if Self.isConnectionInterruption(error) {
                interrupted.insert(entry.relativePath)
                progress[entry.relativePath] = "Ожидает соединения; продолжится при возвращении"
                _ = persistJobs()
                scheduleConnectionRetry(entry.relativePath, in: workspace)
                return nil
            }
            let message = Self.explain(error)
            failed[entry.relativePath] = message
            lastError = message
            return nil
        }
    }

    /// Ограниченный повтор покрывает timeout без изменения сетевого интерфейса.
    /// После трёх попыток ждём возвращения пользователя или восстановления сети.
    private func scheduleConnectionRetry(_ path: String, in workspace: WorkspaceStore) {
        guard let job = configurations[path] else { return }
        let attempt = connectionRetries[path, default: 0]
        guard attempt < 3 else { return }
        connectionRetries[path] = attempt + 1
        let delay = [2, 10, 30][attempt]
        Task { [weak self, weak workspace] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, let workspace, self.foreground,
                  self.configurations[path]?.id == job.id,
                  self.interrupted.contains(path), self.active[path] == nil else { return }
            self.resumeInterrupted(in: workspace)
        }
    }

    nonisolated static func isConnectionInterruption(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.networkConnectionLost, .notConnectedToInternet, .timedOut,
                .backgroundSessionWasDisconnected, .backgroundSessionInUseByAnotherProcess].contains(error.code)
    }

    /// Что показать в строке состояния. У облачных движков нет процентов внутри
    /// запроса, поэтому важно хотя бы честно назвать текущий шаг.
    nonisolated static func note(done: Int, total: Int, cloud: Bool) -> String {
        guard total > 1 else {
            guard cloud else { return "расшифровываю" }
            return done == 0 ? "жду ответ сервиса" : "получаю текст"
        }
        let current = min(done + 1, total)
        return cloud ? "часть \(current) из \(total), жду ответ" : "часть \(current) из \(total)"
    }

    /// Сетевые ошибки в переводе на человеческий: «The request timed out» ничего
    /// не говорит о том, что делать дальше.
    nonisolated static func explain(_ error: Error) -> String {
        guard let url = error as? URLError else { return error.localizedDescription }
        switch url.code {
        case .timedOut:
            return "Сервис не ответил вовремя. Через VPN канал обычно медленный: попробуй запись короче, другой движок или локальный GigaAM — он не зависит от сети."
        case .notConnectedToInternet, .networkConnectionLost:
            return "Соединение пропало на середине запроса. Локальный GigaAM работает без сети."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "Адрес сервиса недоступен с этого телефона: \(url.localizedDescription)"
        default:
            return url.localizedDescription
        }
    }
}

// MARK: - Пакетный импорт и постановка

/// Итог пакетного импорта: что вошло в очередь, что нет и почему.
struct TranscriptionImportReport: Equatable {
    struct Imported: Equatable {
        /// Файл в промежуточной папке, откуда его взяли, — по нему интерфейс узнаёт «свой» файл.
        let source: URL
        /// Путь записи в рабочей папке — по нему она стоит в очереди.
        let path: String
    }

    struct Failure: Equatable {
        let source: URL
        /// Причина текстом для человека: имя файла в ней уже есть.
        let message: String
    }

    /// Не `nil` — движок не готов, и **не сделано ничего**: ни импорта, ни очереди.
    /// Прикреплённые файлы лежат где лежали, человеку нужно починить движок и повторить.
    var blockedBy: String?
    var imported: [Imported] = []
    var failed: [Failure] = []

    /// Всё, что просили, вошло в очередь.
    var isComplete: Bool { blockedBy == nil && failed.isEmpty }
}

extension TranscriptionService {
    /// Принимает **один** подготовленный файл (из `ImportInbox`) и ставит его в очередь:
    /// копирует в рабочую папку и тут же встаёт в очередь, как одно действие.
    ///
    /// Цикл по нескольким файлам и отчёт о частичном успехе остаются за вызывающим — для
    /// этого функция и одна: один файл вошёл или не вошёл, и третьего нет. (Для пачки есть
    /// `importAndEnqueue(_:[URL]…)`: она ещё и держит пачку одной — см. там.)
    ///
    /// - Успех: возвращает путь записи; файл в промежуточной папке убран (иначе он вернулся
    ///   бы в панель при следующем открытии и импортировался второй раз).
    /// - Неподдерживаемый формат: `ImportError.unsupportedFormat`, промежуточная копия убрана —
    ///   негодный файл годным не станет, а в панели он только мешает.
    /// - Любой другой отказ при копировании: бросает ошибку, файл **остаётся** в
    ///   промежуточной папке для повтора.
    /// - Очередь не сохранилась: импорт откатывается (копия в рабочей папке убирается),
    ///   `ImportError.queueUnavailable`, промежуточный файл остаётся. Запись не остаётся
    ///   в списке «Без расшифровки» в состоянии, которого человек не просил.
    ///
    /// `didImport` вызывается синхронно сразу после постановки, раньше, чем работа успеет
    /// хоть на шаг продвинуться: здесь интерфейс ставит записи временный заголовок
    /// (имя принесённого файла), и расшифровка не может закончиться и дать записи
    /// заголовок от модели до того, как он будет задан.
    ///
    /// Сама запись в работу **не** уходит без вызова: «Принесённый файл никогда не уходит в
    /// расшифровку сам» — этот вызов и есть нажатие человека.
    @discardableResult
    func importAndEnqueue(
        _ staged: URL,
        into workspace: WorkspaceStore,
        using kind: TranscriptionEngineKind? = nil,
        modifiedAt: Date = .now,
        didImport: (_ relativePath: String) -> Void = { _ in }
    ) async throws -> String {
        let path = try await importStaged(staged, into: workspace, modifiedAt: modifiedAt)
        return try enqueueImported(path, staged: staged, into: workspace, using: kind, didImport: didImport)
    }

    /// Принимает пачку файлов: **одна** проверка движка в начале, затем копирование всех, и
    /// только потом — разом в очередь, по порядку. Отчёт — о том, что вошло и что нет.
    ///
    /// - Движок не готов — не делается ничего, в отчёте `blockedBy` с причиной. Пять файлов
    ///   при пропавшем ключе раньше давали пять строк «Ошибка»; теперь — один вопрос до импорта.
    /// - **Пачка остаётся одной.** Сначала копируются все файлы, и только потом они встают в
    ///   очередь — подряд, без единой паузы между ними. Будь постановка вперемешку с
    ///   копированием, короткая первая запись успевала бы расшифроваться, пока копируется
    ///   вторая: очередь пустела бы посреди ввода, счётчик «1 из 5» превращался в «1 из 1» и
    ///   «1 из 4», а фоновая задача закрывалась бы и просилась заново.
    /// - Файлы встают в очередь **в порядке выбора**; движок один на всю пачку: он назван один
    ///   раз в начале, и смена настройки посреди ввода пачку не перемешает.
    /// - Один негодный файл не отменяет остальных: он попадает в `failed`, остальные идут.
    /// - Даты изменения идут с шагом в 10 мс на убыль: первый файл — самый новый. В списке
    ///   «новые сверху» пачка читается сверху вниз в том порядке, в каком расшифровывается.
    ///
    /// `didImport` получает исходный файл и путь записи — этого хватает, чтобы задать записи
    /// заголовок по имени принесённого файла.
    func importAndEnqueue(
        _ files: [URL],
        into workspace: WorkspaceStore,
        using kind: TranscriptionEngineKind? = nil,
        didImport: (_ source: URL, _ relativePath: String) -> Void = { _, _ in }
    ) async -> TranscriptionImportReport {
        var report = TranscriptionImportReport()
        guard !files.isEmpty else { return report }

        let engine = kind ?? TranscriptionSettings.engine
        if let problem = await preflightProblem(for: engine) {
            Diagnostics.note("импорт: пачка из \(files.count) остановлена до начала — \(problem)")
            report.blockedBy = problem
            return report
        }

        // Сначала копирование — по файлу и по порядку; на постановке пока ничего не стоит.
        let start = Date()
        var copied: [(source: URL, path: String)] = []
        for (index, file) in files.enumerated() {
            do {
                let path = try await importStaged(
                    file, into: workspace, modifiedAt: start.addingTimeInterval(-Double(index) * 0.01)
                )
                copied.append((file, path))
            } catch {
                Diagnostics.note("импорт: «\(file.lastPathComponent)» не вошла — \(error.localizedDescription)")
                report.failed.append(.init(source: file, message: error.localizedDescription))
            }
        }

        // Потом разом в очередь: цикл без `await`, пачка не может опустеть на полпути.
        for (source, path) in copied {
            do {
                try enqueueImported(path, staged: source, into: workspace, using: engine) { didImport(source, $0) }
                report.imported.append(.init(source: source, path: path))
            } catch {
                Diagnostics.note("импорт: «\(source.lastPathComponent)» не вошла — \(error.localizedDescription)")
                report.failed.append(.init(source: source, message: error.localizedDescription))
            }
        }
        return report
    }

    /// Первая половина импорта: копия в рабочую папку. Неподдерживаемый формат убирает и
    /// промежуточную копию; любой другой отказ её оставляет.
    private func importStaged(_ staged: URL, into workspace: WorkspaceStore, modifiedAt: Date) async throws -> String {
        do {
            return try await workspace.importFileAsync(from: staged, modifiedAt: modifiedAt)
        } catch let refusal as ImportError {
            ImportInbox.forget(staged)
            throw refusal
        }
    }

    /// Вторая половина: постановка в очередь. Не встала — копия в рабочей папке откатывается,
    /// промежуточная остаётся. Встала — хук, и промежуточная копия убирается.
    @discardableResult
    private func enqueueImported(
        _ path: String,
        staged: URL,
        into workspace: WorkspaceStore,
        using kind: TranscriptionEngineKind?,
        didImport: (_ relativePath: String) -> Void
    ) throws -> String {
        guard let entry = try? workspace.entry(at: path) else {
            workspace.discardImportedFile(at: path)
            throw WorkspaceError.importFailed
        }
        guard enqueue(entry, in: workspace, using: kind) else {
            workspace.discardImportedFile(at: path)
            throw ImportError.queueUnavailable(fileName: staged.lastPathComponent)
        }
        didImport(path)
        ImportInbox.forget(staged)
        Diagnostics.note("импорт: «\(path)» принята и поставлена в очередь")
        return path
    }
}
