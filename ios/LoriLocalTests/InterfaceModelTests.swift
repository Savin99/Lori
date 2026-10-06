import XCTest
@testable import LoriLocal

/// Заголовок и сниппет карточки: «Новая запись 48» ни о чём не говорит, и вспомнить
/// запись без открытия было нельзя.
final class TranscriptTitleTests: XCTestCase {
    private let markdown = """
    # Recording-2026-08-27T20-20-11Z

    _Расшифровано: GigaAM v3 RNN-T (int8), на этом iPhone_

    **[0:00–0:34]** Значит, по корпусу Славы: сначала гоним вертикальный срез, смотрим recall.
    **[0:34–1:12]** По метаданным: марка, позиция, вид документа.

    > Пропуск 2:00–2:30: модель не вернула текст для этого участка.
    """

    func testTitleComesFromFirstWordsWithoutServiceLines() {
        let title = TranscriptTitle.title(from: markdown)

        XCTAssertEqual(title, "Значит, по корпусу Славы")
        XCTAssertFalse(title?.contains("Расшифровано") ?? true)
        XCTAssertFalse(title?.contains("[0:00") ?? true)
    }

    /// Метка говорящего — обвязка: «S1: Здравствуйте» в заголовке читается как
    /// мусор. Старое написание «Г1:» тоже отбрасывается — такие файлы уже есть.
    func testTitleDropsSpeakerMarks() {
        let dialog = """
        # Dialog sample

        **[0:00–0:01]** S1: Здравствуйте, давайте начнём встречу.

        Г2: Согласен, начинаем работу.
        """
        XCTAssertEqual(TranscriptTitle.title(from: dialog), "Здравствуйте, давайте начнём встречу")
        let snippet = TranscriptTitle.snippet(from: dialog)
        XCTAssertFalse(snippet?.contains("Г2:") ?? true)
        XCTAssertFalse(snippet?.contains("S1:") ?? true)
    }

    /// Сниппет начинается там, где кончился заголовок. Раньше он начинался с
    /// начала — и карточка дважды показывала одну и ту же фразу.
    func testSnippetStartsWhereTheTitleEnds() {
        let title = try? XCTUnwrap(TranscriptTitle.title(from: markdown))
        let snippet = TranscriptTitle.snippet(from: markdown)

        XCTAssertFalse(snippet?.hasPrefix("Значит, по корпусу Славы") ?? true, "заголовок повторять незачем")
        XCTAssertTrue(snippet?.contains("По метаданным") ?? false, "сниппет — это продолжение")
        if let title, let snippet {
            XCTAssertFalse(snippet.hasPrefix(title), "дубля заголовка быть не должно")
        }
        XCTAssertFalse(snippet?.contains("Пропуск") ?? true, "предупреждение — не текст записи")
    }

    /// Короткая запись целиком уходит в заголовок. Показать её ещё раз лучше,
    /// чем оставить под ним пустоту.
    func testSnippetFallsBackWhenThereIsNoContinuation() {
        let snippet = TranscriptTitle.snippet(from: "**[0:00–0:02]** Коротко.")

        XCTAssertEqual(snippet, "Коротко.")
    }

    /// Длинный текст обрезается с многоточием: две строки под названием, не больше.
    func testLongSnippetEndsWithEllipsis() {
        let long = "**[0:00–0:10]** " + String(repeating: "слово ", count: 60)
        let snippet = TranscriptTitle.snippet(from: long)

        XCTAssertTrue(snippet?.hasSuffix("…") ?? false, snippet ?? "—")
        XCTAssertLessThanOrEqual(snippet?.count ?? 0, TranscriptTitle.snippetLimit + 1)
    }

    /// Обрезка идёт по слову: «Планы по RAG для ОВи…» читается хуже, чем «Планы по RAG для…».
    func testTitleIsCutOnWordBoundary() {
        let long = "Планы по RAG для ОВиК и ещё много слов про инжест и метаданные документов"
        let title = TranscriptTitle.shortened(long, limit: 24)

        XCTAssertLessThanOrEqual(title.count, 24)
        XCTAssertFalse(title.hasSuffix(" "))
        XCTAssertTrue(long.hasPrefix(title), title)
    }

    func testEmptyTranscriptHasNoTitle() {
        XCTAssertNil(TranscriptTitle.title(from: "# Только заголовок\n"))
        XCTAssertNil(TranscriptTitle.snippet(from: ""))
    }

    // MARK: - Настоящий файл, а не рукописный образец

