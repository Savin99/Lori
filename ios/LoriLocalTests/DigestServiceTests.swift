import XCTest
@testable import LoriLocal

/// Ответ модели задаётся заранее. Актор, потому что `ChatCompleting` — Sendable,
/// а зовут его из стора на главном акторе.
private actor ScriptedDigestClient: ChatCompleting {
    private let answer: String?
    private(set) var lastSystemPrompt = ""
    private(set) var lastUserText = ""
    private(set) var callCount = 0

    init(answer: String?) {
        self.answer = answer
    }

    func complete(
        apiKey: String,
        model: String,
        messages: [DeepSeekMessage],
        tools: [DeepSeekTool]
    ) async throws -> DeepSeekMessage {
        callCount += 1
        lastSystemPrompt = messages.first(where: { $0.role == "system" })?.content ?? ""
        lastUserText = messages.last(where: { $0.role == "user" })?.content ?? ""
        guard let answer else { throw AgentError.invalidResponse }
        return DeepSeekMessage(role: "assistant", content: answer)
    }
}

final class DigestServiceTests: XCTestCase {
    private var temporaryRoot: URL!

    private static let answer = """
    {"title": "Планёрка по найму", "theme": "работа", "summary": "Итоги встречи.",
     "highlights": ["Кандидат А сильнее"], "decisions": ["Берём А"], "tasks": ["Написать оффер"],
     "tags": ["найм"]}
    """

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "LoriDigestTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    @MainActor
    private func seededWorkspace() throws -> WorkspaceStore {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        try workspace.writeText(
            "# Rec-1\n\n**[00:00–00:05]** Обсудили кандидатов. Решили взять первого.\n",
            at: "Transcripts/Rec-1.md"
        )
        try workspace.writeText("аудио", at: "Recordings/Rec-1.m4a")
        return workspace
    }

    @MainActor
    func testProcessWritesNoteIntoExistingThemeFolder() async throws {
        let workspace = try seededWorkspace()
        // Папка уже есть с большой буквы, модель ответила с маленькой:
        // заметка должна лечь в существующую, а не создать вторую рядом.
        try workspace.createFolder(named: "Работа")

        let client = ScriptedDigestClient(answer: Self.answer)
        let service = DigestService(client: client, keyProvider: { "test-key" })

        let path = await service.process(
            transcriptPath: "Transcripts/Rec-1.md",
            audioPath: "Recordings/Rec-1.m4a",
            in: workspace,
            model: "deepseek-v4-flash"
        )

        XCTAssertEqual(path, "Работа/Планёрка по найму.md")
        XCTAssertNil(service.lastError)

        let notePath = try XCTUnwrap(path)
        let note = try workspace.readText(at: notePath)
        let meta = NoteMeta.parse(note)
        XCTAssertTrue(meta.isDigest)
        XCTAssertEqual(meta.audio, "Recordings/Rec-1.m4a")
        XCTAssertEqual(meta.transcript, "Transcripts/Rec-1.md")
        XCTAssertEqual(meta.theme, "Работа")
        XCTAssertTrue(note.contains("## Важное"))

        // Карточка находит заметку и по аудио, и по расшифровке.
        XCTAssertEqual(service.digestPath(for: "Recordings/Rec-1.m4a", in: workspace), path)
        XCTAssertEqual(service.digestPath(for: "Transcripts/Rec-1.md", in: workspace), path)

        // В модель уходит текст без служебного заголовка и без метки времени.
        let sent = await client.lastUserText
        XCTAssertEqual(sent, "Обсудили кандидатов. Решили взять первого.")
        let prompt = await client.lastSystemPrompt
        XCTAssertTrue(prompt.contains("Работа"), "модель не увидела список существующих папок")
    }

    @MainActor
    func testProcessCreatesThemeFolderWhenThereIsNone() async throws {
        let workspace = try seededWorkspace()
        let service = DigestService(
            client: ScriptedDigestClient(answer: Self.answer),
            keyProvider: { "test-key" }
        )

        let path = await service.process(
            transcriptPath: "Transcripts/Rec-1.md",
            audioPath: nil,
            in: workspace,
            model: "deepseek-v4-flash"
        )

        XCTAssertEqual(path, "работа/Планёрка по найму.md")
        let folders = try workspace.entries(at: "").filter(\.isDirectory).map(\.name)
        XCTAssertTrue(folders.contains("работа"))
    }

    @MainActor
    func testSecondNoteWithSameTitleDoesNotOverwriteTheFirst() async throws {
        let workspace = try seededWorkspace()
        try workspace.writeText("# Rec-2\n\nВторая запись про то же.\n", at: "Transcripts/Rec-2.md")
        let service = DigestService(
            client: ScriptedDigestClient(answer: Self.answer),
            keyProvider: { "test-key" }
        )

        let first = await service.process(
            transcriptPath: "Transcripts/Rec-1.md",
            audioPath: nil,
            in: workspace,
            model: "m"
        )
        let second = await service.process(
            transcriptPath: "Transcripts/Rec-2.md",
            audioPath: nil,
            in: workspace,
            model: "m"
        )

        XCTAssertEqual(first, "работа/Планёрка по найму.md")
        XCTAssertEqual(second, "работа/Планёрка по найму 2.md")
    }

    @MainActor
    func testMissingKeyReportsErrorAndWritesNothing() async throws {
        let workspace = try seededWorkspace()
        let service = DigestService(
            client: ScriptedDigestClient(answer: Self.answer),
            keyProvider: { nil }
        )

        let path = await service.process(
            transcriptPath: "Transcripts/Rec-1.md",
            audioPath: nil,
            in: workspace,
            model: "m"
        )

        XCTAssertNil(path)
        XCTAssertEqual(service.lastError, DigestError.missingKey.errorDescription)
        XCTAssertFalse(service.hasKey)
        XCTAssertEqual(try workspace.entries(at: "").filter(\.isDirectory).count, 2)
    }

