import Foundation

/// Находка поиска для модели: путь, счёт и строки, в которых совпало.
struct NoteSearchHit: Equatable {
    let path: String
    let score: Int
    let snippets: [String]
}

/// Поиск по всей рабочей папке — то, чего агенту не хватало больше всего:
/// `list_files` показывает имена, `read_text_file` читает по одному файлу,
/// а вопрос «что я говорил про найм» требует заглянуть сразу во всё.
///
/// Это честный поиск по словам, а не векторный: слова сравниваются по основе
/// (первые пять букв), чтобы падежи и числа не мешали. Личная база небольшая,
/// и обход обходится дешевле, чем хранение эмбеддингов и их пересчёт.
enum NoteSearchIndex {
    static let maxHits = 6
    static let maxSnippetsPerHit = 3
    static let snippetLimit = 200
    /// Слова, по которым искать бессмысленно: они есть в любой заметке.
    static let stopWords: Set<String> = [
        "что", "как", "или", "это", "тот", "там", "чем", "кто", "где", "когда", "если", "для",
        "про", "над", "под", "при", "без", "все", "они", "она", "оно", "мне", "нас", "вас",
        "был", "была", "было", "были", "есть", "надо", "нужно", "может", "можно", "ещё",
        "the", "and", "for", "you", "not", "but", "with", "this", "that", "from", "have",
    ]

    /// Основа слова: первые пять букв. Грубо, но «найму», «найма» и «найм»
    /// после этого сходятся, а морфологического анализатора в проекте нет.
    static func stems(of query: String) -> [String] {
        var seen = Set<String>()
        return query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
            .map { $0.count > 5 ? String($0.prefix(5)) : $0 }
            .filter { seen.insert($0).inserted }
    }

    @MainActor
    static func search(_ query: String, in workspace: WorkspaceStore) -> [NoteSearchHit] {
        let stems = stems(of: query)
        guard !stems.isEmpty else { return [] }

        var hits: [NoteSearchHit] = []
        var queue = [""]
        while let directory = queue.popLast() {
            guard let items = try? workspace.entries(at: directory) else { continue }
            for item in items {
                if item.isDirectory {
                    queue.append(item.relativePath)
                    continue
                }
                // Аудио и прочее нетекстовое ищется по имени: `readText` на них падает.
                guard !item.isAudio, let text = try? workspace.readText(at: item.relativePath) else {
                    if matches(name: item.name, stems: stems) {
                        hits.append(NoteSearchHit(path: item.relativePath, score: 5, snippets: []))
                    }
                    continue
                }
                if let hit = score(text: text, name: item.name, path: item.relativePath, stems: stems) {
                    hits.append(hit)
                }
            }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(maxHits))
    }

    private static func matches(name: String, stems: [String]) -> Bool {
        let lowered = name.lowercased()
        return stems.contains { lowered.contains($0) }
    }

    private static func score(text: String, name: String, path: String, stems: [String]) -> NoteSearchHit? {
        let lowered = text.lowercased()
        var matched = 0
        var occurrences = 0
        for stem in stems {
            let count = lowered.components(separatedBy: stem).count - 1
            if count > 0 {
                matched += 1
                occurrences += count
            }
        }
        let nameBonus = matches(name: name, stems: stems) ? 5 : 0
        guard matched > 0 || nameBonus > 0 else { return nil }
        // Совпавшие слова весят больше, чем их количество: заметка, где есть
        // и «найм», и «оффер», важнее той, где «найм» повторён десять раз.
        let score = matched * 10 + min(occurrences, 20) + nameBonus
        // Цитаты — только из тела: front matter это служебные строки, читать их незачем.
        return NoteSearchHit(path: path, score: score, snippets: snippets(in: NoteMeta.body(of: text), stems: stems))
    }

    private static func snippets(in text: String, stems: [String]) -> [String] {
        var found: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("---"), !line.hasPrefix("#") else { continue }
            let lowered = line.lowercased()
            guard stems.contains(where: { lowered.contains($0) }) else { continue }
            found.append(line.count > snippetLimit ? "\(line.prefix(snippetLimit))…" : line)
            if found.count == maxSnippetsPerHit { break }
        }
        return found
    }
}

