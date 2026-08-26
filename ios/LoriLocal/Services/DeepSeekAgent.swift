import Foundation

struct ChatBubble: Identifiable, Hashable, Codable {
    /// `attachment` — файл, который принесли в разговор: в ленте он карточкой,
    /// а не текстом. Старые записи истории поля `path` не имеют, и это нормально.
    enum Role: String, Hashable, Codable { case user, assistant, system, attachment }

    let id: UUID
    let role: Role
    let text: String
    /// Путь внутри рабочей папки. Есть только у вложения.
    let path: String?

    init(role: Role, text: String, path: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.role = role
        self.text = text
        self.path = path
    }
}

struct SavedConversation: Identifiable, Hashable, Codable {
    let id: UUID
    var bubbles: [ChatBubble]
    var updatedAt: Date

    init(id: UUID = UUID(), bubbles: [ChatBubble], updatedAt: Date = .now) {
        self.id = id
        self.bubbles = bubbles
        self.updatedAt = updatedAt
    }

    var title: String {
        bubbles.first(where: { $0.role == .user })?.text ?? "Новый диалог"
    }

    var preview: String {
        bubbles.last(where: { $0.role == .assistant })?.text ?? "Черновик сообщения"
    }
}

/// Модели, которые действительно принимает DeepSeek Chat Completions.
/// Раньше меню предлагало два пункта с одним и тем же значением, а модель в настройках
/// была свободным полем ввода — туда можно было вписать что угодно.
enum DeepSeekModel: String, CaseIterable, Identifiable {
    case flash = "deepseek-v4-flash"
    case pro = "deepseek-v4-pro"

    static let fallback = DeepSeekModel.flash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flash: "V4 Flash"
        case .pro: "V4 Pro"
        }
    }

    var detail: String {
        switch self {
        case .flash: "Быстрые ответы по заметкам"
        case .pro: "Медленнее, лучше в сложных запросах"
        }
    }

    init(storedValue: String) {
        self = DeepSeekModel(rawValue: storedValue) ?? .fallback
    }
}

protocol ChatCompleting: Sendable {
    func complete(
        apiKey: String,
        model: String,
        messages: [DeepSeekMessage],
        tools: [DeepSeekTool]
    ) async throws -> DeepSeekMessage
}

@MainActor
final class AssistantStore: ObservableObject {
    /// Сколько раз подряд модели разрешено вызывать файловые инструменты в одном ответе.
    /// Системный промпт требует list_files корня, потом list_files папки, потом чтение —
    /// одного раунда принципиально не хватает.
    static let maxToolRounds = 6
    /// Сколько знаков вложения уходит в контекст диалога.
    static let maxContextCharacters = 12_000

    @Published private(set) var bubbles: [ChatBubble] = []
    @Published private(set) var isSending = false
    @Published private(set) var history: [SavedConversation] = []
    @Published var errorMessage: String?

    private(set) var queuedPrompt: String?
    /// Заготовка для поля ввода: «спросить про заметку» открывает чат с готовым вопросом,
    /// но отправляет его человек, а не приложение.
    private(set) var prefilledDraft: String?

    private static let systemPrompt = """
    Ты — ассистент Lori на iPhone. У тебя есть доступ только к рабочей папке Lori.
    Используй файловые инструменты, когда это нужно для задачи. Никогда не выдумывай имя,
    расположение или существование файла: до первого чтения, изменения или поиска сначала вызови
    list_files для корня, а затем для нужной папки. Используй только полный относительный путь,
    который вернул list_files. Если папка пуста, прямо скажи об этом и предложи пользователю
    добавить файл через кнопку «+» или скрепку. Не утверждай, что файл изменён, пока не получишь
    результат инструмента. Удаление всегда означает перенос в локальную корзину.

    Вопрос про содержание записей начинай с search_notes: он ищет сразу по всем заметкам
    и расшифровкам и возвращает точные пути. Читай найденное через read_text_file, а если
    поиск ничего не дал — скажи об этом прямо, не пересказывай догадки.

    Ты — внешняя память владельца. Устойчивый факт о нём или его делах сохраняй
    инструментом remember: коротко, одним предложением, и только то, что пригодится позже.
    Разовые мелочи запоминать не надо. Просят забыть — вызывай forget.
    """

