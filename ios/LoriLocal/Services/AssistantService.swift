import Foundation

/// Локальные препятствия ассистента. Ошибки сервиса и Keychain остаются
/// `TranscriptionError`: их текст уже доходит до человека дословно.
enum AssistantError: LocalizedError, Equatable {
    case noSources
    case emptyQuestion
    case emptyAnswer

    var errorDescription: String? {
        switch self {
        case .noSources:
            "Спрашивать не по чему: у выбранных записей нет расшифровок."
        case .emptyQuestion:
            "Напиши вопрос."
        case .emptyAnswer:
            "Сервис вернул пустой ответ."
        }
    }
}

/// Разговор по расшифровкам.
///
/// Один движок на оба входа: экран записи заводит тред по одной расшифровке,
/// главный — по архиву или теме. Сам движок про интерфейс ничего не знает: он
/// получает готовые источники, замораживает из них контекст и дальше только
/// дописывает вопросы в конец.
///
/// Наружу уходит только текст расшифровок и только когда человек нажал кнопку:
/// ни аудио, ни имена файлов, ни что-либо ещё из рабочей папки.
struct AssistantService: Sendable {
    /// Ссылка на место в архиве: номер записи из оглавления и секунда.
    struct Citation: Codable, Sendable, Equatable, Identifiable {
        /// Номер записи в оглавлении контекста.
        let number: Int
        let path: String
        let title: String
        /// Куда перематывать. Секунда из ответа модели, приведённая к
        /// ближайшему настоящему началу реплики; nil — если модель секунду не
        /// назвала или назвала такую, которой в записи нет.
        let start: TimeInterval?

        /// Две ссылки на одну запись, но разные секунды — разные места.
        var id: String { "\(number)@\(start.map { Int($0) } ?? -1)" }
    }

    /// Что вернул сервис на один вопрос.
    struct Reply: Sendable, Equatable {
        let text: String
        let citations: [Citation]
        /// Сколько токенов префикса сервис взял из кэша. Без этого числа нечем
        /// доказать, что заморозка контекста вообще работает.
        let cachedTokens: Int?
        /// Тексты записей, ушедшие вместе с этим вопросом. Их сохраняют в
        /// сообщение треда: иначе история перестанет собираться байт в байт.
        let added: [ContextSnapshot.Piece]

        init(
            text: String,
            citations: [Citation],
            cachedTokens: Int?,
            added: [ContextSnapshot.Piece] = []
        ) {
            self.text = text
            self.citations = citations
            self.cachedTokens = cachedTokens
            self.added = added
        }
    }

    /// Сообщение в форме, понятной сервису.
    struct BackendMessage: Sendable, Equatable {
        let role: String
        let content: String
    }

    struct BackendReply: Sendable, Equatable {
        let text: String
        let cachedTokens: Int?
    }

    /// Откуда берётся ответ. Тесты подставляют замыкание и обходятся без сети.
    protocol Backend: Sendable {
        func answer(messages: [BackendMessage], cacheKey: String) async throws -> BackendReply
    }

    private let backend: Backend

    init(
        session: URLSession = CloudSession.shared,
        keyProvider: @escaping @Sendable () throws -> String? = { try KeychainStore.key(for: .assistant) },
        backend: Backend? = nil
    ) {
        self.backend = backend ?? CloudBackend(session: session, keyProvider: keyProvider)
    }

    /// Подставной источник ответа для тестов.
    struct ClosureBackend: Backend {
        let generate: @Sendable ([BackendMessage], String) async throws -> BackendReply

        init(_ generate: @escaping @Sendable ([BackendMessage], String) async throws -> BackendReply) {
            self.generate = generate
        }

        init(text: @escaping @Sendable ([BackendMessage]) async throws -> String) {
            self.generate = { messages, _ in BackendReply(text: try await text(messages), cachedTokens: nil) }
        }

        func answer(messages: [BackendMessage], cacheKey: String) async throws -> BackendReply {
            try await generate(messages, cacheKey)
        }
    }

    // MARK: - Контекст