    /// Реплики двух говорящих с таймкодами — так пишут Gemini, ElevenLabs и OpenAI
    /// в режиме «Говорящие».
    private let dialog = Transcript(
        text: "",
        segments: [
            TranscriptSegment(start: 0, end: 4, text: "S1: Привет, это тест записи."),
            TranscriptSegment(start: 4, end: 11, text: "S2: Да, слышу тебя хорошо. Начнём с бюджета на квартал."),
        ]
    )

    /// Что угодно из обвязки файла, чего на карточке быть не должно.
    private func assertClean(_ value: String?, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let value else { return XCTFail("\(label): пусто", file: file, line: line) }
        for junk in ["Режим", "_", "Расшифровано", "S1", "S2", "**[", "0:00", "Recording-"] {
            XCTAssertFalse(value.contains(junk), "\(label) «\(value)» содержит «\(junk)»", file: file, line: line)
        }
    }

    /// **Регрессия.** `Transcript.markdown` пишет строку `_Режим: …_` для каждого
    /// движка с режимом, а построчный разбор заголовка её не знал: карточка
    /// называлась «_Режим: Спикеры и таймкоды_ Привет, это», и тем же мусором
    /// начинались сниппет и текст под чужим заголовком.
    func testModeLineFromRealFileNeverReachesTheCard() {
        for stamps in [true, false] {
            let markdown = dialog.markdown(
                title: "Recording-2026-09-04T22-22-10Z",
                engine: "Gemini · gemini-3.5-transcribe",
                mode: "Спикеры и таймкоды",
                stamps: stamps
            )
            XCTAssertTrue(markdown.contains("_Режим: Спикеры и таймкоды_"), "файл тот самый, с режимом")

            XCTAssertEqual(TranscriptTitle.title(from: markdown), "Привет, это тест записи", "таймкоды: \(stamps)")
            assertClean(TranscriptTitle.title(from: markdown), "заголовок")
            assertClean(TranscriptTitle.snippet(from: markdown), "сниппет")
            assertClean(TranscriptTitle.head(from: markdown), "начало")
            XCTAssertEqual(TranscriptTitle.snippet(from: markdown), "Да, слышу тебя хорошо. Начнём с бюджета на квартал.")
            XCTAssertTrue(TranscriptTitle.head(from: markdown)?.hasPrefix("Привет, это тест записи.") == true)
        }
    }

    /// Движок без реплик (OpenAI «Быстрый текст», «Причёсанный текст» у Gemini)
    /// отдаёт текст одним куском — режим в файле стоит и у него.
    func testModeLineIsDroppedForPlainTextEnginesToo() {
        let markdown = Transcript(text: "Обсудили переезд офиса в новое помещение. Коробки перевезут в субботу.")
            .markdown(title: "audio_5_2", engine: "OpenAI · gpt-transcribe", mode: "Быстрый текст")

        XCTAssertEqual(TranscriptTitle.title(from: markdown), "Обсудили переезд офиса в новое помещение")
        XCTAssertEqual(TranscriptTitle.snippet(from: markdown), "Коробки перевезут в субботу.")
        assertClean(TranscriptTitle.head(from: markdown), "начало")
    }

    /// Предупреждения о пропусках и «кусок» у приблизительных таймкодов — тоже
    /// обвязка, а не слова записи.
    func testWarningsAndApproximateStampsStayOutOfTheCard() {
        let markdown = Transcript(
            text: "",
            segments: [TranscriptSegment(start: 0, end: 300, text: "Начали с отчёта о продажах за август.", isApproximate: true)],
            warnings: ["Пропуск 2:00–2:30: слов для этого участка сервис не дал"]
        ).markdown(title: "Новая запись 12", engine: "Gemini · gemini-3.5-transcribe", mode: "Точность")

        XCTAssertEqual(TranscriptTitle.title(from: markdown), "Начали с отчёта о продажах за август")
        for value in [TranscriptTitle.snippet(from: markdown), TranscriptTitle.head(from: markdown)] {
            XCTAssertFalse(value?.contains("Пропуск") ?? true)
            XCTAssertFalse(value?.contains("кусок") ?? true)
            XCTAssertFalse(value?.contains("Режим") ?? true)
        }
    }

    // MARK: - Где кончается первая фраза