    private let client: any ChatCompleting
    private let archive: ConversationArchive
    private let keyProvider: () throws -> String?
    /// Память отключается в настройках. Читается на каждую отправку, а не в init:
    /// переключатель должен действовать сразу, без перезапуска приложения.
    private let memoryEnabled: () -> Bool
    private var conversation: [DeepSeekMessage]
    private var activeID = UUID()

    init(
        client: any ChatCompleting = DeepSeekClient(),
        archive: ConversationArchive = ConversationArchive(),
        keyProvider: @escaping () throws -> String? = { try KeychainStore.deepSeekKey() },
        memoryEnabled: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: "loriMemory") }
    ) {
        self.client = client
        self.archive = archive
        self.keyProvider = keyProvider
        self.memoryEnabled = memoryEnabled
        conversation = [DeepSeekMessage(role: "system", content: Self.systemPrompt)]
        history = archive.load()
    }

    func clear() {
        persistActiveConversation()
        activeID = UUID()
        conversation = [DeepSeekMessage(role: "system", content: Self.systemPrompt)]
        bubbles = []
        errorMessage = nil
    }

    func restore(_ saved: SavedConversation) {
        persistActiveConversation()
        activeID = saved.id
        bubbles = saved.bubbles
        conversation = [DeepSeekMessage(role: "system", content: Self.systemPrompt)]
            + saved.bubbles.compactMap { bubble in
                switch bubble.role {
                case .user: DeepSeekMessage(role: "user", content: bubble.text)
                case .assistant: DeepSeekMessage(role: "assistant", content: bubble.text)
                // Служебные строки и вложения в контекст не возвращаются: текст вложения
                // при восстановлении диалога придётся принести заново, зато модель
                // не получит выдуманную историю.
                case .system, .attachment: nil
                }
            }
        errorMessage = nil
    }

    /// Служебная строка в ленте: это говорит приложение, а не модель.
    func note(_ text: String) {
        bubbles.append(ChatBubble(role: .system, text: text))
        persistActiveConversation()
    }

    /// Файл уже лежит в рабочей папке — показываем его в ленте карточкой.
    func attach(_ relativePath: String, title: String) {
        bubbles.append(ChatBubble(role: .attachment, text: title, path: relativePath))
        persistActiveConversation()
    }

    /// Текст вложения уходит модели служебным сообщением, а не пузырём: человек
    /// уже видит карточку, а вставлять стену расшифровки в ленту незачем.
    func addContext(title: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var body = String(trimmed.prefix(Self.maxContextCharacters))
        if trimmed.count > Self.maxContextCharacters {
            body += "\n… (текст обрезан, полностью он лежит в файле)"
        }
        conversation.append(DeepSeekMessage(
            role: "system",
            content: "Человек принёс в разговор «\(title)». Вот его текст:\n\n\(body)"
        ))
    }

    func queue(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        queuedPrompt = prompt
    }

    func takeQueuedPrompt() -> String? {
        defer { queuedPrompt = nil }
        return queuedPrompt
    }

    func prefill(_ text: String) {
        prefilledDraft = text
    }

    func takePrefilledDraft() -> String? {
        defer { prefilledDraft = nil }
        return prefilledDraft
    }

    func send(
        _ text: String,
        workspace: WorkspaceStore,
        model: String,
        allowMutations: Bool
    ) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSending else { return }
        isSending = true
        errorMessage = nil
        defer {
            isSending = false
            persistActiveConversation()
        }

        bubbles.append(ChatBubble(role: .user, text: prompt))
        conversation.append(DeepSeekMessage(role: "user", content: prompt))

        do {
            guard let key = try keyProvider(), !key.isEmpty else { throw AgentError.missingKey }
            let allowMemory = memoryEnabled()
            // Память подмешивается в системную инструкцию перед каждой отправкой:
            // диалог мог начаться раньше, чем в памяти появился нужный факт.
            conversation[0] = DeepSeekMessage(
                role: "system",
                content: Self.systemMessage(for: workspace, includeMemory: allowMemory)
            )
            let tools = WorkspaceTools.definitions(allowMutations: allowMutations)
                + BrainTools.definitions(allowMemory: allowMemory)
            // Имя модели зависит от провайдера: у своего оно своё.
            let effectiveModel = LLMSettings.resolvedModel(picked: model)

            for round in 1...Self.maxToolRounds {
                let message = try await client.complete(
                    apiKey: key,
                    model: effectiveModel,
                    messages: conversation,
                    tools: tools
                )
                conversation.append(message)

                let visibleText = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !visibleText.isEmpty {
                    bubbles.append(ChatBubble(role: .assistant, text: visibleText))
                }

                guard let calls = message.toolCalls, !calls.isEmpty else {
                    if visibleText.isEmpty {
                        bubbles.append(ChatBubble(role: .assistant, text: "Пустой ответ модели."))
                    }
                    return
                }

                bubbles.append(ChatBubble(role: .system, text: Self.activityLine(for: calls)))
                for call in calls {
                    // Инструменты «мозга» — поиск по всей базе и память — проверяются первыми;
                    // всё остальное исполняет файловая часть.
                    let result = BrainTools.execute(
                        named: call.function.name,
                        arguments: call.function.arguments,
                        workspace: workspace,
                        allowMemory: allowMemory
                    ) ?? workspace.executeTool(
                        named: call.function.name,
                        arguments: call.function.arguments,
                        allowMutations: allowMutations
                    )
                    conversation.append(DeepSeekMessage(role: "tool", content: result, toolCallID: call.id))
                }

                if round == Self.maxToolRounds {
                    bubbles.append(ChatBubble(
                        role: .system,
                        text: "Остановился после \(Self.maxToolRounds) обращений к файлам — ответ не был получен. Уточни запрос."
                    ))
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Активный диалог попадает в историю сразу после обмена сообщениями,
    /// иначе он теряется при выгрузке приложения из памяти.
    private func persistActiveConversation() {
        guard !bubbles.isEmpty else { return }
        let snapshot = SavedConversation(id: activeID, bubbles: bubbles, updatedAt: .now)
        history.removeAll { $0.id == activeID }
        history.insert(snapshot, at: 0)
        history = Array(history.prefix(ConversationArchive.maxConversations))
        do {
            try archive.save(history)
        } catch {
            errorMessage = "Не удалось сохранить историю диалогов: \(error.localizedDescription)"
        }
    }

    private static func activityLine(for calls: [DeepSeekToolCall]) -> String {
        let parts = calls.map { call -> String in
            let action = switch call.function.name {
            case "list_files": "смотрю список"
            case "read_text_file": "читаю"
            case "write_text_file": "записываю"
            case "rename_file": "перемещаю"
            case "move_to_trash": "переношу в корзину"
            case "search_notes": "ищу по заметкам"
            case "remember": "запоминаю"
            case "forget": "убираю из памяти"
            default: call.function.name
            }
            guard let path = decodedPath(from: call.function.arguments), !path.isEmpty else { return action }
            return "\(action) «\(path)»"
        }
        return "Работаю: \(parts.joined(separator: ", "))"
    }

    /// Системная инструкция вместе с памятью. Без памяти — ровно прежний текст:
    /// пустой заголовок «что ты знаешь» модель только путал бы.
    private static func systemMessage(for workspace: WorkspaceStore, includeMemory: Bool) -> String {
        guard includeMemory, let memory = MemoryStore.promptBlock(in: workspace) else { return systemPrompt }
        return "\(systemPrompt)\n\n\(memory)"
    }

    private static func decodedPath(from arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["path"] as? String
    }
}

enum AgentError: LocalizedError {
    case missingKey
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: "Добавь ключ DeepSeek в настройках Lori. Он сохранится только в Keychain телефона."
        case .invalidResponse: "DeepSeek вернул неполный ответ."
        }
    }
}

