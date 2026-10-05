import Foundation

/// Расшифровка через ElevenLabs Scribe: `POST /v1/speech-to-text`.
///
/// Отличие от двух других облачных движков — запись уходит **целиком, одним
/// запросом**. Нарезки здесь нет вовсе, и это не экономия кода:
///
/// 1. Говорящих сервис нумерует внутри запроса. Разрезать запись значит получить
///    «S1» в первой части и «S1» во второй — разных людей под одной меткой. А
///    разделение говорящих и есть главная причина выбрать этот движок.
/// 2. Тайминги каждого слова приходят нативно на всю запись, поэтому сдвигать
///    время по началу куска, склеивать перекрытия и отбрасывать дубли не нужно.
/// 3. Предел одного запроса — 5 ГБ и 10 часов (документация, `openapi.json`
///    сервиса). Часовая запись в FLAC 16 кГц моно — около 29 МБ, резать нечего.
///
/// Плата за это — минуты тишины на экране, пока идёт запрос. Поэтому движок
/// докладывает словами (`note`), сколько ушло на сервер: пустая полоса без
/// объяснения выглядит как зависшее приложение, владелец на этом уже спотыкался.
struct ElevenLabsTranscriber: Transcribing {
    /// Пределы сервиса. Проверяются заранее: отказ до отправки честнее, чем
    /// оборванная выгрузка на сотне мегабайт.
    static let maxSeconds: TimeInterval = 10 * 60 * 60
    static let maxRequestBytes = 5 * 1024 * 1024 * 1024

    let session: URLSession
    let splitter: AudioSplitter
    /// Ключ приходит извне: так движок проверяется тестами без Keychain и без сети.
    let keyProvider: @Sendable () throws -> String?

    init(
        session: URLSession = CloudSession.patient,
        splitter: AudioSplitter = AudioSplitter(),
        keyProvider: @escaping @Sendable () throws -> String? = { try KeychainStore.key(for: .elevenLabs) }
    ) {
        self.session = session
        self.splitter = splitter
        self.keyProvider = keyProvider
    }

    var name: String { "ElevenLabs · \(TranscriptionSettings.elevenLabsModel)" }

    /// Доступность — это наличие ключа. Проверять сеть заранее смысла нет:
    /// человек всё равно узнает об этом по ошибке конкретной расшифровки.
    func isAvailable() async -> Bool {
        ((try? keyProvider()) ?? nil)?.isEmpty == false
    }

    /// Что просим у сервиса в этой расшифровке. Считается один раз на запись:
    /// настройки, изменённые посреди расшифровки, не должны менять её на полпути.
    struct Ask: Sendable {
        let mode: ElevenLabsMode
        let timestamps: Bool
        let speakers: Bool