/// Память Lori: обычная заметка в рабочей папке, а не скрытая база.
///
/// Так человек видит, что о нём запомнили, и может это исправить или стереть
/// руками — то же правило, что и у файлов заметок. Содержимое подмешивается
/// в системную инструкцию каждого диалога, поэтому «помнит» работает и без вызова
/// инструмента.
@MainActor
enum MemoryStore {
    static let path = "Память Lori.md"
    /// Сколько знаков памяти уходит в модель. Дальше — обрезка с явным сообщением,
    /// молча терять факты нельзя.
    static let maxPromptCharacters = 4_000
    static let maxFacts = 400

    private static let header = """
    # Память Lori

    Здесь Lori хранит то, что просили запомнить. Файл можно править и чистить руками —
    это обычная заметка.
    """

    static func facts(in workspace: WorkspaceStore) -> [String] {
        guard let text = try? workspace.readText(at: path) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") else { return nil }
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

    /// Блок для системной инструкции. Пусто, если памяти ещё нет:
    /// пустой заголовок «Память» только путал бы модель.
    static func promptBlock(in workspace: WorkspaceStore) -> String? {
        let facts = facts(in: workspace)
        guard !facts.isEmpty else { return nil }
        var block = "Что ты уже знаешь о владельце и его делах (память Lori):"
        for fact in facts {
            let line = "\n- \(fact)"
            if block.count + line.count > maxPromptCharacters {
                block += "\n- (память длиннее, чем влезает в запрос: показаны первые факты)"
                break
            }
            block += line
        }
        return block
    }

    @discardableResult
    static func remember(_ fact: String, in workspace: WorkspaceStore, on date: Date = .now) throws -> String {
        let cleaned = fact
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw MemoryError.emptyFact }

        var facts = self.facts(in: workspace)
        guard facts.count < maxFacts else { throw MemoryError.full }
        let stamped = "\(dayFormatter.string(from: date)) — \(cleaned)"
        // Дубли ловим по самому факту, без даты: иначе одно и то же ложилось бы
        // в память каждый день заново.
        if facts.contains(where: { $0.hasSuffix(cleaned) }) { return stamped }
        facts.append(stamped)
        try write(facts, in: workspace)
        return stamped
    }

    /// Забыть — это убрать строки, в которых встречается указанное.
    /// Возвращает, сколько строк ушло.
    @discardableResult
    static func forget(_ needle: String, in workspace: WorkspaceStore) throws -> Int {
        let cleaned = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { throw MemoryError.emptyFact }
        let facts = self.facts(in: workspace)
        let kept = facts.filter { !$0.lowercased().contains(cleaned) }
        guard kept.count != facts.count else { return 0 }
        try write(kept, in: workspace)
        return facts.count - kept.count
    }

    /// Дата в памяти абсолютная: «вчера» в файле, который живёт годами, бесполезно.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = LoriFormat.locale
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    private static func write(_ facts: [String], in workspace: WorkspaceStore) throws {
        let body = facts.map { "- \($0)" }.joined(separator: "\n")
        try workspace.writeText("\(header)\n\n\(body)\n", at: path)
    }
}

enum MemoryError: LocalizedError, Equatable {
    case emptyFact
    case full
    case disabled

    var errorDescription: String? {
        switch self {
        case .emptyFact: "Нечего запоминать: факт пустой."
        case .full: "Память Lori заполнена — почисти «Память Lori.md» и повтори."
        case .disabled: "Память отключена в настройках Lori."
        }
    }
}

/// Инструменты «второго мозга»: поиск по всей базе и память.
/// Файловые инструменты остаются в `WorkspaceTools` — здесь то, что делает
/// из хранилища именно память, а не папку с файлами.
enum BrainTools {
    static let names: Set<String> = ["search_notes", "list_topics", "topic_notes", "remember", "forget"]

