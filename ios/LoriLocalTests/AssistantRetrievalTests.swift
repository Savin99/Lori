import XCTest
@testable import LoriLocal

/// Отбор кусков под вопрос: ни сети, ни файлов — чистые функции.
final class AssistantRetrievalTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.vocabularyKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.vocabularyKey)
    }

    private func source(_ title: String, markdown: String, days: Int = 0) -> AssistantSource {
        AssistantSource(
            path: "Recordings/\(title).m4a",
            title: title,
            date: Date(timeIntervalSince1970: 1_756_000_000 - Double(days) * 86_400),
            markdown: markdown
        )
    }

    /// Много одинаковых строк: удобно набирать объём, не задевая слова вопроса.
    private func filler(_ lines: Int) -> String {
        (1...lines)
            .map { "Погода сегодня ясная, ветер слабый, обсуждать особо нечего, строка номер \($0)." }
            .joined(separator: "\n")
    }

    // MARK: - Одна запись

    /// Помещается — отдаём целиком: отбор на одной записи только мешает,
    /// модель сама найдёт нужное место.
    func testSmallSelectionGoesWholeWithoutRanking() {
        let one = source("Планёрка", markdown: filler(6))
        let selection = AssistantRetrieval.select(question: "что решили по договору?", sources: [one])

        XCTAssertTrue(selection.whole, "при полном тексте отбирать нечего")
        XCTAssertEqual(
            selection.chunks.map(\.text).joined(separator: "\n").split(separator: "\n").count,
            6,
            "ни одна строка не должна потеряться"
        )
    }

    /// Якорь ссылки — время первой реплики куска. Без него `[1]` некуда вести.
    func testChunkKeepsStartOfItsFirstLine() {
        let markdown = """
        # Встреча
        _Расшифровано: GigaAM v3_
        > Похоже на пропуск 0:10–0:20: в ответе сервиса нет текста.
        **[0:00–0:12]** Начали с бюджета.
        **[1:05–1:20]** Потом перешли к найму.
        """
        let chunks = AssistantRetrieval.chunks(of: source("Встреча", markdown: markdown), index: 0)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].start, 0)
        XCTAssertEqual(
            chunks[0].text,
            "0| Начали с бюджета.\n65| Потом перешли к найму.",
            "секунда в начале строки — то, что модель вернёт в ссылке"
        )
        XCTAssertEqual(chunks[0].end, 65, "конец куска нужен, чтобы проверить секунду из ответа")
        XCTAssertEqual(chunks[0].starts, [0, 65], "начала строк — то, к чему притягивается секунда из ответа")
        XCTAssertFalse(chunks[0].text.contains("Расшифровано"), "служебные строки в контекст не идут")
        XCTAssertFalse(chunks[0].text.contains("пропуск"), "предупреждения файла — не речь")
    }

    /// Второй кусок начинается со своего времени, а не с нуля.
    func testSecondChunkStartsAtItsOwnTime() {
        let head = (1...30).map { "**[0:\(String(format: "%02d", $0 % 60))–0:59]** Строка про погоду номер \($0), довольно длинная, чтобы набрать объём." }
        let tail = "**[9:30–9:40]** Последняя реплика встречи."
        let markdown = (head + [tail]).joined(separator: "\n")
        let chunks = AssistantRetrieval.chunks(of: source("Долгая", markdown: markdown), index: 0, target: 600)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks[0].position, 0)
        XCTAssertEqual(chunks[1].position, 1)
        XCTAssertNotNil(chunks[1].start)
        XCTAssertEqual(chunks.last?.text.hasSuffix("Последняя реплика встречи."), true)
    }

    // MARK: - Архив

    /// Не помещается — куски со словами вопроса берём первыми, остатком бюджета
    /// добираем соседние. Раньше в контекст шли **только** совпавшие, и бюджет
    /// оставался недобранным втрое: 14 тысяч знаков из сорока.
    func testRelevantChunkWinsAndBudgetIsFilled() {
        let noise = source("Погода", markdown: filler(40))
        let wanted = source("Подряд", markdown: filler(20) + "\nРешили подписать договор с подрядчиком в пятницу.")
        let selection = AssistantRetrieval.select(
            question: "что решили по договору с подрядчиком?",
            sources: [noise, wanted],
            budget: 4_000
        )

        XCTAssertFalse(selection.whole)
        XCTAssertLessThanOrEqual(selection.usedCharacters, 4_000, "бюджет не должен превышаться")
        XCTAssertTrue(
            selection.chunks.contains { $0.text.contains("подрядчиком") },
            "кусок со словами вопроса обязан попасть в контекст"
        )
        XCTAssertGreaterThan(
            selection.usedCharacters,
            3_000,
            "оплаченный, но пустой контекст — это молча выброшенные знаки"
        )
    }

    /// Разговор режется по объёму, а не по смыслу: упоминание оказывается в
    /// одном куске, а разговор о нём — в следующем. Отсюда и «есть только
    /// упоминание, больше ничего».
    func testNeighboursOfAMatchComeAlong() {
        let lines = (1...60).map { index -> String in
            index == 30
                ? "Про Думатель рассказывали отдельно и довольно долго, вот эта самая строка."
                : "Погода сегодня ясная, ветер слабый, строка номер \(index) для объёма."
        }
        let selection = AssistantRetrieval.select(
            question: "что говорили про Думатель?",
            sources: [source("Долгая", markdown: lines.joined(separator: "\n"))],
            budget: 3_000
        )

        let positions = Set(selection.chunks.map(\.position))
        guard let match = selection.chunks.first(where: { $0.text.contains("Думатель") })?.position else {
            return XCTFail("кусок с упоминанием обязан попасть в контекст")
        }
        XCTAssertTrue(
            positions.contains(match + 1) || positions.contains(match - 1),
            "сосед куска с упоминанием обязан прийти вместе с ним: \(positions.sorted())"
        )
    }

    /// Русский склоняет всё подряд: «договор» в вопросе обязан найти «договорами».
    func testInflectedWordsStillMatch() {
        let wanted = source("Договоры", markdown: filler(20) + "\nЗанимались договорами и сроками поставки.")
        let selection = AssistantRetrieval.select(
            question: "что там с договором?",
            sources: [source("Шум", markdown: filler(40)), wanted],
            budget: 2_000
        )

        XCTAssertTrue(selection.chunks.contains { $0.text.contains("договорами") })
    }

    /// Слово из словаря владельца весит вдвое: обычно это и есть название темы.
    func testVocabularyTermOutranksAPlainWord() {
        let plain = source("Обычная", markdown: "Обсудили сроки поставки и поставщиков.")
        let special = source("Своя", markdown: "Обсудили Думатель и его роль.")
        let selection = AssistantRetrieval.select(
            question: "Думатель и сроки",
            sources: [plain, special],
            budget: 40,
            vocabulary: ["Думатель"]
        )

        XCTAssertEqual(selection.chunks.count, 1, "в такой бюджет влезает только один кусок")
        XCTAssertTrue(selection.chunks[0].text.contains("Думатель"))
    }

    /// Ни одно слово вопроса не встретилось — отбирать не по чему. Тогда берём
    /// начало списка: интерфейс отдаёт записи от новых к старым.
    func testWithoutAnyMatchSelectionIsByRecency() {
        let selection = AssistantRetrieval.select(
            question: "квартальная отчётность акционерам",
            sources: [source("Свежая", markdown: filler(30)), source("Старая", markdown: filler(30), days: 5)],
            budget: 1_500
        )

        XCTAssertFalse(selection.whole)
        XCTAssertFalse(selection.chunks.isEmpty)
        XCTAssertEqual(selection.chunks.first?.sourceIndex, 0, "первой идёт самая свежая запись")
    }

    /// Порядок чтения возвращается: подряд идущие куски одной записи модель
    /// понимает как разговор, а перемешанные по весу — как обрывки.
    func testSelectedChunksKeepReadingOrder() {
        let text = (1...30).map { "Строка про договор номер \($0), нужная для объёма контекста." }.joined(separator: "\n")
        let selection = AssistantRetrieval.select(
            question: "договор",
            sources: [source("Первая", markdown: text), source("Вторая", markdown: text)],
            budget: 3_000
        )

        var previous = (source: -1, position: -1)
        for chunk in selection.chunks {
            let current = (source: chunk.sourceIndex, position: chunk.position)
            let ordered = current.source > previous.source
                || (current.source == previous.source && current.position > previous.position)
            XCTAssertTrue(ordered, "куски идут не по порядку: \(previous) → \(current)")
            previous = current
        }
        XCTAssertGreaterThan(selection.chunks.count, 1)
    }

    /// Пустая расшифровка кусков не даёт — иначе в промпт уходили бы дырки.
    func testEmptyTranscriptProducesNoChunks() {
        XCTAssertTrue(AssistantRetrieval.chunks(of: source("Пусто", markdown: "# Пусто\n_Расшифровано: Apple_\n"), index: 0).isEmpty)
    }

    func testStopWordsDoNotBecomeSearchTerms() {
        let terms = AssistantRetrieval.terms(in: "Что это было, когда и как?")
        XCTAssertTrue(terms.isEmpty, "остались слова-паразиты: \(terms)")
    }
}