    /// Заморозка контекста. Делается один раз на тред: оглавление, порядок
    /// текстов и их номера после этого не меняются — на этом и держится кэш.
    static func snapshot(
        question: String,
        sources: [AssistantSource],
        scopeTitle: String,
        budget: Int = AssistantSettings.contextCharacters
    ) -> ContextSnapshot {
        // Каждая расшифровка разбирается ровно один раз: и на куски, и на
        // строку оглавления.
        let documents = sources.map { TranscriptDocument.parse($0.markdown) }
        let selection = AssistantRetrieval.select(
            question: question,
            sources: sources,
            documents: documents,
            budget: budget
        )
        let pieces = selection.chunks.map { chunk in
            ContextSnapshot.Piece(
                record: chunk.sourceIndex + 1,
                start: chunk.start,
                end: chunk.end,
                starts: chunk.starts,
                text: chunk.text
            )
        }
        let included = Set(selection.chunks.map { sources[$0.sourceIndex].path })
        return ContextSnapshot(
            scopeTitle: scopeTitle,
            records: AssistantOutline.records(for: sources, documents: documents, included: included),
            pieces: pieces,
            characters: selection.usedCharacters,
            whole: selection.whole
        )
    }

    // MARK: - Вопрос

    /// Продолжение треда.
    ///
    /// Запрос растёт **только в конец**: системное сообщение не меняется
    /// никогда, история идёт в том же порядке, а новые тексты записей
    /// дописываются в то же сообщение, что и вопрос. Отсюда главное свойство —
    /// запрос N является побайтовым префиксом запроса N+1, — и оно же
    /// единственная причина, по которой ветка из десяти вопросов не стоит как
    /// месяц расшифровок.
    ///
    /// - Parameter sources: расшифровки охвата. Нужны, только когда охват не
    ///   влез целиком: из них берутся тексты записей, которых сервис ещё не
    ///   видел. Уже отправленное не отправляется повторно никогда.
    func answer(
        question: String,
        in thread: AssistantThread,
        sources: [AssistantSource] = []
    ) async throws -> Reply {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { throw AssistantError.emptyQuestion }
        guard !thread.context.records.isEmpty else { throw AssistantError.noSources }

        var sent = thread.sentRecords
        var room = AssistantSettings.threadCharacters - thread.characters
        var added: [ContextSnapshot.Piece] = []

        // Какие записи нужны под этот вопрос — решает модель по оглавлению.
        // Лексика тут промахивается на синонимах и на том, чего в словах
        // вопроса нет вовсе; оглавление же помещается в запрос всегда.
        if !thread.context.whole, !sources.isEmpty {
            let wanted = (try? await route(question: asked, context: thread.context)) ?? []
            added += Self.texts(of: wanted, sources: sources, context: thread.context, sent: &sent, room: &room)
        }

        var reply = try await ask(asked, in: thread, added: added)

        // «Дай ещё»: модель назвала записи, которых ей не хватило. Один лишний
        // заход дешевле неверного ответа, но ровно один: два подряд означают,
        // что вопрос не про этот архив, и честное «не нашёл» уже обосновано.
        let requested = Self.requestedRecords(in: reply.text)
        if !requested.isEmpty, !sources.isEmpty {
            let more = Self.texts(of: requested, sources: sources, context: thread.context, sent: &sent, room: &room)
            if !more.isEmpty {
                Diagnostics.note("ассистент: модель попросила записи \(requested.map(String.init).joined(separator: ", "))")
                added += more
                reply = try await ask(asked, in: thread, added: added)
            }
        }

        // Модель попросила тексты, а дать их неоткуда: так бывает, когда охват
        // собран без расшифровок под рукой. Служебная строка — это весь её
        // ответ, и после снятия не остаётся ничего. Показывать человеку
        // «Сервис вернул пустой ответ» тут — врать: сервис ответил, и ответ
        // осмысленный, просто адресован не человеку.
        var text = Self.withoutRequest(reply.text)
        if text.isEmpty, !requested.isEmpty {
            text = Self.missing(requested.filter { !sent.contains($0) }, in: thread.context)
        }
        guard !text.isEmpty else { throw AssistantError.emptyAnswer }
        var merged = thread
        merged.messages.append(ThreadMessage(role: .question, text: asked, added: added))
        return Reply(
            text: text,
            citations: Self.citations(in: text, context: merged.merged),
            cachedTokens: reply.cachedTokens,
            added: added
        )
    }