    @MainActor
    func testAnswerThatIsNotJSONIsReportedNotSaved() async throws {
        let workspace = try seededWorkspace()
        let service = DigestService(
            client: ScriptedDigestClient(answer: "Не могу обработать этот текст."),
            keyProvider: { "test-key" }
        )

        let path = await service.process(
            transcriptPath: "Transcripts/Rec-1.md",
            audioPath: nil,
            in: workspace,
            model: "m"
        )

        XCTAssertNil(path)
        XCTAssertEqual(service.lastError, DigestError.notJSON.errorDescription)
    }

    @MainActor
    func testEmptyTranscriptIsNotSentToTheModel() async throws {
        let workspace = try seededWorkspace()
        try workspace.writeText("# Пусто\n\n", at: "Transcripts/Empty.md")
        let client = ScriptedDigestClient(answer: Self.answer)
        let service = DigestService(client: client, keyProvider: { "test-key" })

        let path = await service.process(
            transcriptPath: "Transcripts/Empty.md",
            audioPath: nil,
            in: workspace,
            model: "m"
        )

        XCTAssertNil(path)
        XCTAssertEqual(service.lastError, DigestError.emptySource.errorDescription)
        let calls = await client.callCount
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testRescanFindsNoteWrittenByHand() throws {
        let workspace = try seededWorkspace()
        let service = DigestService(
            client: ScriptedDigestClient(answer: nil),
            keyProvider: { "test-key" }
        )
        let digest = NoteDigest(
            title: "Ручная заметка",
            theme: "Личное",
            summary: "Итог.",
            highlights: ["Пункт"],
            decisions: [],
            tasks: [],
            tags: []
        )
        try workspace.writeText(
            digest.markdown(
                audioPath: "Recordings/Rec-1.m4a",
                transcriptPath: "Transcripts/Rec-1.md",
                created: .now
            ),
            at: "Личное/Ручная заметка.md"
        )

        // Обход идёт лениво, на первый запрос: индекса на диске нет,
        // источник правды — front matter самой заметки.
        XCTAssertEqual(
            service.digestPath(for: "Recordings/Rec-1.m4a", in: workspace),
            "Личное/Ручная заметка.md"
        )
    }

    @MainActor
    func testDeletedNoteStopsBeingLinked() async throws {
        let workspace = try seededWorkspace()
        let service = DigestService(
            client: ScriptedDigestClient(answer: Self.answer),
            keyProvider: { "test-key" }
        )
        // `await` внутри автоклозуры XCTUnwrap не компилируется — сначала в let.
        let produced = await service.process(
            transcriptPath: "Transcripts/Rec-1.md",
            audioPath: "Recordings/Rec-1.m4a",
            in: workspace,
            model: "m"
        )
        let path = try XCTUnwrap(produced)

        try workspace.moveToTrash(path)

        XCTAssertNil(service.digestPath(for: "Recordings/Rec-1.m4a", in: workspace))
    }

    @MainActor
    func testServiceFolderCannotBecomeATheme() async throws {
        let workspace = try seededWorkspace()
        // Модель ответила служебной папкой приложения — заметка не должна лечь в сырьё.
        let answer = Self.answer.replacingOccurrences(of: "\"theme\": \"работа\"", with: "\"theme\": \"Transcripts\"")
        let service = DigestService(
            client: ScriptedDigestClient(answer: answer),
            keyProvider: { "test-key" }
        )

        let path = await service.process(
            transcriptPath: "Transcripts/Rec-1.md",
            audioPath: nil,
            in: workspace,
            model: "m"
        )

        XCTAssertEqual(path, "Заметки/Планёрка по найму.md")
    }

    /// Автоматический проход после расшифровки в симуляторе не воспроизвести —
    /// моделей распознавания там нет. Поэтому проверяется само правило.
    func testAutoProcessRule() {
        func decide(
            automatic: Bool = true,
            autoEnabled: Bool = true,
            hasTranscript: Bool = true,
            hasDigest: Bool = false,
            hasKey: Bool = true,
            isRunning: Bool = false
        ) -> Bool {
            DigestService.shouldProcess(
                automatic: automatic,
                autoEnabled: autoEnabled,
                hasTranscript: hasTranscript,
                hasDigest: hasDigest,
                hasKey: hasKey,
                isRunning: isRunning
            )
        }

        XCTAssertTrue(decide(), "после расшифровки обработка должна пойти сама")
        XCTAssertFalse(decide(autoEnabled: false), "выключенная автообработка должна молчать")
        // Нажатие руками сильнее переключателя: человек попросил именно сейчас.
        XCTAssertTrue(decide(automatic: false, autoEnabled: false))
        XCTAssertFalse(decide(hasTranscript: false), "без текста обрабатывать нечего")
        XCTAssertFalse(decide(hasDigest: true), "второй раз обрабатывать не нужно")
        XCTAssertFalse(decide(hasKey: false), "без ключа запрос всё равно не уйдёт")
        XCTAssertFalse(decide(isRunning: true), "две обработки одной расшифровки — двойной счёт")
        XCTAssertFalse(decide(automatic: false, hasKey: false))
    }

    @MainActor
    func testFreeNameKeepsExtension() {
        XCTAssertEqual(DigestService.freeName("Итог.md", taken: []), "Итог.md")
        XCTAssertEqual(DigestService.freeName("Итог.md", taken: ["Итог.md"]), "Итог 2.md")
        XCTAssertEqual(
            DigestService.freeName("Итог.md", taken: ["Итог.md", "Итог 2.md"]),
            "Итог 3.md"
        )
    }
}
