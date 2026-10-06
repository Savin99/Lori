import XCTest
@testable import LoriLocal

/// Движок ElevenLabs Scribe целиком: что уходит в запросе и что получается из
/// ответа. Ни сети, ни ключа из Keychain здесь нет — транспорт и ключ подставляются.
final class ElevenLabsTranscriberTests: XCTestCase {
    private var audio: URL!
    private let keys = [
        TranscriptionSettings.elevenLabsBaseURLKey,
        TranscriptionSettings.elevenLabsModelKey,
        TranscriptionSettings.elevenLabsModeKey,
        TranscriptionSettings.vocabularyKey,
        TranscriptionSettings.languageKey,
        TranscriptionSettings.timecodesKey,
        TranscriptionSettings.speakerLabelsKey,
    ]

    override func setUpWithError() throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        audio = FileManager.default.temporaryDirectory.appending(path: "lori-\(UUID().uuidString).wav")
        try AudioFixture.wav(at: audio)
    }

    override func tearDownWithError() throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        try? FileManager.default.removeItem(at: audio)
        StubURLProtocol.reset()
    }

    private func engine(_ reply: @escaping @Sendable (URLRequest, Data) -> StubURLProtocol.Reply) -> ElevenLabsTranscriber {
        ElevenLabsTranscriber(session: StubURLProtocol.session(reply), keyProvider: { "тест-ключ" })
    }

    private static let plain = #"{"text":"Привет мир.","language_code":"rus","words":[{"text":"Привет","start":0.0,"end":0.4,"type":"word"},{"text":" ","start":0.4,"end":0.5,"type":"spacing"},{"text":"мир.","start":0.5,"end":0.9,"type":"word"}]}"#

    // MARK: - Запрос

    func testRequestCarriesModelKeyLanguageAndFile() async throws {
        _ = try await engine { _, _ in .json(Self.plain) }.transcribe(audioURL: audio)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "xi-api-key"), "тест-ключ")
        XCTAssertNil(sent.request.value(forHTTPHeaderField: "Authorization"), "ключ у сервиса живёт в своём заголовке")
        XCTAssertTrue(sent.contains("name=\"model_id\""))
        XCTAssertTrue(sent.contains(TranscriptionSettings.defaultElevenLabsModel))
        XCTAssertTrue(sent.contains("name=\"language_code\""))
        XCTAssertTrue(sent.contains("filename=\"\(audio.lastPathComponent)\""))
    }

    func testCustomAddressIsHonoured() async throws {
        UserDefaults.standard.set("https://proxy.example/v1", forKey: TranscriptionSettings.elevenLabsBaseURLKey)

        _ = try await engine { _, _ in .json(Self.plain) }.transcribe(audioURL: audio)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://proxy.example/v1/speech-to-text")
    }

    /// «Определять сам» — это отсутствие поля, а не пустая строка: пустое
    /// значение сервис считает ошибкой, а не просьбой угадать.
    func testAutomaticLanguageSendsNoField() async throws {
        UserDefaults.standard.set("", forKey: TranscriptionSettings.languageKey)

        _ = try await engine { _, _ in .json(Self.plain) }.transcribe(audioURL: audio)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertFalse(sent.contains("name=\"language_code\""))
    }

    /// Самое важное поле запроса: у сервиса `tag_audio_events` по умолчанию
    /// **включён**, и промолчать значит получить «(laughter)» в тексте, не
    /// спросив человека.
    func testAudioEventsAreSwitchedOffUnlessTheModeAsksForThem() async throws {
        _ = try await engine { _, _ in .json(Self.plain) }.transcribe(audioURL: audio)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertTrue(sent.contains("name=\"tag_audio_events\""), "поле обязано уйти явно")
        XCTAssertTrue(sent.contains("tag_audio_events\"\r\n\r\nfalse"))
        XCTAssertFalse(sent.contains("name=\"no_verbatim\""), "дословность — умолчание, поле не нужно")
    }

    func testEventsModeAsksForTagsAndKeepsThemInTheText() async throws {
        UserDefaults.standard.set(ElevenLabsMode.events.rawValue, forKey: TranscriptionSettings.elevenLabsModeKey)
        let answer = #"{"text":"Смешно (laughter)","words":[{"text":"Смешно","start":0.0,"end":0.4,"type":"word"},{"text":"(laughter)","start":0.5,"end":1.2,"type":"audio_event"}]}"#

        let transcript = try await engine { _, _ in .json(answer) }.transcribe(audioURL: audio)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertTrue(sent.contains("tag_audio_events\"\r\n\r\ntrue"))
        XCTAssertEqual(transcript.words.map(\.text), ["Смешно", "(laughter)"])
    }

    /// Пометка нереплики речью не является: вне режима «Со звуками» её в
    /// расшифровке быть не должно, даже если сервис её всё-таки прислал.
    func testAudioEventsDoNotLeakIntoVerbatimMode() async throws {
        let answer = #"{"text":"Смешно","words":[{"text":"Смешно","start":0.0,"end":0.4,"type":"word"},{"text":"(laughter)","start":0.5,"end":1.2,"type":"audio_event"}]}"#

        let transcript = try await engine { _, _ in .json(answer) }.transcribe(audioURL: audio)

        XCTAssertEqual(transcript.words.map(\.text), ["Смешно"])
    }

    func testCleanModeAsksTheServiceToTidyTheText() async throws {
        UserDefaults.standard.set(ElevenLabsMode.clean.rawValue, forKey: TranscriptionSettings.elevenLabsModeKey)

        _ = try await engine { _, _ in .json(Self.plain) }.transcribe(audioURL: audio)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertTrue(sent.contains("no_verbatim\"\r\n\r\ntrue"))
    }

    /// Оба переключателя «Расшифровки» здесь настоящие, и это единственный
    /// движок, где они независимы: `EngineToggles` обещает `active` обоим.
    func testTogglesReachTheRequestIndependently() async throws {
        UserDefaults.standard.set(false, forKey: TranscriptionSettings.timecodesKey)
        UserDefaults.standard.set(true, forKey: TranscriptionSettings.speakerLabelsKey)

        _ = try await engine { _, _ in .json(#"{"text":"текст"}"#) }.transcribe(audioURL: audio)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertTrue(sent.contains("timestamps_granularity\"\r\n\r\nnone"))
        XCTAssertTrue(sent.contains("diarize\"\r\n\r\ntrue"))
        XCTAssertEqual(EngineToggles.current(for: .elevenLabs).timecodes, .active)
        XCTAssertEqual(EngineToggles.current(for: .elevenLabs).speakers, .active)
    }

    /// Вся запись уходит одним запросом, и полоса это признаёт: 0 из 1, затем
    /// 1 из 1. Нарезки у этого движка нет вовсе — сервис берёт до десяти часов,
    /// а разрезать запись значит перепутать говорящих на стыке.
    func testWholeRecordingGoesInOneRequest() async throws {
        let long = FileManager.default.temporaryDirectory.appending(path: "long-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 30, at: long)
        defer { try? FileManager.default.removeItem(at: long) }
        let steps = Steps()

        _ = try await engine { _, _ in .json(#"{"text":"Полминуты речи."}"#) }
            .transcribe(audioURL: long) { done, total in steps.add(done, total) }

        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(steps.recorded, [[0, 1], [1, 1]])
    }

    // MARK: - Словарь

    /// Словарь уходит штатным полем, а не подсказкой-текстом: `keyterms` для
    /// этого и сделано. Каждый термин — своё поле формы.
    func testVocabularyGoesIntoKeytermsFields() async throws {
        UserDefaults.standard.set("Кайрос\nИнтегра-4D", forKey: TranscriptionSettings.vocabularyKey)

        _ = try await engine { _, _ in .json(Self.plain) }.transcribe(audioURL: audio)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.occurrences(of: "name=\"keyterms\""), 2)
        XCTAssertTrue(sent.contains("Кайрос"))
        XCTAssertTrue(sent.contains("Интегра-4D"))
        XCTAssertFalse(sent.contains("name=\"prompt\""), "подсказки-текста у этого сервиса нет")
    }

    func testEmptyVocabularySendsNoKeyterms() async throws {
        _ = try await engine { _, _ in .json(Self.plain) }.transcribe(audioURL: audio)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.occurrences(of: "name=\"keyterms\""), 0)
    }

    /// Требования поля описаны в `openapi.json` сервиса: до 50 знаков, до пяти
    /// слов, и без `< > { } [ ] \`. Один плохой термин отверг бы **весь**
    /// запрос, поэтому чистится он здесь, а не у сервиса.
    func testKeytermsAreCleanedToTheServiceRules() {
        let cleaned = ElevenLabsTranscriber.keyterms(from: [
            "Кайрос",
            "Интегра<4D>",
            String(repeating: "я", count: 51),
            "шесть слов это уже слишком много",
            "  ",
        ])

        XCTAssertEqual(cleaned, ["Кайрос", "Интегра 4D"])
    }

    /// Отказ из-за словаря не должен стоить человеку расшифровки: словарь — это
    /// удобство, а не условие работы.
    func testServiceRejectingKeytermsIsRetriedWithoutThem() async throws {
        UserDefaults.standard.set("Кайрос", forKey: TranscriptionSettings.vocabularyKey)
        let session = StubURLProtocol.session { _, body in
            guard body.range(of: Data("name=\"keyterms\"".utf8)) != nil else { return .json(Self.plain) }
            return .json(#"{"detail":{"status":"invalid_keyterms","message":"keyterms are not supported"}}"#, status: 400)
        }

        let transcript = try await ElevenLabsTranscriber(session: session, keyProvider: { "тест-ключ" })
            .transcribe(audioURL: audio)

        XCTAssertEqual(transcript.text, "Привет мир.")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        XCTAssertEqual(StubURLProtocol.requests.last?.occurrences(of: "name=\"keyterms\""), 0)
    }

    // MARK: - Ответ

    func testWordTimingsBecomeSegments() async throws {
        let transcript = try await engine { _, _ in .json(Self.plain) }.transcribe(audioURL: audio)

        XCTAssertEqual(transcript.words.map(\.text), ["Привет", "мир."])
        XCTAssertEqual(transcript.segments.count, 1, "точка в конце закрывает реплику")
        XCTAssertEqual(transcript.text, "Привет мир.", "текст берётся у сервиса, а не склеивается из слов")
    }

    /// `spacing` — это пробелы между словами. Словом они не являются, и в
    /// таймлайне им места нет.
    func testSpacingIsNotAWord() async throws {
        let transcript = try await engine { _, _ in .json(Self.plain) }.transcribe(audioURL: audio)

        XCTAssertFalse(transcript.words.contains { $0.text.isEmpty })
        XCTAssertEqual(transcript.words.count, 2)
    }

    /// У сервиса говорящие считаются с нуля (`speaker_0`), а метки в приложении —
    /// с единицы: человек читает «S1» как «первый говорящий».
    func testSpeakersBecomeLabelledSegmentsCountedFromOne() async throws {
        UserDefaults.standard.set(true, forKey: TranscriptionSettings.speakerLabelsKey)
        let answer = """
        {"text":"Привет. Здравствуй.","words":[
          {"text":"Привет.","start":0.0,"end":0.5,"type":"word","speaker_id":"speaker_0"},
          {"text":"Здравствуй.","start":1.0,"end":1.8,"type":"word","speaker_id":"speaker_1"}
        ]}
        """

        let transcript = try await engine { _, _ in .json(answer) }.transcribe(audioURL: audio)

        XCTAssertEqual(transcript.segments.map(\.text), ["S1: Привет.", "S2: Здравствуй."])
        // Метка обязана читаться разбором файла расшифровки, иначе кружок
        // говорящего на экране записи её не найдёт.
        let mark = TranscriptDocument.speakerMark(in: try XCTUnwrap(transcript.segments.first?.text))
        XCTAssertEqual(mark?.label, "S1")
        XCTAssertEqual(mark?.rest, "Привет.")
    }

    func testSpeakerLabelCountsFromOne() {
        XCTAssertEqual(ElevenLabsTranscriber.label(for: "speaker_0"), "S1")
        XCTAssertEqual(ElevenLabsTranscriber.label(for: "speaker_11"), "S12")
        XCTAssertEqual(ElevenLabsTranscriber.label(for: "Лёша"), "Лёша", "имя остаётся именем")
    }

    /// Разделение говорящих просили, а сервис их не прислал (один голос на
    /// записи) — это не ошибка, реплики просто без меток.
    func testDiarizationWithoutSpeakersStillGivesSegments() async throws {
        UserDefaults.standard.set(true, forKey: TranscriptionSettings.speakerLabelsKey)

        let transcript = try await engine { _, _ in .json(Self.plain) }.transcribe(audioURL: audio)

        XCTAssertEqual(transcript.segments.map(\.text), ["Привет мир."])
    }

    /// Таймкоды выключены — времени в ответе нет, и придумывать его нельзя:
    /// границы отправленного куска это не таймкоды речи.
    func testTextWithoutTimingsStaysPlainText() async throws {
        UserDefaults.standard.set(false, forKey: TranscriptionSettings.timecodesKey)
        let answer = #"{"text":"Речь без времени.","words":[{"text":"Речь","type":"word"}]}"#

        let transcript = try await engine { _, _ in .json(answer) }.transcribe(audioURL: audio)

        XCTAssertEqual(transcript.text, "Речь без времени.")
        XCTAssertTrue(transcript.segments.isEmpty)
        XCTAssertTrue(transcript.words.isEmpty)
    }

    /// Пустой ответ — это отказ, а не расшифровка из пустой строки.
    func testEmptyAnswerIsAnError() async {
        do {
            _ = try await engine { _, _ in .json(#"{"text":""}"#) }.transcribe(audioURL: audio)
            XCTFail("пустой ответ обязан быть ошибкой")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .emptyResult)
        }
    }

    /// Тишина не должна давать плашку «пропуск»: у записи из нулей звука в
    /// незакрытых участках нет, а плашка на каждой паузе — ложная тревога.
    func testSilenceIsNotReportedAsAGap() async throws {
        let long = FileManager.default.temporaryDirectory.appending(path: "long-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 30, at: long)
        defer { try? FileManager.default.removeItem(at: long) }

        let transcript = try await engine { _, _ in .json(Self.plain) }.transcribe(audioURL: long)

        XCTAssertTrue(transcript.warnings.isEmpty, "ложный пропуск: \(transcript.warnings)")
    }

    /// Запись «минута разговора — проверяемый участок — минута разговора» с
    /// шумом комнаты: так выглядели пропуски на записи владельца 43:28.
    private func conversation(around middle: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "gap-\(UUID().uuidString).wav")
        try SyntheticSound.write(SyntheticSound.conversation(around: middle, seed: 71), to: url)
        return url
    }

    /// Ответ сервиса со словами только на заданных отрезках: «слово» каждые
    /// полсекунды, точка — на каждом десятом.
    private static func words(on ranges: [ClosedRange<TimeInterval>]) -> String {
        var items: [String] = []
        var texts: [String] = []
        for range in ranges {
            var time = range.lowerBound
            var count = 0
            while time + 0.4 <= range.upperBound {
                count += 1
                let text = count.isMultiple(of: 10) ? "слово." : "слово"
                items.append(
                    #"{"text":"\#(text)","start":\#(time),"end":\#(time + 0.4),"type":"word","speaker_id":"speaker_0"}"#
                )
                texts.append(text)
                time += 0.5
            }
        }
        return #"{"text":"\#(texts.joined(separator: " "))","language_code":"rus","words":[\#(items.joined(separator: ","))]}"#
    }

    /// **Случай владельца целиком через движок.** Минута тишины со щелчками,
    /// стуками, кашлем и клавиатурой, слов сервиса на ней нет — и плашки нет:
    /// это молчание, а не потерянная речь.
    func testSilentMinuteWithClicksAndCoughsIsNotAGap() async throws {
        let long = try conversation(around: SyntheticSound.busySilence(speech: 0.1, seed: 74))
        defer { try? FileManager.default.removeItem(at: long) }
        let answer = Self.words(on: [0...60, 120...180])

        let transcript = try await engine { _, _ in .json(answer) }.transcribe(audioURL: long)

        XCTAssertFalse(transcript.segments.isEmpty, "реплики на речи есть")
        XCTAssertTrue(transcript.warnings.isEmpty, "ложный пропуск над тишиной: \(transcript.warnings)")
    }

    /// А речь, которую сервис пропустил, по-прежнему называется — даже тихая:
    /// ради этого проверка и существует.
    func testSpeechTheServiceSkippedIsStillReported() async throws {
        let long = try conversation(around: SyntheticSound.speechLike(seconds: 60, level: 0.05, seed: 75))
        defer { try? FileManager.default.removeItem(at: long) }
        let answer = Self.words(on: [0...60, 120...180])

        let transcript = try await engine { _, _ in .json(answer) }.transcribe(audioURL: long)

        XCTAssertEqual(transcript.warnings.count, 1, "\(transcript.warnings)")
        // Пропуск по словам — от конца последнего слова (59,9 с) до 2:00; плашка
        // пишет время с точностью до секунды вниз.
        let range = try XCTUnwrap(transcript.warnings.first.flatMap(TranscriptCoverage.gap(in:)))
        XCTAssertGreaterThanOrEqual(range.lowerBound, 59, "плашка называет место внутри пропуска: \(range)")
        XCTAssertLessThanOrEqual(range.upperBound, 120, "\(range)")
        XCTAssertGreaterThan(range.upperBound - range.lowerBound, 50, "и почти целиком — речь там всю минуту: \(range)")
    }

    // MARK: - Ключ и ошибки

    func testMissingKeyIsNamedByTheAccount() async {
        let engine = ElevenLabsTranscriber(session: StubURLProtocol.session { _, _ in .json("{}") }, keyProvider: { nil })

        let available = await engine.isAvailable()
        XCTAssertFalse(available)
        do {
            _ = try await engine.transcribe(audioURL: audio)
            XCTFail("без ключа расшифровка обязана отказать")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .missingKey(.elevenLabs))
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "без ключа в сеть не ходим")
    }

    /// Форма ошибки у сервиса своя (`{"detail": …}`), и без её разбора человек
    /// получал в сообщении сырой JSON вместо текста сервиса.
    func testServiceErrorTextReachesThePerson() async {
        let session = StubURLProtocol.session { _, _ in
            .json(#"{"detail":{"status":"invalid_api_key","message":"Неверный ключ."}}"#, status: 401)
        }
        do {
            _ = try await ElevenLabsTranscriber(session: session, keyProvider: { "тест-ключ" })
                .transcribe(audioURL: audio)
            XCTFail("401 обязан быть ошибкой")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .api("Неверный ключ."))
        }
    }

    func testValidationFormsOfTheServiceErrorAreUnderstood() {
        XCTAssertEqual(APICheck.detail(in: Data(#"{"detail":"строкой"}"#.utf8)), "строкой")
        XCTAssertEqual(
            APICheck.detail(in: Data(#"{"detail":[{"msg":"поле не то"},{"msg":"и это"}]}"#.utf8)),
            "поле не то; и это"
        )
        XCTAssertNil(APICheck.detail(in: Data(#"{"error":{"message":"это OpenAI"}}"#.utf8)))
    }

    func testKeyCheckAsksTheCheapestEndpoint() async throws {
        let session = StubURLProtocol.session { _, _ in .json(#"{"subscription":{"tier":"pro"}}"#) }

        let target = try await ElevenLabsTranscriber(session: session, keyProvider: { "тест-ключ" }).validate()

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://api.elevenlabs.io/v1/user")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "xi-api-key"), "тест-ключ")
        XCTAssertTrue(target.contains("scribe_v2"))
    }
}

/// Счётчик шагов полосы: замыкание прогресса `@Sendable`, и копить в локальную
/// переменную из него нельзя.
private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [[Int]] = []

    func add(_ done: Int, _ total: Int) {
        lock.withLock { steps.append([done, total]) }
    }

    var recorded: [[Int]] { lock.withLock { steps } }
}