    /// Один запрос к сервису со всей историей.
    private func ask(
        _ asked: String,
        in thread: AssistantThread,
        added: [ContextSnapshot.Piece]
    ) async throws -> BackendReply {
        var messages: [BackendMessage] = [
            BackendMessage(role: "system", content: Self.system(for: thread.context)),
        ]
        for message in thread.messages {
            messages.append(BackendMessage(
                role: message.role == .question ? "user" : "assistant",
                content: message.role == .question
                    ? Self.userContent(question: message.text, added: message.added, in: thread.context)
                    : message.text
            ))
        }
        messages.append(BackendMessage(
            role: "user",
            content: Self.userContent(question: asked, added: added, in: thread.context)
        ))

        let reply = try await backend.answer(messages: messages, cacheKey: thread.context.cacheKey)
        return BackendReply(text: Summarizer.withoutThoughts(reply.text), cachedTokens: reply.cachedTokens)
    }

    // MARK: - Выбор записей

    /// Какие записи нужны под вопрос. Отдельный дешёвый запрос: оглавление и
    /// вопрос, в ответ — только номера.
    func route(question: String, context: ContextSnapshot) async throws -> [Int] {
        let outline = AssistantOutline.text(context.records, scopeTitle: context.scopeTitle)
        let reply = try await backend.answer(
            messages: [
                BackendMessage(role: "system", content: Self.routerInstructions),
                BackendMessage(role: "user", content: "\(outline)\n\nВопрос: \(question)"),
            ],
            // Свой ключ: у роутера другой префикс, и мешать его с разговором
            // значит промахиваться кэшем в обе стороны.
            cacheKey: "\(context.cacheKey)-router"
        )
        return Self.numbers(in: Summarizer.withoutThoughts(reply.text), among: context.records.map(\.number))
    }

    static let routerInstructions = """
    Тебе дают оглавление архива расшифровок и вопрос. Твоя работа — выбрать записи, тексты которых \
    нужны, чтобы на вопрос ответить. Отвечай только номерами через запятую, например «3, 7». \
    Ничего кроме номеров не пиши. Если не подходит ни одна запись, ответь «0».
    """

    /// Тексты названных записей — тех, которых сервис ещё не видел.
    ///
    /// Порядок строго по номеру записи, а не по тому, в каком модель их назвала:
    /// иначе один и тот же набор дал бы два разных префикса и промахнулся мимо
    /// кэша на ровном месте.
    static func texts(
        of numbers: [Int],
        sources: [AssistantSource],
        context: ContextSnapshot,
        sent: inout Set<Int>,
        room: inout Int
    ) -> [ContextSnapshot.Piece] {
        var result: [ContextSnapshot.Piece] = []
        for number in numbers.sorted() {
            guard !sent.contains(number),
                  let record = context.records.first(where: { $0.number == number }),
                  let source = sources.first(where: { $0.path == record.path }) else { continue }

            // Запись целиком — единица дописки: куски рвут связность, а
            // записей тут десятки, а не тысячи.
            let whole = AssistantRetrieval.chunks(of: source, index: number - 1, target: .max)
            let fitting = whole.first.map { $0.text.count <= room ? whole : [] } ?? []
            let chosen = fitting.isEmpty
                ? AssistantRetrieval.chunks(of: source, index: number - 1)
                : fitting
            var taken = false
            for chunk in chosen where chunk.text.count <= room {
                result.append(ContextSnapshot.Piece(
                    record: number,
                    start: chunk.start,
                    end: chunk.end,
                    starts: chunk.starts,
                    text: chunk.text
                ))
                room -= chunk.text.count
                taken = true
            }
            if taken { sent.insert(number) }
        }
        return result
    }

