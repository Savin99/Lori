import Foundation

/// Обработка расшифровки в читаемую заметку и раскладка её по тематическим папкам.
///
/// Расшифровка остаётся дословной и локальной. Обработка — отдельный шаг: он идёт
/// через ту же модель, что и чат, и потому требует ключа. Без ключа карточка показывает
/// расшифровку, приведённую к читаемому виду локально (`TranscriptReadability`).
@MainActor
final class DigestService: ObservableObject {
    /// Что сейчас обрабатывается — по пути расшифровки.
    @Published private(set) var running: Set<String> = []
    @Published var lastError: String?

    /// Сколько знаков расшифровки уходит в модель. Шесть минут речи — около 1200 знаков,
    /// так что лимит покрывает многочасовую запись и всё равно не раздувает запрос.
    static let maxSourceCharacters = 24_000
    /// Папки, которые темой быть не могут: их создаёт само приложение.
    /// `nonisolated` — константу читает и вики, которая живёт вне главного актора.
    nonisolated static let nonThemeFolders: Set<String> = ["Recordings", "Transcripts", "Inbox", "Models"]

    private let client: any ChatCompleting
    private let keyProvider: () throws -> String?
    /// «Путь аудио или расшифровки → путь заметки». Источник правды — front matter
    /// в самих заметках, здесь только кэш обхода.
    private var links: [String: String] = [:]
    private var didScan = false

    init(
        client: any ChatCompleting = DeepSeekClient(),
        keyProvider: @escaping () throws -> String? = { try KeychainStore.deepSeekKey() }
    ) {
        self.client = client
        self.keyProvider = keyProvider
    }

    func isRunning(_ transcriptPath: String) -> Bool { running.contains(transcriptPath) }

    /// Пускать ли обработку. Правило вынесено из интерфейса нарочно: автоматический
    /// проход случается после расшифровки, а расшифровку в симуляторе не получить —
    /// значит проверить эту ветку можно только тестом на самом правиле.
    nonisolated static func shouldProcess(
        automatic: Bool,
        autoEnabled: Bool,
        hasTranscript: Bool,
        hasDigest: Bool,
        hasKey: Bool,
        isRunning: Bool
    ) -> Bool {
        guard hasTranscript, !hasDigest, hasKey, !isRunning else { return false }
        // Ручное нажатие работает и при выключенной автообработке: человек попросил сам.
        return automatic ? autoEnabled : true
    }

    var hasKey: Bool {
        guard let key = try? keyProvider() else { return false }
        return !(key ?? "").isEmpty
    }

    /// Путь готовой заметки для аудиофайла или его расшифровки.
    func digestPath(for path: String, in workspace: WorkspaceStore) -> String? {
        if !didScan { rescan(workspace) }
        guard let candidate = links[path] else { return nil }
        // Заметку могли удалить или переименовать вручную — тогда пересобираем связи.
        if (try? workspace.fileURL(for: candidate)) != nil { return candidate }
        rescan(workspace)
        return links[path]
    }

    /// Пересобирает связи обходом рабочей папки. `entries(at:)` уже отсекает скрытое,
    /// симлинки и корзину, поэтому свой обход песочницу не расширяет.
    func rescan(_ workspace: WorkspaceStore) {
        var found: [String: String] = [:]
        var queue = [""]
        while let directory = queue.popLast() {
            guard let items = try? workspace.entries(at: directory) else { continue }
            for item in items {
                if item.isDirectory {
                    guard !Self.nonThemeFolders.contains(item.name) else { continue }
                    queue.append(item.relativePath)
                    continue
                }
                guard item.name.lowercased().hasSuffix(".md") else { continue }
                guard let meta = head(of: item.relativePath, in: workspace) else { continue }
                guard meta.isDigest else { continue }
                if let audio = meta.audio { found[audio] = item.relativePath }
                if let transcript = meta.transcript { found[transcript] = item.relativePath }
            }
        }
        links = found
        didScan = true
    }

