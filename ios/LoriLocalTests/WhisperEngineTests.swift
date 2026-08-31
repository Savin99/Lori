import XCTest
@testable import LoriLocal

/// Движок-заглушка: настоящие требуют моделей на устройстве.
private struct StubEngine: LocalTranscribing {
    let name: String
    let available: Bool

    func isAvailable() async -> Bool { available }

    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript {
        Transcript(text: name)
    }
}

final class WhisperTranscriptTests: XCTestCase {
    func testStripsSeparatorSpaceAndKeepsPunctuation() {
        let words = WhisperTranscript.words(from: [
            WhisperWord(text: " Привет,", start: 0.2, end: 0.6),
            WhisperWord(text: " мир.", start: 0.6, end: 1.0),
        ])

        XCTAssertEqual(words.map(\.text), ["Привет,", "мир."])
        XCTAssertEqual(words.first?.start, 0.2)
    }

    /// Смещение куска обязано попасть во время слов: без него вторая половина
    /// длинной записи получила бы времена с нуля и реплики склеились бы.
    func testShiftsWordsByChunkOffset() {
        let words = WhisperTranscript.words(
            from: [WhisperWord(text: " дальше", start: 1.0, end: 1.5)],
            offset: 28
        )

        XCTAssertEqual(words.first?.start, 29.0)
        XCTAssertEqual(words.first?.end, 29.5)
    }

    func testDropsEmptyWords() {
        let words = WhisperTranscript.words(from: [
            WhisperWord(text: "   ", start: 0, end: 0.1),
            WhisperWord(text: " есть", start: 0.1, end: 0.4),
        ])

        XCTAssertEqual(words.map(\.text), ["есть"])
    }

    /// На стыке окон Whisper выдаёт конец раньше начала. Слово должно остаться,
    /// иначе текст теряется, но время не должно идти вспять.
    func testClampsBackwardsTiming() {
        let words = WhisperTranscript.words(from: [
            WhisperWord(text: "слово", start: 5.0, end: 4.2),
        ])

        XCTAssertEqual(words.first?.start, 5.0)
        XCTAssertEqual(words.first?.end, 5.0)
    }

    /// Реплики режутся по знакам препинания, которые ставит сама модель.
    func testAssemblesSegmentsFromWhisperWords() {
        let words = WhisperTranscript.words(from: [
            WhisperWord(text: " Купил хлеб.", start: 0, end: 0.5),
            WhisperWord(text: " Ещё молоко", start: 0.6, end: 1.2),
        ])
        let transcript = TranscriptAssembler().transcript(from: words)

        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.text, "Купил хлеб. Ещё молоко")
    }
}

final class TranscriptionEngineChoiceTests: XCTestCase {
    func testUnknownStoredValueFallsBackToAutomatic() {
        XCTAssertEqual(TranscriptionEngineChoice(storedValue: "кириллица"), .automatic)
        XCTAssertEqual(TranscriptionEngineChoice(storedValue: "whisper"), .whisper)
    }

    /// Выбранный движок идёт первым, но список на нём не обрывается:
    /// его моделей может не оказаться на устройстве.
    func testChosenEngineGoesFirstAndOthersRemain() {
        let order = TranscriptionEngines.ordered(
            for: .whisper,
            gigaAM: StubEngine(name: "GigaAM", available: true),
            whisper: StubEngine(name: "Whisper", available: true),
            apple: StubEngine(name: "Apple", available: true)
        )

        XCTAssertEqual(order.map(\.name), ["Whisper", "GigaAM", "Apple"])
    }

    func testResolvePicksChosenEngineWhenItsModelsArePresent() async {
        let chosen = await TranscriptionEngines.resolve(
            for: .whisper,
            gigaAM: StubEngine(name: "GigaAM", available: true),
            whisper: StubEngine(name: "Whisper", available: true),
            apple: StubEngine(name: "Apple", available: true)
        )

        XCTAssertEqual(chosen.name, "Whisper")
    }

    /// Выбор Whisper без его моделей не должен оставлять человека без расшифровки.
    func testResolveFallsThroughWhenChosenEngineIsMissing() async {
        let chosen = await TranscriptionEngines.resolve(
            for: .whisper,
            gigaAM: StubEngine(name: "GigaAM", available: false),
            whisper: StubEngine(name: "Whisper", available: false),
            apple: StubEngine(name: "Apple", available: true)
        )

        XCTAssertEqual(chosen.name, "Apple")
    }

    /// Настройку читают в момент расшифровки: смена движка обязана подхватываться
    /// без перезапуска приложения.
    @MainActor
    func testServiceReadsChoiceAtTranscriptionTime() async {
        nonisolated(unsafe) var choice = TranscriptionEngineChoice.gigaAM
        let service = TranscriptionService(
            engine: StubEngine(name: "GigaAM", available: true),
            whisper: StubEngine(name: "Whisper", available: true),
            fallback: StubEngine(name: "Apple", available: true),
            choice: { choice }
        )

        var name = await service.resolvedEngine().name
        XCTAssertEqual(name, "GigaAM")

        choice = .whisper
        name = await service.resolvedEngine().name
        XCTAssertEqual(name, "Whisper")
    }
}

final class WhisperModelSetTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "Whisper-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ names: [String]) throws {
        for name in names {
            try FileManager.default.createDirectory(
                at: folder.appending(path: name),
                withIntermediateDirectories: true
            )
        }
    }

    func testFolderWithoutAllPartsIsIncomplete() throws {
        try write(["AudioEncoder.mlmodelc"])

        XCTAssertFalse(WhisperModelSet(folder: folder).isComplete())
    }

    /// Без токенизатора рядом WhisperKit пошёл бы за ним на HuggingFace.
    /// Расшифровка обязана работать без сети, поэтому такой случай — ошибка, а не докачка.
    func testTokenizerIsCheckedSeparatelyFromWeights() throws {
        try write(WhisperModelSet.parts)
        let models = WhisperModelSet(folder: folder)

        XCTAssertTrue(models.isComplete())
        XCTAssertEqual(models.missingTokenizerFile(), "tokenizer.json")

        // Одного `tokenizer.json` мало: без `tokenizer_config.json` разбор падает
        // уже внутри пакета, и объяснить это человеку будет нечем.
        try Data("{}".utf8).write(to: folder.appending(path: "tokenizer.json"))
        XCTAssertEqual(models.missingTokenizerFile(), "tokenizer_config.json")

        try Data("{}".utf8).write(to: folder.appending(path: "tokenizer_config.json"))
        XCTAssertNil(models.missingTokenizerFile())
    }
}
