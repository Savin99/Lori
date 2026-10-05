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
            "Модели GigaAM ещё не скачаны. Настройки → «Модель GigaAM» → «Скачать», или выбери другой движок."
        case .whisperModelMissing:
            "Модель Whisper не найдена. Положи папку модели в «Файлы» → Lori → Models: приложение её не качает — это 632 МБ."
        case let .modelIncomplete(name, file):
            "Папке модели движка «\(name)» не хватает файла «\(file)». Без него расшифровка пошла бы за ним в сеть."
        case let .missingKey(account):
            "Ключ \(account.title) не сохранён. Настройки → «\(account.title)» → вставь ключ."
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
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    /// Все пять движков создаются сразу: они ничего не занимают до первой расшифровки,
    /// а тестам удобно подменять набор целиком.
    init(
        engines: [TranscriptionEngineKind: any Transcribing]? = nil,
        interruptedStore: URL = InterruptedRecords.url,
        availableMemory: @escaping @MainActor () -> UInt64 = { MemoryReport.availableBytes }
    ) {
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
    }

    func engine(for kind: TranscriptionEngineKind) -> any Transcribing {
        engines[kind] ?? AppleSpeechTranscriber()
    }

    /// Название выбранного движка для настроек и карточки записи.
    var selectedName: String { engine(for: TranscriptionSettings.engine).name }

    func isRunning(_ relativePath: String) -> Bool { running.contains(relativePath) }

    func isQueued(_ relativePath: String) -> Bool { queued.contains(relativePath) }

    func isInterrupted(_ relativePath: String) -> Bool { interrupted.contains(relativePath) }

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
    func enqueue(_ entry: WorkspaceEntry, in workspace: WorkspaceStore, using kind: TranscriptionEngineKind? = nil) {
        recoveryWorkspace = workspace
        let path = entry.relativePath
        guard active[path] == nil, !waiting.contains(where: { $0.entry.relativePath == path }) else { return }
        failed[path] = nil
        forget(interrupted: path)
        let starting = !busy
        busy = true
        let previous = configurations[path]
        let configuration = (kind == nil || previous?.kind == kind ? previous : nil)
            ?? TranscriptionJob.capture(kind: kind ?? TranscriptionSettings.engine)
        configurations[path] = configuration
        inFlight[path] = configuration.kind
        guard persistJobs() else { busy = !isIdle; return }
        waiting.append(Job(entry: entry, configuration: configuration, workspace: workspace))
        admit()
        // Просить фон только на переходе «ничего не шло → пошло»: задача одна на всю
        // пачку, а записи, добавленные по ходу, входят в неё же.
        if starting { runway?.batchDidStart() }
    }

    /// Отменяет расшифровку: и ту, что идёт, и ту, что ещё ждёт.
    func cancel(_ relativePath: String) {
        if let job = configurations.removeValue(forKey: relativePath) {
            GeminiTranscriber.cleanupRemoteFiles(for: job)
            BackgroundTranscriptionTransport.shared.cancel(jobID: job.id)
        }
        connectionRetries.removeValue(forKey: relativePath)
        resumeOnReturn.remove(relativePath)
        waiting.removeAll { $0.entry.relativePath == relativePath }
        waitingForMemory.remove(relativePath)
        forget(interrupted: relativePath)
        if inFlight.removeValue(forKey: relativePath) != nil {
            _ = persistJobs()
        }
        // Задача снимается, но из `active` её убирает сама завершившаяся работа:
        // иначе освободившееся место занял бы кто-то раньше, чем движок отпустил модель.
        active[relativePath]?.cancel()
        admit()
    }

    func cancelAll() {
        let paths = Set(queued).union(active.keys).union(interrupted)
        waiting.removeAll()
        for path in paths { cancel(path) }
    }

    /// Систему перестало устраивать, что мы работаем: процесс забирают.
    ///
    /// Это не отмена человеком и не ошибка движка, и путать их нельзя — иначе
    /// карточка скажет «Ошибка» там, где никто не ошибся. Прерванные переживают
    /// перезапуск; готовые части восстанавливаются, незаконченная считается заново.
    func interruptEverything() {
        for job in waiting {
            let path = job.entry.relativePath
            interrupted.insert(path)
            inFlight[path] = job.kind
        }
        for path in active.keys {
            interrupted.insert(path)
            interrupting.insert(path)
            if inFlight[path] == nil { inFlight[path] = lane[path] }
        }
        waiting.removeAll()
        waitingForMemory.removeAll()
        _ = persistJobs()
        for task in active.values { task.cancel() }
        queued = []
        waitingForMemory = []
        signalDrainIfIdle()
    }

    /// Продолжаем исходное задание с зафиксированными настройками. Новые облачные
    /// задания уже запущены человеком; старые записи без снимка ждут ручного повтора.
    func resumeInterrupted(in workspace: WorkspaceStore) {
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
        _ = persistJobs()
    }

    @discardableResult
    private func persistJobs() -> Bool {
        do {
            let all = configurations.filter { inFlight[$0.key] != nil }
            let legacy = inFlight.filter { all[$0.key] == nil }
            try InterruptedRecords.saveJobs(all, legacy: legacy, to: interruptedStore)
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
        resumeOnReturn.formUnion(interrupted)
        recoveryWorkspace = workspace
        resumeInterrupted(in: workspace)
        admit()
    }

    /// Ждёт, пока очередь опустеет. Этим живёт фоновая задача: сама она ничего не
    /// считает, она держит процесс и ведёт системную полосу, пока работа идёт здесь.
    func waitForDrain() async {
        guard !isIdle else { return }
        await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
        }
    }

    // MARK: - Планировщик

    /// Берёт из очереди всё, чему хватает места, и запускает. Зовётся после каждого
    /// добавления и после каждого завершения — другого способа освободить полосу нет.
    private func admit() {
        var held: [Job] = []
        var heldForMemory: Set<String> = []
        for job in waiting {
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
        inFlight[path] = lane[path]
        _ = persistJobs()
        active[path] = Task { [weak self] in
            await self?.willStart?()
            await TranscriptionJob.$current.withValue(job.configuration) {
                if !Task.isCancelled {
                    _ = await self?.transcribe(job.entry, in: job.workspace, using: job.kind)
                }
            }
            self?.finish(path)
            if let self, self.foreground, self.resumeOnReturn.remove(path) != nil {
                self.resumeInterrupted(in: job.workspace)
            }
        }
    }

    private func finish(_ path: String) {
        active[path] = nil
        lane[path] = nil
        startedAt[path] = nil
        // Прерванная запись остаётся в файле: её судьба решится при следующем запуске.
        if !interrupted.contains(path), inFlight.removeValue(forKey: path) != nil {
            connectionRetries.removeValue(forKey: path)
            if let job = configurations.removeValue(forKey: path) {
                GeminiTranscriber.cleanupRemoteFiles(for: job)
            BackgroundTranscriptionTransport.shared.cancel(jobID: job.id)
            }
            _ = persistJobs()
        }
        admit()
    }

    private func signalDrainIfIdle() {
        guard isIdle else { return }
        if !drainWaiters.isEmpty {
            let waiters = drainWaiters
            drainWaiters = []
            for waiter in waiters { waiter.resume() }
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
    nonisolated static func elapsedShare(seconds: TimeInterval, ceiling: Double = 0.9) -> Double {
        guard seconds > 0 else { return 0 }
        return min(ceiling, seconds / (30 * 60))
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

        running.insert(entry.relativePath)
        // Первая строка состояния появляется до начала работы: облачный запрос
        // может уйти на минуту, и всё это время экран не должен выглядеть мёртвым.
        progress[entry.relativePath] = chosenKind.leavesDevice ? "отправляю запись" : "готовлю аудио"
        defer {
            running.remove(entry.relativePath)
            progress[entry.relativePath] = nil
            fraction[entry.relativePath] = nil
            partial[entry.relativePath] = nil
            remaining[entry.relativePath] = nil
        }

        do {
            let url = try workspace.fileURL(for: entry.relativePath)
            let path = entry.relativePath
            let cloud = chosenKind.leavesDevice
            let started = Date()
            let transcript = try await chosen.transcribe(
                audioURL: url,
                progress: { done, total in
                    Task { @MainActor [weak self] in
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
            failed[entry.relativePath] = nil
            await measure(url: url, kind: chosenKind, started: started)
            try Task.checkCancellation()
            let mode = TranscriptionSettings.hasCustomModel(for: chosenKind) ? nil : TranscriptionSettings.mode(for: chosenKind)?.title
            let saved = try await workspace.saveTranscriptAsync(transcript, for: url, engine: chosen.name, mode: mode)
            didSaveTranscript?(entry.relativePath, TranscriptDocument.parse(transcript.markdown(title: "")).plainText)
            return saved
        } catch is CancellationError {
            // Отмену человек сделал сам: показывать её как ошибку незачем. А вот
            // обрыв системой — не отмена: там никто ничего не решал, и запись обязана
            // об этом сказать, иначе после возвращения в приложение её судьба неизвестна.
            if interrupting.remove(entry.relativePath) != nil {
                interrupted.insert(entry.relativePath)
            }
            return nil
        } catch {
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