    static func definitions(allowMemory: Bool) -> [DeepSeekTool] {
        var tools = [
            tool(
                "search_notes",
                "Ищет по тексту всех заметок и расшифровок в рабочей папке Lori сразу. Возвращает подходящие файлы со строками совпадений. Начинай с этого инструмента на любой вопрос про содержание записей, а потом читай нужный файл через read_text_file.",
                ["query": .object(["type": .string("string")])]
            ),
        ]
        tools += [
            tool(
                "list_topics",
                "Показывает темы (папки) и теги рабочей папки Lori с числом заметок в каждой. Годится, чтобы понять, о чём вообще есть записи.",
                [:]
            ),
            tool(
                "topic_notes",
                "Показывает заметки одной темы или тега: заголовки и точные пути. Передай название темы или тег без решётки.",
                ["topic": .object(["type": .string("string")])]
            ),
        ]
        if allowMemory {
            tools += [
                tool(
                    "remember",
                    "Запоминает один факт о владельце или его делах надолго. Пиши коротко и по делу, одним предложением. Вызывай, когда просят запомнить или когда в разговоре появился устойчивый факт.",
                    ["fact": .object(["type": .string("string")])]
                ),
                tool(
                    "forget",
                    "Убирает из памяти строки, в которых встречается указанный текст. Вызывай, когда просят забыть.",
                    ["about": .object(["type": .string("string")])]
                ),
            ]
        }
        return tools
    }

    /// Возвращает nil, если инструмент не наш: тогда его исполняет `WorkspaceStore`.
    @MainActor
    static func execute(
        named name: String,
        arguments: String,
        workspace: WorkspaceStore,
        allowMemory: Bool
    ) -> String? {
        guard names.contains(name) else { return nil }
        let payload = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        switch name {
        case "search_notes":
            let query = payload["query"] as? String ?? ""
            return report(NoteSearchIndex.search(query, in: workspace), query: query)
        case "list_topics":
            return topics(in: workspace)
        case "topic_notes":
            return notes(inTopic: payload["topic"] as? String ?? "", workspace: workspace)
        case "remember":
            guard allowMemory else { return "Ошибка инструмента: \(MemoryError.disabled.errorDescription ?? "")" }
            do {
                let stamped = try MemoryStore.remember(payload["fact"] as? String ?? "", in: workspace)
                return "Запомнил: \(stamped)"
            } catch {
                return "Ошибка инструмента: \(error.localizedDescription)"
            }
        case "forget":
            guard allowMemory else { return "Ошибка инструмента: \(MemoryError.disabled.errorDescription ?? "")" }
            do {
                let removed = try MemoryStore.forget(payload["about"] as? String ?? "", in: workspace)
                return removed == 0 ? "В памяти такого не нашлось." : "Убрал из памяти строк: \(removed)."
            } catch {
                return "Ошибка инструмента: \(error.localizedDescription)"
            }
        default:
            return nil
        }
    }

    @MainActor
    private static func topics(in workspace: WorkspaceStore) -> String {
        let index = WikiIndex.build(workspace)
        let themes = index.themes.map { "\($0.name) — \(LoriFormat.noteCount($0.count))" }
        let tags = index.tags.map { "#\($0.name) — \(LoriFormat.noteCount($0.count))" }
        guard !themes.isEmpty || !tags.isEmpty else { return "Тем и тегов пока нет: заметок мало." }
        var lines: [String] = []
        if !themes.isEmpty { lines.append("Темы:\n\(themes.joined(separator: "\n"))") }
        if !tags.isEmpty { lines.append("Теги:\n\(tags.joined(separator: "\n"))") }
        return lines.joined(separator: "\n\n")
    }

    @MainActor
    private static func notes(inTopic topic: String, workspace: WorkspaceStore) -> String {
        let cleaned = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard !cleaned.isEmpty else { return "Не указана тема." }
        let index = WikiIndex.build(workspace)
        // Тема и тег ищутся одним инструментом: модель не знает заранее,
        // папка это или тег, а человек называет и то и другое просто «темой».
        var found = index.notes(inTheme: cleaned)
        if found.isEmpty { found = index.notes(withTag: cleaned) }
        guard !found.isEmpty else { return "По теме «\(cleaned)» заметок нет." }
        let lines = found.map { "\($0.title) — \($0.path)" }
        return "Заметки по теме «\(cleaned)»:\n\(lines.joined(separator: "\n"))"
    }

    private static func report(_ hits: [NoteSearchHit], query: String) -> String {
        guard !hits.isEmpty else {
            return "По запросу «\(query)» в заметках ничего не нашлось. Не придумывай ответ: скажи, что записей на эту тему нет."
        }
        let body = hits.enumerated().map { index, hit -> String in
            let lines = hit.snippets.map { "   \($0)" }.joined(separator: "\n")
            return lines.isEmpty
                ? "\(index + 1). \(hit.path)"
                : "\(index + 1). \(hit.path)\n\(lines)"
        }
        return "Нашёл \(hits.count):\n\(body.joined(separator: "\n"))"
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
