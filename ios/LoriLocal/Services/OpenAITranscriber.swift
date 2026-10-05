import Foundation

/// Расшифровка через `POST /v1/audio/transcriptions`.
///
/// Адрес базовый, а не зашитый: тот же протокол понимают Groq и локальный
/// whisper-сервер в домашней сети, так что «OpenAI-совместимый» здесь буквально.
/// Аудио при этом покидает телефон — движок выбирается человеком руками.
struct OpenAITranscriber: Transcribing {
    /// 25 МБ — предел запроса у OpenAI. Берём с запасом: длинную запись
    /// `AudioSplitter` порежет на части, а тайминги слов сдвинет по началу части.
    static let maxRequestBytes = 24 * 1024 * 1024
    /// Плюс ограничение по времени: на медленном канале человеку нужно видеть
    /// движение, а не один запрос на всю запись.
    static let maxPartSeconds: TimeInterval = 10 * 60

    let session: URLSession
    let splitter: AudioSplitter
    /// Ключ приходит извне: так движок проверяется тестами без Keychain и без сети.
    let keyProvider: @Sendable () throws -> String?

    init(
        session: URLSession = CloudSession.shared,
        splitter: AudioSplitter = AudioSplitter(),
        keyProvider: @escaping @Sendable () throws -> String? = { try KeychainStore.key(for: .openAI) }
    ) {
        self.session = session
        self.splitter = splitter
        self.keyProvider = keyProvider
    }

    var name: String { "OpenAI · \(TranscriptionSettings.openAIModel)" }

    /// Что модель умеет и что ей можно присылать.
    /// У `gpt-transcribe` язык передаётся списком `languages[]` — это поле
    /// заменило одиночное `language` прежних моделей. У whisper и `gpt-4o-…`
    /// осталось прежнее имя.
    static func usesLanguageList(_ model: String) -> Bool {
        model.lowercased().hasPrefix("gpt-transcribe")
    }

    enum Family {
        /// whisper: тайминги слов, подсказка списком ключевых слов.
        case whisper
        /// `…-diarize`: говорящие и таймкоды реплик, подсказку не принимает вовсе.
        case diarization
        /// Остальные `gpt-…-transcribe`: только текст, подсказка свободным текстом.
        case plain

        static func of(_ model: String) -> Family {
            let lower = model.lowercased()
            if lower.contains("diarize") { return .diarization }
            if lower.contains("whisper") { return .whisper }
            return .plain
        }

        /// У whisper развёрнутый ответ с таймингами имеет смысл только когда
        /// таймкоды включены; diarize без `diarized_json` вовсе не отдаёт
        /// говорящих, поэтому там формат не зависит от переключателя.
        func responseFormat(timecodes: Bool) -> String {
            switch self {
            case .whisper: timecodes ? "verbose_json" : "json"
            case .diarization: "diarized_json"
            case .plain: "json"
            }
        }

        /// Название для журнала: по нему сразу видно, какой путь выбран.
        var title: String {
            switch self {
            case .whisper: "whisper"
            case .diarization: "с говорящими"
            case .plain: "текст"
            }
        }

        var acceptsPrompt: Bool { self != .diarization }
        var wantsWordTimestamps: Bool { self == .whisper }
    }

