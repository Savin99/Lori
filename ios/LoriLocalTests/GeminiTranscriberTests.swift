import XCTest
@testable import LoriLocal

/// Запрос к Gemini: что уходит в сервис и как разбирается ответ.
/// Ни сети, ни ключа из Keychain здесь нет — транспорт и ключ подставляются.
final class GeminiTranscriberTests: XCTestCase {
    private var audio: URL!
    private let keys = [
        TranscriptionSettings.geminiModelKey,
        TranscriptionSettings.geminiBaseURLKey,
        TranscriptionSettings.geminiModeKey,
        TranscriptionSettings.vocabularyKey,
        TranscriptionSettings.languageKey,
        TranscriptionSettings.timecodesKey,
        TranscriptionSettings.speakerLabelsKey,
    ]

    override func setUpWithError() throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        audio = FileManager.default.temporaryDirectory.appending(path: "gem-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 3, at: audio)
    }

    override func tearDownWithError() throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        try? FileManager.default.removeItem(at: audio)
        StubURLProtocol.reset()
    }

    // MARK: - Ответы сервиса

    /// Нативные тайминги слов, как их отдаёт модель расшифровки.
    private static func wordsReply(_ words: [(Double, Double, String, String?)]) -> StubURLProtocol.Reply {
        let items: [[String: Any]] = words.map { word in
            var item: [String: Any] = [
                "word": word.2,
                "start_offset": "\(word.0)s",
                "end_offset": "\(word.1)s",
            ]
            if let speaker = word.3 { item["speaker"] = speaker }
            return item
        }
        let payload = try! JSONSerialization.data(withJSONObject: [
            "steps": [["type": "model_output", "content": [["type": "transcript", "words": items]]]],
        ])
        return .json(String(data: payload, encoding: .utf8)!)
    }

    private static func textReply(_ text: String) -> StubURLProtocol.Reply {
        let payload = try! JSONSerialization.data(withJSONObject: [
            "steps": [["type": "model_output", "content": [["type": "text", "text": text]]]],
        ])
        return .json(String(data: payload, encoding: .utf8)!)
    }

    /// Только отправки: при отказе поля приложение ещё спрашивает карточку модели,
    /// и по номеру запроса легко попасть в неё вместо расшифровки.
    private func payload(of index: Int = 0) throws -> [String: Any] {
        let sent = StubURLProtocol.requests.filter { !$0.body.isEmpty }
        let request = try XCTUnwrap(sent[safe: index])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    private static let card = StubURLProtocol.Reply.json(
        "{\"name\": \"models/gemini-3.5-transcribe\", \"supportedGenerationMethods\": [\"generateContent\"]}"
    )

    // MARK: - Один запрос вместо нарезки

    /// Запись до предела уходит одним запросом: никакой ручной нарезки, из-за
    /// которой и появлялись срывы на стыках.
    func testShortRecordingGoesInOneRequest() async throws {
        let session = StubURLProtocol.session { _, _ in
            Self.wordsReply([(0, 0.5, "Привет", nil), (0.6, 1.2, "мир.", nil)])
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertEqual(StubURLProtocol.requests.count, 1, "одна запись — один запрос")
        XCTAssertEqual(transcript.text, "Привет мир.")
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertFalse(transcript.segments[0].isApproximate, "тайминги нативные, а не границы куска")
        XCTAssertEqual(transcript.segments[0].start, 0)
    }

    /// Нативные тайминги слов и говорящие: то, ради чего тумблеры и включают.
    func testWordTimingsAndSpeakersBecomeSegments() async throws {
        UserDefaults.standard.set(GeminiMode.accuracy.rawValue, forKey: TranscriptionSettings.geminiModeKey)
        UserDefaults.standard.set(true, forKey: TranscriptionSettings.timecodesKey)
        UserDefaults.standard.set(true, forKey: TranscriptionSettings.speakerLabelsKey)
        let session = StubURLProtocol.session { _, _ in
            Self.wordsReply([
                (0, 0.4, "Значит", "spk:0"),
                (0.5, 1.0, "начали.", "spk:0"),
                (2.0, 2.6, "Согласен.", "spk:1"),
            ])
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertEqual(transcript.segments.count, 2, "смена говорящего разделяет реплики")
        XCTAssertEqual(transcript.segments.first?.text, "S1: Значит начали.")
        XCTAssertEqual(transcript.segments.last?.text, "S2: Согласен.")
        XCTAssertEqual(transcript.segments.last?.start ?? 0, 2.0, accuracy: 0.01)
    }

    // MARK: - Настройки запроса

    func testAutomaticLanguageSendsNoTag() async throws {
        UserDefaults.standard.set("", forKey: TranscriptionSettings.languageKey)
        let session = StubURLProtocol.session { _, _ in Self.textReply("Текст") }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio)

        XCTAssertNil(try payload()["language"])
    }

    /// Форма настроек у интерфейса своя: на «Unknown name» приложение убирает
    /// именно это поле и повторяет запрос, а не падает.
    func testUnknownFieldIsDroppedAndRequestRepeated() async throws {
        UserDefaults.standard.set(GeminiMode.accuracy.rawValue, forKey: TranscriptionSettings.geminiModeKey)
        UserDefaults.standard.set(true, forKey: TranscriptionSettings.timecodesKey)
        UserDefaults.standard.set("MCP", forKey: TranscriptionSettings.vocabularyKey)
        let session = StubURLProtocol.session { request, body in
            if request.httpMethod == "GET" { return Self.card }
            if body.range(of: Data("custom_vocabulary".utf8)) != nil {
                return .json(
                    #"{"error":{"code":400,"message":"Invalid JSON payload received. Unknown name \"custom_vocabulary\": Cannot find field."}}"#,
                    status: 400
                )
            }
            return Self.wordsReply([(0, 1, "Слово", nil)])
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertEqual(transcript.text, "Слово")
        let sent = StubURLProtocol.requests.filter { !$0.body.isEmpty }
        XCTAssertEqual(sent.count, 2, "первый запрос отклонён, второй — без неизвестного поля")
        let config = try XCTUnwrap(
            (try payload(of: 1)["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any]
        )
        XCTAssertNil(config["custom_vocabulary"], "непринятое поле убрано")
        XCTAssertNotNil(config["mode"], "остальные настройки остаются")
    }

    /// Словарь не теряется, даже если штатное поле не принято: он уходит в подсказку.
    func testVocabularyMovesToPromptWhenFieldIsRejected() async throws {
        UserDefaults.standard.set("MCP\nДокер", forKey: TranscriptionSettings.vocabularyKey)
        let session = StubURLProtocol.session { _, body in
            if body.range(of: Data("custom_vocabulary".utf8)) != nil {
                return .json(
                    #"{"error":{"message":"Unknown name \"custom_vocabulary\": Cannot find field."}}"#,
                    status: 400
                )
            }
            return Self.textReply("Текст")
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio)

        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertTrue(request.contains("MCP"), "словарь должен остаться хотя бы в подсказке")
    }

    func testUnknownFieldNameIsParsedFromServiceMessage() {
        let error = TranscriptionError.api("Invalid JSON payload received. Unknown name \"timestamp_granularities\": Cannot find field.")
        XCTAssertEqual(GeminiTranscriber.unknownField(error), "timestamp_granularities")
        XCTAssertNil(GeminiTranscriber.unknownField(TranscriptionError.api("API key not valid")))
    }

    // MARK: - Files API и ошибки

    /// Крупное аудио уходит по ссылке через Files API — так рекомендует документация.
    func testLargeAudioGoesThroughFilesAPI() async throws {
        let session = StubURLProtocol.session { request, _ in
            let path = request.url?.path ?? ""
            let command = request.value(forHTTPHeaderField: "X-Goog-Upload-Command") ?? ""
            if path.hasPrefix("/upload/v1beta/files"), command == "start" {
                return StubURLProtocol.Reply(
                    status: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "x-goog-upload-url": "https://generativelanguage.googleapis.com/upload/v1beta/files?id=1",
                    ],
                    body: Data()
                )
            }
            if path.hasPrefix("/upload/v1beta/files") {
                return .json(#"{"file":{"name":"files/abc","uri":"https://generativelanguage.googleapis.com/v1beta/files/abc","state":"ACTIVE"}}"#)
            }
            return Self.textReply("Текст по ссылке.")
        }
        // Порог в один байт заставляет пойти через загрузку файла.
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" }, inlineLimit: 1)

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertEqual(transcript.text, "Текст по ссылке.")
        let paths = StubURLProtocol.requests.compactMap { $0.request.url?.path }
        XCTAssertEqual(paths.filter { $0.hasPrefix("/upload/v1beta/files") }.count, 2, "загрузка идёт в два шага")

        let ask = try XCTUnwrap(StubURLProtocol.requests.first { $0.request.url?.path.hasSuffix("/interactions") == true })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: ask.body) as? [String: Any])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["uri"] as? String, "https://generativelanguage.googleapis.com/v1beta/files/abc")
        XCTAssertNil(input.first?["data"], "байты в запросе не дублируются")
    }

    func testGeoBlockIsExplainedNotSwallowed() async throws {
        let session = StubURLProtocol.session { _, _ in
            .json(#"{"error":{"code":400,"message":"User location is not supported for the API use."}}"#, status: 400)
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        do {
            _ = try await engine.transcribe(audioURL: audio)
            XCTFail("отказ по региону должен дойти до человека")
        } catch {
            guard case let .api(message)? = error as? TranscriptionError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("региона"), message)
        }
    }

    func testWithoutKeyNothingIsSent() async throws {
        let session = StubURLProtocol.session { _, _ in Self.textReply("не должно случиться") }
        let engine = GeminiTranscriber(session: session, keyProvider: { nil })

        do {
            _ = try await engine.transcribe(audioURL: audio)
            XCTFail("без ключа запрос уходить не должен")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .missingKey(.gemini))
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: - Незнакомая форма ответа

    /// Пустая расшифровка на устройстве получилась именно так: сервис ответил,
    /// а разбор искал текст по единственному известному пути. Теперь ответ
    /// просматривается целиком.
    func testTranscriptIsFoundInUnfamiliarResponseShape() async throws {
        let spoken = "Значит смотри, я записал эту встречу целиком и жду расшифровку."
        let session = StubURLProtocol.session { _, _ in
            .json("{\"response\": {\"results\": [{\"alternatives\": [{\"transcript\": \"\(spoken)\"}]}]}, \"state\": \"ACTIVE\"}")
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertEqual(transcript.text, spoken, "текст найден, хотя лежал не там, где ждали")
    }

    /// Служебные строки за расшифровку не принимаются.
    func testServiceFieldsAreNotMistakenForSpeech() throws {
        let json: [String: Any] = ["state": "ACTIVE", "model": "gemini-3.5-transcribe", "id": "abc-123"]
        XCTAssertNil(GeminiAnnotations.text(in: json))
    }

    /// У специализированной модели поведение задают поля запроса, а не текст.
    func testTranscribeModelGetsNoTextPrompt() async throws {
        let session = StubURLProtocol.session { _, _ in Self.textReply("Текст расшифровки записи.") }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio)

        let input = try XCTUnwrap(try payload()["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1, "в запросе только аудио")
        XCTAssertNil(input.first(where: { $0["type"] as? String == "text" }), "подсказка не нужна")
    }

    /// Когда штатное поле не приняли, подсказка возвращается — иначе настройка потеряется.
    func testPromptReturnsWhenFieldWasRejected() async throws {
        let counter = Counter()
        UserDefaults.standard.set("MCP", forKey: TranscriptionSettings.vocabularyKey)
        let refusal = "{\"error\": {\"message\": \"Unknown name \\\"custom_vocabulary\\\": cannot be found\"}}"
        let session = StubURLProtocol.session { request, _ in
            if request.httpMethod == "GET" { return Self.card }
            return counter.next() == 1 ? .json(refusal, status: 400) : Self.textReply("Текст расшифровки записи.")
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio)

        let input = try XCTUnwrap(try payload(of: 1)["input"] as? [[String: Any]])
        let prompt = try XCTUnwrap(input.first(where: { $0["type"] as? String == "text" })?["text"] as? String)
        XCTAssertTrue(prompt.contains("MCP"), "словарь ушёл текстом: \(prompt)")
    }

    /// Живой формат меток говорящих (28 августа): «spk:0», «spk:1» — счёт с нуля.
    /// Показ — латиницей «S1»: владелец выбрал её вместо «Г1».
    func testSpeakerLabelsAreNormalized() {
        XCTAssertEqual(GeminiAnnotations.label(for: "spk:0"), "S1")
        XCTAssertEqual(GeminiAnnotations.label(for: "spk:1"), "S2")
        XCTAssertEqual(GeminiAnnotations.label(for: "1"), "S1")
        XCTAssertEqual(GeminiAnnotations.label(for: "speaker_2"), "S2")
        XCTAssertEqual(GeminiAnnotations.label(for: "Г1"), "S1", "старое написание не расползается")
        XCTAssertEqual(GeminiAnnotations.label(for: "Илья"), "Илья", "имя остаётся именем")
    }

    // MARK: - Подсказка следует тумблерам

    /// Fallback-просьбы повторяют тумблеры: включены только говорящие — в тексте
    /// просятся только они, без абзаца про время.
    func testPromptFollowsTogglesWhenModeIsRejected() {
        let capabilities = GeminiTranscriber.Capabilities()
        capabilities.drop("mode")
        let speakersOnly = GeminiTranscriber.Ask(mode: .accuracy, timestamps: false, speakers: true)

        let prompt = GeminiTranscriber.prompt(insist: false, ask: speakersOnly, capabilities: capabilities)

        XCTAssertTrue(prompt.contains("S1"), "говорящих просим: \(prompt)")
        XCTAssertFalse(prompt.contains("квадратных скобках"), "время не просили — и не просим")
    }

    /// Абзац про время встречается один раз: он был продублирован дословно.
    func testStampsParagraphAppearsExactlyOnce() {
        let capabilities = GeminiTranscriber.Capabilities()
        capabilities.drop("mode")
        let both = GeminiTranscriber.Ask(mode: .accuracy, timestamps: true, speakers: true)

        let prompt = GeminiTranscriber.prompt(insist: false, ask: both, capabilities: capabilities)

        let marker = "квадратных скобках"
        let occurrences = prompt.components(separatedBy: marker).count - 1
        XCTAssertEqual(occurrences, 1, "абзац про время не должен дублироваться: \(prompt)")
        XCTAssertTrue(prompt.contains("S1"))
    }

    /// Таймкоды не просили — похожие на них числа в тексте ответа не время.
    func testStampsInTextAreIgnoredWhenNotRequested() async throws {
        UserDefaults.standard.set(GeminiMode.accuracy.rawValue, forKey: TranscriptionSettings.geminiModeKey)
        UserDefaults.standard.set(false, forKey: TranscriptionSettings.timecodesKey)
        UserDefaults.standard.set(false, forKey: TranscriptionSettings.speakerLabelsKey)
        let session = StubURLProtocol.session { _, _ in
            Self.textReply("[0:01] Первая строка похожа на штамп.\n[0:02] И вторая тоже.")
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertEqual(transcript.segments.count, 1, "текст не разбирается на реплики по случайным числам")
        XCTAssertTrue(transcript.segments[0].isApproximate)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int { lock.withLock { value += 1; return value } }
    }
}


private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
