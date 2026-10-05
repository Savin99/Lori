import XCTest
@testable import LoriLocal

/// Форма запроса к Gemini. Здесь проверяется то, что уже ломалось на устройстве:
/// отказ отдельного поля, ошибочный уход на другую точку входа, лишняя подсказка.
final class GeminiRequestShapeTests: XCTestCase {
    private var audio: URL!
    private let keys = [
        TranscriptionSettings.geminiModeKey,
        TranscriptionSettings.vocabularyKey,
        TranscriptionSettings.languageKey,
        TranscriptionSettings.timecodesKey,
        TranscriptionSettings.speakerLabelsKey,
    ]

    override func setUpWithError() throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        audio = FileManager.default.temporaryDirectory.appending(path: "shape-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 2, at: audio)
    }

    override func tearDownWithError() throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        try? FileManager.default.removeItem(at: audio)
        StubURLProtocol.reset()
    }

    /// Настоящий ответ сервиса: значение поля не подошло. Это отказ поля, а не
    /// пропавший метод — на устройстве приложение бросало рабочую точку входа.
    func testRejectedFieldValueDropsFieldAndKeepsEndpoint() async throws {
        let counter = Counter()
        let complaint = "The value 'verbatim' is not supported for 'mode'. Supported values: 'live'."
        let session = StubURLProtocol.session { request, _ in
            if Self.isCard(request) { return Self.card }
            return counter.next() == 1
                ? .json("{\"error\": {\"message\": \"\(complaint)\"}}", status: 400)
                : Self.words([(0, 1, "Работает.")])
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertEqual(transcript.text, "Работает.")
        let sent = StubURLProtocol.requests.filter { !$0.body.isEmpty }
        let paths = sent.map { $0.request.url?.path ?? "" }
        XCTAssertTrue(paths.allSatisfy { $0.hasSuffix("interactions") }, "точка входа та же: \(paths)")
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1].body) as? [String: Any])
        let config = try XCTUnwrap(
            (second["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any]
        )
        XCTAssertNil(config["mode"], "непринятое поле убрано")
        XCTAssertEqual(config["language_codes"] as? [String], ["ru-RU"], "остальные настройки на месте")
    }

    func testValueComplaintIsNotTreatedAsMissingEndpoint() {
        let error = TranscriptionError.api("The value 'verbatim' is not supported for 'mode'.")
        XCTAssertFalse(GeminiTranscriber.looksLikeMissingEndpoint(error))
        XCTAssertEqual(GeminiTranscriber.unknownField(error), "mode")
    }

    func testMissingMethodStillSwitchesToClassicPath() async throws {
        let counter = Counter()
        let session = StubURLProtocol.session { request, _ in
            if Self.isCard(request) { return Self.card }
            return counter.next() == 1
                ? .json("{\"error\": {\"message\": \"Requested entity was not found.\"}}", status: 404)
                : Self.words([(0, 1, "Классика.")])
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio)

        let paths = StubURLProtocol.requests
            .filter { !$0.body.isEmpty }
            .map { $0.request.url?.path ?? "" }
        XCTAssertTrue(paths.last?.contains("generateContent") == true, "ушли на классический путь: \(paths)")
    }

    /// Классический путь для модели расшифровки: только запись, без подсказки.
    /// Прошлый запрос уходил с 49 токенами текста и возвращался пустым.
    func testClassicPathSendsAudioOnlyForTranscribeModel() async throws {
        let counter = Counter()
        let session = StubURLProtocol.session { request, _ in
            if Self.isCard(request) { return Self.card }
            return counter.next() == 1
                ? .json("{\"error\": {\"message\": \"Requested entity was not found.\"}}", status: 404)
                : Self.words([(0, 1, "Только аудио.")])
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio)

        // Между запросами есть ещё обращение за карточкой модели — берём отправки.
        let sent = try XCTUnwrap(StubURLProtocol.requests.last(where: { !$0.body.isEmpty }))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        let parts = try XCTUnwrap((body["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1, "в запросе только запись")
        XCTAssertNotNil(parts[0]["inline_data"] ?? parts[0]["file_data"])
    }

    /// Пустой ответ объясняется по расходу токенов: так и выяснилось, что аудио
    /// сервис прочитал целиком, а выдал ноль.
    func testEmptyAnswerIsExplainedByTokenUsage() throws {
        let reply = """
        {"candidates": [{"content": {"parts": [{}], "role": "model"}, "finishReason": "STOP"}],
         "usageMetadata": {"promptTokenCount": 17351, "candidatesTokenCount": 0,
         "promptTokensDetails": [{"modality": "AUDIO", "tokenCount": 17302}]}}
        """
        let summary = GeminiTranscriber.describeOutcome(Data(reply.utf8))

        XCTAssertTrue(summary.contains("STOP"), summary)
        XCTAssertTrue(summary.contains("17302"), "видно, что запись дошла: \(summary)")
        XCTAssertTrue(summary.contains("выдано: 0"), summary)
    }

    /// Все формы отказа, которые сервис уже присылал. Каждая новая форма стоила
    /// отдельного прогона на устройстве — пусть их держит тест.
    func testEveryComplaintFormNamesTheField() {
        let cases = [
            "Invalid JSON payload received. Unknown name \"mode\": Cannot find field.": "mode",
            "The value 'verbatim' is not supported for 'mode'. Supported values: 'live'.": "mode",
            "Unknown parameter 'language'.": "language",
            "Unknown parameter \"custom_vocabulary\".": "custom_vocabulary",
            "Invalid value at 'payload.diarization'": "diarization",
            // Живой ответ сервиса (28 августа): без кавычек, виновник первым словом.
            "custom_vocabulary is incompatible with timestamps.": "custom_vocabulary",
        ]
        for (message, field) in cases {
            XCTAssertEqual(
                GeminiTranscriber.unknownField(TranscriptionError.api(message)),
                field,
                "не разобрано: \(message)"
            )
        }
    }

    /// Жалоба на подполе снимает только его: `verbatim` и говорящие остаются,
    /// а просьба про таймкоды переезжает в текст запроса.
    func testRejectedSubfieldKeepsModeAndOtherSubfield() async throws {
        UserDefaults.standard.set(GeminiMode.speakers.rawValue, forKey: TranscriptionSettings.geminiModeKey)
        let counter = Counter()
        let session = StubURLProtocol.session { request, _ in
            if Self.isCard(request) { return Self.card }
            return counter.next() == 1
                ? .json("{\"error\": {\"message\": \"Unknown name \\\"timestamp_granularities\\\": Cannot find field.\"}}", status: 400)
                : Self.words([(0, 1, "Работает.")])
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio)

        let sent = StubURLProtocol.requests.filter { !$0.body.isEmpty }
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1].body) as? [String: Any])
        let config = try XCTUnwrap(
            (second["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any]
        )
        let mode = try XCTUnwrap(config["mode"] as? [String: Any], "весь mode снимать нельзя")
        XCTAssertEqual(mode["type"] as? String, "verbatim")
        XCTAssertNil(mode["timestamp_granularities"], "непринятое подполе убрано")
        XCTAssertEqual(mode["diarization_mode"] as? String, "speaker", "второе подполе на месте")
        let input = try XCTUnwrap(second["input"] as? [[String: Any]])
        let prompt = input.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(prompt.contains("квадратных скобках"), "таймкоды теперь просятся текстом")
    }

    /// Живой сценарий от 28 августа: сервис не принимает словарь вместе с
    /// таймкодами. Словарь снимается и уходит подсказкой, таймкоды остаются.
    func testVocabularyIncompatibleWithTimestampsFallsBackToPrompt() async throws {
        UserDefaults.standard.set(GeminiMode.speakers.rawValue, forKey: TranscriptionSettings.geminiModeKey)
        UserDefaults.standard.set("Кайрос", forKey: TranscriptionSettings.vocabularyKey)
        let counter = Counter()
        let session = StubURLProtocol.session { request, _ in
            if Self.isCard(request) { return Self.card }
            return counter.next() == 1
                ? .json("{\"error\": {\"message\": \"custom_vocabulary is incompatible with timestamps.\"}}", status: 400)
                : Self.words([(0, 1, "Работает.")])
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertEqual(transcript.text, "Работает.")
        let sent = StubURLProtocol.requests.filter { !$0.body.isEmpty }
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1].body) as? [String: Any])
        let config = try XCTUnwrap(
            (second["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any]
        )
        XCTAssertNil(config["custom_vocabulary"], "несовместимое поле убрано")
        let mode = try XCTUnwrap(config["mode"] as? [String: Any])
        XCTAssertEqual(mode["timestamp_granularities"] as? [String], ["word"], "таймкоды человек просил — они остаются")
        let input = try XCTUnwrap(second["input"] as? [[String: Any]])
        let prompt = input.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(prompt.contains("Кайрос"), "словарь не потерян — ушёл текстом")
    }

    /// Отказы идут один за другим — убираться должны все, а не первое поле.
    func testFieldsAreDroppedOneAfterAnother() async throws {
        UserDefaults.standard.set(GeminiMode.speakers.rawValue, forKey: TranscriptionSettings.geminiModeKey)
        let counter = Counter()
        let session = StubURLProtocol.session { request, _ in
            if Self.isCard(request) { return Self.card }
            switch counter.next() {
            case 1: return .json("{\"error\": {\"message\": \"The value 'verbatim' is not supported for 'mode'.\"}}", status: 400)
            case 2: return .json("{\"error\": {\"message\": \"Unknown parameter 'language_codes'.\"}}", status: 400)
            case 3: return .json("{\"error\": {\"message\": \"Unknown parameter 'custom_vocabulary'.\"}}", status: 400)
            default: return Self.words([(0, 1, "Дошло.")])
            }
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertEqual(transcript.text, "Дошло.")
        let sent = try XCTUnwrap(StubURLProtocol.requests.last(where: { !$0.body.isEmpty }))
        let last = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(Set(last.keys), ["model", "input"], "остались только обязательные поля: \(last.keys)")
    }

    /// Ответ на запрос карточки модели: он теперь уходит при любом отказе поля,
    /// и в тестах его надо отделять от самих запросов расшифровки.
    private static let card = StubURLProtocol.Reply.json(
        "{\"name\": \"models/gemini-3.5-transcribe\", \"supportedGenerationMethods\": [\"generateContent\"]}"
    )

    private static func isCard(_ request: URLRequest) -> Bool {
        request.httpMethod == "GET"
    }

    private static func words(_ items: [(Double, Double, String)]) -> StubURLProtocol.Reply {
        let words: [[String: Any]] = items.map {
            ["word": $0.2, "start_offset": "\($0.0)s", "end_offset": "\($0.1)s"]
        }
        let payload = try! JSONSerialization.data(withJSONObject: [
            "steps": [["type": "model_output", "content": [["words": words]]]],
        ])
        return .json(String(data: payload, encoding: .utf8)!)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int { lock.withLock { value += 1; return value } }
    }
}
