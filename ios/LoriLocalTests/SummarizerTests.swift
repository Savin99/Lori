import XCTest
@testable import LoriLocal

/// Заголовок и описание от локальной модели. Сеть и веса здесь не нужны:
/// генерация подставляется, проверяется разбор ответа и подготовка текста.
final class SummarizerTests: XCTestCase {
    private func engine(answering answer: String) -> Summarizer {
        Summarizer(
            variant: .light,
            directory: FileManager.default.temporaryDirectory,
            generate: { _, _ in answer }
        )
    }

    /// Разные ответы на первую и вторую попытку.
    private func engine(first: String, then second: String) -> Summarizer {
        let counter = Counter()
        return Summarizer(
            variant: .light,
            directory: FileManager.default.temporaryDirectory,
            generate: { _, _ in counter.next() == 1 ? first : second }
        )
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    func testTitleAndDetailAreTakenFromMarkedLines() async throws {
        let engine = engine(answering: """
        Заголовок: Разбор базы знаний и MCP
        Описание: Обсудили структуру базы знаний, доступ MCP к документам и порядок индексации.
        """)

        let summary = try await engine.summary(of: "Так, идём дальше. База знаний, да?")

        XCTAssertEqual(summary.title, "Разбор базы знаний и MCP")
        XCTAssertTrue(summary.detail.hasPrefix("Обсудили структуру базы знаний"))
    }

    /// Модель любит добавлять рассуждения и разметку — берём помеченные строки.
    func testChatterAroundTheAnswerIsIgnored() async throws {
        let engine = engine(answering: """
        Хорошо, вот что получилось:

        **Заголовок:** «Планёрка по скиллам»
        **Описание:** Договорились о механике создания скиллов через чат и раздел.
        Надеюсь, это подходит!
        """)

        let summary = try await engine.summary(of: "текст")

        XCTAssertEqual(summary.title, "Планёрка по скиллам", "кавычки и звёздочки не часть заголовка")
        XCTAssertFalse(summary.detail.contains("Надеюсь"))
    }

    /// Qwen3 «думает вслух»: рассуждения приходят в теге <think>, и внутри
    /// может встретиться слово «Заголовок». На устройстве из-за этого ответ
    /// не разбирался вовсе.
    func testThinkingBlockIsStripped() async throws {
        let engine = engine(answering: """
        <think>
        Пользователь просит заголовок. Заголовок: наверное, про базу знаний.
        Надо подумать ещё.
        </think>
        Заголовок: База знаний и доступы MCP
        Описание: Обсудили структуру базы и порядок индексации документов.
        """)

        let summary = try await engine.summary(of: "текст")

        XCTAssertEqual(summary.title, "База знаний и доступы MCP", "берём ответ, а не рассуждения")
    }

    /// Рассуждения без закрывающего тега — обрыв по лимиту токенов.
    func testUnclosedThinkingIsDropped() {
        XCTAssertEqual(Summarizer.withoutThoughts("<think>рассуждаю и не закончил"), "")
    }

    /// Живой ответ с телефона: модель повторила шаблон из задания дословно,
    /// и заголовком стало «<о чём разговор, до 60 знаков>».
    func testTemplateEchoIsRejectedAndAskedAgain() async throws {
        let engine = engine(
            first: "Заголовок: <о чём разговор, до 60 знаков>\nОписание: <одно-два предложения>",
            then: "Заголовок: База знаний и доступы\nОписание: Обсудили структуру базы и индексацию."
        )

        let summary = try await engine.summary(of: "текст расшифровки")

        XCTAssertEqual(summary.title, "База знаний и доступы", "второй заход дал настоящий заголовок")
    }

    /// Пример из запроса тоже нельзя принимать за ответ.
    func testBorrowedExampleIsNotATitle() {
        XCTAssertTrue(Summarizer.looksLikeTemplate("<о чём разговор, до 60 знаков>"))
        XCTAssertTrue(Summarizer.looksLikeTemplate("Планёрка по базе знаний"), "это пример из задания")
        XCTAssertFalse(Summarizer.looksLikeTemplate("Разбор структуры документов"))
    }

    /// Если и вторая попытка — шаблон, честно признаём неудачу.
    func testTwoTemplateAnswersFail() async {
        let engine = engine(answering: "Заголовок: <о чём разговор>\nОписание: <текст>")

        do {
            _ = try await engine.summary(of: "текст расшифровки")
            XCTFail("шаблон принимать нельзя")
        } catch {
            XCTAssertEqual(error as? Summarizer.Failure, .emptyAnswer)
        }
    }

    /// Живой ответ с телефона: модель ушла писать документ, и заголовком стало
    /// вступление «Вот обобщённый и структурированный текст вашего…».
    func testPreambleAndMarkdownAreNotTakenAsTitle() async throws {
        let engine = engine(answering: """
        <think>

        </think>

        Вот обобщённый и структурированный текст вашего выступления, который можно \
        использовать для создания презентации, отчёта или другой документации:

        ---

        ### **Обзор системы управления документами и организационной структурой**

        **1. Название документа и существующая база данных**
        """)

        let summary = try await engine.summary(of: "текст")

        XCTAssertEqual(summary.title, "Обзор системы управления документами и организационной…")
        XCTAssertFalse(summary.title.hasPrefix("Вот"), "вступление — не заголовок")
    }

    /// Требование к формату повторяется после текста: одного системного указания
    /// модели не хватило.
    func testPromptRepeatsTheFormatAfterTheTranscript() {
        let prompt = Summarizer.prompt(for: "речь")
        let transcript = try! XCTUnwrap(prompt.range(of: "речь"))
        let format = try! XCTUnwrap(prompt.range(of: "Заголовок:"))
        XCTAssertTrue(transcript.upperBound < format.lowerBound, "формат идёт после расшифровки")
        XCTAssertTrue(prompt.contains("двумя строками"))
    }

    /// Разметки нет вовсе — заголовком становится первая строка, а не отказ.
    func testUnmarkedAnswerStillGivesTitle() async throws {
        let engine = engine(answering: """
        Планёрка по скиллам и MCP
        Договорились о механике создания скиллов через чат.
        """)

        let summary = try await engine.summary(of: "текст")

        XCTAssertEqual(summary.title, "Планёрка по скиллам и MCP")
        XCTAssertEqual(summary.detail, "Договорились о механике создания скиллов через чат.")
    }

    /// Рассуждать модели не запрещаем: на заголовках это помогает.
    func testPromptDoesNotForbidThinking() {
        XCTAssertFalse(Summarizer.prompt(for: "текст").contains("/no_think"))
    }

    /// Генерация обрывается, как только ответ дописан: досчитывать потолок
    /// в 1200 токенов ради двух строк — лишние полминуты ожидания.
    func testCompletionIsDetectedAfterBothLines() {
        let thinking = "<think>Думаю, о чём это</think>\nЗаголовок: База знаний\n"
        XCTAssertFalse(Summarizer.isComplete(thinking), "описания ещё нет")

        let whole = thinking + "Описание: Обсудили структуру и индексацию.\n"
        XCTAssertTrue(Summarizer.isComplete(whole))
    }

    /// Пока модель размышляет, ответа нет — обрывать нельзя.
    func testThinkingAloneIsNotComplete() {
        let mid = "<think>Заголовок должен быть про базу знаний. Описание тоже.\n"
        XCTAssertFalse(Summarizer.isComplete(mid), "внутри размышлений ответа ещё нет")
    }

    func testAnswerWithoutTitleIsRejected() async {
        let engine = engine(answering: "   \n  \n ")

        do {
            _ = try await engine.summary(of: "текст")
            XCTFail("без заголовка ответ принимать нельзя")
        } catch {
            XCTAssertEqual(error as? Summarizer.Failure, .emptyAnswer)
        }
    }

    /// Живой заголовок с телефона: модель написала пересказ, и обрезка оставила
    /// висеть союз — «Обсуждали структуру базы знаний, оргструктуре и…».
    func testLongTitleIsCutAtMeaningBoundary() {
        let sentence = "Обсуждали структуру базы знаний, оргструктуре и регламентам подразделений"

        let cut = Summarizer.clamp(sentence, to: 60)

        XCTAssertEqual(cut, "Обсуждали структуру базы знаний", "обрыв по запятой, а не посреди перечисления")
        XCTAssertFalse(cut.hasSuffix("…"), "законченная фраза многоточия не требует")
    }

    /// Союз или предлог в конце названия выглядит обрубком.
    func testDanglingConjunctionIsDropped() {
        XCTAssertEqual(Summarizer.tidy("Планы по базе знаний и"), "Планы по базе знаний")
        XCTAssertEqual(Summarizer.tidy("Разбор документов для"), "Разбор документов")
        XCTAssertEqual(Summarizer.tidy("Итоги встречи"), "Итоги встречи")
    }

    /// В запросе прямо сказано, что нужно название, а не пересказ.
    func testPromptAsksForANameNotASentence() {
        let prompt = Summarizer.prompt(for: "речь")
        XCTAssertTrue(prompt.contains("название, а не пересказ"))
        XCTAssertTrue(prompt.contains("без глаголов"))
    }

    /// Длину режем по границе слова: половина слова выглядит поломкой.
    func testLongTitleIsCutAtWordBoundary() {
        let long = "Очень длинное обсуждение структуры базы знаний доступов и планов на квартал"

        let cut = Summarizer.clamp(long, to: 40)

        XCTAssertLessThanOrEqual(cut.count, 41)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertFalse(cut.dropLast().hasSuffix(" "), "перед многоточием не должно быть пробела")
        XCTAssertTrue(long.hasPrefix(String(cut.dropLast())))
    }

    /// В модель уходит начало и конец: середина часовой встречи заголовку не нужна.
    func testLongTranscriptIsShortenedFromBothEnds() {
        let head = String(repeating: "а", count: Summarizer.headCharacters)
        let middle = String(repeating: "б", count: 50_000)
        let tail = String(repeating: "в", count: Summarizer.tailCharacters)

        let excerpt = Summarizer.excerpt(from: head + middle + tail)

        XCTAssertTrue(excerpt.hasPrefix("а"))
        XCTAssertTrue(excerpt.hasSuffix("в"))
        XCTAssertFalse(excerpt.contains(String(repeating: "б", count: 100)), "середина отброшена")
        XCTAssertLessThan(excerpt.count, Summarizer.headCharacters + Summarizer.tailCharacters + 10)
    }

    /// Короткая расшифровка уходит целиком.
    func testShortTranscriptIsKeptWhole() {
        XCTAssertEqual(Summarizer.excerpt(from: "  Короткая заметка.  "), "Короткая заметка.")
    }
}