    /// Точка между цифрами — дата или версия, а не конец фразы. Раньше заголовок
    /// обрывался на ней: «Совещание 27», «Переходим на версию 3».
    func testDatesAndVersionsDoNotEndTheSentence() {
        let meeting = "Совещание 27.08 по бюджету отдела. Дальше обсуждали найм."
        XCTAssertEqual(TranscriptTitle.title(from: meeting), "Совещание 27.08 по бюджету отдела")
        XCTAssertEqual(TranscriptTitle.snippet(from: meeting), "Дальше обсуждали найм.")

        XCTAssertEqual(
            TranscriptTitle.title(from: "Переходим на версию 3.5 уже в понедельник. Остальное позже."),
            "Переходим на версию 3.5 уже в понедельник"
        )
        XCTAssertEqual(TranscriptTitle.title(from: "27.08 планёрка по релизу. Дальше детали."), "27.08 планёрка по релизу")
    }

    /// Двоеточие во времени — тоже не граница мысли.
    func testTimeOfDayDoesNotEndTheSentence() {
        XCTAssertEqual(
            TranscriptTitle.title(from: "Созвон в 12:30 по поводу релиза. Потом обед."),
            "Созвон в 12:30 по поводу релиза"
        )
    }

    /// «т.е.» посреди фразы — сокращение: раньше из него выходило «Мы решили, т».
    func testAbbreviationsDoNotEndTheSentence() {
        let title = TranscriptTitle.title(from: "Мы решили, т.е. договорились, перенести релиз на май. Остальное потом.")
        XCTAssertEqual(title, "Мы решили, т.е. договорились, перенести")
        // Инициалы — тоже не конец фразы.
        XCTAssertEqual(
            TranscriptTitle.title(from: "Встреча с А. С. Петровым по договору аренды. Потом ремонт."),
            "Встреча с А. С. Петровым по договору"
        )
    }

    /// Слишком ранняя граница («Ок.») — повод взять следующую, а не резать весь
    /// текст по длине посреди фразы, как раньше: «Ок. Итак, сегодня разбираем итоги».
    ///
    /// До 6 октября 2026 тест ждал «Ок. Итак, сегодня разбираем итоги квартала»:
    /// короткую реплику приклеивали к следующей фразе. Тем же правилом карточка
    /// владельца называлась «Что хотел? Не» — и теперь отклик «Ок.» в заголовок не
    /// идёт вовсе: заголовок — первая содержательная фраза (`TranscriptTitle.lead`).
    /// Суть проверки прежняя: текст не режется посреди фразы, сниппет продолжает
    /// его после заголовка.
    func testTooEarlyBoundaryGivesWayToTheNextOne() {
        let text = "Ок. Итак, сегодня разбираем итоги квартала. Начнём с продаж, потом расходы."
        XCTAssertEqual(TranscriptTitle.title(from: text), "Итак, сегодня разбираем итоги квартала")
        XCTAssertEqual(TranscriptTitle.snippet(from: text), "Начнём с продаж, потом расходы.")
    }

    /// Обрезка по длине не оставляет висеть предлог или союз — то же правило,
    /// что у заголовков модели (`Summarizer.tidy`).
    func testCutNeverEndsOnAPreposition() {
        XCTAssertEqual(
            TranscriptTitle.title(from: "Обсуждали структуру базы знаний вместе с командой поддержки"),
            "Обсуждали структуру базы знаний вместе"
        )
        XCTAssertEqual(TranscriptTitle.tidy("Отчёт по продажам, и"), "Отчёт по продажам")
        XCTAssertEqual(Summarizer.tidy("Разбор документов для"), "Разбор документов", "правило одно на оба заголовка")
    }

    /// Заголовок — не предложение: точка в конце короткой записи ему не нужна.
    func testShortTranscriptTitleHasNoTrailingPeriod() {
        XCTAssertEqual(TranscriptTitle.title(from: "**[0:00–0:02]** Коротко."), "Коротко")
        XCTAssertEqual(TranscriptTitle.title(from: "Что дальше по проекту?"), "Что дальше по проекту")
    }
}

/// Разбор файла расшифровки для экрана записи: по тапу на реплику плеер должен
/// перематываться именно туда.
final class TranscriptDocumentTests: XCTestCase {
    func testLinesCarryTheirTimecodes() {
        let document = TranscriptDocument.parse("""
        # Запись

        _Расшифровано: Gemini · gemini-3.5-transcribe_

        **[0:00–0:34]** Первая реплика.
        **[1:40–2:05]** Вторая реплика.

        > Пропуск 2:05–3:00: модель не вернула текст.
        """)

        XCTAssertEqual(document.lines.count, 2)
        XCTAssertEqual(document.lines.first?.start, 0)
        XCTAssertEqual(document.lines.last?.start, 100)
        XCTAssertEqual(document.lines.last?.text, "Вторая реплика.")
        XCTAssertEqual(document.engine, "Gemini · gemini-3.5-transcribe")
        XCTAssertEqual(document.warnings.count, 1)
    }