    /// Обрабатывает расшифровку и сохраняет заметку в тематическую папку.
    /// Возвращает путь заметки; при ошибке — nil, а текст ошибки лежит в `lastError`.
    @discardableResult
    func process(
        transcriptPath: String,
        audioPath: String?,
        in workspace: WorkspaceStore,
        model: String
    ) async -> String? {
        guard !running.contains(transcriptPath) else { return nil }
        running.insert(transcriptPath)
        defer { running.remove(transcriptPath) }

        do {
            let raw = try workspace.readText(at: transcriptPath)
            let source = TranscriptReadability.plainText(fromMarkdown: raw)
            guard !source.isEmpty else { throw DigestError.emptySource }
            guard let key = try keyProvider(), !key.isEmpty else { throw DigestError.missingKey }

            let themes = existingThemes(in: workspace)
            let message = try await client.complete(
                apiKey: key,
                model: LLMSettings.resolvedModel(picked: model),
                messages: [
                    DeepSeekMessage(role: "system", content: Self.systemPrompt(themes: themes)),
                    DeepSeekMessage(role: "user", content: String(source.prefix(Self.maxSourceCharacters))),
                ],
                tools: []
            )
            let answer = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !answer.isEmpty else { throw DigestError.notJSON }

            var digest = try NoteDigestPayload.parse(answer).digest
            digest.theme = matchedTheme(digest.theme, among: themes)

            let path = try write(digest, transcriptPath: transcriptPath, audioPath: audioPath, in: workspace)
            links[transcriptPath] = path
            if let audioPath { links[audioPath] = path }
            return path
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Сохранение заметки. Имя берётся из заголовка выжимки, а не из первой строки текста:
    /// первая строка здесь — служебный `---`.
    private func write(
        _ digest: NoteDigest,
        transcriptPath: String,
        audioPath: String?,
        in workspace: WorkspaceStore
    ) throws -> String {
        let content = digest.markdown(audioPath: audioPath, transcriptPath: transcriptPath, created: .now)
        let taken = Set((try? workspace.entries(at: digest.theme))?.map(\.name) ?? [])
        let path = "\(digest.theme)/\(Self.freeName(digest.filename, taken: taken))"
        try workspace.writeText(content, at: path)
        return path
    }

    /// Существующие тематические папки первого уровня. Модель выбирает из них,
    /// иначе на каждую запись появлялась бы новая папка с почти тем же названием.
    private func existingThemes(in workspace: WorkspaceStore) -> [String] {
        let items = (try? workspace.entries(at: "")) ?? []
        return items
            .filter { $0.isDirectory && !Self.nonThemeFolders.contains($0.name) }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Совпадение без учёта регистра: «работа» и «Работа» должны попасть в одну папку.
    /// Служебную папку приложения темой признать нельзя: модель вполне может ответить
    /// «Transcripts», и тогда заметка легла бы в сырьё, где её не показывает вики.
    private func matchedTheme(_ theme: String, among existing: [String]) -> String {
        let needle = theme.lowercased()
        if Self.nonThemeFolders.contains(where: { $0.lowercased() == needle }) {
            return NoteDigest.fallbackTheme
        }
        return existing.first { $0.lowercased() == needle } ?? theme
    }

    static func freeName(_ preferred: String, taken: Set<String>) -> String {
        guard taken.contains(preferred) else { return preferred }
        let base = (preferred as NSString).deletingPathExtension
        let suffix = (preferred as NSString).pathExtension
        var index = 2
        while true {
            let candidate = suffix.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(suffix)"
            if !taken.contains(candidate) { return candidate }
            index += 1
        }
    }

    /// Первые байты файла: для front matter хватает головы, а читать целиком
    /// каждую заметку на каждый обход — лишняя работа на главном потоке.
    private func head(of relativePath: String, in workspace: WorkspaceStore) -> NoteMeta? {
        guard let url = try? workspace.fileURL(for: relativePath) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2048), !data.isEmpty else { return nil }
        // Обрезок UTF-8 на границе символа декодируется с заменой, а не отбрасывается целиком.
        return NoteMeta.parse(String(decoding: data, as: UTF8.self))
    }

    private static func systemPrompt(themes: [String]) -> String {
        let folders = themes.isEmpty
            ? "Тематических папок пока нет — придумай первую."
            : "Существующие тематические папки: \(themes.joined(separator: ", "))."
        return """
        Ты — редактор личных заметок Lori. На входе дословная расшифровка записи, часто без \
        структуры и с оговорками. Верни только JSON-объект, без пояснений и без ограждения:
        {"title": "...", "theme": "...", "summary": "...", "highlights": ["..."], \
        "decisions": ["..."], "tasks": ["..."], "tags": ["..."]}

        Правила:
        - Отвечай на языке расшифровки.
        - title: 3–7 слов по сути записи, без даты и кавычек.
        - theme: тематическая папка. \(folders) Если подходит существующая — верни её \
        точно так, как она написана. Иначе придумай новую в одно-два слова.
        - summary: 2–3 предложения о самом важном.
        - highlights: от 3 до 8 пунктов — то, ради чего запись стоит помнить. Каждый пункт \
        законченная мысль, без воды и без повторов.
        - decisions: только решения, которые действительно приняты. Нет — пустой массив.
        - tasks: только явные задачи и договорённости. Нет — пустой массив.
        - tags: 2–5 коротких тегов в нижнем регистре, без решётки.

        Ничего не добавляй от себя: чего нет в расшифровке, того нет и в ответе.
        """
    }
}
