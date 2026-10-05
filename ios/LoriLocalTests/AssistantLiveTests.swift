import XCTest
@testable import LoriLocal

/// Живой прогон ассистента по настоящему сервису.
///
/// Нужен потому, что подставной `URLProtocol` проверяет форму запроса, но не
/// отвечает на главный вопрос — стал ли ассистент умнее. Это видно только по
/// настоящему ответу настоящей модели.
///
/// **Ключ агенту не передаётся.** Он лежит в файле владельца вне репозитория
/// (`~/.config/lori/assistant-key`, как токен моста в корневом README), а сюда
/// приходит переменной окружения через `design/qa/live-assistant.sh`. Ключ
/// нигде не печатается: ни в утверждениях, ни в выводе теста. Файла нет —
/// тест пропускается, как интеграционный тест GigaAM без скачанных весов.
final class AssistantLiveTests: XCTestCase {
    private func key() throws -> String {
        let value = (ProcessInfo.processInfo.environment["LORI_ASSISTANT_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipIf(
            value.isEmpty,
            "Живой прогон пропущен: положите ключ в ~/.config/lori/assistant-key и запустите design/qa/live-assistant.sh"
        )
        return value
    }

    private func model() -> String {
        let value = (ProcessInfo.processInfo.environment["LORI_ASSISTANT_MODEL"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "deepseek-v4-flash" : value
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set("https://api.deepseek.com/v1", forKey: AssistantSettings.baseURLKey)
        UserDefaults.standard.set(model(), forKey: AssistantSettings.modelKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AssistantSettings.baseURLKey)
        UserDefaults.standard.removeObject(forKey: AssistantSettings.modelKey)
        super.tearDown()
    }

    // MARK: - Архив под вопросы

    /// Три записи, устроенные как настоящий разбор со скриншота: беглое
    /// упоминание в одной записи и подробный разговор в другой. Ассистент,
    /// который отвечает «есть только упоминание», проваливает этот архив.
    private var archive: [AssistantSource] {
        [
            AssistantSource(
                path: "Recordings/Скиллы и интеграция MCP.m4a",
                title: "Скиллы и интеграция MCP",
                date: Date(timeIntervalSince1970: 1_756_400_000),
                markdown: """
                **[0:00–0:20]** Сегодня про скиллы и про то, как приложение будет ходить в MCP.
                **[0:38–1:10]** Думатель 2.0 должен уметь отправлять пользователю информацию, например файлы или сводку.
                **[2:14–2:50]** Дальше обсудили формат манифеста и на этом закончили.
                """,
                topic: "Lori"
            ),
            AssistantSource(
                path: "Recordings/Разбор думателя.m4a",
                title: "Разбор думателя",
                date: Date(timeIntervalSince1970: 1_756_300_000),
                markdown: """
                **[0:00–0:30]** Разбираем думатель целиком, потому что в прошлый раз только упомянули.
                **[1:05–1:40]** Думатель принимает задачу текстом, разбивает её на шаги и ведёт их до конца, а не отвечает одной репликой.
                **[3:20–4:00]** У него два ограничения: он не ходит в сеть сам и не пишет в хранилище без подтверждения человека.
                **[6:10–6:45]** Решили, что первой версией будет только сводка и отправка файла, остальное потом.
                """,
                topic: "Lori"
            ),
            AssistantSource(
                path: "Recordings/Планёрка по бюджету.m4a",
                title: "Планёрка по бюджету",
                date: Date(timeIntervalSince1970: 1_756_200_000),
                markdown: """
                **[0:12–0:40]** Бюджет на квартал согласовали, спорить не о чем.
                **[1:30–2:00]** Оффер кандидату отправляем до пятницы.
                """,
                topic: "Работа"
            ),
        ]
    }

    private func thread(question: String) -> AssistantThread {
        AssistantThread(context: AssistantService.snapshot(
            question: question,
            sources: archive,
            scopeTitle: "Все"
        ))
    }

    // MARK: - Прогоны

    /// Тот самый вопрос со скриншота. Раньше ответ был «есть только упоминание,
    /// больше ничего»: подробный разговор в контекст не попадал.
    func testAnswerAboutTheThinkerUsesTheWholeConversation() async throws {
        let key = try key()
        let service = AssistantService(keyProvider: { key })

        let reply = try await service.answer(question: "Что ты знаешь про думатель?", in: thread(question: "Что ты знаешь про думатель?"))

        print("=== ОТВЕТ ===\n\(reply.text)\n=== ССЫЛКИ ===")
        for citation in reply.citations {
            print("\(citation.title) · \(citation.start.map(TranscriptSegment.stamp) ?? "без времени")")
        }

        XCTAssertGreaterThan(
            reply.text.count,
            200,
            "ответ на «что знаешь про X» при подробной записи не может быть в две фразы"
        )
        XCTAssertTrue(
            reply.citations.contains { $0.path == "Recordings/Разбор думателя.m4a" },
            "подробный разбор обязан попасть в ответ, а не только беглое упоминание"
        )
        XCTAssertTrue(
            reply.citations.contains { ($0.start ?? 0) > 0 },
            "хотя бы одна ссылка обязана вести не в начало записи"
        )
    }

    /// Ссылка ведёт в настоящую секунду. Пилюля «0:00» на всё подряд — это то,
    /// чем ассистент отличается от «скопировал в чат»: ничем.
    func testCitationsPointAtRealSeconds() async throws {
        let key = try key()
        let service = AssistantService(keyProvider: { key })
        let context = thread(question: "какие у думателя ограничения?").context

        let reply = try await service.answer(question: "какие у думателя ограничения?", in: AssistantThread(context: context))

        print("=== ОТВЕТ ===\n\(reply.text)")
        let known = Set(context.pieces.flatMap(\.starts))
        for citation in reply.citations {
            guard let start = citation.start else { continue }
            XCTAssertTrue(known.contains(start), "секунда \(start) в записи не начинает ни одной реплики")
        }
    }

    /// Про запись, текста которой в контексте нет, модель обязана сказать по
    /// оглавлению, а не отвечать «в записях этого нет».
    func testOutlineLetsTheModelNameARecordWithoutText() async throws {
        let key = try key()
        let service = AssistantService(keyProvider: { key })
        // Бюджет подобран так, чтобы текст планёрки не влез, а две записи про
        // думатель влезли. Проверять это обязательно: при слишком щедром бюджете
        // короткая планёрка попадает в контекст добивкой, модель отвечает по её
        // тексту — и тест проходит, ничего не проверив.
        let context = AssistantService.snapshot(
            question: "что говорили про думатель",
            sources: archive,
            scopeTitle: "Все",
            budget: 600
        )
        XCTAssertFalse(context.whole, "проверять нечего, если влезло всё")
        let planned = context.records.first { $0.title == "Планёрка по бюджету" }
        XCTAssertEqual(
            planned?.included,
            false,
            "текст планёрки не должен попасть в контекст — иначе проверяется не оглавление"
        )

        let reply = try await service.answer(question: "О чём была планёрка по бюджету?", in: AssistantThread(context: context))

        print("=== ОТВЕТ (без источников) ===\n\(reply.text)")
        XCTAssertTrue(
            reply.text.lowercased().contains("планёрка") || reply.text.lowercased().contains("бюджет"),
            "модель обязана назвать запись из оглавления: \(reply.text)"
        )
    }

    /// Полный круг «дай ещё»: текста записи в контексте нет, модель называет её
    /// номер, приложение дописывает текст и переспрашивает — человек видит один
    /// ответ. Ради этого весь слой дописки и делался.
    func testModelAsksForARecordAndAnswersAfterIt() async throws {
        let key = try key()
        let service = AssistantService(keyProvider: { key })
        let context = AssistantService.snapshot(
            question: "что говорили про думатель",
            sources: archive,
            scopeTitle: "Все",
            budget: 600
        )
        XCTAssertEqual(
            context.records.first { $0.title == "Планёрка по бюджету" }?.included,
            false,
            "текст планёрки не должен быть в контексте — иначе просить нечего"
        )

        let reply = try await service.answer(
            question: "Кому и к какому сроку отправляем оффер?",
            in: AssistantThread(context: context),
            sources: archive
        )

        print("=== ОТВЕТ (с дописком) ===\n\(reply.text)")
        XCTAssertTrue(
            reply.added.contains { $0.record == 3 },
            "текст планёрки обязан быть дописан: \(reply.added.map(\.record))"
        )
        XCTAssertTrue(
            reply.text.lowercased().contains("пятниц"),
            "ответ обязан опираться на дописанный текст: \(reply.text)"
        )
        XCTAssertFalse(reply.text.contains("НУЖНЫ"), "служебная строка до человека не доходит")
    }

    /// Кэш префикса — то, на чём держится цена треда. Второй вопрос обязан
    /// попасть в кэш, иначе заморозка контекста не работает вовсе.
    func testSecondQuestionHitsThePrefixCache() async throws {
        let key = try key()
        let service = AssistantService(keyProvider: { key })
        var conversation = thread(question: "что решили по думателю?")

        let first = try await service.answer(question: "что решили по думателю?", in: conversation)
        conversation.messages.append(ThreadMessage(role: .question, text: "что решили по думателю?"))
        conversation.messages.append(ThreadMessage(role: .answer, text: first.text, citations: first.citations))
        let second = try await service.answer(question: "а какие у него ограничения?", in: conversation)

        print("=== ИЗ КЭША === первый: \(first.cachedTokens.map(String.init) ?? "—"), второй: \(second.cachedTokens.map(String.init) ?? "—")")
        guard let cached = second.cachedTokens else {
            return XCTFail("сервис не сказал, сколько взял из кэша — доказать заморозку нечем")
        }
        XCTAssertGreaterThan(cached, 0, "второй вопрос обязан попасть в кэш префикса")
    }
}