    /// Конец диапазона экрану не нужен — перематывают по началу, — но он есть
    /// в файле, и экспорт без него отдал бы наружу меньше, чем лежит на диске.
    func testLinesKeepTheEndOfTheRange() {
        let document = TranscriptDocument.parse("""
        **[0:00–0:34]** Первая реплика.
        **[1:05:20–1:05:44]** Через час.
        **[2:10]** Без диапазона.
        """)

        XCTAssertEqual(document.lines.first?.end, 34)
        XCTAssertEqual(document.lines[1].start, 3920)
        XCTAssertEqual(document.lines[1].end, 3944)
        // Конца не было — придумывать его нечем.
        XCTAssertNil(document.lines.last?.end)
    }

    func testTextWithoutTimecodesStillReadable() {
        let document = TranscriptDocument.parse("# Запись\n\nПросто текст без таймкодов.\n")

        XCTAssertEqual(document.lines.count, 1)
        XCTAssertNil(document.lines.first?.start)
        XCTAssertEqual(document.plain, "Просто текст без таймкодов.")
    }

    /// Метка говорящего уходит из текста в своё поле: на экране она рисуется
    /// цветным кружком. В экспорте (`plain`) метка возвращается в текст.
    /// Движок без таймкодов отдаёт расшифровку одним куском. Читать такую
    /// простыню невозможно, а зацепиться не за что — таймкодов-то нет.
    func testLongTextWithoutTimecodesIsSplitIntoParagraphs() {
        let sentence = "Обсудили интеграцию с внешним сервисом и договорились о сроках. "
        let markdown = String(repeating: sentence, count: 20)

        let document = TranscriptDocument.parse(markdown)

        XCTAssertGreaterThan(document.lines.count, 1, "сплошной простыни быть не должно")
        XCTAssertFalse(document.hasTimecodes)
        for line in document.lines {
            XCTAssertLessThanOrEqual(line.text.count, TranscriptDocument.paragraphLimit + sentence.count)
        }
    }

    /// Резать надо по границам предложений: обрыв посреди фразы читается как
    /// ошибка распознавания, хотя это всего лишь вёрстка.
    func testParagraphsBreakOnSentences() {
        let text = String(repeating: "Раз два три четыре пять. ", count: 40)

        let blocks = TranscriptDocument.paragraphs(of: text)

        XCTAssertGreaterThan(blocks.count, 1)
        for block in blocks {
            XCTAssertTrue(block.hasSuffix("."), "абзац кончается на границе предложения: \(block.suffix(30))")
        }
    }

    func testShortTextIsLeftAlone() {
        XCTAssertEqual(TranscriptDocument.paragraphs(of: "Короткая реплика."), ["Короткая реплика."])
    }

    /// Реплику с меткой говорящего резать нельзя: разрез посреди чужих слов
    /// превратил бы одного человека в двух.
    func testSpeakerLineIsNeverSplit() {
        let long = "S1: " + String(repeating: "Длинная мысль без пауз и остановок. ", count: 30)

        let document = TranscriptDocument.parse(long)

        XCTAssertEqual(document.lines.count, 1)
        XCTAssertEqual(document.lines.first?.speaker, "S1")
    }

    /// Реплика со временем тоже бывает стеной: у Gemini в «Точности» одна
    /// реплика — это целая отправленная часть, десять минут речи. Абзацы ей
    /// нужны ровно так же, как реплике без времени.
    func testStampedReplyIsSplitIntoParagraphsToo() {
        let sentence = "Обсудили оценочную систему и структуру курса на ближайший модуль. "
        let markdown = "**[кусок 0:00–10:00]** " + String(repeating: sentence, count: 20)

        let document = TranscriptDocument.parse(markdown)

        XCTAssertGreaterThan(document.lines.count, 1, "десять минут одной строкой — это стена")
        XCTAssertTrue(document.hasTimecodes, "время реплики никуда не делось")
        for line in document.lines {
            XCTAssertLessThanOrEqual(line.text.count, TranscriptDocument.paragraphLimit + sentence.count)
        }
    }

