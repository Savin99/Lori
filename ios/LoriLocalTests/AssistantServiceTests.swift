import XCTest
@testable import LoriLocal

/// Движок ассистента целиком: что уходит в запросе и что получается из ответа.
/// Ни сети, ни ключа из Keychain — транспорт и ключ подставляются.
final class AssistantServiceTests: XCTestCase {
    private let keys = [
        AssistantSettings.baseURLKey,
        AssistantSettings.modelKey,
        TranscriptionSettings.vocabularyKey,
    ]

    override func setUp() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        StubURLProtocol.reset()
    }

    private var sources: [AssistantSource] {
        [
            AssistantSource(
                path: "Recordings/Планёрка.m4a",
                title: "Планёрка по бюджету",
                date: Date(timeIntervalSince1970: 1_756_000_000),
                markdown: "**[0:12–0:30]** Бюджет на квартал согласовали."
            ),
            AssistantSource(
                path: "Recordings/Найм.m4a",
                title: "Найм бэкендера",
                date: Date(timeIntervalSince1970: 1_755_000_000),
                markdown: "**[2:05–2:40]** Оффер кандидату отправляем до пятницы."
            ),
        ]
    }

    private func thread(question: String = "что с бюджетом?") -> AssistantThread {
        AssistantThread(context: AssistantService.snapshot(
            question: question,
            sources: sources,
            scopeTitle: "Все"
        ))
    }

    private static func reply(_ content: String, usage: [String: Any]? = nil) -> StubURLProtocol.Reply {
        var payload: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": content]]],
        ]
        if let usage { payload["usage"] = usage }
        return .json(String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!)
    }

    // MARK: - Запрос

    func testRequestGoesToChatCompletionsWithBearerAndBothRoles() async throws {
        UserDefaults.standard.set("gpt-5.1-mini", forKey: AssistantSettings.modelKey)
        let session = StubURLProtocol.session { _, _ in Self.reply("Согласовали бюджет [1].") }
        let service = AssistantService(session: session, keyProvider: { "тест-ключ" })

        _ = try await service.answer(question: "что с бюджетом?", in: thread())

        let recorded = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(recorded.request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(recorded.request.httpMethod, "POST")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "Authorization"), "Bearer тест-ключ")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: recorded.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-5.1-mini")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertEqual(messages.last?["role"], "user")
        XCTAssertEqual(messages.last?["content"], "что с бюджетом?")
    }

    /// Контекст уходит в системном сообщении — одним куском, чтобы у сервиса
    /// было цельное начало запроса, которое он может закэшировать.
    func testDefaultLunaRequestOmitsTemperatureAndUsesLowReasoning() async throws {
        let session = StubURLProtocol.session { _, _ in Self.reply("Ответ [1].") }
        let service = AssistantService(session: session, keyProvider: { "fixture-key" })
        _ = try await service.answer(question: "что с бюджетом?", in: thread())
        let recorded = try XCTUnwrap(StubURLProtocol.requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: recorded.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
        XCTAssertNil(body["temperature"])
    }

    func testContextTravelsInsideTheSystemMessage() async throws {
        let session = StubURLProtocol.session { _, _ in Self.reply("Ответ [1].") }
        let service = AssistantService(session: session, keyProvider: { "ключ" })

        _ = try await service.answer(question: "что с бюджетом?", in: thread())

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.requests.first).body) as? [String: Any]
        )
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let system = try XCTUnwrap(messages.first?["content"])
        XCTAssertTrue(system.contains("Бюджет на квартал согласовали"), "фрагменты внутри системного сообщения")
        XCTAssertTrue(system.contains("[1] Планёрка по бюджету"), "у фрагмента есть номер и подпись")
    }

    /// Главное свойство всего слоя: начало запроса не меняется от вопроса к
    /// вопросу. Именно на этом держится кэш у сервиса, а значит и цена ветки.
    func testPrefixStaysByteIdenticalAcrossTheThread() async throws {
        let session = StubURLProtocol.session { _, _ in Self.reply("Ответ [1].") }
        let service = AssistantService(session: session, keyProvider: { "ключ" })
        var conversation = thread()

        _ = try await service.answer(question: "первый вопрос", in: conversation)
        conversation.messages.append(ThreadMessage(role: .question, text: "первый вопрос"))
        conversation.messages.append(ThreadMessage(role: .answer, text: "Ответ [1]."))
        _ = try await service.answer(question: "второй вопрос", in: conversation)

        let systems = try StubURLProtocol.requests.map { recorded -> String in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: recorded.body) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            return try XCTUnwrap(messages.first?["content"])
        }
        XCTAssertEqual(systems.count, 2)
        XCTAssertEqual(systems[0], systems[1], "префикс обязан совпасть до знака, иначе кэш не сработает")
    }

    func testHistoryGoesInOrderAndKeepsRoles() async throws {
        let session = StubURLProtocol.session { _, _ in Self.reply("Ответ [1].") }
        let service = AssistantService(session: session, keyProvider: { "ключ" })
        var conversation = thread()
        conversation.messages = [
            ThreadMessage(role: .question, text: "первый"),
            ThreadMessage(role: .answer, text: "ответ на первый"),
        ]

        _ = try await service.answer(question: "второй", in: conversation)

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.requests.first).body) as? [String: Any]
        )
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(messages[1]["content"], "первый")
        XCTAssertEqual(messages[3]["content"], "второй")
    }

    func testCacheKeyTravelsAndIsStable() async throws {
        let session = StubURLProtocol.session { _, _ in Self.reply("Ответ [1].") }
        let service = AssistantService(session: session, keyProvider: { "ключ" })
        let conversation = thread()

        _ = try await service.answer(question: "раз", in: conversation)
        _ = try await service.answer(question: "два", in: conversation)

        let keys = try StubURLProtocol.requests.map { recorded -> String in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: recorded.body) as? [String: Any])
            return try XCTUnwrap(body["prompt_cache_key"] as? String)
        }
        XCTAssertEqual(keys[0], keys[1])
        XCTAssertEqual(keys[0], conversation.context.cacheKey)
    }

    func testCachedTokensAreReadFromTheAnswer() async throws {
        let session = StubURLProtocol.session { _, _ in
            Self.reply("Ответ [1].", usage: ["prompt_tokens_details": ["cached_tokens": 8_192]])
        }
        let service = AssistantService(session: session, keyProvider: { "ключ" })

        let reply = try await service.answer(question: "вопрос", in: thread())

        XCTAssertEqual(reply.cachedTokens, 8_192, "без этого числа нечем доказать, что кэш работает")
    }

    /// Разбор поля кэша напрямую: у двух сервисов оно лежит на разной глубине.
    func testBothShapesOfTheCacheFieldAreUnderstood() throws {
        let openAI = try JSONDecoder().decode(
            AssistantUsage.self,
            from: Data(#"{"prompt_tokens_details": {"cached_tokens": 8192}}"#.utf8)
        )
        let deepSeek = try JSONDecoder().decode(
            AssistantUsage.self,
            from: Data(#"{"prompt_cache_hit_tokens": 4096}"#.utf8)
        )
        let nothing = try JSONDecoder().decode(
            AssistantUsage.self,
            from: Data(#"{"prompt_tokens": 100}"#.utf8)
        )

        XCTAssertEqual(openAI.cachedTokens, 8_192)
        XCTAssertEqual(deepSeek.cachedTokens, 4_096)
        XCTAssertNil(nothing.cachedTokens, "нет поля — нет и числа, выдумывать нечего")
    }

    /// У DeepSeek поле называется иначе, а смысл тот же.
    func testDeepSeekCacheFieldIsUnderstoodToo() async throws {
        let session = StubURLProtocol.session { _, _ in
            Self.reply("Ответ [1].", usage: ["prompt_cache_hit_tokens": 4_096])
        }
        let service = AssistantService(session: session, keyProvider: { "ключ" })

        let reply = try await service.answer(question: "вопрос", in: thread())

        XCTAssertEqual(reply.cachedTokens, 4_096)
    }

    // MARK: - Заморозка контекста

    func testSnapshotNumbersRecordsFromOne() {
        let context = AssistantService.snapshot(question: "бюджет", sources: sources, scopeTitle: "Все")

        XCTAssertEqual(context.records.map(\.number), [1, 2])
        XCTAssertEqual(context.includedCount, 2)
        XCTAssertTrue(context.whole, "две короткие записи обязаны войти целиком")
        XCTAssertEqual(context.scopeTitle, "Все")
        XCTAssertEqual(
            Set(context.pieces.map(\.record)),
            [1, 2],
            "кусок ссылается на номер записи, а не на свой собственный"
        )
    }

    /// Оглавление идёт в промпт всегда и перечисляет **все** записи охвата —
    /// иначе «в записях этого нет» становится следствием незнания о них.
    func testOutlineListsEveryRecordEvenWithoutItsText() {
        let long = AssistantSource(
            path: "Recordings/Долгая.m4a",
            title: "Долгая планёрка",
            date: Date(timeIntervalSince1970: 1_754_000_000),
            markdown: (1...400)
                .map { "**[0:00–0:10]** Строка про поставки номер \($0), довольно длинная." }
                .joined(separator: "\n")
        )
        let context = AssistantService.snapshot(
            question: "оффер кандидату",
            sources: sources + [long],
            scopeTitle: "Все",
            budget: 100
        )
        let prompt = AssistantService.system(for: context)

        XCTAssertFalse(context.whole)
        XCTAssertLessThan(context.includedCount, context.records.count)
        for record in context.records {
            XCTAssertTrue(
                prompt.contains(record.title),
                "запись «\(record.title)» пропала из оглавления"
            )
        }
        XCTAssertTrue(prompt.contains("текста нет"), "модель должна отличать «не вошло» от «не было»")
    }

    /// Влезает целиком — отдаём целиком: отбор режет разговор на куски и теряет
    /// связь между ними, а платим мы всё равно за то же самое.
    func testWholeScopeGoesWithoutSelection() {
        let context = AssistantService.snapshot(question: "оффер", sources: sources, scopeTitle: "Все")

        XCTAssertTrue(context.whole)
        XCTAssertTrue(context.records.allSatisfy(\.included))
    }

    /// Пересобранный контекст обязан отличаться ключом: иначе сервис отдаст
    /// кэш от старого префикса, а в нём других записей нет.
    func testRebuiltContextGetsANewCacheKey() {
        let first = AssistantService.snapshot(question: "бюджет", sources: sources, scopeTitle: "Все")
        let narrowed = AssistantService.snapshot(
            question: "бюджет",
            sources: Array(sources.prefix(1)),
            scopeTitle: "Все"
        )

        XCTAssertNotEqual(first.cacheKey, narrowed.cacheKey)
    }

    /// Секунды нужны модели, чтобы вернуть точную ссылку, а не начало записи.
    func testPiecesCarrySecondsInsideTheText() {
        let context = AssistantService.snapshot(question: "бюджет", sources: sources, scopeTitle: "Все")

        let text = context.pieces.first?.text ?? ""
        XCTAssertTrue(text.hasPrefix("12| "), "в начале строки — секунда: \(text)")
        XCTAssertEqual(context.pieces.first?.starts, [12], "начала строк нужны для проверки ссылки")
    }

    // MARK: - Ссылки

    private static func record(_ number: Int, _ path: String, _ title: String) -> ContextSnapshot.Record {
        ContextSnapshot.Record(
            number: number,
            path: path,
            title: title,
            date: Date(timeIntervalSince1970: 1_756_000_000),
            topic: nil,
            detail: nil,
            characters: 100,
            seconds: 90,
            included: true
        )
    }

    private static func piece(_ record: Int, starts: [TimeInterval], text: String) -> ContextSnapshot.Piece {
        ContextSnapshot.Piece(
            record: record,
            start: starts.first,
            end: starts.last,
            starts: starts,
            text: text
        )
    }

    private static func context(
        _ records: [ContextSnapshot.Record],
        _ pieces: [ContextSnapshot.Piece]
    ) -> ContextSnapshot {
        ContextSnapshot(scopeTitle: "Все", records: records, pieces: pieces, characters: 100, whole: true)
    }

    private var citationContext: ContextSnapshot {
        Self.context(
            [Self.record(1, "Recordings/Интеграция.m4a", "Интеграция")],
            [Self.piece(1, starts: [30, 90], text: "30| Решили забирать документы из Google Docs.\n90| И складывать их рядом.")]
        )
    }

    func testCitationCarriesTheSecondFromTheAnswer() {
        let found = AssistantService.citations(in: "Решили забирать [1@90].", context: citationContext)

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.start, 90, "перематывать надо туда, о чём речь")
        XCTAssertEqual(found.first?.path, "Recordings/Интеграция.m4a")
        XCTAssertEqual(found.first?.title, "Интеграция")
    }

    /// Модель нередко пишет «судя по расшифровке [2]» — это оборот речи, а не
    /// ссылка на место. Пилюля без времени рядом с настоящими секундами той же
    /// записи никуда не ведёт и только засоряет список.
    func testTimelessCitationDropsWhenTheSameRecordHasSeconds() {
        let found = AssistantService.citations(
            in: "Судя по расшифровке [1], решили так [1@30] и вот так [1@90].",
            context: citationContext
        )

        XCTAssertEqual(found.map { $0.start }, [30, 90])
    }

    /// А если у записи секунд нет вовсе, ссылка без времени — единственная,
    /// какая возможна, и убирать её нельзя.
    func testTimelessCitationSurvivesWithoutAnySeconds() {
        let context = Self.context(
            [Self.record(1, "a", "Без таймкодов")],
            [Self.piece(1, starts: [], text: "Просто текст без времени.")]
        )

        let found = AssistantService.citations(in: "Так и было [1].", context: context)

        XCTAssertEqual(found.map(\.number), [1])
        XCTAssertNil(found.first?.start)
    }

    func testUnknownNumbersAreDropped() {
        let found = AssistantService.citations(in: "Ответ [7] и [заметка] и [1@30].", context: citationContext)

        XCTAssertEqual(found.map(\.number), [1])
    }

    /// Две ссылки на один фрагмент, но разные секунды — это разные места.
    func testSameRecordWithDifferentSecondsGivesTwoPills() {
        let found = AssistantService.citations(in: "Раз [1@30]. Два [1@90]. Снова [1@30].", context: citationContext)

        XCTAssertEqual(found.map { $0.start }, [30, 90])
    }

    /// Секунда рядом с настоящей — это промах модели на соседнюю реплику, и он
    /// притягивается к реальному началу. Проверять диапазоном нельзя: он
    /// пропускает любое число внутри, в том числе то, которого в записи нет.
    func testNearbySecondSnapsToARealLineStart() {
        let found = AssistantService.citations(in: "Решили [1@33].", context: citationContext)

        XCTAssertEqual(found.map { $0.start }, [30])
    }

    func testInventedSecondLosesTheTime() {
        let found = AssistantService.citations(in: "Решили [1@4000].", context: citationContext)

        XCTAssertEqual(found.count, 1, "ссылка на запись остаётся")
        XCTAssertNil(found.first?.start, "выдуманная секунда открыла бы запись не там")
    }

    /// Голое «[1]» временем не дополняется. Раньше на него подставлялось начало
    /// фрагмента, и вся лента получала пилюли «0:00»: единица контекста — запись,
    /// а её начало всегда ноль.
    func testCitationWithoutSecondHasNoTime() {
        let found = AssistantService.citations(in: "Решили [1].", context: citationContext)

        XCTAssertEqual(found.map(\.number), [1])
        XCTAssertNil(found.first?.start)
    }

    func testCitationsKeepTheOrderOfAppearance() {
        let context = Self.context(
            [Self.record(1, "a", "Раз"), Self.record(2, "b", "Два")],
            [Self.piece(1, starts: [0], text: "0| раз"), Self.piece(2, starts: [0], text: "0| два")]
        )

        let found = AssistantService.citations(in: "Сначала [2], потом [1].", context: context)

        XCTAssertEqual(found.map(\.number), [2, 1])
    }

    // MARK: - Абзацы и маркеры

    /// Пилюля стоит под своим абзацем: ответ из двух утверждений с разными
    /// источниками иначе превращается в «угадай, что к чему относится».
    func testEachParagraphKeepsItsOwnCitations() {
        let context = Self.context(
            [Self.record(1, "a", "Раз"), Self.record(2, "b", "Два")],
            [Self.piece(1, starts: [0], text: "0| раз"), Self.piece(2, starts: [0], text: "0| два")]
        )

        let split = AssistantService.paragraphs(of: "Первое [1@10].\n\nВторое [2@20].", context: context)

        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split[0].citations.map(\.number), [1])
        XCTAssertEqual(split[1].citations.map(\.number), [2])
    }

    /// Маркер — служебный: он нужен, чтобы понять, к чему ссылка, а читать его
    /// человеку незачем.
    func testMarkersLeaveTheVisibleText() {
        XCTAssertEqual(AssistantService.withoutMarkers("Решили так [1@38]."), "Решили так.")
        XCTAssertEqual(AssistantService.withoutMarkers("Раз [1] и два [2, 3]."), "Раз и два.")
    }

    /// «[смотри запись]» — это часть речи, а не ссылка, и её трогать нельзя.
    func testOnlyNumericMarkersAreRemoved() {
        XCTAssertEqual(
            AssistantService.withoutMarkers("Как сказано [в записи], решили [1@38]."),
            "Как сказано [в записи], решили."
        )
    }

    // MARK: - Отказы

    func testEmptyQuestionIsRefusedBeforeTheNetwork() async {
        let service = AssistantService(backend: AssistantService.ClosureBackend { _ in
            XCTFail("пустой вопрос не должен доходить до сервиса")
            return ""
        })

        await XCTAssertThrowsErrorAsync(try await service.answer(question: "   ", in: thread())) { error in
            XCTAssertEqual(error as? AssistantError, .emptyQuestion)
        }
    }

    func testEmptyContextIsRefused() async {
        let empty = AssistantThread(context: Self.context([], []))
        let service = AssistantService(backend: AssistantService.ClosureBackend { _ in "" })

        await XCTAssertThrowsErrorAsync(try await service.answer(question: "вопрос", in: empty)) { error in
            XCTAssertEqual(error as? AssistantError, .noSources)
        }
    }

    func testEmptyAnswerIsAnError() async {
        let service = AssistantService(backend: AssistantService.ClosureBackend { _ in "   " })

        await XCTAssertThrowsErrorAsync(try await service.answer(question: "вопрос", in: thread())) { error in
            XCTAssertEqual(error as? AssistantError, .emptyAnswer)
        }
    }

    /// Рассуждения модели — не ответ: `<think>` срезается тем же разбором,
    /// что и у локальной модели заголовков.
    func testThoughtsAreCutOff() async throws {
        let service = AssistantService(backend: AssistantService.ClosureBackend { _ in
            "<think>надо посмотреть фрагмент 1</think>Бюджет согласовали [1]."
        })

        let reply = try await service.answer(question: "бюджет?", in: thread())

        XCTAssertEqual(reply.text, "Бюджет согласовали [1].")
    }
}

/// `XCTAssertThrowsError` не умеет `await`, а без него тест на отказ пришлось бы
/// писать через do/catch в каждом месте.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("ожидалась ошибка", file: file, line: line)
    } catch {
        handler(error)
    }
}
