import XCTest
@testable import LoriLocal

/// Движок-заглушка: настоящие требуют либо системных моделей распознавания,
/// которых в симуляторе нет, либо сети и ключа.
private struct StubEngine: Transcribing {
    let name: String
    let text: String?
    /// Доступность задаётся отдельно: движок может быть на месте и всё равно ошибиться.
    let available: Bool

    init(name: String = "Стаб", text: String?, available: Bool = true) {
        self.name = name
        self.text = text
        self.available = available
    }

    func isAvailable() async -> Bool { available }

    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript {
        progress(0, 1)
        guard let text else { throw TranscriptionError.emptyResult }
        progress(1, 1)
        return Transcript(text: text)
    }
}

final class TranscriptionServiceTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "LoriTranscription-\(UUID().uuidString)", directoryHint: .isDirectory)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.engineKey)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.engineKey)
    }

    @MainActor
    private func makeService(
        _ engine: StubEngine,
        as kind: TranscriptionEngineKind = .gigaam
    ) -> TranscriptionService {
        TranscriptionService(engines: [kind: engine])
    }

    @MainActor
    private func makeWorkspace(withAudio name: String = "Встреча.m4a") throws -> (WorkspaceStore, WorkspaceEntry) {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        try Data("не настоящее аудио".utf8).write(to: temporaryRoot.appending(path: name))
        try workspace.refresh()
        return (workspace, try workspace.entry(at: name))
    }

    @MainActor
    func testSavesTranscriptWithEngineName() async throws {
        let (workspace, entry) = try makeWorkspace()
        let service = makeService(StubEngine(text: "Купить хлеб"))

        let path = await service.transcribe(entry, in: workspace, using: .gigaam)

        XCTAssertEqual(path, "Transcripts/Встреча.md")
        XCTAssertEqual(
            try workspace.readText(at: "Transcripts/Встреча.md"),
            "# Встреча\n\n_Расшифровано: Стаб_\n\n_Режим: \(TranscriptionSettings.mode(for: .gigaam)!.title)_\n\nКупить хлеб\n"
        )
        XCTAssertNil(service.lastError)
        XCTAssertTrue(service.running.isEmpty, "после завершения файл не должен оставаться в работе")
    }

    @MainActor
    func testReportsEngineFailureAndKeepsAudio() async throws {
        let (workspace, entry) = try makeWorkspace()
        let service = makeService(StubEngine(text: nil))

        let path = await service.transcribe(entry, in: workspace, using: .gigaam)

        XCTAssertNil(path)
        XCTAssertEqual(service.lastError, TranscriptionError.emptyResult.errorDescription)
        XCTAssertThrowsError(try workspace.readText(at: "Transcripts/Встреча.md"))
        XCTAssertNoThrow(try workspace.entry(at: "Встреча.m4a"), "звук остаётся, даже если расшифровка не удалась")
    }

    @MainActor
    func testRefusesNonAudioWithoutTouchingEngine() async throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        try workspace.writeText("текст", at: "заметка.md")
        let entry = try workspace.entry(at: "заметка.md")
        let service = makeService(StubEngine(text: nil))

        let path = await service.transcribe(entry, in: workspace, using: .gigaam)

        XCTAssertNil(path)
        XCTAssertEqual(service.lastError, TranscriptionError.notAudio.errorDescription)
    }

    /// Перерасшифровка другим движком заменяет текст, а не плодит копии.
    @MainActor
    func testRetranscriptionReplacesTheText() async throws {
        let (workspace, entry) = try makeWorkspace()
        let first = TranscriptionService(engines: [.gigaam: StubEngine(name: "GigaAM-стаб", text: "Первый прогон")])
        _ = await first.transcribe(entry, in: workspace, using: .gigaam)

        let second = TranscriptionService(engines: [.gemini: StubEngine(name: "Gemini-стаб", text: "Второй прогон")])
        let path = await second.transcribe(entry, in: workspace, using: .gemini)

        XCTAssertEqual(path, "Transcripts/Встреча.md")
        let saved = try workspace.readText(at: "Transcripts/Встреча.md")
        XCTAssertTrue(saved.contains("Второй прогон"))
        XCTAssertFalse(saved.contains("Первый прогон"))
        XCTAssertEqual(try workspace.entries(at: "Transcripts").count, 1)
    }

    @MainActor
    func testFindsExistingTranscript() async throws {
        let (workspace, entry) = try makeWorkspace()
        XCTAssertNil(workspace.existingTranscript(for: entry))

        _ = await makeService(StubEngine(text: "Готово")).transcribe(entry, in: workspace, using: .gigaam)

        XCTAssertEqual(workspace.existingTranscript(for: entry), "Transcripts/Встреча.md")
    }

    /// Самое важное правило: недоступный движок — это ошибка, а не повод отправить
    /// запись в облако. Раньше сервис молча уходил на резервный движок.
    @MainActor
    func testUnavailableEngineDoesNotSilentlySwitchToAnother() async throws {
        let (workspace, entry) = try makeWorkspace()
        let service = TranscriptionService(engines: [
            .gigaam: StubEngine(name: "GigaAM-стаб", text: "локальный текст", available: false),
            .gemini: StubEngine(name: "Gemini-стаб", text: "облачный текст"),
        ])

        let path = await service.transcribe(entry, in: workspace, using: .gigaam)

        XCTAssertNil(path)
        XCTAssertEqual(service.lastError, TranscriptionError.modelsMissing.errorDescription)
        XCTAssertThrowsError(
            try workspace.readText(at: "Transcripts/Встреча.md"),
            "запись не должна была уйти ни в один другой движок"
        )
    }

    @MainActor
    func testUnavailabilityReasonIsSpecificToTheEngine() async throws {
        let service = TranscriptionService(engines: [
            .gigaam: StubEngine(text: nil, available: false),
            .apple: StubEngine(text: nil, available: false),
            .openAI: StubEngine(text: nil, available: false),
            .gemini: StubEngine(text: nil, available: false),
        ])

        let gigaam = await service.unavailability(of: .gigaam)
        let apple = await service.unavailability(of: .apple)
        let openAI = await service.unavailability(of: .openAI)
        let gemini = await service.unavailability(of: .gemini)
        XCTAssertEqual(gigaam, .modelsMissing)
        XCTAssertEqual(apple, .assetsUnavailable)
        XCTAssertEqual(openAI, .missingKey(.openAI))
        XCTAssertEqual(gemini, .missingKey(.gemini))

        let ready = TranscriptionService(engines: [.gigaam: StubEngine(text: "текст")])
        let none = await ready.unavailability(of: .gigaam)
        XCTAssertNil(none)
    }

    @MainActor
    func testEngineComesFromSettingsWhenNotAskedExplicitly() async throws {
        let (workspace, entry) = try makeWorkspace()
        UserDefaults.standard.set(TranscriptionEngineKind.gemini.rawValue, forKey: TranscriptionSettings.engineKey)
        let service = TranscriptionService(engines: [
            .gigaam: StubEngine(name: "GigaAM-стаб", text: "локальный текст"),
            .gemini: StubEngine(name: "Gemini-стаб", text: "облачный текст"),
        ])

        _ = await service.transcribe(entry, in: workspace)

        XCTAssertTrue(try workspace.readText(at: "Transcripts/Встреча.md").contains("облачный текст"))
        XCTAssertEqual(service.selectedName, "Gemini-стаб")
    }

    /// Экран не должен выглядеть мёртвым, пока идёт облачный запрос: у него нет
    /// процентов внутри, но шаг назвать можно.
    func testCloudNoteNamesTheStepInsteadOfPercentages() {
        XCTAssertEqual(TranscriptionService.note(done: 0, total: 1, cloud: true), "жду ответ сервиса")
        XCTAssertEqual(TranscriptionService.note(done: 1, total: 1, cloud: true), "получаю текст")
        XCTAssertEqual(TranscriptionService.note(done: 1, total: 4, cloud: true), "часть 2 из 4, жду ответ")
        XCTAssertEqual(TranscriptionService.note(done: 0, total: 1, cloud: false), "расшифровываю")
        XCTAssertEqual(TranscriptionService.note(done: 2, total: 6, cloud: false), "часть 3 из 6")
    }

    /// «The request timed out» человеку ничего не говорит.
    func testNetworkErrorsAreTranslated() {
        let timeout = TranscriptionService.explain(URLError(.timedOut))
        XCTAssertTrue(timeout.contains("не ответил вовремя"), timeout)
        XCTAssertTrue(timeout.contains("GigaAM"), "подсказка про локальный движок здесь уместна")

        let offline = TranscriptionService.explain(URLError(.notConnectedToInternet))
        XCTAssertTrue(offline.contains("без сети"), offline)

        XCTAssertEqual(
            TranscriptionService.explain(TranscriptionError.modelsMissing),
            TranscriptionError.modelsMissing.errorDescription
        )
    }

    /// Полоса считает сделанное, а не начатое: «100%» на неготовой записи читается
    /// как зависание — на Whisper, где кусок идёт минутами, так и прочиталось.
    func testProgressFractionCountsFinishedWorkOnly() {
        XCTAssertNil(TranscriptionService.fraction(done: 0, total: 1), "одному куску проценты не нужны")
        XCTAssertEqual(TranscriptionService.fraction(done: 0, total: 4), 0, "в начале сделано ноль")
        XCTAssertEqual(TranscriptionService.fraction(done: 1, total: 4), 0.25)
        XCTAssertEqual(
            TranscriptionService.fraction(done: 3, total: 4),
            0.75,
            "последний кусок ещё считается — сотни здесь быть не должно"
        )
        XCTAssertEqual(TranscriptionService.fraction(done: 4, total: 4), 1, "сотню ставит только конец работы")
    }

    func testAudioDetectionByExtension() {
        func entry(_ name: String) -> WorkspaceEntry {
            WorkspaceEntry(relativePath: name, isDirectory: false, size: 0, modifiedAt: .now)
        }
        XCTAssertTrue(entry("Запись.m4a").isAudio)
        XCTAssertTrue(entry("подкаст.MP3").isAudio)
        XCTAssertTrue(entry("dump.wav").isAudio)
        XCTAssertFalse(entry("заметка.md").isAudio)
        XCTAssertFalse(entry("картинка.png").isAudio)
        XCTAssertFalse(
            WorkspaceEntry(relativePath: "Recordings", isDirectory: true, size: 0, modifiedAt: .now).isAudio
        )
    }
}