    /// Время принадлежит реплике целиком. Раздать его абзацам по доле знаков
    /// технически можно, и это было бы выдуманной секундой: речь идёт
    /// неравномерно, а подпись под абзацем читается как факт.
    func testOnlyTheFirstParagraphKeepsTheTime() {
        let markdown = "**[кусок 5:00–15:00]** " + String(repeating: "Раз два три четыре пять. ", count: 40)

        let document = TranscriptDocument.parse(markdown)
        let stamped = document.lines.filter { $0.start != nil }

        XCTAssertGreaterThan(document.lines.count, 1)
        XCTAssertEqual(stamped.count, 1, "время стоит ровно у одного абзаца")
        XCTAssertEqual(document.lines.first?.start, 300, "и это первый абзац реплики")
        XCTAssertTrue(document.lines.allSatisfy(\.isApproximate), "пометка «кусок» относится ко всей реплике")
    }

    /// Длительность записи меряют по последнему таймкоду. Брать её из последней
    /// строки нельзя: реплика режется на абзацы, и последняя строка почти всегда
    /// без времени — экспорт (`TranscriptExport`) остался бы без длительности.
    func testLastStampIgnoresParagraphsWithoutTime() {
        let markdown = "**[кусок 5:00–15:00]** " + String(repeating: "Раз два три четыре пять. ", count: 40)

        let document = TranscriptDocument.parse(markdown)

        XCTAssertNil(document.lines.last?.start, "последняя строка — абзац без времени")
        XCTAssertEqual(document.lastStamp, 300, "а длительность берётся по настоящему таймкоду")
    }

    func testTimecodedTranscriptReportsItHasThem() {
        let document = TranscriptDocument.parse("**[0:00–0:12]** Начали с бюджета.")

        XCTAssertTrue(document.hasTimecodes)
    }

    func testSpeakerMarkBecomesItsOwnField() {
        let document = TranscriptDocument.parse("""
        # Запись

        **[0:00–0:01]** S1: Здравствуйте.

        Г2: Согласен.
        """)

        XCTAssertEqual(document.lines.first?.speaker, "S1")
        XCTAssertEqual(document.lines.first?.text, "Здравствуйте.")
        XCTAssertEqual(document.lines.last?.speaker, "S2", "старая метка «Г» читается и показывается латиницей")
        XCTAssertEqual(document.lines.last?.text, "Согласен.")
        XCTAssertTrue(document.plain.contains("S1: Здравствуйте."), "в экспорте метка на месте")
        XCTAssertFalse(document.plainText.contains("S1"), "модели заголовков метки не нужны")
    }
}

/// Темы: плоский список в метаданных, автопредложение по словам из расшифровки.
@MainActor
final class TopicStoreTests: XCTestCase {
    private var url: URL!
    private var store: TopicStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "topics-\(UUID().uuidString).json")
        store = TopicStore(url: url)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    func testAssignmentSurvivesReload() {
        store.assign("Работа", to: "Recordings/a.m4a")

        let reopened = TopicStore(url: url)

        XCTAssertEqual(reopened.topic(for: "Recordings/a.m4a"), "Работа")
        XCTAssertEqual(reopened.topics, ["Работа"])
    }

    func testRenameKeepsRecordsAttached() {
        store.assign("BIOS", to: "Recordings/a.m4a")
        store.rename("BIOS", to: "Прошивка")

        XCTAssertEqual(store.topic(for: "Recordings/a.m4a"), "Прошивка")
        XCTAssertFalse(store.topics.contains("BIOS"))
    }

    func testSameTopicIsNotDuplicatedByCase() {
        store.add("Работа")
        store.add("работа")

        XCTAssertEqual(store.topics, ["Работа"])
    }

    /// Расшифровка уже есть — тему можно предложить, а человек только подтверждает.
    func testSuggestionComesFromTextAndVocabulary() {
        store.add("BIOS")
        store.add("Работа")

        XCTAssertEqual(store.suggestion(for: "Надо не забыть про BIOS и Hermes"), "BIOS")
        XCTAssertEqual(
            store.suggestion(for: "Обсудили mcp и почту", vocabulary: ["MCP"]),
            nil,
            "тема с таким названием не создана — предлагать нечего"
        )

        store.add("MCP")
        XCTAssertEqual(store.suggestion(for: "Обсудили mcp и почту", vocabulary: ["MCP"]), "MCP")
        XCTAssertNil(store.suggestion(for: ""))
    }

    func testForgettingRecordRemovesOnlyIt() {
        store.assign("Работа", to: "Recordings/a.m4a")
        store.assign("Работа", to: "Recordings/b.m4a")

        store.forget("Recordings/a.m4a")

        XCTAssertNil(store.topic(for: "Recordings/a.m4a"))
        XCTAssertEqual(store.topic(for: "Recordings/b.m4a"), "Работа")
        XCTAssertEqual(store.count(of: "Работа"), 1)
    }
}

