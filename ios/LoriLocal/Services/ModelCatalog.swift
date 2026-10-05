import Foundation

/// Модель у провайдера: то, из чего человек выбирает в настройках.
struct RemoteModel: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let detail: String?
}

/// Список моделей забирается у самого сервиса.
///
/// Вписывать имя модели руками — не дело человека: линейки меняются чаще, чем выходят
/// сборки приложения, а угаданное имя даёт ошибку вместо расшифровки. Ключ для запроса
/// уже есть в Keychain, так что список стоит один лишний вызов.
struct ModelCatalog: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// У OpenAI аудио умеют только модели расшифровки — по имени это видно надёжно:
    /// остальные полторы сотни моделей в списке выбора только мешали бы.
    func openAI(key: String) async throws -> [RemoteModel] {
        var request = URLRequest(url: TranscriptionSettings.openAIModelsURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try APICheck.ensureSuccess(response: response, data: data)

        struct Answer: Decodable {
            let data: [Item]
            struct Item: Decodable { let id: String }
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw TranscriptionError.badResponse("OpenAI вернул список моделей в неизвестном виде.")
        }
        return Self.audioModels(answer.data.map(\.id))
    }

    static func audioModels(_ identifiers: [String]) -> [RemoteModel] {
        identifiers
            .filter { $0.contains("transcribe") || $0.contains("whisper") }
            .sorted { lhs, rhs in
                // Whisper наверх: он отдаёт тайминги слов, а на них держатся таймкоды.
                let left = lhs.contains("whisper") ? 0 : 1
                let right = rhs.contains("whisper") ? 0 : 1
                return left == right ? lhs < rhs : left < right
            }
            .map { id in
                let detail: String
                if id.contains("diarize") {
                    detail = "говорящие и таймкоды реплик, словарь не принимает"
                } else if id.contains("whisper") {
                    detail = "тайминги слов"
                } else {
                    detail = "без таймингов слов"
                }
                return RemoteModel(id: id, title: id, detail: detail)
            }
    }

    /// Из списка выбрасывается то, что аудио точно не умеет: эмбеддинги, картинки,
    /// видео, синтез речи. Всё остальное остаётся — и специализированные
    /// распознаватели вроде `gemini-3.5-transcribe`, и обычные модели, которые
    /// понимают звук наравне с текстом.
    func gemini(key: String) async throws -> [RemoteModel] {
        var models: [RemoteModel] = []
        var pageToken: String?
        var pages = 0

        repeat {
            var components = URLComponents(url: TranscriptionSettings.geminiModelsURL, resolvingAgainstBaseURL: false)!
            var query = [URLQueryItem(name: "pageSize", value: "200")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = query

            var request = URLRequest(url: components.url!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            request.timeoutInterval = 30
            let (data, response) = try await session.data(for: request)
            try APICheck.ensureSuccess(response: response, data: data)

            struct Answer: Decodable {
                let models: [Item]?
                let nextPageToken: String?

                struct Item: Decodable {
                    let name: String
                    let displayName: String?
                    let description: String?
                    let supportedGenerationMethods: [String]?
                }
            }
            guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
                throw TranscriptionError.badResponse("Google вернул список моделей в неизвестном виде.")
            }
            models += (answer.models ?? []).compactMap {
                Self.geminiModel(
                    name: $0.name,
                    displayName: $0.displayName,
                    description: $0.description,
                    methods: $0.supportedGenerationMethods
                )
            }
            pageToken = answer.nextPageToken
            pages += 1
        } while pageToken != nil && pages < 5

        return models.sorted { $0.id < $1.id }
    }

    private static let geminiSkipped = ["embedding", "imagen", "veo", "tts", "image", "aqa", "gemma"]

    static func geminiModel(name: String, displayName: String?, description: String?, methods: [String]?) -> RemoteModel? {
        let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
        let lower = id.lowercased()
        guard !geminiSkipped.contains(where: lower.contains) else { return nil }
        // Распознаватель речи оставляем всегда: у специализированной модели набор
        // методов может быть свой, а выбросить из списка именно её — худшее, что
        // может сделать этот фильтр.
        let speech = lower.contains("transcribe")
            || (description ?? "").localizedCaseInsensitiveContains("speech")
        if !speech, let methods, !methods.isEmpty,
           !methods.contains(where: { $0.lowercased().contains("generatecontent") }) {
            return nil
        }
        let detail = (description ?? displayName)?
            .split(separator: "\n").first
            .map(String.init)
        return RemoteModel(id: id, title: id, detail: detail?.count ?? 0 > 90 ? String(detail!.prefix(90)) + "…" : detail)
    }

    /// Что показать до того, как ключ сохранён: список из документации сервисов.
    /// Как только ключ есть, он заменяется настоящим ответом API.
    // `gpt-transcribe` — та модель, которую документация теперь называет
    // основной для расшифровки файлов, поэтому она первая в подсказках.
    static let openAISuggestions = audioModels([
        "gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-transcribe-diarize",
        "gpt-4o-mini-transcribe", "whisper-1",
    ])

    /// Модели ассистента — те же `/models` у любого совместимого сервиса, но
    /// нужны из них чат-модели, а не распознаватели речи.
    func chat(key: String) async throws -> [RemoteModel] {
        var request = URLRequest(url: AssistantSettings.modelsURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try APICheck.ensureSuccess(response: response, data: data)

        struct Answer: Decodable {
            let data: [Item]
            struct Item: Decodable { let id: String }
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw TranscriptionError.badResponse("Сервис вернул список моделей в неизвестном виде.")
        }
        return Self.chatModels(answer.data.map(\.id))
    }

    /// Фильтр чёрным списком, а не белым. Белый пришлось бы писать по именам
    /// («gpt», «deepseek», …), а они меняются чаще, чем выходят сборки, и новая
    /// модель просто пропала бы из выбора. Выбрасываем то, что отвечать текстом
    /// точно не умеет.
    private static let chatSkipped = [
        "embedding", "whisper", "transcribe", "tts", "dall-e", "image", "vision-preview",
        "moderation", "realtime", "audio", "search-index", "rerank", "guard",
    ]

    static func chatModels(_ identifiers: [String]) -> [RemoteModel] {
        identifiers
            .filter { id in
                let lower = id.lowercased()
                return !chatSkipped.contains(where: lower.contains)
            }
            .sorted()
            .map { RemoteModel(id: $0, title: $0, detail: nil) }
    }

    /// Что показать до того, как ключ сохранён. Первая строка — значение по
    /// умолчанию для нового ключа.
    static let chatSuggestions = [
        RemoteModel(id: "gpt-6-luna", title: "GPT-6 Luna", detail: "OpenAI, быстрые и недорогие ответы по записям"),
        RemoteModel(id: "gpt-6-sol", title: "GPT-6 Sol", detail: "OpenAI, сложные вопросы, дороже"),
        RemoteModel(id: "gpt-5.1", title: "gpt-5.1", detail: "OpenAI, универсальная"),
        RemoteModel(id: "gpt-5.1-mini", title: "gpt-5.1-mini", detail: "OpenAI, дешевле и быстрее"),
        RemoteModel(id: "deepseek-chat", title: "deepseek-chat", detail: "DeepSeek, дешёвая"),
        RemoteModel(id: "deepseek-reasoner", title: "deepseek-reasoner", detail: "DeepSeek, рассуждает дольше"),
    ]

    /// Модели распознавания у ElevenLabs списком **не отдаются**: `GET /v1/models`
    /// отвечает моделями синтеза речи, и признака «умеет распознавать» в ответе
    /// нет вовсе (проверено по `openapi.json` сервиса). Поэтому здесь короткий
    /// список из документации, а не живой запрос, и кнопки «Обновить список» на
    /// экране этого движка нет — обещать то, чего сервис не даёт, нельзя.
    static let elevenLabsSuggestions = [
        RemoteModel(
            id: "scribe_v2",
            title: "scribe_v2",
            detail: "основная для файлов: тайминги слов, говорящие, звуки"
        ),
        RemoteModel(id: "scribe_v1", title: "scribe_v1", detail: "предыдущая версия"),
    ]

    static let geminiSuggestions = [
        RemoteModel(
            id: "gemini-3.5-transcribe",
            title: "gemini-3.5-transcribe",
            detail: "специализированная на распознавании речи"
        ),
        RemoteModel(id: "gemini-3.7-flash", title: "gemini-3.7-flash", detail: "универсальная, понимает аудио"),
        RemoteModel(id: "gemini-3.1-flash-lite", title: "gemini-3.1-flash-lite", detail: "дешевле и быстрее"),
    ]
}
