import Foundation

/// Замороженный контекст треда.
///
/// Это главное решение всего слоя ассистента, и оно не про интерфейс, а про
/// деньги. В треде каждое сообщение пересылает сервису всё, что уже отправлено:
/// ветка из десяти вопросов по архиву стоила бы дороже месяца расшифровок.
/// Спасает то, что и OpenAI, и DeepSeek кэшируют **начало** запроса
/// автоматически — но только пока это начало байт в байт то же самое.
///
/// Отсюда весь договор: префикс — правила, оглавление и тексты записей — не
/// меняется никогда. Ничего не переупорядочивается и не переотправляется.
/// Новое дописывается строго в конец, вместе с вопросом. Пересобрать префикс
/// можно только явно, сменой охвата, и человеку при этом говорят, что счёт
/// начнётся заново.
struct ContextSnapshot: Codable, Equatable, Sendable {
    /// Запись охвата. Есть у **каждой** записи, даже если её текст в контекст не
    /// вошёл: оглавление — единственное, из чего модель узнаёт, что запись
    /// вообще существует.
    struct Record: Codable, Equatable, Sendable {
        /// Номер в оглавлении. Он же номер в ссылке `[3@218]`: ссылка ведёт в
        /// запись и секунду, а не в кусок текста.
        let number: Int
        let path: String
        let title: String
        let date: Date
        let topic: String?
        let detail: String?
        /// Длина расшифровки целиком — и той части, что в контекст не попала.
        let characters: Int
        /// Последнее известное время расшифровки. nil — таймкодов у неё нет.
        let seconds: TimeInterval?
        /// Текст записи в контексте есть.
        let included: Bool
    }

    /// Текст записи в неизменном порядке — целиком или куском, если целиком не
    /// влезла.
    struct Piece: Codable, Equatable, Sendable {
        /// Номер записи из оглавления. Кусков у записи бывает несколько, и номер
        /// у них общий.
        let record: Int
        let start: TimeInterval?
        let end: TimeInterval?
        /// Начала строк. По ним проверяется секунда из ответа модели: диапазон
        /// «от и до» пропускает любое число внутри, а такой секунды в записи
        /// может не быть вовсе.
        let starts: [TimeInterval]
        let text: String
    }

    /// Как назывался охват, когда тред заводили: «Все», тема или одна запись.
    let scopeTitle: String
    /// Все записи охвата — это и есть оглавление.
    let records: [Record]
    /// Тексты тех записей, что вошли.
    let pieces: [Piece]
    let characters: Int
    /// Охват вошёл целиком. Ложь означает, что тексты отбирались под вопрос, —
    /// и тогда «в записях этого нет» нельзя читать как факт про архив.
    let whole: Bool

    /// Сколько записей вошло текстом.
    var includedCount: Int { records.filter(\.included).count }

    /// Строка шапки: чем ассистент **располагает**.
    ///
    /// Раньше здесь стояло «49 кусков не поместилось». Факт тот же, а читается
    /// как «приложение не справилось» — и человек не понимает, что у него на
    /// руках, только что он потерял.
    var headline: String {
        let size = "\(thousands(characters)) знаков"
        guard !whole else {
            return records.count == 1
                ? "Запись целиком · \(size)"
                : "Все \(LoriFormat.plural(records.count, one: "запись", few: "записи", many: "записей")) целиком · \(size)"
        }
        let included = LoriFormat.plural(includedCount, one: "запись", few: "записи", many: "записей")
        return "\(included) из \(records.count) · \(size)"
    }

    /// Вошло не всё — человек должен знать, что остальное модель всё-таки
    /// видит: оглавление уходит по всем записям охвата, включая эти.
    var note: String? {
        whole ? nil : "Остальные записи модель видит в оглавлении и может их назвать"
    }

    private func thousands(_ value: Int) -> String {
        value < 1_000 ? "\(value)" : "\((value + 500) / 1_000) тыс."
    }

    /// Ключ кэша для сервиса. Считается по содержимому префикса, поэтому у
    /// одинакового контекста он одинаковый, а у пересобранного — другой.
    var cacheKey: String {
        var hasher = Hasher()
        for record in records {
            hasher.combine(record.number)
            hasher.combine(record.path)
        }
        for piece in pieces {
            hasher.combine(piece.record)
            hasher.combine(piece.text)
        }
        return "lori-\(UInt(bitPattern: hasher.finalize()))"
    }

    /// Спрашивать не по чему. Считается по записям, а не по текстам: контекст
    /// из одного оглавления — рабочий, тексты к нему дописываются под вопрос.
    var isEmpty: Bool { records.isEmpty }
}

/// Одно сообщение треда.
struct ThreadMessage: Codable, Equatable, Sendable, Identifiable {
    enum Role: String, Codable, Sendable {
        case question
        case answer
    }

