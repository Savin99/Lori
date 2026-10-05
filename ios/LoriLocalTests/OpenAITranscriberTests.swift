import XCTest
@testable import LoriLocal

/// Движок OpenAI целиком: что уходит в запросе и что получается из ответа.
/// Ни сети, ни ключа из Keychain здесь нет — транспорт и ключ подставляются.
final class OpenAITranscriberTests: XCTestCase {
    private var audio: URL!
    private let keys = [
        TranscriptionSettings.openAIBaseURLKey,
        TranscriptionSettings.openAIModelKey,
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

    /// Модель без таймингов на записи длиннее порога пропуска: предупреждать не о
    /// чем — «время не пришло» не значит «текста нет». Раньше тут появлялся
    /// ложный «Пропуск 0:00–…» на каждую запись длиннее восьми секунд.
    func testNoFalseGapWarningWithoutTimings() async throws {
        let long = FileManager.default.temporaryDirectory.appending(path: "long-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 10, at: long)
        defer { try? FileManager.default.removeItem(at: long) }
        UserDefaults.standard.set("gpt-transcribe", forKey: TranscriptionSettings.openAIModelKey)
        let session = StubURLProtocol.session { _, _ in .json(#"{"text": "Десять секунд речи без таймингов."}"#) }
        let engine = OpenAITranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: long)

        XCTAssertTrue(transcript.warnings.isEmpty, "ложный пропуск: \(transcript.warnings)")
        XCTAssertEqual(transcript.text, "Десять секунд речи без таймингов.")
    }

    func testWordTimingsBecomeSegments() async throws {
        let session = StubURLProtocol.session { _, _ in
            .json("""
            {"text":"Привет мир.","words":[
              {"word":"Привет","start":0.0,"end":0.4},
              {"word":"мир.","start":0.5,"end":0.9}
            ]}
            """)
        }
        let engine = OpenAITranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertEqual(transcript.words.map(\.text), ["Привет", "мир."])
        XCTAssertEqual(transcript.segments.count, 1, "точка в конце закрывает реплику")
        XCTAssertEqual(transcript.text, "Привет мир.")
    }

    func testRequestCarriesModelLanguageAndFile() async throws {
        UserDefaults.standard.set("https://api.groq.com/openai/v1", forKey: TranscriptionSettings.openAIBaseURLKey)
        let session = StubURLProtocol.session { _, _ in .json(#"{"text":"текст"}"#) }
        let engine = OpenAITranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer тест-ключ")
        XCTAssertTrue(sent.contains("name=\"model\""))
        XCTAssertTrue(sent.contains(TranscriptionSettings.defaultOpenAIModel))
        XCTAssertTrue(sent.contains("name=\"language\""))
        XCTAssertTrue(sent.contains("verbose_json"), "у whisper просим тайминги слов")
        XCTAssertTrue(sent.contains("filename=\"\(audio.lastPathComponent)\""))
    }

    /// Словарь — единственный способ добиться правильных имён, и он должен
    /// действительно доезжать до сервиса.
    func testVocabularyGoesIntoThePromptField() async throws {
        UserDefaults.standard.set("Кайрос\nИнтегра-4D", forKey: TranscriptionSettings.vocabularyKey)
        let session = StubURLProtocol.session { _, _ in .json(#"{"text":"текст"}"#) }
        let engine = OpenAITranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertTrue(sent.contains("name=\"prompt\""))
        XCTAssertTrue(sent.contains("Кайрос, Интегра-4D"))
    }

    func testWordsAreNotRequestedFromModelsThatCannotGiveThem() async throws {
        UserDefaults.standard.set("gpt-4o-transcribe", forKey: TranscriptionSettings.openAIModelKey)
        let session = StubURLProtocol.session { _, _ in .json(#"{"text":"текст"}"#) }
        let engine = OpenAITranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertFalse(sent.contains("verbose_json"))
        XCTAssertFalse(sent.contains("timestamp_granularities"))
        XCTAssertEqual(transcript.text, "текст")
        XCTAssertTrue(transcript.words.isEmpty)
    }

    /// Модели с разделением говорящих подсказку не принимают: сервис отвечал
    /// «Prompt is not supported for diarization models», и словарь ломал расшифровку.
    func testDiarizationModelGetsNoPromptAndReturnsSpeakers() async throws {
        UserDefaults.standard.set("gpt-4o-transcribe-diarize", forKey: TranscriptionSettings.openAIModelKey)
        UserDefaults.standard.set("Кайрос", forKey: TranscriptionSettings.vocabularyKey)
        let session = StubURLProtocol.session { _, _ in
            .json("""
            {"text":"полный текст","segments":[
              {"start":0.0,"end":4.7,"text":"Спасибо за звонок.","speaker":"agent"},
              {"start":4.7,"end":8.0,"text":"Здравствуйте.","speaker":"A"}]}
            """)
        }
        let engine = OpenAITranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertFalse(sent.contains("name=\"prompt\""), "подсказку этой модели присылать нельзя")
        XCTAssertTrue(sent.contains("diarized_json"), "иначе говорящих в ответе не будет")
        XCTAssertTrue(sent.contains("chunking_strategy"))
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments.first?.text, "agent: Спасибо за звонок.")
        XCTAssertEqual(transcript.segments.last?.start, 4.7)
    }

    /// «Определять сам» — это отсутствие поля, а не пустая строка в нём.
    func testAutomaticLanguageMeansNoField() async throws {
        UserDefaults.standard.set("", forKey: TranscriptionSettings.languageKey)
        let session = StubURLProtocol.session { _, _ in .json(#"{"text":"текст"}"#) }
        let engine = OpenAITranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try await engine.transcribe(audioURL: audio)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertFalse(sent.contains("name=\"language\""))
    }

    /// Запасной путь для будущих моделей: сервис пожаловался на подсказку —
    /// повторяем запрос без неё, а не падаем.
    func testRetriesWithoutPromptWhenServiceRefusesIt() async throws {
        UserDefaults.standard.set("Кайрос", forKey: TranscriptionSettings.vocabularyKey)
        let session = StubURLProtocol.session { _, body in
            if body.range(of: Data("name=\"prompt\"".utf8)) != nil {
                return .json(#"{"error":{"message":"Prompt is not supported for this model"}}"#, status: 400)
            }
            return .json(#"{"text":"получилось без словаря"}"#)
        }
        let engine = OpenAITranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertEqual(transcript.text, "получилось без словаря")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testServiceErrorTextReachesTheUser() async throws {
        let session = StubURLProtocol.session { _, _ in
            .json(#"{"error":{"message":"Incorrect API key provided"}}"#, status: 401)
        }
        let engine = OpenAITranscriber(session: session, keyProvider: { "тест-ключ" })

        do {
            _ = try await engine.transcribe(audioURL: audio)
            XCTFail("ошибка сервиса должна дойти до человека")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .api("Incorrect API key provided"))
        }
    }

    func testWithoutKeyNothingIsSent() async throws {
        let session = StubURLProtocol.session { _, _ in .json(#"{"text":"не должно случиться"}"#) }
        let engine = OpenAITranscriber(session: session, keyProvider: { nil })

        let available = await engine.isAvailable()
        XCTAssertFalse(available)
        do {
            _ = try await engine.transcribe(audioURL: audio)
            XCTFail("без ключа запрос уходить не должен")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .missingKey(.openAI))
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "аудио не должно уходить в сеть без ключа")
    }
}