    /// Доступность — это наличие ключа. Проверять сеть заранее смысла нет:
    /// человек всё равно узнает об этом по ошибке конкретной расшифровки.
    func isAvailable() async -> Bool {
        ((try? keyProvider()) ?? nil)?.isEmpty == false
    }

    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, progress: progress, partial: { _ in })
    }

    func transcribe(
        audioURL: URL,
        progress: @Sendable (Int, Int) -> Void,
        partial: @Sendable (Transcript) -> Void
    ) async throws -> Transcript {
        guard let key = try keyProvider(), !key.isEmpty else {
            throw TranscriptionError.missingKey(.openAI)
        }
        let model = TranscriptionSettings.openAIModel
        let duration = try await splitter.duration(of: audioURL)
        let bySize = splitter.partSeconds(for: audioURL, duration: duration, maxBytes: Self.maxRequestBytes)
        let seconds = min(bySize, Self.maxPartSeconds)
        let parts = try await splitter.split(audioURL, partSeconds: seconds)
        defer { splitter.discard(parts) }

        var words: [TranscriptWord] = []
        var segments: [TranscriptSegment] = []
        var texts: [String] = []
        // Части заходят друг на друга, поэтому слова и реплики из перекрытия
        // отбрасываются по времени — иначе стык дублируется в тексте.
        let assembler = TranscriptAssembler()
        var coveredUntil: TimeInterval = 0
        for (index, part) in parts.enumerated() {
            progress(index, parts.count)
            let answer = try await send(part: part, model: model, key: key)
            texts.append(answer.text)
            assembler.merge(
                into: &words,
                words: answer.words.map {
                    TranscriptWord(start: $0.start + part.start, end: $0.end + part.start, text: $0.text)
                },
                coveredUntil: coveredUntil
            )
            for segment in answer.segments {
                let shifted = TranscriptSegment(
                    start: segment.start + part.start,
                    end: segment.end + part.start,
                    text: segment.text
                )
                guard shifted.end > coveredUntil + 0.2 else { continue }
                segments.append(shifted)
            }
            coveredUntil = max(coveredUntil, part.end)
            // Часть готова — отдаём её сразу: ждать конца длинной записи,
            // глядя в пустой экран, незачем.
            partial(
                segments.isEmpty
                    ? Transcript(text: texts.joined(separator: "\n\n"))
                    : Transcript(text: texts.joined(separator: "\n\n"), segments: segments, words: words)
            )
        }
        progress(parts.count, parts.count)

        // Полнота проверяется и здесь: у whisper есть тайминги слов, а значит
        // видно, если модель пропустила участок записи. Без таймингов проверять
        // нечего: пустой список — это «время не пришло», а не «текста нет»,
        // и на нём проверка выдавала ложный пропуск на всю запись.
        var warnings: [String] = []
        let measured = segments.isEmpty
            ? words.map { TranscriptSegment(start: $0.start, end: $0.end, text: $0.text) }
            : segments
        if !measured.isEmpty {
            // Пропуск проверяется звуком, а не только арифметикой: порог здесь
            // восемь секунд, а восьмисекундных пауз в разговоре сколько угодно, и
            // плашка на каждой — ложная тревога. Порог тишины считается от уровня
            // речи этой же записи (`AudioLoudness`), переспроса тут нет: у whisper
            // тайминги плотные, и пропуск на нём почти всегда и есть молчание.
            let level = AudioLoudness.speechLevel(in: audioURL, speech: TranscriptCoverage.merged(measured))
            let threshold = AudioLoudness.threshold(speechLevel: level)
            let gaps = TranscriptCoverage.gaps(in: measured, duration: duration)
                .sorted { ($0.upperBound - $0.lowerBound) > ($1.upperBound - $1.lowerBound) }
            // Слушаем десять самых длинных: запись с сотней дыр сломана целиком,
            // и сто чтений звука этого не исправят.
            for gap in gaps.prefix(10) {
                guard let sound = AudioLoudness.sound(in: audioURL, range: gap, louderThan: threshold) else { continue }
                warnings.append("Пропуск \(TranscriptCoverage.describe(sound)): в ответе сервиса нет текста для этого участка.")
            }
        }
        if !warnings.isEmpty {
            Diagnostics.note("OpenAI: пропусков \(warnings.count), покрытие \(Int(TranscriptCoverage.share(measured, duration: duration) * 100))%")
        }

        let joined = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty || !words.isEmpty || !segments.isEmpty else {
            throw TranscriptionError.emptyResult
        }
        if !words.isEmpty {
            let assembled = assembler.transcript(from: words)
            return Transcript(
                text: assembled.text,
                segments: assembled.segments,
                words: assembled.words,
                warnings: warnings
            )
        }
        // Реплики с говорящими: таймкоды настоящие, а слов по отдельности сервис не даёт.
        if !segments.isEmpty {
            let text = segments.map(\.text).joined(separator: " ")
            return Transcript(text: text.isEmpty ? joined : text, segments: segments, warnings: warnings)
        }
        return Transcript(text: joined, warnings: warnings)
    }

    // MARK: - Запрос

    private struct Answer {
        let text: String
        let words: [TranscriptWord]
        let segments: [TranscriptSegment]
    }

    private func send(
        part: AudioSplitter.Part,
        model: String,
        key: String,
        withPrompt: Bool = true
    ) async throws -> Answer {
        let family = Family.of(model)
        let timecodes = TranscriptionSettings.timecodes
        var body = MultipartBody()
        body.field("model", model)
        body.field("response_format", family.responseFormat(timecodes: timecodes))
        // Язык записи: документация прямо говорит, что он улучшает точность и
        // скорость. У `gpt-transcribe` поле называется во множественном числе и
        // принимает список, у остальных — одиночное `language`. Когда выбрано
        // «определять сам», поле не отправляется вовсе: пустое значение сервис
        // считает ошибкой, а не просьбой угадать.
        if !TranscriptionSettings.detectsLanguage {
            let code = TranscriptionSettings.language
            if Self.usesLanguageList(model) {
                body.field("languages[]", code)
            } else {
                body.field("language", code)
            }
        }
        if family.wantsWordTimestamps, timecodes { body.field("timestamp_granularities[]", "word") }
        // Своя нарезка длинного аудио на стороне сервиса — так в документации
        // показан именно путь с разделением говорящих.
        if family == .diarization { body.field("chunking_strategy", "auto") }
        // Словарь уходит штатным полем `prompt`: модель считает его началом текста
        // и потому пишет имена и термины так, как они там написаны. Модели с
        // разделением говорящих подсказку не принимают вовсе и отвечают
        // «Prompt is not supported for diarization models».
        let hint = TranscriptionSettings.vocabularyHint
        if withPrompt, family.acceptsPrompt, !hint.isEmpty { body.field("prompt", hint) }
        // Тот же перевод в FLAC 16 кГц, что и для Gemini: ALAC сервисы не берут,
        // а вес запроса падает примерно в десять раз — при лимите 25 МБ это важно.
        let prepared = try CloudAudio.prepare(part.url, limit: Self.maxRequestBytes)
        defer { prepared.discard() }
        body.file(
            "file",
            filename: prepared.url.lastPathComponent,
            contentType: prepared.mime,
            data: try Data(contentsOf: prepared.url)
        )

        Diagnostics.note(
            "OpenAI → \(model) (\(family.title)) участок \(Int(part.start))–\(Int(part.end))с, "
            + "\(prepared.mime), \(body.size / 1024 / 1024) МБ, ответ \(family.responseFormat(timecodes: timecodes))"
        )
        var request = URLRequest(url: TranscriptionSettings.openAITranscriptionsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        // Часовая запись режется на части, но одна часть — это всё равно минуты
        // ожидания на медленной сети.
        request.timeoutInterval = 300
        request.httpBody = body.finish()

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await BackgroundTranscriptionTransport.data(for: request, session: session)
        } catch {
            // Таймаут и обрыв связи HTTP-кода не имеют, и раньше такой отказ
            // не оставлял в журнале ни строчки.
            Diagnostics.fault("OpenAI: запрос не дошёл — \(error.localizedDescription)")
            throw error
        }
        do {
            try APICheck.ensureSuccess(response: response, data: data)
        } catch {
            // Запасной путь на случай моделей, которые появятся позже: если сервис
            // ругается именно на подсказку, повторяем запрос без неё.
            guard withPrompt, Self.complainsAboutPrompt(error) else { throw error }
            Diagnostics.log.notice("OpenAI: модель не принимает подсказку, повторяю без словаря")
            return try await send(part: part, model: model, key: key, withPrompt: false)
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TranscriptionError.badResponse("OpenAI вернул ответ, который не удалось разобрать.")
        }
        let words = (decoded.words ?? []).compactMap { word -> TranscriptWord? in
            let text = word.word.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return TranscriptWord(start: word.start, end: word.end, text: text)
        }
        let segments = (decoded.segments ?? []).compactMap { segment -> TranscriptSegment? in
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            // Говорящий приписывается к реплике: в файле расшифровки это единственное
            // место, где он не потеряется.
            let labelled = segment.speaker.map { "\($0): \(text)" } ?? text
            return TranscriptSegment(start: segment.start, end: segment.end, text: labelled)
        }
        return Answer(text: decoded.text, words: words, segments: segments)
    }

    static func complainsAboutPrompt(_ error: Error) -> Bool {
        guard case let .api(message)? = error as? TranscriptionError else { return false }
        return message.localizedCaseInsensitiveContains("prompt")
    }

    private struct Response: Decodable {
        let text: String
        let words: [Word]?
        let segments: [Segment]?

        struct Word: Decodable {
            let word: String
            let start: TimeInterval
            let end: TimeInterval
        }

        /// Ответ `diarized_json`: реплики с временем и говорящим.
        struct Segment: Decodable {
            let start: TimeInterval
            let end: TimeInterval
            let text: String
            let speaker: String?
        }
    }

    /// Проверка ключа для настроек: список моделей — самый дешёвый запрос,
    /// который отвечает «ключ рабочий» без расхода на распознавание.
    func validate() async throws -> String {
        guard let key = try keyProvider(), !key.isEmpty else {
            throw TranscriptionError.missingKey(.openAI)
        }
        var request = URLRequest(url: TranscriptionSettings.openAIModelsURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await BackgroundTranscriptionTransport.data(for: request, session: session)
        try APICheck.ensureSuccess(response: response, data: data)
        return TranscriptionSettings.describedTarget(for: .openAI)
    }
}

/// Тело multipart/form-data. Своё, а не через сторонний пакет: полей четыре,
/// а зависимость в проекте без пакетного менеджера обошлась бы дороже.
struct MultipartBody {
    private let boundary = "lori-\(TranscriptionJob.current?.id ?? UUID().uuidString)"
    private var data = Data()

    /// Размер собранного тела — нужен журналу, чтобы видеть вес запроса.
    var size: Int { data.count }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func file(_ name: String, filename: String, contentType: String, data payload: Data) {
        append("--\(boundary)\r\n")
        let stableName = TranscriptionJob.current.map { $0.id + "." + (filename as NSString).pathExtension } ?? filename
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(stableName)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        data.append(payload)
        append("\r\n")
    }

    mutating func finish() -> Data {
        append("--\(boundary)--\r\n")
        return data
    }

    private mutating func append(_ text: String) {
        data.append(Data(text.utf8))
    }
}
