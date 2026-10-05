import XCTest
@testable import LoriLocal

/// Форма запросов по официальной документации. Каждый пункт здесь — то, что
/// раньше отправлялось неправильно и стоило прогона на устройстве.
final class DocumentedShapeTests: XCTestCase {
    private var audio: URL!
    private let keys = [
        TranscriptionSettings.geminiModeKey,
        TranscriptionSettings.vocabularyKey,
        TranscriptionSettings.languageKey,
        TranscriptionSettings.openAIModelKey,
        TranscriptionSettings.timecodesKey,
        TranscriptionSettings.speakerLabelsKey,
    ]

    override func setUpWithError() throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        audio = FileManager.default.temporaryDirectory.appending(path: "doc-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 2, at: audio)
    }

    override func tearDownWithError() throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        try? FileManager.default.removeItem(at: audio)
        StubURLProtocol.reset()
    }

    // MARK: - Gemini

    /// Настройки лежат внутри `generation_config.transcription_config`, а не
    /// верхним уровнем: верхним сервис отвечал «Unknown parameter» на каждое поле.
    func testGeminiNestsSettingsInGenerationConfig() async throws {
        setGemini(mode: .speakers)
        UserDefaults.standard.set("MCP\nДуматель 2.0", forKey: TranscriptionSettings.vocabularyKey)
        let session = StubURLProtocol.session { _, _ in Self.textReply("Готово.") }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.requests[0].body) as? [String: Any])
        XCTAssertNil(body["mode"], "верхним уровнем настроек больше нет")
        XCTAssertNil(body["language"])
        let config = try XCTUnwrap(
            (body["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any]
        )
        XCTAssertEqual(config["language_codes"] as? [String], ["ru-RU"], "код языка списком, как в документации")
        XCTAssertEqual(config["custom_vocabulary"] as? [String], ["MCP", "Думатель 2.0"])
        let mode = try XCTUnwrap(config["mode"] as? [String: Any])
        XCTAssertEqual(mode["type"] as? String, "verbatim")
        XCTAssertEqual(mode["timestamp_granularities"] as? [String], ["word"])
        XCTAssertEqual(mode["diarization_mode"] as? String, "speaker", "разделение говорящих — это diarization_mode")
    }

    /// Дословный режим с выключенными тумблерами: объект с одним типом.
    func testAccuracyModeSendsVerbatimWithoutTimestamps() async throws {
        setGemini(mode: .accuracy)
        let session = StubURLProtocol.session { _, _ in Self.textReply("Готово.") }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.requests[0].body) as? [String: Any])
        let config = try XCTUnwrap((body["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any])
        let mode = try XCTUnwrap(config["mode"] as? [String: Any])
        XCTAssertEqual(mode["type"] as? String, "verbatim")
        XCTAssertNil(mode["timestamp_granularities"])
        XCTAssertNil(mode["diarization_mode"])
    }

    /// Говорящие приходят только вместе с таймингами слов: живой прогон
    /// показал, что без `timestamp_granularities` сервис не присылает их вовсе.
    /// Поэтому режим «Спикеры и таймкоды» посылает оба подполя разом — собрать
    /// одно без другого больше нельзя, и это и было целью переделки.
    func testSpeakersModeSendsBothSubfields() async throws {
        setGemini(mode: .speakers)
        let session = StubURLProtocol.session { _, _ in Self.textReply("Готово.") }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio)

        let mode = try modeObject(of: StubURLProtocol.requests[0])
        XCTAssertEqual(mode["timestamp_granularities"] as? [String], ["word"], "носитель говорящих — word_info")
        XCTAssertEqual(mode["diarization_mode"] as? String, "speaker")
    }

    /// Режим `smart` — строка, а не объект: так описано в документации. Тумблеры
    /// с ним несовместимы и подполей не добавляют, даже когда включены.
    func testSmartModeSendsPlainString() async throws {
        setGemini(mode: .smart)
        let session = StubURLProtocol.session { _, _ in Self.textReply("Причёсанный текст.") }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.requests[0].body) as? [String: Any])
        let config = try XCTUnwrap((body["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any])
        XCTAssertEqual(config["mode"] as? String, "smart")
    }

    /// `smart` несовместим с таймкодами и говорящими: действующие запросы — нули,
    /// и предел одного запроса остаётся часовым.
    func testSmartModeAsksForNoTimestampsOrSpeakers() {
        setGemini(mode: .smart)
        XCTAssertFalse(TranscriptionSettings.geminiWantsWordTimestamps)
        XCTAssertFalse(TranscriptionSettings.geminiWantsDiarization)
        XCTAssertEqual(TranscriptionSettings.geminiMaxSeconds, 60 * 60, "без таймкодов сервис берёт час")

        setGemini(mode: .speakers)
        XCTAssertTrue(TranscriptionSettings.geminiWantsWordTimestamps)
        XCTAssertEqual(TranscriptionSettings.geminiMaxSeconds, 30 * 60, "с таймкодами — 30 минут")

        setGemini(mode: .speakers)
        XCTAssertTrue(TranscriptionSettings.geminiWantsDiarization)
        XCTAssertEqual(TranscriptionSettings.geminiMaxSeconds, 30 * 60, "с говорящими — тоже 30 минут")
    }

    /// Ответ модели: полный текст в `output_text`, слова — в аннотациях `word_info`.
    func testDocumentedResponseShapeIsParsed() async throws {
        setGemini(mode: .speakers)
        let reply = """
        {"output_text": "Значит начали. Согласен.",
         "steps": [{"content": [{"annotations": [
           {"type": "word_info", "text": "Значит", "speaker": "1", "start_offset": "0s", "end_offset": "0.4s"},
           {"type": "word_info", "text": "начали.", "speaker": "1", "start_offset": "0.5s", "end_offset": "1s"},
           {"type": "word_info", "text": "Согласен.", "speaker": "2", "start_offset": "2s", "end_offset": "2.6s"}
         ]}]}]}
        """
        let session = StubURLProtocol.session { _, _ in .json(reply) }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertEqual(transcript.segments.count, 2, "смена говорящего разделила реплики")
        XCTAssertEqual(transcript.segments.first?.text, "S1: Значит начали.")
        XCTAssertEqual(transcript.segments.last?.start ?? 0, 2, accuracy: 0.01)
        XCTAssertFalse(transcript.segments[0].isApproximate, "тайминги настоящие")
    }

    // MARK: - OpenAI

    /// Язык улучшает точность и скорость — документация говорит это прямо, а мы
    /// его не отправляли вовсе. Ровно один раз: поле дублировалось двумя блоками.
    func testOpenAISendsLanguage() async throws {
        UserDefaults.standard.set("gpt-4o-transcribe", forKey: TranscriptionSettings.openAIModelKey)
        let session = StubURLProtocol.session { _, _ in .json(#"{"text": "Речь."}"#) }
        let engine = OpenAITranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio) { _, _ in }

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.occurrences(of: "name=\"language\""), 1, "поле языка есть и не продублировано")
        XCTAssertTrue(request.contains("ru"), "и в нём код языка")
    }

    /// У `gpt-transcribe` поле называется во множественном числе — и оно
    /// заменяет одиночное `language`, а не приходит вместе с ним.
    func testNewModelUsesLanguageList() async throws {
        UserDefaults.standard.set("gpt-transcribe", forKey: TranscriptionSettings.openAIModelKey)
        let session = StubURLProtocol.session { _, _ in .json(#"{"text": "Речь."}"#) }
        let engine = OpenAITranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio) { _, _ in }

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertTrue(request.contains("name=\"languages[]\""), "список языков")
        XCTAssertFalse(request.contains("name=\"language\""), "одиночное поле этой модели не знакомо")
        XCTAssertTrue(OpenAITranscriber.usesLanguageList("gpt-transcribe"))
        XCTAssertFalse(OpenAITranscriber.usesLanguageList("gpt-4o-transcribe"))
    }

    /// «Определяй сам» — поле не уходит вовсе.
    func testAutomaticLanguageSendsNoField() async throws {
        UserDefaults.standard.set("", forKey: TranscriptionSettings.languageKey)
        let session = StubURLProtocol.session { _, _ in .json(#"{"text": "Речь."}"#) }
        let engine = OpenAITranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio) { _, _ in }

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertFalse(request.contains("name=\"language\""))
    }

    /// Выключенные «Таймкоды реплик» у whisper: обычный `json`-ответ и никакой
    /// просьбы про тайминги слов.
    func testWhisperWithoutTimecodesAsksPlainJSON() async throws {
        UserDefaults.standard.set("whisper-1", forKey: TranscriptionSettings.openAIModelKey)
        UserDefaults.standard.set(false, forKey: TranscriptionSettings.timecodesKey)
        let session = StubURLProtocol.session { _, _ in .json(#"{"text": "Речь."}"#) }
        let engine = OpenAITranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio) { _, _ in }

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertFalse(request.contains("timestamp_granularities"))
        XCTAssertTrue(request.contains("json"))
        XCTAssertFalse(request.contains("verbose_json"))
    }

    // MARK: - Помощники

    /// Что уйдёт в запрос, решает режим — и только он. Движок выставляется
    /// заодно: матрица возможностей смотрит на выбранный движок.
    private func setGemini(mode: GeminiMode) {
        UserDefaults.standard.set(TranscriptionEngineKind.gemini.rawValue, forKey: TranscriptionSettings.engineKey)
        UserDefaults.standard.set(mode.rawValue, forKey: TranscriptionSettings.geminiModeKey)
    }

    private func modeObject(of recorded: StubURLProtocol.Recorded) throws -> [String: Any] {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: recorded.body) as? [String: Any])
        let config = try XCTUnwrap((body["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any])
        return try XCTUnwrap(config["mode"] as? [String: Any])
    }

    private static func textReply(_ text: String) -> StubURLProtocol.Reply {
        .json("{\"output_text\": \"\(text) Полный текст расшифровки записи.\"}")
    }
}
