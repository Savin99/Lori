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
    /// без времени — оглавление ассистента осталось бы без длительности.
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
    }    /// Какой движок отработал — свойство конкретной расшифровки, и его показывают на
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