    /// Номера из ответа роутера. «0» и всё, чего нет в оглавлении, отбрасывается.
    static func numbers(in text: String, among known: [Int]) -> [Int] {
        let allowed = Set(known)
        var result: [Int] = []
        for piece in text.split(whereSeparator: { !$0.isNumber }) {
            guard let number = Int(piece), allowed.contains(number), !result.contains(number) else { continue }
            result.append(number)
        }
        return result
    }

    /// Записи, которых модели не хватило.
    static func requestedRecords(in text: String) -> [Int] {
        for line in text.split(separator: "\n") {
            let clean = line.trimmingCharacters(in: .whitespaces)
            guard clean.uppercased().hasPrefix(Self.requestMarker) else { continue }
            return clean.dropFirst(Self.requestMarker.count)
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
        }
        return []
    }

    /// Служебная строка до человека не доходит: это разговор приложения с
    /// моделью, а не часть ответа.
    static func withoutRequest(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix(Self.requestMarker) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let requestMarker = "НУЖНЫ:"

    /// Ответ за модель, когда она попросила тексты, а дать их неоткуда.
    static func missing(_ numbers: [Int], in context: ContextSnapshot) -> String {
        let titles = numbers.compactMap { number in
            context.records.first { $0.number == number }?.title
        }
        guard !titles.isEmpty else { return "" }
        let list = titles.map { "«\($0)»" }.joined(separator: ", ")
        // `LoriFormat.plural` возвращает число вместе со словом, и здесь оно
        // лишнее: записи уже перечислены по именам.
        let tail = titles.count == 1 ? "Спроси по ней отдельно" : "Спроси по ним отдельно"
        return "Для ответа не хватает текста: \(list). \(tail) — на экране записи есть «Спросить»."
    }

    // MARK: - Промпт

    /// Правила, оглавление и тексты одним блоком. Вместе, а не тремя
    /// сообщениями, по той же причине, по которой контекст заморожен: сервис
    /// кэширует начало запроса, и чем оно цельнее, тем меньше поводов ему
    /// разъехаться.
    static func system(for context: ContextSnapshot) -> String {
        var parts = [instructions, ""]
        let outline = AssistantOutline.text(context.records, scopeTitle: context.scopeTitle)
        if !outline.isEmpty {
            parts.append(outline)
            parts.append("")
        }
        parts.append(context.pieces.isEmpty ? "Текстов записей пока нет — проси нужные." : "Тексты расшифровок:")
        parts.append("")
        parts += rendered(context.pieces, records: context.records)
        return parts.joined(separator: "\n")
    }

    /// Тексты записей с подписями. Один рендер и на замороженную часть, и на
    /// дописанную: разойдись они — история перестала бы собираться байт в байт.
    static func rendered(
        _ pieces: [ContextSnapshot.Piece],
        records: [ContextSnapshot.Record]
    ) -> [String] {
        var parts: [String] = []
        for piece in pieces {
            guard let record = records.first(where: { $0.number == piece.record }) else { continue }
            var label = "[\(record.number)] \(record.title)"
            if let start = piece.start { label += ", с \(TranscriptSegment.stamp(start))" }
            parts.append(label)
            parts.append(piece.text)
            parts.append("")
        }
        return parts
    }

    /// Сообщение с вопросом: новые тексты идут перед ним, в том же сообщении.
    ///
    /// Именно здесь, а не отдельным сообщением и не в начале запроса: всё, что
    /// уходит в конец, оставляет префикс нетронутым, и сервис берёт его из кэша.
    static func userContent(
        question: String,
        added: [ContextSnapshot.Piece],
        in context: ContextSnapshot
    ) -> String {
        guard !added.isEmpty else { return question }
        let block = ["Тексты записей, которых раньше не было:", ""]
            + rendered(added, records: context.records)
        return block.joined(separator: "\n") + "\n" + question
    }

    static let instructions = """
    Ты отвечаешь на вопросы по расшифровкам разговоров. Отвечаешь только по-русски. Опираешься \
    исключительно на переданные записи: ничего не добавляешь из общих знаний. А вот связывать и \
    обобщать то, что в записях есть, — можно и нужно: это не выдумка, а работа.

    Контекст устроен так. Сначала оглавление: в нём перечислены все записи охвата, у каждой свой \
    номер, и помечено, дан ли её текст. Ниже — тексты, и они есть не у всех записей. Если для \
    ответа нужна запись, текста которой нет, не отвечай «в записях этого нет»: назови её номер и \
    скажи, что нужен её текст.

    Отвечай настолько подробно, насколько позволяют записи: если про предмет вопроса сказано \
    много, перескажи это, а не ограничивайся упоминанием. Если ответа в записях действительно \
    нет, так и говори — и не выдумывай правдоподобный.

    Ссылки обязательны. После утверждения ставь ссылку в квадратных скобках: номер записи, знак @ \
    и секунду от начала — например [3@218]. Секунду бери из начала той строки, на которую \
    опираешься: в каждой строке первым идёт число, это и есть секунда. Одна ссылка на утверждение \
    или абзац, а не на каждое предложение. Если у строк записи чисел нет, ставь просто [3].

    Если для ответа не хватает текстов, начни ответ строкой «НУЖНЫ: 3, 7» — только номера записей \
    через запятую — и больше в этот раз ничего не пиши. Тексты пришлют следующим сообщением, и \
    тогда ты ответишь. Проси только то, чего в контексте нет, и только когда без этого ответа не \
    выйдет.
    """

    // MARK: - Разбор ссылок

    /// Ссылки из ответа в порядке появления.
    ///
    /// Секунда приходит от модели, и проверять её обязательно: за границами
    /// фрагмента она выдумана, а выдуманный таймкод открывает запись не там и
    /// подрывает доверие ко всей фиче. Не прошла проверку — берём начало
    /// фрагмента, оно известно точно.
    static func citations(in text: String, context: ContextSnapshot) -> [Citation] {
        var seen = Set<String>()
        var result: [Citation] = []
        var cursor = text.startIndex

        while let open = text[cursor...].firstIndex(of: "["),
              let close = text[open...].firstIndex(of: "]") {
            cursor = text.index(after: open)
            let inside = text[text.index(after: open)..<close]
            for piece in inside.split(separator: ",") {
                guard let citation = citation(from: String(piece), context: context),
                      seen.insert(citation.id).inserted else { continue }
                result.append(citation)
            }
            cursor = text.index(after: close)
        }
        // «Судя по расшифровке [2]» — это оборот речи, а не ссылка на место.
        // Пилюля без времени рядом с настоящими секундами той же записи только
        // засоряет список: она никуда не ведёт, а выглядит как ещё одно место.
        let timed = Set(result.filter { $0.start != nil }.map(\.number))
        return result.filter { $0.start != nil || !timed.contains($0.number) }
    }

    /// Ответ, разложенный на абзацы со своими ссылками.
    ///
    /// Пилюли стоят под тем абзацем, к которому относятся, а не общим списком в
    /// конце: ответ из трёх утверждений с тремя разными источниками иначе
    /// превращается в задачу «угадай, какая ссылка к какому предложению».
    struct Paragraph: Identifiable, Equatable {
        let id: Int
        let text: String
        let citations: [Citation]
    }

    static func paragraphs(of text: String, context: ContextSnapshot) -> [Paragraph] {
        let blocks = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return blocks.enumerated().map { offset, block in
            Paragraph(
                id: offset,
                text: withoutMarkers(block),
                citations: citations(in: block, context: context)
            )
        }
    }

    /// Текст без служебных маркеров. Сами ссылки уже разобраны в пилюли, а
    /// «[1@218]» посреди предложения человек читать не должен.
    ///
    /// Убираются только скобки, внутри которых нет ничего, кроме цифр, «@»,
    /// запятых и пробелов: «[смотри запись]» — это не ссылка, а часть речи.
    static func withoutMarkers(_ text: String) -> String {
        var result = ""
        var cursor = text.startIndex

        while let open = text[cursor...].firstIndex(of: "["),
              let close = text[open...].firstIndex(of: "]") {
            let inside = text[text.index(after: open)..<close]
            let isMarker = !inside.isEmpty && inside.allSatisfy {
                $0.isNumber || $0 == "@" || $0 == "," || $0 == " " || $0 == "." 
            }
            result += text[cursor..<open]
            if !isMarker { result += text[open...close] }
            cursor = text.index(after: close)
        }
        result += text[cursor...]

        // После снятия маркера остаётся « .» — пробел перед точкой, которого
        // в написанном человеком тексте не бывает.
        return result
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Одна ссылка: «3@218», «3» или мусор.
    ///
    /// Голое «3» временем **не** дополняется. Раньше на него подставлялось
    /// начало фрагмента, и вся лента получала пилюли «0:00»: единица контекста —
    /// запись, а её начало всегда ноль. Ссылка без времени честна, ссылка в
    /// неверную секунду — нет.
    private static func citation(from raw: String, context: ContextSnapshot) -> Citation? {
        let parts = raw.split(separator: "@", maxSplits: 1)
        guard let first = parts.first,
              let number = Int(first.trimmingCharacters(in: .whitespaces)),
              let record = context.records.first(where: { $0.number == number }) else { return nil }

        var start: TimeInterval?
        if parts.count == 2, let second = TimeInterval(parts[1].trimmingCharacters(in: .whitespaces)) {
            start = resolve(second: second, in: context.pieces.filter { $0.record == number })
        }
        return Citation(number: number, path: record.path, title: record.title, start: start)
    }

    /// Секунда из ответа, приведённая к ближайшему настоящему началу реплики.
    ///
    /// Модель списывает число с начала строки, поэтому попадание обычно точное,
    /// а промах — на соседнюю реплику. Проверять диапазоном нельзя: он пропускает
    /// любое число внутри, в том числе то, которого в записи нет вовсе.
    static func resolve(second: TimeInterval, in pieces: [ContextSnapshot.Piece]) -> TimeInterval? {
        let starts = pieces.flatMap(\.starts)
        guard let nearest = starts.min(by: { abs($0 - second) < abs($1 - second) }) else { return nil }
        return abs(nearest - second) <= 120 ? nearest : nil
    }
}

/// Настоящий вызов: `POST {адрес}/chat/completions` в форме, которую понимают
/// OpenAI, DeepSeek, Groq и локальные совместимые серверы.
private struct CloudBackend: AssistantService.Backend {
    let session: URLSession
    let keyProvider: @Sendable () throws -> String?

    func answer(
        messages: [AssistantService.BackendMessage],
        cacheKey: String
    ) async throws -> AssistantService.BackendReply {
        guard let key = try keyProvider(), !key.isEmpty else {
            throw TranscriptionError.missingKey(.assistant)
        }
        let model = AssistantSettings.model
        let reasoningModel = model.hasPrefix("gpt-5") || model.hasPrefix("gpt-6")
            || model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4")
        let payload = Request(
            model: model,
            messages: messages.map { Request.Message(role: $0.role, content: $0.content) },
            temperature: reasoningModel ? nil : 0.2,
            reasoningEffort: model.hasPrefix("gpt-6") ? "low" : nil,
            promptCacheKey: cacheKey
        )

        var request = URLRequest(url: AssistantSettings.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Рассуждающая модель на длинном контексте думает минуту и дольше.
        request.timeoutInterval = 180
        request.httpBody = try JSONEncoder().encode(payload)

        let size = messages.reduce(0) { $0 + $1.content.count }
        Diagnostics.note("ассистент → \(model), \(messages.count) сообщений, \(size) знаков")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Таймаут и обрыв связи кода состояния не имеют, и без этой строки
            // в журнале от них не остаётся следа.
            Diagnostics.fault("ассистент: запрос не дошёл — \(error.localizedDescription)")
            throw error
        }
        try APICheck.ensureSuccess(response: response, data: data)

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TranscriptionError.badResponse("Сервис вернул ответ, который не удалось разобрать.")
        }
        let text = (decoded.choices.first?.message?.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cached = decoded.usage?.cachedTokens
        Diagnostics.note("ассистент ← \(text.count) знаков, из кэша \(cached.map(String.init) ?? "—") токенов")
        return AssistantService.BackendReply(text: text, cachedTokens: cached)
    }

    private struct Request: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double?
        let reasoningEffort: String?
        /// Подсказка сервису, что запросы с одинаковым началом — это одна ветка.
        /// У OpenAI поле официальное, остальные его просто игнорируют.
        let promptCacheKey: String

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case reasoningEffort = "reasoning_effort"
            case promptCacheKey = "prompt_cache_key"
        }

        struct Message: Encodable {
            let role: String
            let content: String
        }
    }

