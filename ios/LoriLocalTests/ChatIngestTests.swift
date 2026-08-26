import XCTest
@testable import LoriLocal

/// Движок-заглушка: настоящего распознавания в симуляторе нет.
private struct IngestStubEngine: LocalTranscribing {
    let name = "Стаб приёма"
    let text: String

    func isAvailable() async -> Bool { true }

    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript {
        progress(1, 1)
        return Transcript(text: text)
    }
}

/// Запоминает всё, что ушло модели: контекст вложения — это отдельное служебное
/// сообщение, и проверять надо именно его, а не первый системный промпт.
private actor ContextRecordingClient: ChatCompleting {
    private let answer: String
    private(set) var systemMessages: [String] = []

    init(answer: String = "Понял.") {
        self.answer = answer
    }

    func complete(
        apiKey: String,
        model: String,
        messages: [DeepSeekMessage],
        tools: [DeepSeekTool]
    ) async throws -> DeepSeekMessage {
        systemMessages = messages.filter { $0.role == "system" }.compactMap(\.content)
        return DeepSeekMessage(role: "assistant", content: answer)
    }
}

final class ChatIngestTests: XCTestCase {
    private var temporaryRoot: URL!
    private var historyURL: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "LoriIngest-\(UUID().uuidString)", directoryHint: .isDirectory)
        temporaryRoot = base.appending(path: "Workspace", directoryHint: .isDirectory)
        historyURL = base.appending(path: "chat-history.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot.deletingLastPathComponent())
    }

    func testDecideByWhatIsActuallyReadable() {
        XCTAssertEqual(ChatIngest.decide(isAudio: true, text: nil), .audio)
        XCTAssertEqual(ChatIngest.decide(isAudio: false, text: "текст"), .text)
        // Картинка: не аудио и не читается — врать, что «принял», нельзя.
        XCTAssertEqual(ChatIngest.decide(isAudio: false, text: nil), .unreadable)
        XCTAssertEqual(ChatIngest.decide(isAudio: false, text: "   \n "), .unreadable)
    }

    @MainActor
    func testAudioAttachmentIsTranscribedAndItsTextReachesTheModel() async throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        try workspace.writeText("не пустой файл", at: "Inbox/Планёрка.m4a")
        let entry = try workspace.entry(at: "Inbox/Планёрка.m4a")

        let client = ContextRecordingClient()
        let assistant = AssistantStore(
            client: client,
            archive: ConversationArchive(fileURL: historyURL),
            keyProvider: { "test-key" },
            memoryEnabled: { false }
        )
        let transcription = TranscriptionService(
            engine: IngestStubEngine(text: "Оффер до пятницы, иначе перехватят."),
            fallback: IngestStubEngine(text: "резерв")
        )
        let digests = DigestService(
            client: ContextRecordingClient(),
            keyProvider: { nil } // без ключа обработки не будет — проверяем только приём
        )

        assistant.attach(entry.relativePath, title: entry.displayName)
        await ChatIngest.ingest(
            entry: entry,
            in: workspace,
            assistant: assistant,
            transcription: transcription,
            digests: digests,
            model: "m",
            autoProcess: true
        )

        // Вложение видно в ленте карточкой, с путём.
        XCTAssertEqual(assistant.bubbles.count, 1)
        XCTAssertEqual(assistant.bubbles.first?.role, .attachment)
        XCTAssertEqual(assistant.bubbles.first?.path, "Inbox/Планёрка.m4a")

        // Расшифровка легла в файл.
        XCTAssertNotNil(workspace.existingTranscript(for: entry))

        // И ушла модели служебным сообщением, а не пузырём.
        await assistant.send("о чём запись?", workspace: workspace, model: "m", allowMutations: false)
        let system = await client.systemMessages
        XCTAssertTrue(
            system.contains { $0.contains("Оффер до пятницы, иначе перехватят.") },
            "текст расшифровки не дошёл до модели: \(system)"
        )
        XCTAssertFalse(
            assistant.bubbles.contains { $0.role == .user && $0.text.contains("Оффер до пятницы") },
            "расшифровка не должна становиться сообщением человека"
        )
    }

    @MainActor
    func testTextAttachmentGoesStraightToContext() async throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        try workspace.writeText("Договор на три года, ставка фиксированная.\n", at: "Inbox/Договор.md")
        let entry = try workspace.entry(at: "Inbox/Договор.md")

        let client = ContextRecordingClient()
        let assistant = AssistantStore(
            client: client,
            archive: ConversationArchive(fileURL: historyURL),
            keyProvider: { "test-key" },
            memoryEnabled: { false }
        )
        // Движок обязан остаться нетронутым: текст расшифровывать незачем.
        let transcription = TranscriptionService(
            engine: IngestStubEngine(text: "этого не должно случиться"),
            fallback: IngestStubEngine(text: "и этого тоже")
        )

        await ChatIngest.ingest(
            entry: entry,
            in: workspace,
            assistant: assistant,
            transcription: transcription,
            digests: DigestService(client: ContextRecordingClient(), keyProvider: { nil }),
            model: "m",
            autoProcess: true
        )

        XCTAssertNil(workspace.existingTranscript(for: entry), "текстовый файл не расшифровывают")
        await assistant.send("что там?", workspace: workspace, model: "m", allowMutations: false)
        let system = await client.systemMessages
        XCTAssertTrue(system.contains { $0.contains("Договор на три года") }, "текст файла не дошёл до модели")
    }

    @MainActor
    func testUnreadableAttachmentSaysSoInsteadOfPretending() async throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        // Двоичный файл: `readText` на нём честно падает.
        let url = try workspace.fileURL(for: "").appending(path: "Inbox")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: url.appending(path: "Скан.png"))
        try workspace.refresh()
        let entry = try workspace.entry(at: "Inbox/Скан.png")

        let assistant = AssistantStore(
            client: ContextRecordingClient(),
            archive: ConversationArchive(fileURL: historyURL),
            keyProvider: { "test-key" },
            memoryEnabled: { false }
        )

        await ChatIngest.ingest(
            entry: entry,
            in: workspace,
            assistant: assistant,
            transcription: TranscriptionService(
                engine: IngestStubEngine(text: "нет"),
                fallback: IngestStubEngine(text: "нет")
            ),
            digests: DigestService(client: ContextRecordingClient(), keyProvider: { nil }),
            model: "m",
            autoProcess: true
        )

        let note = assistant.bubbles.last
        XCTAssertEqual(note?.role, .system)
        XCTAssertEqual(note?.text.contains("прочитать его я не могу"), true)
    }

    @MainActor
    func testAudioAttachmentIsProcessedIntoNoteWhenKeyIsThere() async throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        try workspace.writeText("не пустой файл", at: "Inbox/Созвон.m4a")
        let entry = try workspace.entry(at: "Inbox/Созвон.m4a")

        let assistant = AssistantStore(
            client: ContextRecordingClient(),
            archive: ConversationArchive(fileURL: historyURL),
            keyProvider: { "test-key" },
            memoryEnabled: { false }
        )
        let digestAnswer = """
        {"title": "Созвон по офферу", "theme": "Работа", "summary": "Итог.",
         "highlights": ["Оффер до пятницы"], "decisions": [], "tasks": [], "tags": ["оффер"]}
        """

        await ChatIngest.ingest(
            entry: entry,
            in: workspace,
            assistant: assistant,
            transcription: TranscriptionService(
                engine: IngestStubEngine(text: "Обсудили оффер, нужен до пятницы."),
                fallback: IngestStubEngine(text: "резерв")
            ),
            digests: DigestService(
                client: ContextRecordingClient(answer: digestAnswer),
                keyProvider: { "test-key" }
            ),
            model: "m",
            autoProcess: true
        )

        // Принесённая в чат запись проходит тот же путь, что и своя: заметка в теме.
        let note = try workspace.readText(at: "Работа/Созвон по офферу.md")
        XCTAssertTrue(note.contains("audio: Inbox/Созвон.m4a"))
        XCTAssertTrue(note.contains("## Важное"))
    }

    @MainActor
    func testContextIsTrimmedButNeverSilently() async throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        let client = ContextRecordingClient()
        let assistant = AssistantStore(
            client: client,
            archive: ConversationArchive(fileURL: historyURL),
            keyProvider: { "test-key" },
            memoryEnabled: { false }
        )

        assistant.addContext(title: "длинный файл", text: String(repeating: "слово ", count: 5_000))
        await assistant.send("что там?", workspace: workspace, model: "m", allowMutations: false)

        let system = await client.systemMessages
        let context = try XCTUnwrap(system.first { $0.contains("длинный файл") })
        XCTAssertTrue(context.contains("текст обрезан"), "обрезка должна быть видна модели")
        XCTAssertLessThan(context.count, AssistantStore.maxContextCharacters + 300)
    }
}
