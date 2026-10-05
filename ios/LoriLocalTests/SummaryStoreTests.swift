import XCTest
@testable import LoriLocal

/// Хранилище заголовков: главное правило — имя, заданное человеком, модель не трогает.
@MainActor
final class SummaryStoreTests: XCTestCase {
    private var url: URL!
    private var store: SummaryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "sum-\(UUID().uuidString).json")
        store = SummaryStore(url: url)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    func testModelSummaryIsStoredAndRead() {
        store.store(title: "Планёрка по скиллам", detail: "Обсудили механику создания.", for: "a.m4a")

        XCTAssertEqual(store.title(for: "a.m4a"), "Планёрка по скиллам")
        XCTAssertEqual(store.detail(for: "a.m4a"), "Обсудили механику создания.")
        XCTAssertFalse(store.needsSummary(for: "a.m4a"), "заголовок уже есть")
    }

    func testImportedFilenameIsVisibleUntilModelReplacesIt() {
        store.setImported(title: "Новая запись 5", for: "Inbox/Новая запись 5.m4a")
        XCTAssertEqual(store.title(for: "Inbox/Новая запись 5.m4a"), "Новая запись 5")
        XCTAssertTrue(store.needsSummary(for: "Inbox/Новая запись 5.m4a"))
        store.store(title: "Подготовка выставки", detail: "Распределили задачи.", for: "Inbox/Новая запись 5.m4a")
        XCTAssertEqual(SummaryStore(url: url).title(for: "Inbox/Новая запись 5.m4a"), "Подготовка выставки")
    }

    func testExplicitRegenerationUnlocksLegacyImportedNameWithoutErasingIt() {
        store.setManual(title: "Новая запись 5", for: "a.m4a")
        store.store(title: "Потерянный заголовок", detail: "Описание уже было.", for: "a.m4a")
        XCTAssertTrue(store.allowGeneratedTitle(for: "a.m4a"))
        XCTAssertEqual(store.title(for: "a.m4a"), "Новая запись 5", "до ответа модели название не пропадает")
        let reopened = SummaryStore(url: url)
        reopened.store(title: "Подготовка выставки", detail: "Распределили задачи.", for: "a.m4a", force: true)
        XCTAssertEqual(reopened.title(for: "a.m4a"), "Подготовка выставки")
    }

    func testRenamingAfterImportStillProtectsManualTitle() {
        store.setImported(title: "Новая запись 5", for: "a.m4a")
        store.setManual(title: "Моё важное интервью", for: "a.m4a")
        store.setImported(title: "Другое имя файла", for: "a.m4a")
        store.store(title: "Название от модели", detail: "Описание", for: "a.m4a", force: true)
        XCTAssertEqual(store.title(for: "a.m4a"), "Моё важное интервью")
    }

    /// Ручное имя приоритетнее: следующая расшифровка не должна его перетирать.
    func testManualTitleSurvivesModel() {
        store.setManual(title: "Важное", for: "a.m4a")

        store.store(title: "Придуманное моделью", detail: "…", for: "a.m4a")

        XCTAssertEqual(store.title(for: "a.m4a"), "Важное")
        XCTAssertFalse(store.needsSummary(for: "a.m4a"))
    }

    /// Переименование файла меняет путь — заголовок должен переехать вместе с ним.
    func testTitleFollowsRenamedFile() {
        store.store(title: "Разбор базы знаний", detail: "…", for: "old.m4a")

        store.move(from: "old.m4a", to: "new.m4a")

        XCTAssertNil(store.title(for: "old.m4a"))
        XCTAssertEqual(store.title(for: "new.m4a"), "Разбор базы знаний")
    }

    func testEntriesSurviveRestart() {
        store.store(title: "Заголовок", detail: "Описание", for: "a.m4a")

        let reopened = SummaryStore(url: url)

        XCTAssertEqual(reopened.title(for: "a.m4a"), "Заголовок")
    }

    func testForgettingRemovesEntry() {
        store.store(title: "Заголовок", detail: "Описание", for: "a.m4a")

        store.forget("a.m4a")

        XCTAssertNil(store.title(for: "a.m4a"))
        XCTAssertTrue(store.needsSummary(for: "a.m4a"))
    }
}
