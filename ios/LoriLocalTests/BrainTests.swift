import XCTest
@testable import LoriLocal

/// Записывает, с чем именно позвали модель: набор инструментов и системную инструкцию.
private actor RecordingChatClient: ChatCompleting {
    private let answer: DeepSeekMessage
    private(set) var toolNames: [String] = []
    private(set) var systemPrompt = ""

    init(answer: DeepSeekMessage = DeepSeekMessage(role: "assistant", content: "Готово.")) {
        self.answer = answer
    }

    func complete(
        apiKey: String,
        model: String,
        messages: [DeepSeekMessage],
        tools: [DeepSeekTool]
    ) async throws -> DeepSeekMessage {
        toolNames = tools.map(\.function.name)
        systemPrompt = messages.first(where: { $0.role == "system" })?.content ?? ""
        return answer
    }
}

final class BrainTests: XCTestCase {
    private var temporaryRoot: URL!
    private var historyURL: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "LoriBrainTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        temporaryRoot = base.appending(path: "Workspace", directoryHint: .isDirectory)
        historyURL = base.appending(path: "chat-history.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot.deletingLastPathComponent())
    }

    @MainActor
    private func workspace() -> WorkspaceStore {
        let store = WorkspaceStore(rootURL: temporaryRoot)
        store.start()
        return store
    }

    // MARK: - Поиск

    func testStemsDropNoiseAndCutToFiveLetters() {
        XCTAssertEqual(
            NoteSearchIndex.stems(of: "Что мы решили по найму кандидата?"),
            ["решил", "найму", "канди"]
        )
        XCTAssertTrue(NoteSearchIndex.stems(of: "что как это").isEmpty)
    }

    @MainActor
    func testSearchFindsNoteByInflectedWord() throws {
        let store = workspace()
        try store.writeText("Оффера кандидатам ушли в пятницу.\n", at: "Работа/Оффер.md")
        try store.writeText("Купить молоко и хлеб.\n", at: "Личное/Покупки.md")

        let hits = NoteSearchIndex.search("оффер кандидату", in: store)

        XCTAssertEqual(hits.map(\.path), ["Работа/Оффер.md"])
        XCTAssertEqual(hits.first?.snippets, ["Оффера кандидатам ушли в пятницу."])
    }

    @MainActor
    func testSearchPutsNoteWithMoreMatchedWordsFirst() throws {
        let store = workspace()
        // Одно слово, зато десять раз.
        try store.writeText(String(repeating: "найм ", count: 10), at: "A.md")
        // Два разных слова из запроса — это ближе к вопросу.
        try store.writeText("Найм закрыт, оффер подписан.\n", at: "B.md")

        let hits = NoteSearchIndex.search("найм оффер", in: store)

        XCTAssertEqual(hits.first?.path, "B.md")
        XCTAssertEqual(hits.count, 2)
    }

    @MainActor
    func testSearchFindsAudioByNameOnly() throws {
        let store = workspace()
        try store.writeText("не текст", at: "Recordings/Планёрка найм.m4a")

        let hits = NoteSearchIndex.search("найм", in: store)

        XCTAssertEqual(hits.map(\.path), ["Recordings/Планёрка найм.m4a"])
        XCTAssertTrue(hits.first?.snippets.isEmpty == true, "у аудио нет строк для цитаты")
    }

    @MainActor
    func testSearchSnippetsSkipFrontMatter() throws {
        let store = workspace()
        let digest = NoteDigest(
            title: "Планёрка",
            theme: "Работа",
            summary: "Обсудили оффер.",
            highlights: ["Оффер до пятницы"],
            decisions: [],
            tasks: [],
            tags: ["оффер"]
        )
        try store.writeText(
            digest.markdown(audioPath: "Recordings/R.m4a", transcriptPath: "Transcripts/R.md", created: .now),
            at: "Работа/Планёрка.md"
        )

        let hits = NoteSearchIndex.search("оффер", in: store)

        XCTAssertEqual(hits.count, 1)
        // Служебные строки front matter в цитаты попадать не должны.
        XCTAssertFalse(hits[0].snippets.contains { $0.hasPrefix("tags:") })
        XCTAssertTrue(hits[0].snippets.contains("Обсудили оффер."))
    }

    // MARK: - Память

    @MainActor
    func testRememberWritesVisibleNoteWithDate() throws {
        let store = workspace()
        let stamped = try MemoryStore.remember(
            "Илья работает в Integra-4D",
            in: store,
            on: Date(timeIntervalSince1970: 1_787_000_000)
        )

        XCTAssertTrue(stamped.hasSuffix("Илья работает в Integra-4D"))
        let text = try store.readText(at: MemoryStore.path)
        XCTAssertTrue(text.hasPrefix("# Память Lori"))
        // Дата в файле абсолютная: «вчера» в памяти, которая живёт годами, бесполезно.
        XCTAssertTrue(text.contains("2026 — Илья работает в Integra-4D"), "нет абсолютной даты: \(text)")
        XCTAssertEqual(MemoryStore.facts(in: store).count, 1)
    }

