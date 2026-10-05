import XCTest
@testable import LoriLocal

/// Тред и его контекст. Проверяется главным образом то, ради чего он вообще
/// устроен именно так: замороженный префикс и честная история.
@MainActor
final class AssistantThreadStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appending(path: "thread-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func context(_ title: String = "Все", text: String = "0| Бюджет согласовали.") -> ContextSnapshot {
        ContextSnapshot(
            scopeTitle: title,
            records: [
                .init(
                    number: 1,
                    path: "Recordings/Планёрка.m4a",
                    title: "Планёрка",
                    date: Date(timeIntervalSince1970: 1_756_000_000),
                    topic: nil,
                    detail: nil,
                    characters: text.count,
                    seconds: 60,
                    included: true
                ),
            ],
            pieces: [.init(record: 1, start: 0, end: 60, starts: [0], text: text)],
            characters: text.count,
            whole: true
        )
    }

    func testThreadSurvivesRestart() {
        let store = AssistantThreadStore(url: url)
        store.start(with: context())
        store.append(ThreadMessage(role: .question, text: "что с бюджетом?"))
        store.append(ThreadMessage(role: .answer, text: "Согласовали [1@0]."))

        let restarted = AssistantThreadStore(url: url)

        XCTAssertEqual(restarted.thread?.messages.count, 2)
        XCTAssertEqual(restarted.thread?.messages.first?.text, "что с бюджетом?")
        XCTAssertEqual(restarted.thread?.context.scopeTitle, "Все")
    }

    /// Ссылки — часть ответа: без них вернувшийся к вчерашней ветке человек
    /// увидит текст, но не сможет открыть запись, о которой он.
    func testCitationsSurviveRestartToo() {
        let store = AssistantThreadStore(url: url)
        store.start(with: context())
        store.append(ThreadMessage(
            role: .answer,
            text: "Согласовали [1@38].",
            citations: [.init(number: 1, path: "Recordings/Планёрка.m4a", title: "Планёрка", start: 38)]
        ))

        let restarted = AssistantThreadStore(url: url)

        XCTAssertEqual(restarted.thread?.messages.first?.citations.first?.start, 38)
    }

    /// Вопрос ушёл, ответ не пришёл — вопрос не должен остаться висеть в ленте.
    func testFailedQuestionIsTakenBack() {
        let store = AssistantThreadStore(url: url)
        store.start(with: context())
        store.append(ThreadMessage(role: .question, text: "вопрос"))

        store.removeLastQuestion()

        XCTAssertEqual(store.thread?.messages.count, 0)
    }

    func testAnswerIsNeverTakenBackByMistake() {
        let store = AssistantThreadStore(url: url)
        store.start(with: context())
        store.append(ThreadMessage(role: .question, text: "вопрос"))
        store.append(ThreadMessage(role: .answer, text: "ответ"))

        store.removeLastQuestion()

        XCTAssertEqual(store.thread?.messages.count, 2, "снимается только висящий вопрос")
    }

    func testNewConversationForgetsTheOldOne() {
        let store = AssistantThreadStore(url: url)
        store.start(with: context())
        store.append(ThreadMessage(role: .question, text: "вопрос"))

        store.forget()

        XCTAssertNil(store.thread)
        XCTAssertNil(AssistantThreadStore(url: url).thread, "с диска тоже")
    }

    /// Пересбор контекста меняет префикс, но история разговора остаётся.
    func testRebuildingContextKeepsTheConversation() {
        let store = AssistantThreadStore(url: url)
        store.start(with: context())
        store.append(ThreadMessage(role: .question, text: "вопрос"))

        store.replaceContext(with: context("Работа", text: "0| Другой текст."))

        XCTAssertEqual(store.thread?.messages.count, 1)
        XCTAssertEqual(store.thread?.context.scopeTitle, "Работа")
    }
}

final class ContextSnapshotTests: XCTestCase {
    private func snapshot(text: String) -> ContextSnapshot {
        ContextSnapshot(
            scopeTitle: "Все",
            records: [
                .init(
                    number: 1,
                    path: "a.m4a",
                    title: "Раз",
                    date: Date(timeIntervalSince1970: 1_756_000_000),
                    topic: nil,
                    detail: nil,
                    characters: text.count,
                    seconds: 10,
                    included: true
                ),
            ],
            pieces: [.init(record: 1, start: 0, end: 10, starts: [0], text: text)],
            characters: text.count,
            whole: true
        )
    }

    /// Тот же контекст — тот же ключ: иначе сервис не узнает ветку и посчитает
    /// префикс заново, а это и есть та цена, которой всё избегается.
    func testSameContextGivesTheSameKey() {
        XCTAssertEqual(snapshot(text: "0| текст").cacheKey, snapshot(text: "0| текст").cacheKey)
    }

    func testDifferentContextGivesADifferentKey() {
        XCTAssertNotEqual(snapshot(text: "0| текст").cacheKey, snapshot(text: "0| другой").cacheKey)
    }

    // MARK: - Шапка

    private func snapshot(records: Int, included: Int, characters: Int, whole: Bool) -> ContextSnapshot {
        ContextSnapshot(
            scopeTitle: "Все",
            records: (1...records).map { number in
                .init(
                    number: number,
                    path: "\(number).m4a",
                    title: "Запись \(number)",
                    date: Date(timeIntervalSince1970: 1_756_000_000),
                    topic: nil,
                    detail: nil,
                    characters: 100,
                    seconds: 60,
                    included: number <= included
                )
            },
            pieces: [],
            characters: characters,
            whole: whole
        )
    }

    /// Шапка говорит, чем ассистент располагает. «49 кусков не поместилось»
    /// сообщало ровно тот же факт, но читалось как «приложение не справилось».
    func testWholeScopeHeadlineCountsEverything() {
        let context = snapshot(records: 14, included: 14, characters: 76_000, whole: true)

        XCTAssertEqual(context.headline, "Все 14 записей целиком · 76 тыс. знаков")
        XCTAssertNil(context.note, "терять нечего — и говорить не о чем")
    }

    func testSingleRecordHeadlineDoesNotCount() {
        let context = snapshot(records: 1, included: 1, characters: 12_000, whole: true)

        XCTAssertEqual(context.headline, "Запись целиком · 12 тыс. знаков")
    }

    func testPartialHeadlineSaysWhatGotIn() {
        let context = snapshot(records: 14, included: 6, characters: 84_000, whole: false)

        XCTAssertEqual(context.headline, "6 записей из 14 · 84 тыс. знаков")
        XCTAssertEqual(context.note, "Остальные записи модель видит в оглавлении и может их назвать")
    }

    func testShortContextKeepsExactCharacters() {
        let context = snapshot(records: 1, included: 1, characters: 420, whole: true)

        XCTAssertEqual(context.headline, "Запись целиком · 420 знаков")
    }
}