/// Отправка в Obsidian: попасть в его хранилище можно только его же схемой.
final class ObsidianExportTests: XCTestCase {
    func testURLCarriesVaultTitleAndText() throws {
        let url = try XCTUnwrap(ObsidianExport.url(title: "Планы по RAG", text: "Текст расшифровки", vault: "Brain"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        XCTAssertEqual(url.scheme, "obsidian")
        XCTAssertEqual(url.host, "new")
        XCTAssertEqual(items.first { $0.name == "vault" }?.value, "Brain")
        XCTAssertEqual(items.first { $0.name == "name" }?.value, "Планы по RAG")
        XCTAssertEqual(items.first { $0.name == "content" }?.value, "Текст расшифровки")
    }

    func testWithoutVaultThereIsNoURL() {
        XCTAssertNil(ObsidianExport.url(title: "Запись", text: "Текст", vault: ""))
        XCTAssertNil(ObsidianExport.url(title: "Запись", text: "Текст", vault: "   "))
    }

    /// У схемы URL есть предел длины: лучше отдать начало текста, чем ничего.
    func testLongTextIsCut() throws {
        let long = String(repeating: "а", count: ObsidianExport.contentLimit + 500)
        let url = try XCTUnwrap(ObsidianExport.url(title: "Запись", text: long, vault: "Brain"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let content = try XCTUnwrap(items.first { $0.name == "content" }?.value)

        XCTAssertEqual(content.count, ObsidianExport.contentLimit)
    }

    /// **Регрессия.** Имя заметки — имя файла в хранилище: «Запись 21:46» с
    /// двоеточием файловая система не примет, а `#`, `|`, `^`, `[[ ]]` ломают ссылки.
    func testNoteNameIsSafeForTheVault() throws {
        let url = try XCTUnwrap(ObsidianExport.url(title: "Запись 21:46", text: "Текст", vault: "Brain"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "name" }?.value, "Запись 21-46")

        XCTAssertEqual(ObsidianExport.noteName(from: "План/факт: #итоги [[черновик]] | 50%% готово?"), "План-факт- итоги черновик 50% готово")
        XCTAssertEqual(ObsidianExport.noteName(from: ".скрытая заметка"), "скрытая заметка")
        XCTAssertEqual(ObsidianExport.noteName(from: " ### "), "Запись", "пустое имя — не имя")
        XCTAssertEqual(ObsidianExport.noteName(from: "Совещание 27.08"), "Совещание 27.08")
        XCTAssertLessThanOrEqual(ObsidianExport.noteName(from: String(repeating: "слово ", count: 100)).count, ObsidianExport.nameLimit)
    }

    /// Какой движок отработал — свойство конкретной расшифровки, и его показывают на
    /// экране записи. Полное имя в файле длинное, а хвост у него повторяет иконку.
    func testEngineIsShownShortWithItsLocality() {
        let local = TranscriptDocument.parse("""
        # Встреча

        _Расшифровано: GigaAM v3 CTC (int8), на этом iPhone_

        Текст.
        """)
        XCTAssertEqual(local.engineShort, "GigaAM v3 CTC (int8)")
        XCTAssertEqual(local.engineStayedOnDevice, true)

        let apple = TranscriptDocument.parse("# З\n\n_Расшифровано: Apple Speech, на устройстве_\n\nТекст.\n")
        XCTAssertEqual(apple.engineShort, "Apple Speech")
        XCTAssertEqual(apple.engineStayedOnDevice, true)

        let cloud = TranscriptDocument.parse("# З\n\n_Расшифровано: Google Gemini API_\n\nТекст.\n")
        XCTAssertEqual(cloud.engineShort, "Google Gemini API")
        XCTAssertEqual(cloud.engineStayedOnDevice, false)

        // Незнакомое имя: иконку не рисуем вовсе. Спутать облако с телефоном значит
        // соврать про то, уходила ли запись наружу.
        let unknown = TranscriptDocument.parse("# З\n\n_Расшифровано: Нечто_\n\nТекст.\n")
        XCTAssertEqual(unknown.engineShort, "Нечто")
        XCTAssertNil(unknown.engineStayedOnDevice)

        XCTAssertNil(TranscriptDocument.parse("# З\n\nТекст.\n").engineShort)
    }


}