    let id: UUID
    let role: Role
    let text: String
    /// Ссылки на записи — только у ответа.
    let citations: [AssistantService.Citation]
    let date: Date
    /// Тексты записей, ушедшие вместе с этим вопросом.
    ///
    /// Хранятся здесь, а не перечитываются с диска: правка расшифровки изменила
    /// бы уже отправленное, префикс перестал бы совпадать байт в байт, и кэш
    /// сервиса развалился бы на всей ветке.
    let added: [ContextSnapshot.Piece]

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        citations: [AssistantService.Citation] = [],
        date: Date = .now,
        added: [ContextSnapshot.Piece] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.citations = citations
        self.date = date
        self.added = added
    }

    /// Разбор снисходителен к отсутствующим полям: тред — это переписка, и
    /// терять её из-за нового поля в формате нельзя.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        citations = try container.decodeIfPresent([AssistantService.Citation].self, forKey: .citations) ?? []
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? .now
        added = try container.decodeIfPresent([ContextSnapshot.Piece].self, forKey: .added) ?? []
    }
}

/// Разговор по архиву: замороженный контекст плюс лента сообщений.
struct AssistantThread: Codable, Equatable, Sendable {
    var context: ContextSnapshot
    var messages: [ThreadMessage]

    init(context: ContextSnapshot, messages: [ThreadMessage] = []) {
        self.context = context
        self.messages = messages
    }

    /// Заголовок треда — первый заданный вопрос: он же и есть тема разговора.
    var title: String {
        messages.first { $0.role == .question }?.text ?? "Разговор"
    }

    /// Всё, что уже ушло сервису: замороженные тексты плюс дописанные.
    var pieces: [ContextSnapshot.Piece] {
        context.pieces + messages.flatMap(\.added)
    }

    /// Номера записей, тексты которых сервис уже видел. Повторно они не уходят
    /// никогда: на них ссылаются номером, и в этом весь смысл дописки в конец.
    var sentRecords: Set<Int> {
        Set(pieces.map(\.record))
    }

    /// Сколько знаков расшифровок набрал разговор. Считается по всему, что
    /// ушло: потолок треда — про суммарный счёт, а не про один запрос.
    var characters: Int {
        pieces.reduce(0) { $0 + $1.text.count }
    }

    /// Строка шапки с учётом дописанного.
    var headline: String { merged.headline }

    /// Что дописалось под последний вопрос и что модель видит помимо текстов.
    var note: String? {
        let last = messages.last { $0.role == .question }?.added ?? []
        let records = Set(last.map(\.record)).count
        guard records > 0 else { return merged.note }
        let word = LoriFormat.plural(records, one: "запись", few: "записи", many: "записей")
        return "+\(word) под этот вопрос"
    }

    /// Контекст с учётом дописанного — для разбора ссылок и для шапки. Ссылка
    /// на дописанную запись обязана вести туда же, куда и на замороженную.
    var merged: ContextSnapshot {
        let sent = sentRecords
        return ContextSnapshot(
            scopeTitle: context.scopeTitle,
            records: context.records.map { record in
                record.included || !sent.contains(record.number)
                    ? record
                    : ContextSnapshot.Record(
                        number: record.number,
                        path: record.path,
                        title: record.title,
                        date: record.date,
                        topic: record.topic,
                        detail: record.detail,
                        characters: record.characters,
                        seconds: record.seconds,
                        included: true
                    )
            },
            pieces: pieces,
            characters: characters,
            whole: context.whole
        )
    }
}

/// Хранилище треда.
///
/// Тред один. Список разговоров — это отдельный экран, отдельное удаление и
/// отдельная миграция, а ценность вопроса к архиву в том, чтобы вернуться к
/// вчерашней ветке, а не листать сорок. «Новый разговор» заменяет текущий.
@MainActor
final class AssistantThreadStore: ObservableObject {
    @Published private(set) var thread: AssistantThread?

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
        load()
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Lori", directoryHint: .isDirectory)
            .appending(path: "thread.json")
    }

    var hasThread: Bool { thread != nil }

    func start(with context: ContextSnapshot) {
        thread = AssistantThread(context: context)
        save()
    }

    /// Пересбор контекста существующего треда: история остаётся, префикс новый.
    func replaceContext(with context: ContextSnapshot) {
        guard var current = thread else { return start(with: context) }
        current.context = context
        thread = current
        save()
    }

    /// Тексты, ушедшие вместе с последним вопросом. Приходят уже после ответа —
    /// какие записи понадобились, известно только по итогам запроса.
    func attach(added: [ContextSnapshot.Piece]) {
        guard var current = thread, !added.isEmpty,
              let index = current.messages.lastIndex(where: { $0.role == .question }) else { return }
        let question = current.messages[index]
        current.messages[index] = ThreadMessage(
            id: question.id,
            role: question.role,
            text: question.text,
            citations: question.citations,
            date: question.date,
            added: added
        )
        thread = current
        save()
    }

    func append(_ message: ThreadMessage) {
        guard var current = thread else { return }
        current.messages.append(message)
        thread = current
        save()
    }

    /// Вопрос ушёл, а ответ не пришёл — вопрос не должен остаться висеть в ленте.
    func removeLastQuestion() {
        guard var current = thread, current.messages.last?.role == .question else { return }
        current.messages.removeLast()
        thread = current
        save()
    }

    func forget() {
        thread = nil
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Хранение

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(AssistantThread.self, from: data) else { return }
        thread = stored
    }

    private func save() {
        guard let thread, let data = try? JSONEncoder().encode(thread) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