        static func fromSettings() -> Ask {
            Ask(
                mode: TranscriptionSettings.elevenLabsMode,
                timestamps: TranscriptionSettings.timecodes,
                speakers: TranscriptionSettings.speakerLabels
            )
        }
    }

    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, progress: progress, partial: { _ in }, note: { _ in })
    }

    func transcribe(
        audioURL: URL,
        progress: @Sendable (Int, Int) -> Void,
        partial: @Sendable (Transcript) -> Void,
        note: @Sendable (String) -> Void
    ) async throws -> Transcript {
        guard let key = try keyProvider(), !key.isEmpty else {
            throw TranscriptionError.missingKey(.elevenLabs)
        }
        let ask = Ask.fromSettings()
        let duration = try await splitter.duration(of: audioURL)
        guard duration <= Self.maxSeconds else {
            throw TranscriptionError.api(
                "ElevenLabs берёт до 10 часов одним запросом, а в записи \(Int(duration / 3600)) ч. "
                + "Выбери другой движок или раздели запись."
            )
        }

        // Одна часть — один запрос: полоса показывает начало и конец, как у
        // Gemini на коротких записях.
        progress(0, 1)
        let answer = try await send(audioURL, key: key, ask: ask, duration: duration, note: note)
        progress(1, 1)
        return try transcript(from: answer, ask: ask, audioURL: audioURL, duration: duration)
    }

    // MARK: - Запрос

    private struct Answer {
        let text: String
        /// Слово плюс метка говорящего, как её вернул сервис.
        let words: [(word: TranscriptWord, speaker: String?)]
    }

    private func send(
        _ audioURL: URL,
        key: String,
        ask: Ask,
        duration: TimeInterval,
        note: @Sendable (String) -> Void,
        withKeyterms: Bool = true
    ) async throws -> Answer {
        let model = TranscriptionSettings.elevenLabsModel
        var body = MultipartBody()
        body.field("model_id", model)
        // Язык записи: сервис принимает ISO-639-1 и ISO-639-3. «Определять сам» —
        // это отсутствие поля, а не пустая строка.
        if !TranscriptionSettings.detectsLanguage {
            body.field("language_code", TranscriptionSettings.language)
        }
        // Все три поля отправляются всегда, включая выключенные: у сервиса
        // `tag_audio_events` по умолчанию **включён**, и промолчать значит
        // получить «(laughter)» в тексте, не спросив человека.
        body.field("timestamps_granularity", ask.timestamps ? "word" : "none")
        body.field("diarize", ask.speakers ? "true" : "false")
        body.field("tag_audio_events", ask.mode == .events ? "true" : "false")
        if ask.mode == .clean { body.field("no_verbatim", "true") }

        // Словарь уходит штатным полем `keyterms` — оно для этого и сделано, в
        // отличие от `prompt` у whisper, который модель считает началом текста.
        // Поле платное: +20% к стоимости расшифровки, поэтому оно отправляется
        // только когда словарь действительно набран, и об этом сказано в
        // подсказке на экране провайдера.
        let keyterms = withKeyterms ? Self.keyterms(from: TranscriptionSettings.vocabulary) : []
        for term in keyterms { body.field("keyterms", term) }

        let prepared = try CloudAudio.prepare(audioURL, limit: Self.maxRequestBytes)
        defer { prepared.discard() }
        body.file(
            "file",
            filename: prepared.url.lastPathComponent,
            contentType: prepared.mime,
            data: try Data(contentsOf: prepared.url)
        )

        let megabytes = max(1, body.size / 1024 / 1024)
        Diagnostics.note(
            "ElevenLabs → \(model) вся запись \(Int(duration)) с, режим \(ask.mode.rawValue), "
            + "таймкоды \(ask.timestamps ? "вкл" : "выкл"), говорящие \(ask.speakers ? "вкл" : "выкл"), "
            + "\(prepared.mime), \(megabytes) МБ, словарь \(keyterms.count)"
        )
        // Запрос один и долгий, поэтому о нём говорится словами: иначе на экране
        // минуты пустой полосы без единого признака жизни.
        note("отправляю запись целиком, \(megabytes) МБ")

        var request = URLRequest(url: TranscriptionSettings.elevenLabsTranscriptionsURL)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        // Вся запись одним запросом: полтора часа звука на медленном канале —
        // это выгрузка плюс счёт на стороне сервиса.
        request.timeoutInterval = 1800
        request.httpBody = body.finish()

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await BackgroundTranscriptionTransport.data(for: request, session: session)
        } catch {
            // Таймаут и обрыв связи HTTP-кода не имеют — без этой строки такой
            // отказ не оставлял бы в журнале ничего.
            Diagnostics.fault("ElevenLabs: запрос не дошёл — \(error.localizedDescription)")
            throw error
        }
        do {
            try APICheck.ensureSuccess(response: response, data: data)
        } catch {
            // Словарь — удобство, а не условие работы: если сервис ругается
            // именно на `keyterms` (запрещённый символ, слишком длинный термин),
            // повторяем без словаря, а не отдаём человеку отказ.
            guard withKeyterms, !keyterms.isEmpty, Self.complainsAboutKeyterms(error) else { throw error }
            Diagnostics.log.notice("ElevenLabs: сервис не принял словарь, повторяю без него")
            note("сервис не принял словарь — повторяю без него")
            return try await send(
                audioURL, key: key, ask: ask, duration: duration, note: note, withKeyterms: false
            )
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TranscriptionError.badResponse("ElevenLabs вернул ответ, который не удалось разобрать.")
        }
        return Answer(
            text: decoded.text.trimmingCharacters(in: .whitespacesAndNewlines),
            words: Self.words(from: decoded.words ?? [], mode: ask.mode)
        )
    }

    /// Слова из ответа. `spacing` — это пробелы между словами, они нужны только
    /// готовому тексту; `audio_event` (смех, аплодисменты) речью не является и
    /// остаётся лишь в режиме «Со звуками».
    static func words(from raw: [Response.Word], mode: ElevenLabsMode) -> [(word: TranscriptWord, speaker: String?)] {
        raw.compactMap { item in
            let kind = item.type ?? "word"
            guard kind == "word" || (kind == "audio_event" && mode == .events) else { return nil }
            // Времени нет, когда таймкоды выключены (`timestamps_granularity: none`):
            // такое слово в список не попадает — придумывать ему границы нельзя.
            guard let start = item.start, let end = item.end else { return nil }
            let text = item.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return (TranscriptWord(start: start, end: max(end, start), text: text), item.speakerId)
        }
    }

    /// Метка говорящего. У сервиса это `speaker_0`, счёт с нуля; метки в
    /// приложении считаются с единицы («S1»), потому что человек читает их как
    /// «первый говорящий», а не как индекс массива.
    static func label(for speaker: String) -> String {
        let digits = speaker.filter(\.isNumber)
        guard let number = Int(digits) else { return speaker }
        return "S\(number + 1)"
    }

    /// Словарь под требования поля `keyterms`: не больше 50 символов на термин,
    /// не больше пяти слов, и без символов, которые сервис объявляет
    /// неподдерживаемыми — иначе весь запрос отвергается целиком из-за одного
    /// слова в словаре.
    static func keyterms(from terms: [String]) -> [String] {
        let forbidden = CharacterSet(charactersIn: "<>{}[]\\")
        return terms.compactMap { term -> String? in
            let clean = term
                .components(separatedBy: forbidden)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 50 else { return nil }
            guard clean.split(whereSeparator: \.isWhitespace).count <= 5 else { return nil }
            return clean
        }
    }

    static func complainsAboutKeyterms(_ error: Error) -> Bool {
        guard case let .api(message)? = error as? TranscriptionError else { return false }
        return message.localizedCaseInsensitiveContains("keyterm")
    }

    // MARK: - Разбор ответа

    private func transcript(
        from answer: Answer,
        ask: Ask,
        audioURL: URL,
        duration: TimeInterval
    ) throws -> Transcript {
        let words = answer.words.map(\.word)
        guard !answer.text.isEmpty || !words.isEmpty else { throw TranscriptionError.emptyResult }

        let assembler = TranscriptAssembler()
        let segments = ask.speakers
            ? Self.segmentsBySpeaker(answer.words, assembler: assembler)
            : assembler.segments(from: words)
        let warnings = Self.gapWarnings(segments: segments, audioURL: audioURL, duration: duration)

        guard !segments.isEmpty else {
            // Ни одного слова со временем: таймкоды выключены или сервис их не дал.
            // Текст при этом настоящий, и отдать его — единственно верное.
            return Transcript(text: answer.text, warnings: warnings)
        }
        // Текст берётся у сервиса, а не склеивается из слов: у него своя
        // расстановка пробелов и знаков, и она лучше склейки через пробел.
        // Исключение — разделение говорящих: метки живут в репликах, и без них
        // текст потерял бы, кто что сказал.
        let text = ask.speakers ? segments.map(\.text).joined(separator: "\n") : answer.text
        return Transcript(
            text: text.isEmpty ? answer.text : text,
            segments: segments,
            words: words,
            warnings: warnings
        )
    }

    /// Реплики с говорящими: подряд идущие слова одного голоса — это его речь,
    /// внутри неё реплики режутся как обычно, по знакам конца и паузам.
    /// Метка ставится каждой реплике: файл расшифровки разбирается построчно
    /// (`TranscriptDocument.speakerMark`), и реплика без метки потеряла бы автора.
    static func segmentsBySpeaker(
        _ words: [(word: TranscriptWord, speaker: String?)],
        assembler: TranscriptAssembler
    ) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var run: [TranscriptWord] = []
        var speaker: String?

        func flush() {
            defer { run = [] }
            guard !run.isEmpty else { return }
            let mark = speaker.map { "\(label(for: $0)): " } ?? ""
            result += assembler.segments(from: run).map {
                TranscriptSegment(start: $0.start, end: $0.end, text: mark + $0.text)
            }
        }

        for item in words {
            if item.speaker != speaker {
                flush()
                speaker = item.speaker
            }
            run.append(item.word)
        }
        flush()
        return result.sorted { $0.start < $1.start }
    }

    /// Участки записи, для которых сервис не вернул ни слова. Проверка та же,
    /// что у OpenAI: молчать о пропуске нельзя — человек решит, что там тишина.
    /// Порог тишины считается от уровня речи этой же записи, иначе плашка
    /// вылезала бы на каждой восьмисекундной паузе в разговоре.
    static func gapWarnings(
        segments: [TranscriptSegment],
        audioURL: URL,
        duration: TimeInterval
    ) -> [String] {
        guard !segments.isEmpty else { return [] }
        let level = AudioLoudness.speechLevel(in: audioURL, speech: TranscriptCoverage.merged(segments))
        let threshold = AudioLoudness.threshold(speechLevel: level)
        var warnings: [String] = []
        let gaps = TranscriptCoverage.gaps(in: segments, duration: duration)
            .sorted { ($0.upperBound - $0.lowerBound) > ($1.upperBound - $1.lowerBound) }
        // Десять самых длинных: запись с сотней дыр сломана целиком, и сто
        // чтений звука этого не исправят.
        for gap in gaps.prefix(10) {
            guard let sound = AudioLoudness.sound(in: audioURL, range: gap, louderThan: threshold) else { continue }
            warnings.append("Пропуск \(TranscriptCoverage.describe(sound)): в ответе сервиса нет текста для этого участка.")
        }
        if !warnings.isEmpty {
            Diagnostics.note(
                "ElevenLabs: пропусков \(warnings.count), покрытие "
                + "\(Int(TranscriptCoverage.share(segments, duration: duration) * 100))%"
            )
        }
        return warnings
    }

    struct Response: Decodable {
        let text: String
        let words: [Word]?

        struct Word: Decodable {
            let text: String
            let start: TimeInterval?
            let end: TimeInterval?
            /// `word`, `spacing` или `audio_event`.
            let type: String?
            let speakerId: String?

            enum CodingKeys: String, CodingKey {
                case text, start, end, type
                case speakerId = "speaker_id"
            }
        }
    }

    /// Проверка ключа для настроек: `GET /v1/user` — самый дешёвый запрос,
    /// который отвечает «ключ рабочий» без расхода на расшифровку. Списка
    /// моделей распознавания у сервиса нет, поэтому проверять им нечего.
    func validate() async throws -> String {
        guard let key = try keyProvider(), !key.isEmpty else {
            throw TranscriptionError.missingKey(.elevenLabs)
        }
        var request = URLRequest(url: TranscriptionSettings.elevenLabsUserURL)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 30
        let (data, response) = try await BackgroundTranscriptionTransport.data(for: request, session: session)
        try APICheck.ensureSuccess(response: response, data: data)
        return TranscriptionSettings.describedTarget(for: .elevenLabs)
    }
}