    private struct Response: Decodable {
        let choices: [Choice]
        let usage: AssistantUsage?

        struct Choice: Decodable {
            let message: Message?

            struct Message: Decodable {
                let content: String?
            }
        }
    }
}

/// Сколько токенов сервиса пришло из кэша.
///
/// У OpenAI это `usage.prompt_tokens_details.cached_tokens`, у DeepSeek —
/// плоское `usage.prompt_cache_hit_tokens`. Разбор вынесен из транспорта
/// наружу, потому что это единственное доказательство, что заморозка контекста
/// вообще работает, — и такое стоит проверять тестом, а не на глаз в журнале.
struct AssistantUsage: Decodable, Equatable {
    let cachedTokens: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let details = try container.decodeIfPresent(Details.self, forKey: .promptTokensDetails),
           let cached = details.cachedTokens {
            cachedTokens = cached
        } else {
            cachedTokens = try container.decodeIfPresent(Int.self, forKey: .promptCacheHitTokens)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case promptTokensDetails = "prompt_tokens_details"
        case promptCacheHitTokens = "prompt_cache_hit_tokens"
    }

    private struct Details: Decodable {
        let cachedTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }
}

/// Что удалось собрать под вопрос.
struct AssistantCollection: Sendable {
    let sources: [AssistantSource]
    /// Записи без расшифровки: спрашивать по ним нечего, и человеку это говорят.
    let skipped: Int