    @MainActor
    func testRememberIgnoresRepeatedFact() throws {
        let store = workspace()
        try MemoryStore.remember("Часовой пояс МСК", in: store, on: Date(timeIntervalSince1970: 0))
        try MemoryStore.remember("Часовой пояс МСК", in: store, on: Date(timeIntervalSince1970: 90_000))

        XCTAssertEqual(MemoryStore.facts(in: store).count, 1)
    }

    @MainActor
    func testPromptBlockListsFactsAndIsEmptyWithoutThem() throws {
        let store = workspace()
        XCTAssertNil(MemoryStore.promptBlock(in: store))

        try MemoryStore.remember("Проект Lori — личный второй мозг", in: store)
        let block = try XCTUnwrap(MemoryStore.promptBlock(in: store))
        XCTAssertTrue(block.contains("Проект Lori — личный второй мозг"))
    }

    @MainActor
    func testForgetRemovesOnlyMatchingLines() throws {
        let store = workspace()
        try MemoryStore.remember("Часовой пояс МСК", in: store)
        try MemoryStore.remember("Работает в Integra-4D", in: store)

        XCTAssertEqual(try MemoryStore.forget("интегра", in: store), 0)
        XCTAssertEqual(try MemoryStore.forget("Integra", in: store), 1)
        let left = MemoryStore.facts(in: store)
        XCTAssertEqual(left.count, 1)
        XCTAssertTrue(left[0].hasSuffix("Часовой пояс МСК"))
    }

    // MARK: - Инструменты

    @MainActor
    func testSearchToolReportsPathsAndSaysWhenNothingFound() throws {
        let store = workspace()
        try store.writeText("Оффер до пятницы.\n", at: "Работа/Оффер.md")

        let found = BrainTools.execute(
            named: "search_notes",
            arguments: "{\"query\": \"оффер\"}",
            workspace: store,
            allowMemory: true
        )
        XCTAssertEqual(found?.contains("Работа/Оффер.md"), true)

        let empty = BrainTools.execute(
            named: "search_notes",
            arguments: "{\"query\": \"вертолёт\"}",
            workspace: store,
            allowMemory: true
        )
        // Пустой результат должен прямо запрещать выдумывать ответ.
        XCTAssertEqual(empty?.contains("ничего не нашлось"), true)
    }

    @MainActor
    func testMemoryToolsRefuseWhenMemoryIsOff() throws {
        let store = workspace()
        let result = BrainTools.execute(
            named: "remember",
            arguments: "{\"fact\": \"что-то\"}",
            workspace: store,
            allowMemory: false
        )

        XCTAssertEqual(result?.contains("Память отключена"), true)
        XCTAssertTrue(MemoryStore.facts(in: store).isEmpty)
    }

    @MainActor
    func testUnknownToolIsNotOurs() throws {
        let store = workspace()
        XCTAssertNil(BrainTools.execute(
            named: "list_files",
            arguments: "{}",
            workspace: store,
            allowMemory: true
        ))
    }

    // MARK: - Связь с агентом

    @MainActor
    func testAgentGetsMemoryInSystemPromptAndSearchTool() async throws {
        let store = workspace()
        try MemoryStore.remember("Работает в Integra-4D", in: store)

        let client = RecordingChatClient()
        let assistant = AssistantStore(
            client: client,
            archive: ConversationArchive(fileURL: historyURL),
            keyProvider: { "test-key" },
            memoryEnabled: { true }
        )

        await assistant.send("Привет", workspace: store, model: "m", allowMutations: false)

        let prompt = await client.systemPrompt
        XCTAssertTrue(prompt.contains("Работает в Integra-4D"), "память не попала в системную инструкцию")
        let tools = await client.toolNames
        XCTAssertTrue(tools.contains("search_notes"))
        XCTAssertTrue(tools.contains("remember"))
        // Изменение файлов выключено — файловых мутаций в наборе быть не должно.
        XCTAssertFalse(tools.contains("write_text_file"))
    }

    @MainActor
    func testDisabledMemoryHidesToolsAndFacts() async throws {
        let store = workspace()
        try MemoryStore.remember("Работает в Integra-4D", in: store)

        let client = RecordingChatClient()
        let assistant = AssistantStore(
            client: client,
            archive: ConversationArchive(fileURL: historyURL),
            keyProvider: { "test-key" },
            memoryEnabled: { false }
        )

        await assistant.send("Привет", workspace: store, model: "m", allowMutations: false)

        let tools = await client.toolNames
        XCTAssertFalse(tools.contains("remember"))
        XCTAssertFalse(tools.contains("forget"))
        // Поиск по заметкам от памяти не зависит.
        XCTAssertTrue(tools.contains("search_notes"))
        // Выключенная память не должна подставляться и в системную инструкцию.
        let prompt = await client.systemPrompt
        XCTAssertFalse(prompt.contains("Integra-4D"))
    }
}
