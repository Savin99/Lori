import XCTest
@testable import LoriLocal

/// Список моделей приходит от сервиса, и его нужно отфильтровать: у OpenAI в общем
/// списке полторы сотни моделей, из которых аудио умеют единицы.
final class ModelCatalogTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
    }

    func testOpenAIKeepsOnlyAudioModelsAndPutsWhisperFirst() {
        let models = ModelCatalog.audioModels([
            "gpt-4o", "text-embedding-3-large", "gpt-4o-mini-transcribe",
            "whisper-1", "dall-e-3", "gpt-4o-transcribe",
        ])

        XCTAssertEqual(models.map(\.id), ["whisper-1", "gpt-4o-mini-transcribe", "gpt-4o-transcribe"])
        XCTAssertEqual(models.first?.detail, "тайминги слов")
        XCTAssertEqual(models.last?.detail, "без таймингов слов")
    }

    func testOpenAIListComesFromTheService() async throws {
        let session = StubURLProtocol.session { _, _ in
            .json(#"{"data":[{"id":"whisper-1"},{"id":"gpt-4o"},{"id":"gpt-4o-transcribe"}]}"#)
        }

        let models = try await ModelCatalog(session: session).openAI(key: "тест-ключ")

        XCTAssertEqual(models.map(\.id), ["whisper-1", "gpt-4o-transcribe"])
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer тест-ключ")
    }

    func testGeminiDropsWhatCannotHearAudio() {
        func model(_ name: String, methods: [String]? = ["generateContent"]) -> RemoteModel? {
            ModelCatalog.geminiModel(name: name, displayName: nil, description: nil, methods: methods)
        }

        XCTAssertEqual(model("models/gemini-3.1-flash-lite")?.id, "gemini-3.1-flash-lite")
        XCTAssertNil(model("models/gemini-embedding-2"), "эмбеддинги не расшифровывают")
        XCTAssertNil(model("models/imagen-4"), "картинки не расшифровывают")
        XCTAssertNil(model("models/gemini-2.5-flash-preview-tts"), "синтез речи — не распознавание")
        XCTAssertNil(model("models/veo-3"))
        XCTAssertNil(
            model("models/gemini-3.7-flash", methods: ["embedContent"]),
            "обычная модель без generateContent аудио не примет"
        )
        // А вот распознаватель речи выбрасывать нельзя ни при каком наборе методов:
        // это ровно та модель, за которой сюда и приходят.
        XCTAssertEqual(
            model("models/gemini-3.5-transcribe", methods: ["transcribeAudio"])?.id,
            "gemini-3.5-transcribe"
        )
        XCTAssertEqual(
            ModelCatalog.geminiModel(
                name: "models/speech-to-text-next",
                displayName: nil,
                description: "High-accuracy speech-to-text model",
                methods: ["custom"]
            )?.id,
            "speech-to-text-next"
        )
    }

    func testGeminiListIsPagedAndSorted() async throws {
        let session = StubURLProtocol.session { request, _ in
            let query = request.url?.query() ?? ""
            // Токен страницы латиницей: в URL он уходит percent-кодированным,
            // и русское слово в подставном сервере пришлось бы декодировать.
            if query.contains("pageToken=second") {
                return .json(#"{"models":[{"name":"models/gemini-3.1-flash-lite"}]}"#)
            }
            return .json(#"""
            {"models":[{"name":"models/gemini-3.7-flash","description":"Универсальная модель"},
                       {"name":"models/gemini-embedding-2"}],
             "nextPageToken":"second"}
            """#)
        }

        let models = try await ModelCatalog(session: session).gemini(key: "тест-ключ")

        XCTAssertEqual(models.map(\.id), ["gemini-3.1-flash-lite", "gemini-3.7-flash"])
        XCTAssertEqual(models.last?.detail, "Универсальная модель")
        XCTAssertEqual(StubURLProtocol.requests.count, 2, "вторая страница должна дозапрашиваться")
        XCTAssertTrue(
            StubURLProtocol.requests.first?.request.url?.query()?.contains("pageSize=200") == true,
            "список забирается страницами по 200"
        )
        XCTAssertEqual(StubURLProtocol.requests.first?.request.value(forHTTPHeaderField: "x-goog-api-key"), "тест-ключ")
    }

    func testSuggestionsCoverBothServicesUntilKeyIsSaved() {
        XCTAssertEqual(ModelCatalog.openAISuggestions.first?.id, "whisper-1")
        XCTAssertEqual(ModelCatalog.geminiSuggestions.first?.id, TranscriptionSettings.defaultGeminiModel)
        XCTAssertEqual(TranscriptionSettings.defaultGeminiModel, "gemini-3.5-transcribe")
    }

    func testServiceErrorIsReported() async throws {
        let session = StubURLProtocol.session { _, _ in
            .json(#"{"error":{"message":"API key not valid"}}"#, status: 400)
        }

        do {
            _ = try await ModelCatalog(session: session).gemini(key: "плохой")
            XCTFail("ошибка сервиса должна дойти до человека")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .api("API key not valid"))
        }
    }
}

/// Словарь ONNX-экспорта и тайминги CTC — то, на чём держится текст с таймкодами.
final class VocabularyTests: XCTestCase {
    private func write(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "vocab-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: url)
        return url
    }

    func testTableFormatDropsBlankAndEmptiesUnknown() throws {
        let url = try write("<unk> 0\n. 1\n\u{2581}при 2\nвет 3\n<blk> 4\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let vocabulary = try SentencePieceVocabulary(tableAt: url)

        XCTAssertEqual(vocabulary.pieces, ["", ".", "\u{2581}при", "вет"])
        XCTAssertEqual(vocabulary.blankIndex, 4, "blank живёт сразу за словарём")
        XCTAssertEqual(vocabulary.classCount, 5, "именно столько классов отдаёт модель")
        XCTAssertEqual(vocabulary.detokenize([2, 3, 1]), "привет.")
    }

    /// Кусок словаря может быть самим пробелом, и резать строку по первому пробелу нельзя.
    func testPieceCanBeASpace() throws {
        let url = try write("  0\nа 1\n<blk> 2\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let vocabulary = try SentencePieceVocabulary(tableAt: url)

        XCTAssertEqual(vocabulary.pieces, [" ", "а"])
    }

    func testOrderComesFromIndexNotFromFileOrder() throws {
        let url = try write("б 1\nа 0\n<blk> 2\n")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try SentencePieceVocabulary(tableAt: url).pieces, ["а", "б"])
    }

    func testCTCReturnsFramesForWordTimings() throws {
        let decoder = try CTCGreedyDecoder(pieces: ["\u{2581}раз", "\u{2581}два"])
        // Три кадра: «раз», blank, «два» — на blank токен не выпускается.
        let logits: [Float] = [
            5, 0, 0,
            0, 0, 5,
            0, 5, 0,
        ]

        let output = decoder.tokensWithFrames(logits: logits, frames: 3, classes: 3)

        XCTAssertEqual(output.tokens, [0, 1])
        XCTAssertEqual(output.frames, [0, 2], "кадры нужны для таймкодов слов")
        XCTAssertEqual(decoder.detokenize(output.tokens), "раз два")
    }
}
