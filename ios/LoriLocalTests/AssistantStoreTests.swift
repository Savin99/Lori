import XCTest
@testable import LoriLocal

/// Заранее заданные ответы модели. Актор, потому что `ChatCompleting` — Sendable
/// и вызывается из main-actor стора.
private actor ScriptedChatClient: ChatCompleting {
    private var script: [DeepSeekMessage]
    private let repeated: DeepSeekMessage?
    private(set) var callCount = 0
    private(set) var lastMessageCount = 0

    init(script: [DeepSeekMessage], repeating repeated: DeepSeekMessage? = nil) {
        self.script = script
        self.repeated = repeated
    }

    func complete(
        apiKey: String,
        model: String,
        messages: [DeepSeekMessage],
        tools: [DeepSeekTool]
    ) async throws -> DeepSeekMessage {
        callCount += 1
        lastMessageCount = messages.count
        if script.isEmpty {
            guard let repeated else { throw AgentError.invalidResponse }
            return repeated
        }
        return script.removeFirst()
    }
}

private extension DeepSeekMessage {
    static func toolCall(id: String, name: String, arguments: String) -> DeepSeekMessage {
        DeepSeekMessage(
            role: "assistant",
            toolCalls: [DeepSeekToolCall(id: id, function: DeepSeekFunctionCall(name: name, arguments: arguments))]
        )
    }
}

final class AssistantStoreTests: XCTestCase {
    private var temporaryRoot: URL!
    private var historyURL: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "LoriAgentTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        temporaryRoot = base.appending(path: "Workspace", directoryHint: .isDirectory)
        historyURL = base.appending(path: "chat-history.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot.deletingLastPathComponent())
    }

    @MainActor
    func testAgentKeepsCallingToolsUntilModelAnswers() async throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        try workspace.writeText("Купить хлеб", at: "Дела/список.md")

        let client = ScriptedChatClient(script: [
            .toolCall(id: "1", name: "list_files", arguments: #"{"path":""}"#),
            .toolCall(id: "2", name: "list_files", arguments: #"{"path":"Дела"}"#),
            .toolCall(id: "3", name: "read_text_file", arguments: #"{"path":"Дела/список.md"}"#),
            DeepSeekMessage(role: "assistant", content: "В списке одна задача: купить хлеб."),
        ])
        let store = makeStore(client: client)

        await store.send("Что у меня в делах?", workspace: workspace, model: "deepseek-v4-flash", allowMutations: false)

        let roundsUsed = await client.callCount
        XCTAssertEqual(roundsUsed, 4, "модель должна получить результаты всех трёх раундов инструментов")
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.bubbles.last?.role, .assistant)
        XCTAssertEqual(store.bubbles.last?.text, "В списке одна задача: купить хлеб.")
    }

    @MainActor
    func testToolActivityIsVisibleInTranscript() async throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()

        let client = ScriptedChatClient(script: [
            .toolCall(id: "1", name: "read_text_file", arguments: #"{"path":"Заметка.md"}"#),
            DeepSeekMessage(role: "assistant", content: "Такого файла нет."),
        ])
        let store = makeStore(client: client)

        await store.send("Прочитай заметку", workspace: workspace, model: "m", allowMutations: false)

        let activity = store.bubbles.first { $0.role == .system }
        XCTAssertNotNil(activity, "пользователь должен видеть, что Lori обращалась к файлам")
        XCTAssertTrue(activity?.text.contains("Заметка.md") == true)
    }

    @MainActor
    func testAgentStopsAfterRoundLimit() async throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()

        let client = ScriptedChatClient(
            script: [],
            repeating: .toolCall(id: "loop", name: "list_files", arguments: #"{"path":""}"#)
        )
        let store = makeStore(client: client)

        await store.send("Зацикливайся", workspace: workspace, model: "m", allowMutations: false)

        let roundsUsed = await client.callCount
        XCTAssertEqual(roundsUsed, AssistantStore.maxToolRounds)
        XCTAssertEqual(store.bubbles.last?.role, .system)
        XCTAssertTrue(store.bubbles.last?.text.contains("Остановился") == true)
    }

    @MainActor
    func testMissingKeyReportsErrorWithoutNetworkCall() async throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()

        let client = ScriptedChatClient(script: [DeepSeekMessage(role: "assistant", content: "не должно вызваться")])
        let store = AssistantStore(
            client: client,
            archive: ConversationArchive(fileURL: historyURL),
            keyProvider: { nil }
        )

        await store.send("Привет", workspace: workspace, model: "m", allowMutations: false)

        let roundsUsed = await client.callCount
        XCTAssertEqual(roundsUsed, 0)
        XCTAssertEqual(store.errorMessage, AgentError.missingKey.errorDescription)
    }

    @MainActor
    func testConversationSurvivesStoreRecreation() async throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        let archive = ConversationArchive(fileURL: historyURL)

        let store = AssistantStore(
            client: ScriptedChatClient(script: [DeepSeekMessage(role: "assistant", content: "Готово.")]),
            archive: archive,
            keyProvider: { "test-key" }
        )
        await store.send("Собери задачи", workspace: workspace, model: "m", allowMutations: false)

        let reopened = AssistantStore(
            client: ScriptedChatClient(script: []),
            archive: archive,
            keyProvider: { "test-key" }
        )

        XCTAssertEqual(reopened.history.count, 1)
        XCTAssertEqual(reopened.history.first?.title, "Собери задачи")
        XCTAssertEqual(reopened.history.first?.preview, "Готово.")
    }

    @MainActor
    func testNewChatKeepsPreviousConversationInHistory() async throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()

        let store = makeStore(client: ScriptedChatClient(
            script: [
                DeepSeekMessage(role: "assistant", content: "Первый ответ."),
                DeepSeekMessage(role: "assistant", content: "Второй ответ."),
            ]
        ))

        await store.send("Первый вопрос", workspace: workspace, model: "m", allowMutations: false)
        store.clear()
        await store.send("Второй вопрос", workspace: workspace, model: "m", allowMutations: false)

        XCTAssertEqual(store.history.count, 2)
        XCTAssertEqual(store.history.map(\.title), ["Второй вопрос", "Первый вопрос"])
        XCTAssertEqual(store.bubbles.count, 2, "в открытом диалоге остаётся только новый обмен")
    }

    @MainActor
    private func makeStore(client: any ChatCompleting) -> AssistantStore {
        AssistantStore(
            client: client,
            archive: ConversationArchive(fileURL: historyURL),
            keyProvider: { "test-key" }
        )
    }
}
