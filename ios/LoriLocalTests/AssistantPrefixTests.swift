import XCTest
@testable import LoriLocal

/// Запрос растёт только в конец.
///
/// Это не стиль, а цена: и OpenAI, и DeepSeek кэшируют **начало** запроса, но
/// только пока оно байт в байт то же. Стоит переупорядочить историю или
/// переотправить уже посланную запись — и ветка из десяти вопросов начинает
/// стоить как месяц расшифровок. Поэтому инвариант проверяется тестом, а не
/// надеждой на аккуратность.
final class AssistantPrefixTests: XCTestCase {
    /// Записанный запрос: роль и текст каждого сообщения.
    private typealias Request = [[String]]

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(key: String, request: Request)] = []

        func record(_ messages: [AssistantService.BackendMessage], key: String) {
            lock.lock()
            defer { lock.unlock() }
            storage.append((key, messages.map { [$0.role, $0.content] }))
        }

        /// Разговор без запросов роутера: у него свой префикс и своя жизнь.
        var conversation: [Request] {
            lock.lock()
            defer { lock.unlock() }
            return storage.filter { !$0.key.hasSuffix("-router") }.map(\.request)
        }

        var routerCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage.filter { $0.key.hasSuffix("-router") }.count
        }
    }

    private func source(_ index: Int, word: String) -> AssistantSource {
        AssistantSource(
            path: "Recordings/Запись \(index).m4a",
            title: "Запись \(index)",
            date: Date(timeIntervalSince1970: 1_756_000_000 - Double(index) * 86_400),
            markdown: (0..<8)
                .map { "**[0:\(String(format: "%02d", $0 * 5))–0:59]** \(word) номер \($0), строка для объёма контекста." }
                .joined(separator: "\n")
        )
    }

    private var sources: [AssistantSource] {
        [source(1, word: "Договор"), source(2, word: "Думатель"), source(3, word: "Погода")]
    }

    /// Бюджет мал нарочно: тексты в префикс не влезают, и всё приходит дописками.
    private func context(budget: Int = 200) -> ContextSnapshot {
        AssistantService.snapshot(
            question: "первый вопрос",
            sources: sources,
            scopeTitle: "Все",
            budget: budget
        )
    }

    private func service(_ recorder: Recorder, answer: @escaping @Sendable (Int) -> String) -> AssistantService {
        let counter = Counter()
        return AssistantService(backend: AssistantService.ClosureBackend { messages, key in
            recorder.record(messages, key: key)
            if key.hasSuffix("-router") { return .init(text: "2", cachedTokens: nil) }
            return .init(text: answer(counter.next()), cachedTokens: 1_024)
        })
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    // MARK: - Инвариант

    /// Каждый следующий запрос начинается ровно тем же, чем закончился прошлый.
    func testEachRequestIsAPrefixOfTheNext() async throws {
        let recorder = Recorder()
        let service = service(recorder) { _ in "Ответ [2@0]." }
        var thread = AssistantThread(context: context())

        for question in ["что про думатель?", "а какие ограничения?", "и что решили?"] {
            let reply = try await service.answer(question: question, in: thread, sources: sources)
            thread.messages.append(ThreadMessage(role: .question, text: question, added: reply.added))
            thread.messages.append(ThreadMessage(role: .answer, text: reply.text))
        }

        let requests = recorder.conversation
        XCTAssertEqual(requests.count, 3)
        for index in 1..<requests.count {
            let previous = requests[index - 1]
            let current = requests[index]
            XCTAssertGreaterThan(current.count, previous.count, "запрос обязан расти")
            XCTAssertEqual(
                Array(current.prefix(previous.count)),
                previous,
                "запрос \(index + 1) не начинается запросом \(index): префикс переписан, кэш промахнётся"
            )
        }
    }

    /// Системное сообщение — самый дорогой кусок префикса, и меняться ему нельзя.
    func testSystemMessageNeverChanges() async throws {
        let recorder = Recorder()
        let service = service(recorder) { _ in "Ответ [2@0]." }
        var thread = AssistantThread(context: context())

        for question in ["раз", "два"] {
            let reply = try await service.answer(question: question, in: thread, sources: sources)
            thread.messages.append(ThreadMessage(role: .question, text: question, added: reply.added))
            thread.messages.append(ThreadMessage(role: .answer, text: reply.text))
        }

        let systems = Set(recorder.conversation.compactMap { $0.first?[1] })
        XCTAssertEqual(systems.count, 1, "системное сообщение переписали — кэш начнётся с нуля")
    }

    /// Уже отправленная запись не отправляется повторно никогда: на неё
    /// ссылаются номером, и в этом весь смысл дописки в конец.
    func testSentRecordIsNeverSentTwice() async throws {
        let recorder = Recorder()
        let service = service(recorder) { _ in "Ответ [2@0]." }
        var thread = AssistantThread(context: context())

        for question in ["раз", "два", "три"] {
            let reply = try await service.answer(question: question, in: thread, sources: sources)
            thread.messages.append(ThreadMessage(role: .question, text: question, added: reply.added))
            thread.messages.append(ThreadMessage(role: .answer, text: reply.text))
        }

        let last = recorder.conversation.last ?? []
        let body = last.map { $0[1] }.joined(separator: "\n")
        // Искать надо строку из глубины записи: начало расшифровки живёт ещё и
        // в описании оглавления, и совпадение там — не дубль, а оглавление.
        XCTAssertEqual(
            body.components(separatedBy: "Думатель номер 7").count - 1,
            1,
            "текст записи ушёл дважды: \(body.suffix(400))"
        )
        XCTAssertEqual(thread.sentRecords, [2], "роутер просил только вторую запись")
    }

    /// Охват влез целиком — роутер не нужен вовсе: спрашивать, какие записи
    /// взять, когда взяты все, значит платить за лишний запрос.
    func testWholeScopeNeverCallsTheRouter() async throws {
        let recorder = Recorder()
        let service = service(recorder) { _ in "Ответ [1@0]." }
        let thread = AssistantThread(context: context(budget: 100_000))

        XCTAssertTrue(thread.context.whole)
        _ = try await service.answer(question: "что там?", in: thread, sources: sources)

        XCTAssertEqual(recorder.routerCalls, 0)
    }

    // MARK: - «Дай ещё»

    /// Модель назвала записи, которых ей не хватило — приложение дописывает их
    /// и переспрашивает. Один лишний заход дешевле неверного ответа.
    func testModelCanAskForMoreRecordsOnce() async throws {
        let recorder = Recorder()
        let service = service(recorder) { attempt in
            attempt == 1 ? "НУЖНЫ: 1, 3" : "Теперь понятно [1@0]."
        }
        let thread = AssistantThread(context: context())

        let reply = try await service.answer(question: "что про договор?", in: thread, sources: sources)

        XCTAssertEqual(recorder.conversation.count, 2, "ровно один дозаход")
        // Служебной строки в ответе нет; маркеры ссылок снимаются позже, при
        // показе (`paragraphs`), — до тех пор они и есть способ найти пилюли.
        XCTAssertEqual(reply.text, "Теперь понятно [1@0].", "служебная строка до человека не доходит")
        XCTAssertEqual(Set(reply.added.map(\.record)), [1, 2, 3])
    }

    /// Два дозахода подряд не случаются: если и после текстов модель просит ещё,
    /// вопрос не про этот архив, и честное «не нашёл» уже обосновано.
    func testSecondRequestForMoreIsNotHonoured() async throws {
        let recorder = Recorder()
        let service = service(recorder) { attempt in
            attempt == 1 ? "НУЖНЫ: 1" : "НУЖНЫ: 3\nБольше ничего не нашёл."
        }
        let thread = AssistantThread(context: context())

        let reply = try await service.answer(question: "что там?", in: thread, sources: sources)

        XCTAssertEqual(recorder.conversation.count, 2)
        XCTAssertEqual(reply.text, "Больше ничего не нашёл.")
    }

    // MARK: - Разбор

    func testRouterNumbersAreFilteredByTheOutline() {
        XCTAssertEqual(AssistantService.numbers(in: "3, 7 и ещё 99", among: [1, 3, 7]), [3, 7])
        XCTAssertEqual(AssistantService.numbers(in: "0", among: [1, 2]), [])
        XCTAssertEqual(AssistantService.numbers(in: "2, 2, 1", among: [1, 2]), [2, 1], "порядок ответа сохраняется, дубли уходят")
    }

    /// Модель попросила тексты, а дать их неоткуда: её служебная строка — весь
    /// ответ, и после снятия не остаётся ничего. «Сервис вернул пустой ответ»
    /// тут было бы враньём: сервис ответил, и ответ осмысленный.
    func testUnfulfillableRequestBecomesAHumanSentence() async throws {
        let recorder = Recorder()
        let service = service(recorder) { _ in "НУЖНЫ: 2" }

        let reply = try await service.answer(question: "что там?", in: AssistantThread(context: context()))

        XCTAssertTrue(reply.text.contains("«Запись 2»"), reply.text)
        XCTAssertTrue(reply.text.contains("Спроси по ней отдельно"), "одна запись — «по ней», а не «по ним»")
        XCTAssertFalse(reply.text.contains("НУЖНЫ"))
    }

    func testMissingSentenceListsEveryRecord() {
        let text = AssistantService.missing([1, 3], in: context())

        XCTAssertTrue(text.contains("«Запись 1», «Запись 3»"), text)
        XCTAssertTrue(text.contains("Спроси по ним отдельно"))
        XCTAssertFalse(text.contains("  "), "лишние пробелы: \(text)")
    }

    func testRequestLineIsParsedAndStripped() {
        XCTAssertEqual(AssistantService.requestedRecords(in: "НУЖНЫ: 3, 7"), [3, 7])
        XCTAssertEqual(AssistantService.requestedRecords(in: "Обычный ответ [1@0]."), [])
        XCTAssertEqual(AssistantService.withoutRequest("НУЖНЫ: 3\nОтвет."), "Ответ.")
    }

    /// Порядок дописки — по номеру записи, а не по тому, как их назвала модель:
    /// иначе один и тот же набор дал бы два разных префикса и промахнулся мимо
    /// кэша на ровном месте.
    func testAddedTextsAreOrderedByRecordNumber() async throws {
        var sent: Set<Int> = []
        var room = 100_000
        let pieces = AssistantService.texts(
            of: [3, 1, 2],
            sources: sources,
            context: context(),
            sent: &sent,
            room: &room
        )

        XCTAssertEqual(pieces.map(\.record), [1, 2, 3])
        XCTAssertEqual(sent, [1, 2, 3])
    }

    /// Уже отправленную запись повторно не берут, сколько бы раз её ни назвали.
    func testAlreadySentRecordIsSkipped() async throws {
        var sent: Set<Int> = [2]
        var room = 100_000
        let pieces = AssistantService.texts(
            of: [1, 2],
            sources: sources,
            context: context(),
            sent: &sent,
            room: &room
        )

        XCTAssertEqual(pieces.map(\.record), [1])
    }

    /// Потолок треда не даёт ветке расти бесконечно, и упор в него — это отказ
    /// дописать, а не молча обрезанный текст.
    func testRoomLimitsWhatGetsAppended() async throws {
        var sent: Set<Int> = []
        var room = 10
        let pieces = AssistantService.texts(
            of: [1, 2, 3],
            sources: sources,
            context: context(),
            sent: &sent,
            room: &room
        )

        XCTAssertTrue(pieces.isEmpty)
        XCTAssertTrue(sent.isEmpty, "запись, текст которой не ушёл, отправленной не считается")
    }
}
