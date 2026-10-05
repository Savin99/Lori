import XCTest
@testable import LoriLocal

/// Оглавление охвата: то единственное, из чего модель узнаёт, что запись
/// вообще существует. Ни сети, ни рабочей папки — чистые функции.
final class AssistantOutlineTests: XCTestCase {
    private func source(_ title: String, days: Int, markdown: String, detail: String? = nil, topic: String? = nil) -> AssistantSource {
        AssistantSource(
            path: "Recordings/\(title).m4a",
            title: title,
            date: Date(timeIntervalSince1970: 1_756_000_000 - Double(days) * 86_400),
            markdown: markdown,
            detail: detail,
            topic: topic
        )
    }

    private func records(_ sources: [AssistantSource], included: Set<String> = []) -> [ContextSnapshot.Record] {
        AssistantOutline.records(
            for: sources,
            documents: sources.map { TranscriptDocument.parse($0.markdown) },
            included: included
        )
    }

    // MARK: - Строка записи

    func testLineCarriesNumberTitleTopicAndDuration() {
        let list = records(
            [source("Планёрка", days: 0, markdown: "**[0:00–0:12]** Начали.\n**[2:05–2:20]** Закончили.", topic: "Работа")],
            included: ["Recordings/Планёрка.m4a"]
        )
        let line = AssistantOutline.line(of: list[0])

        XCTAssertTrue(line.hasPrefix("[1] "), "номер записи — то, чем модель сошлётся: «\(line)»")
        XCTAssertTrue(line.contains("Планёрка"))
        XCTAssertTrue(line.contains("тема: Работа"))
        XCTAssertTrue(line.contains("2:05"), "длительность берётся из последнего таймкода: «\(line)»")
        XCTAssertTrue(line.contains("текст ниже"))
    }

    /// Модель обязана отличать «про это не говорили» от «текст этой записи тебе
    /// не показали»: иначе «в записях этого нет» — не вывод, а незнание.
    func testRecordWithoutTextSaysSo() {
        let list = records([source("Найм", days: 1, markdown: "**[0:00–0:10]** Оффер.")])

        XCTAssertFalse(list[0].included)
        XCTAssertTrue(AssistantOutline.line(of: list[0]).contains("текста нет"))
    }

    /// Своего описания нет — берём начало расшифровки. Без него строка
    /// оглавления сообщает только название, а его человек и придумал.
    func testDetailFallsBackToTheStartOfTheTranscript() {
        let list = records([source("Без описания", days: 0, markdown: "**[0:00–0:10]** Обсуждали интеграцию с MCP.")])

        XCTAssertEqual(list[0].detail, "Обсуждали интеграцию с MCP.")
    }

    func testOwnDetailWins() {
        let list = records([
            source("Своё", days: 0, markdown: "**[0:00–0:10]** Обсуждали интеграцию.", detail: "Договорились про скиллы"),
        ])

        XCTAssertEqual(list[0].detail, "Договорились про скиллы")
    }

    func testRecordWithoutTimecodesHasNoDuration() {
        let list = records([source("Без времени", days: 0, markdown: "Просто текст без таймкодов.")])

        XCTAssertNil(list[0].seconds)
        XCTAssertFalse(AssistantOutline.line(of: list[0]).contains("0:00"))
    }

    // MARK: - Бюджет

    private var many: [AssistantSource] {
        (1...40).map { index in
            source(
                "Встреча \(index)",
                days: index,
                markdown: "**[0:00–0:10]** " + String(repeating: "Довольно длинный разговор про поставки. ", count: 12)
            )
        }
    }

    func testEveryRecordFitsWhenBudgetAllows() {
        let text = AssistantOutline.text(records(many), scopeTitle: "Все")

        for index in 1...40 {
            XCTAssertTrue(text.contains("Встреча \(index)"), "запись \(index) пропала из оглавления")
        }
    }

    /// Не влезло — сначала уходят описания, а список записей остаётся целым:
    /// список важнее подробностей, по нему модель и просит текст.
    func testDetailsGoBeforeRecords() {
        let text = AssistantOutline.text(records(many), scopeTitle: "Все", budget: 2_500)

        XCTAssertLessThanOrEqual(text.count, 2_500)
        XCTAssertFalse(text.contains("Довольно длинный разговор"), "описания обязаны уйти первыми")
        for index in 1...40 {
            XCTAssertTrue(text.contains("Встреча \(index)"), "запись \(index) пропала раньше описаний")
        }
    }

    /// Совсем не влезло — уходят самые старые, и об этом написано прямо.
    /// Молча укоротить список нельзя: модель решит, что записи и не было.
    func testTrimmedOutlineSaysHowManyAreMissing() {
        let text = AssistantOutline.text(records(many), scopeTitle: "Все", budget: 600)

        XCTAssertLessThanOrEqual(text.count, 600)
        XCTAssertTrue(text.contains("Встреча 1"), "свежие записи остаются")
        XCTAssertFalse(text.contains("Встреча 40"), "самые старые уходят первыми")
        XCTAssertTrue(text.contains("не поместились"), "об урезанном оглавлении надо сказать: «\(text)»")
    }

    func testEmptyScopeGivesEmptyOutline() {
        XCTAssertTrue(AssistantOutline.text([], scopeTitle: "Все").isEmpty)
    }

    // MARK: - Промпт

    /// Многострочные литералы с отступом уже однажды протащили дорожку пробелов
    /// в интерфейс. В промпте она не видна вовсе, а токены стоит беречь.
    func testInstructionsHaveNoDoubleSpaces() {
        XCTAssertFalse(AssistantService.instructions.contains("  "), AssistantService.instructions)
    }

    /// Промпт обязан объяснить устройство контекста: без этого «в записях этого
    /// нет» звучит как факт про архив, хотя это может быть промах отбора.
    func testInstructionsExplainThatTextsArePartial() {
        let text = AssistantService.instructions

        XCTAssertTrue(text.contains("оглавление"))
        XCTAssertTrue(text.contains("не у всех"))
    }
}