enum WorkspaceTools {
    private static let stringSchema = JSONValue.object(["type": .string("string")])

    static func definitions(allowMutations: Bool) -> [DeepSeekTool] {
        var tools = [
            tool("list_files", "Показывает содержимое папки Lori. Пустой path означает корень. В ответе возвращаются точные относительные пути; используй их без изменений в других инструментах.", ["path": stringSchema]),
            tool("read_text_file", "Читает UTF-8 текстовый файл из рабочей папки Lori.", ["path": stringSchema]),
        ]
        if allowMutations {
            tools += [
                tool("write_text_file", "Создаёт или заменяет UTF-8 текстовый файл внутри рабочей папки Lori.", ["path": stringSchema, "content": stringSchema]),
                tool("rename_file", "Переименовывает или перемещает файл только внутри рабочей папки Lori.", ["path": stringSchema, "destination": stringSchema]),
                tool("move_to_trash", "Перемещает файл в локальную корзину Lori; физически файл не удаляется.", ["path": stringSchema]),
            ]
        }
        return tools
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: JSONValue]) -> DeepSeekTool {
        DeepSeekTool(
            function: DeepSeekFunction(
                name: name,
                description: description,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(properties),
                    "additionalProperties": .bool(false),
                ])
            )
        )
    }
}