    static let empty = AssistantCollection(sources: [], skipped: 0)

    var characters: Int { sources.reduce(0) { $0 + $1.markdown.count } }
}

/// Сбор источников из рабочей папки. Живёт на главном потоке, потому что там же
/// живёт `WorkspaceStore`; движок про файлы ничего не знает.
@MainActor
enum AssistantSources {
    private struct Candidate: Sendable {
        let path: String
        let title: String
        let date: Date
        let url: URL
        let detail: String?
        let topic: String?
    }

    static func collect(
        _ entries: [WorkspaceEntry],
        in workspace: WorkspaceStore,
        title: (WorkspaceEntry) -> String,
        detail: (WorkspaceEntry) -> String? = { _ in nil },
        topic: (WorkspaceEntry) -> String? = { _ in nil }
    ) async -> AssistantCollection {
        var candidates: [Candidate] = []
        var skipped = 0
        for entry in entries {
            guard let path = workspace.existingTranscript(for: entry),
                  let url = try? workspace.readableTextURL(at: path) else {
                skipped += 1
                continue
            }
            candidates.append(Candidate(
                path: entry.relativePath,
                title: title(entry),
                date: entry.modifiedAt,
                url: url,
                detail: detail(entry),
                topic: topic(entry)
            ))
        }
        let sources = await Task.detached(priority: .userInitiated) {
            candidates.compactMap { candidate -> AssistantSource? in
                guard let markdown = try? WorkspaceStore.readTextFile(at: candidate.url),
                      !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return AssistantSource(
                    path: candidate.path,
                    title: candidate.title,
                    date: candidate.date,
                    markdown: markdown,
                    detail: candidate.detail,
                    topic: candidate.topic
                )
            }
        }.value
        return AssistantCollection(
            sources: sources,
            skipped: skipped + candidates.count - sources.count
        )
    }
}
