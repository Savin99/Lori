import XCTest
@testable import LoriLocal

/// Движок-заглушка: настоящий требует системных моделей распознавания,
/// которых в симуляторе нет ни для одного языка.
private struct StubEngine: LocalTranscribing {
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
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    /// Резерв тоже заглушка: иначе тест ушёл бы в настоящий движок Apple.
    @MainActor
    private func makeService(_ engine: StubEngine) -> TranscriptionService {
        TranscriptionService(engine: engine, fallback: engine)
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
    func testSavesTranscriptNextToRecordings() async throws {
        let (workspace, entry) = try makeWorkspace()
        let service = makeService(StubEngine(text: "Купить хлеб"))

        let path = await service.transcribe(entry, in: workspace)

        XCTAssertEqual(path, "Transcripts/Встреча.md")
        XCTAssertEqual(try workspace.readText(at: "Transcripts/Встреча.md"), "# Встреча\n\nКупить хлеб\n")
        XCTAssertNil(service.lastError)
        XCTAssertTrue(service.running.isEmpty, "после завершения файл не должен оставаться в работе")
    }

    @MainActor
    func testReportsEngineFailureAndKeepsAudio() async throws {
        let (workspace, entry) = try makeWorkspace()
        let service = makeService(StubEngine(text: nil))

        let path = await service.transcribe(entry, in: workspace)

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

        let path = await service.transcribe(entry, in: workspace)

        XCTAssertNil(path)
        XCTAssertEqual(service.lastError, TranscriptionError.notAudio.errorDescription)
    }

    @MainActor
    func testSecondTranscriptDoesNotOverwriteFirst() async throws {
        let (workspace, entry) = try makeWorkspace()
        let service = makeService(StubEngine(text: "Первый прогон"))
        _ = await service.transcribe(entry, in: workspace)

        let second = makeService(StubEngine(text: "Второй прогон"))
        let path = await second.transcribe(entry, in: workspace)

        XCTAssertEqual(path, "Transcripts/Встреча 2.md")
        XCTAssertTrue(try workspace.readText(at: "Transcripts/Встреча.md").contains("Первый прогон"))
    }

    @MainActor
    func testFindsExistingTranscript() async throws {
        let (workspace, entry) = try makeWorkspace()
        XCTAssertNil(workspace.existingTranscript(for: entry))

        _ = await makeService(StubEngine(text: "Готово")).transcribe(entry, in: workspace)

        XCTAssertEqual(workspace.existingTranscript(for: entry), "Transcripts/Встреча.md")
    }

    @MainActor
    func testFallsBackWhenMainEngineIsUnavailable() async throws {
        let (workspace, entry) = try makeWorkspace()
        let service = TranscriptionService(
            engine: StubEngine(name: "GigaAM-стаб", text: "не должен позваться", available: false),
            fallback: StubEngine(name: "Apple-стаб", text: "текст резервного движка")
        )

        let path = await service.transcribe(entry, in: workspace)

        XCTAssertEqual(path, "Transcripts/Встреча.md")
        XCTAssertTrue(
            try workspace.readText(at: "Transcripts/Встреча.md").contains("текст резервного движка"),
            "если основного движка нет, работает резервный"
        )
    }

    @MainActor
    func testPrefersMainEngineWhenAvailable() async throws {
        let (workspace, entry) = try makeWorkspace()
        let service = TranscriptionService(
            engine: StubEngine(name: "GigaAM-стаб", text: "текст GigaAM"),
            fallback: StubEngine(name: "Apple-стаб", text: "резерв не нужен")
        )

        _ = await service.transcribe(entry, in: workspace)

        XCTAssertTrue(try workspace.readText(at: "Transcripts/Встреча.md").contains("текст GigaAM"))
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