struct DeepSeekClient: ChatCompleting {
    /// Адрес читается на каждый запрос, а не запоминается в init: клиент создаётся
    /// на запуске приложения, а провайдера меняют в настройках уже потом.
    private var endpoint: URL { LLMSettings.chatCompletionsURL }
    private var modelsEndpoint: URL { LLMSettings.modelsURL }

    /// Checks only whether DeepSeek accepts the key. The key remains in Keychain
    /// and is never shown in the UI, logs, or an error message.
    func validate(apiKey: String) async throws {
        var request = URLRequest(url: modelsEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(DeepSeekAPIError.self, from: data))?.error.message ?? "HTTP \(http.statusCode)"
            throw DeepSeekHTTPError(detail: detail)
        }
    }

    func complete(
        apiKey: String,
        model: String,
        messages: [DeepSeekMessage],
        tools: [DeepSeekTool]
    ) async throws -> DeepSeekMessage {
        let payload = DeepSeekRequest(model: model, messages: messages, tools: tools)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(DeepSeekAPIError.self, from: data))?.error.message ?? "HTTP \(http.statusCode)"
            throw DeepSeekHTTPError(detail: detail)
        }
        let decoded = try JSONDecoder().decode(DeepSeekResponse.self, from: data)
        guard let message = decoded.choices.first?.message else { throw AgentError.invalidResponse }
        return message
    }
}

private struct DeepSeekRequest: Encodable {
    let model: String
    let messages: [DeepSeekMessage]
    let tools: [DeepSeekTool]
    let toolChoice = "auto"
    let stream = false

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, stream
        case toolChoice = "tool_choice"
    }
}

private struct DeepSeekResponse: Decodable {
    struct Choice: Decodable { let message: DeepSeekMessage }
    let choices: [Choice]
}

private struct DeepSeekAPIError: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
}

private struct DeepSeekHTTPError: LocalizedError {
    let detail: String
    var errorDescription: String? { "DeepSeek API: \(detail)" }
}

struct DeepSeekMessage: Codable {
    let role: String
    let content: String?
    let toolCalls: [DeepSeekToolCall]?
    let toolCallID: String?

    init(role: String, content: String? = nil, toolCalls: [DeepSeekToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
}

struct DeepSeekToolCall: Codable {
    let id: String
    let type: String
    let function: DeepSeekFunctionCall

    init(id: String, type: String = "function", function: DeepSeekFunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
}

struct DeepSeekFunctionCall: Codable {
    let name: String
    let arguments: String
}

struct DeepSeekTool: Encodable {
    let type = "function"
    let function: DeepSeekFunction
}

struct DeepSeekFunction: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
}

indirect enum JSONValue: Encodable {
    case string(String)
    case bool(Bool)
    case object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}
