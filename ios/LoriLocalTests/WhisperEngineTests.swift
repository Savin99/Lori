import XCTest
@testable import LoriLocal

/// Движок-заглушка: настоящий требует 632 МБ весов на устройстве.
private struct StubEngine: Transcribing {
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

    /// Whisper режет «что-то» на «что» и «-то», а «D.0.5» — на три куска.
    /// Признак продолжения — отсутствие ведущего пробела; без склейки сборщик
    /// реплик соединял их пробелом и в расшифровке стояло «что -то».
    func testGluesContinuationsToThePreviousWord() {
        let words = WhisperTranscript.words(from: [
            WhisperWord(text: " что", start: 1.0, end: 1.2),
            WhisperWord(text: "-то", start: 1.2, end: 1.4),
            WhisperWord(text: " дальше", start: 1.5, end: 1.9),
        ])

        XCTAssertEqual(words.map(\.text), ["что-то", "дальше"])
        // Время склеенного слова обязано накрыть оба куска: по нему перематывают звук.
        XCTAssertEqual(words.first?.start, 1.0)
        XCTAssertEqual(words.first?.end, 1.4)
    }

    /// Кусок, начинающийся с продолжения, склеивать не к чему — слово остаётся само.
    func testContinuationAtTheStartOfAChunkSurvivesOnItsOwn() {
        let words = WhisperTranscript.words(from: [
            WhisperWord(text: "то", start: 0, end: 0.2),
            WhisperWord(text: " дальше", start: 0.3, end: 0.6),
        ])

        XCTAssertEqual(words.map(\.text), ["то", "дальше"])
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

    /// Documents ищется наравне с Application Support: скачанное приложением
    /// живёт в одной папке, принесённое руками — в другой, и «Файлы» показывают
    /// только вторую.
    func testLooksInBothModelFolders() {
        let locations = WhisperModelSet.locations().map(\.path)

        XCTAssertEqual(locations.count, 2)
        XCTAssertTrue(locations.allSatisfy { $0.hasSuffix("Lori/Models") })
        XCTAssertTrue(locations.contains { $0.contains("/Documents/") }, "папка, видимая через «Файлы»")
    }
}

/// Как движок встроен в приложение: пятый в каталоге, без режимов, без ключа
/// и без права уводить запись с телефона.
final class WhisperEngineWiringTests: XCTestCase {
    /// Главный факт про движок. Если это когда-нибудь станет `true`,
    /// расшифровка начнёт уходить в сеть — тест стоит здесь именно для этого.
    func testEngineNeverLeavesTheDevice() {
        XCTAssertFalse(TranscriptionEngineKind.whisper.leavesDevice)
        XCTAssertNil(TranscriptionEngineKind.whisper.keychainAccount, "ключ движку не нужен")
    }

    /// Режимов у turbo нет: одна модель и один способ её позвать. Пустой список
    /// означает, что чип режима в панели исчезает сам.
    func testHasNoModesSoTheModeChipDisappears() {
        XCTAssertTrue(EngineCatalog.descriptor(for: .whisper).modes.isEmpty)
        XCTAssertNil(TranscriptionSettings.mode(for: .whisper))
        XCTAssertEqual(EngineCatalog.descriptor(for: .whisper).locality, .onDevice)
    }

    /// Таймкоды слов Whisper даёт, говорящих — нет. Тумблеры обязаны говорить
    /// именно это, а не обещать движку то, чего он не умеет.
    func testTogglesTellTheTruthAboutTheEngine() {
        let toggles = EngineToggles.current(for: .whisper)

        XCTAssertEqual(toggles.timecodes, .active)
        guard case let .unavailable(reason) = toggles.speakers else {
            return XCTFail("говорящих Whisper не различает — тумблер должен быть погашен с объяснением")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    /// Пометка у движка без модели — не «Скачать модель»: кнопки скачивания нет,
    /// и обещать её значит врать.
    @MainActor
    func testReadinessSaysThereIsNoModelInsteadOfOfferingADownload() {
        let missing = EngineDirectory(
            hasKey: { _ in true },
            hasModel: { _ in true },
            hasWhisperModel: { false }
        )
        XCTAssertEqual(missing.readiness(of: .whisper), .unavailable("Нет модели"))
        XCTAssertEqual(missing.readiness(of: .whisper).badge, "Нет модели")
        XCTAssertNotEqual(missing.readiness(of: .whisper), .needsDownload)

        let present = EngineDirectory(
            hasKey: { _ in true },
            hasModel: { _ in true },
            hasWhisperModel: { true }
        )
        XCTAssertEqual(present.readiness(of: .whisper), .ready)
        XCTAssertNil(present.readiness(of: .whisper).badge)
    }

    /// Движок не подменяется молча: без модели сервис объясняет причину и встаёт.
    @MainActor
    func testMissingModelIsReportedAndNotSubstituted() async {
        let service = TranscriptionService(engines: [
            .whisper: StubEngine(name: "Whisper", available: false),
        ])

        let reason = await service.unavailability(of: .whisper)
        XCTAssertEqual(reason, .whisperModelMissing)
        XCTAssertNotEqual(reason, .modelsMissing, "у GigaAM есть кнопка «Скачать», у Whisper её нет")

        let ready = TranscriptionService(engines: [
            .whisper: StubEngine(name: "Whisper", available: true),
        ])
        let none = await ready.unavailability(of: .whisper)
        XCTAssertNil(none)
    }

    /// Тексты для человека пишутся одной строкой: склейка многострочных литералов
    /// уже протаскивала в интерфейс дорожку пробелов.
    func testHumanTextsHaveNoDoubleSpaces() {
        let texts = [
            TranscriptionEngineKind.whisper.title,
            TranscriptionEngineKind.whisper.detail,
            TranscriptionError.whisperModelMissing.errorDescription ?? "",
            TranscriptionError.modelIncomplete("Whisper", "tokenizer.json").errorDescription ?? "",
            EngineCatalog.descriptor(for: .whisper).subtitle,
        ]

        for text in texts {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("  "), "двойной пробел в «\(text)»")
        }
    }
}
