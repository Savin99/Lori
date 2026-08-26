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
        }
    }
}

protocol LocalTranscribing: Sendable {
    /// Показывается в настройках, чтобы было видно, чем именно расшифровано.
    var name: String { get }
    func isAvailable() async -> Bool
    /// `progress` вызывается по мере обработки кусков длинного файла.
    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript
}

extension LocalTranscribing {
    func transcribe(audioURL: URL) async throws -> Transcript {
        try await transcribe(audioURL: audioURL) { _, _ in }
    }
}

/// Движок Apple. На iOS 26 это `SpeechAnalyzer` — он рассчитан на длинные файлы;
/// на более старых системах остаётся `SFSpeechURLRecognitionRequest` с его лимитом диктовки.
/// Аудио не покидает устройство ни в одном из путей.
struct AppleSpeechTranscriber: LocalTranscribing {
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
@MainActor
final class TranscriptionService: ObservableObject {
    @Published private(set) var running: Set<String> = []
    /// Человекочитаемый прогресс по пути файла: «3 из 7».
    @Published private(set) var progress: [String: String] = [:]
    /// Та же доля числом, от 0 до 1 — кольцу в интерфейсе нужна она, а не строка.
    /// Разбирать «3 из 7» обратно во вьюхе было бы ломко: строка ещё и локализованная.
    @Published private(set) var fraction: [String: Double] = [:]
    @Published var lastError: String?

    let engine: any LocalTranscribing
    private let fallback: any LocalTranscribing

    /// GigaAM основной, движок Apple — резерв. Выбор делается по факту наличия моделей.
    init(
        engine: any LocalTranscribing = GigaAMCoreMLTranscriber(),
        fallback: any LocalTranscribing = AppleSpeechTranscriber()
    ) {
        self.engine = engine
        self.fallback = fallback
    }

    func isRunning(_ relativePath: String) -> Bool { running.contains(relativePath) }

    func progressText(for relativePath: String) -> String? { progress[relativePath] }

    /// Доля сделанной работы. nil — прогресс неизвестен: короткий файл идёт одним куском,
    /// и показывать проценты там нечем.
    func progressFraction(for relativePath: String) -> Double? { fraction[relativePath] }

    nonisolated static func fraction(done: Int, total: Int) -> Double? {
        guard total > 1 else { return nil }
        return min(1, max(0, Double(min(done + 1, total)) / Double(total)))
    }

    /// Расшифровывает файл и сохраняет `Transcripts/<имя>.md`. Возвращает путь расшифровки.
    @discardableResult
    func transcribe(_ entry: WorkspaceEntry, in workspace: WorkspaceStore) async -> String? {
        guard entry.isAudio else {
            lastError = TranscriptionError.notAudio.errorDescription
            return nil
        }
        guard !running.contains(entry.relativePath) else { return nil }
        running.insert(entry.relativePath)
        defer {
            running.remove(entry.relativePath)
            progress[entry.relativePath] = nil
            fraction[entry.relativePath] = nil
        }

        do {
            let url = try workspace.fileURL(for: entry.relativePath)
            let path = entry.relativePath
            let chosen: any LocalTranscribing = await engine.isAvailable() ? engine : fallback
            let transcript = try await chosen.transcribe(audioURL: url) { done, total in
                guard total > 1 else { return }
                Task { @MainActor [weak self] in
                    self?.progress[path] = "\(min(done + 1, total)) из \(total)"
                    self?.fraction[path] = Self.fraction(done: done, total: total)
                }
            }
            return try workspace.saveTranscript(transcript, for: url)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}
