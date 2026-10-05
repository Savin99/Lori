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

    // MARK: - Защита ручного имени до ответа модели

    /// **Регрессия.** «Придумать заголовок» снимал защиту ручного имени сразу, до
    /// ответа модели. Модель не ответила — а имя человека уже беззащитно, и
    /// следующий автоматический заголовок молча его заменял.
    func testFailedRegenerationLeavesManualNameProtected() {
        store.setManual(title: "Моё интервью", for: "a.m4a")
        XCTAssertTrue(store.allowGeneratedTitle(for: "a.m4a"))
        // Модель не ответила; потом пришёл обычный автоматический ответ.
        let reopened = SummaryStore(url: url)
        reopened.store(title: "Название от автомата", detail: "Описание", for: "a.m4a")

        XCTAssertEqual(reopened.title(for: "a.m4a"), "Моё интервью")
        XCTAssertEqual(reopened.entry(for: "a.m4a")?.manual, true, "защита осталась и на диске")
        XCTAssertEqual(reopened.detail(for: "a.m4a"), "Описание", "описание при этом пришло")
    }

    /// Новое слово человека отменяет его прежнюю просьбу заменить имя.
    func testRenamingAgainCancelsTheRequestToReplaceTheName() {
        store.setManual(title: "Черновое имя", for: "a.m4a")
        store.allowGeneratedTitle(for: "a.m4a")
        store.setManual(title: "Итоговое имя", for: "a.m4a")

        store.store(title: "Название модели", detail: "Описание", for: "a.m4a", force: true)

        XCTAssertEqual(store.title(for: "a.m4a"), "Итоговое имя")
    }

    // MARK: - Когда модели отвечать заново

    /// **Регрессия.** Признаком «модель уже ответила» служило описание, и запись,
    /// у которой модель вернула пустое описание, запускала модель снова на каждом
    /// возвращении в приложение.
    func testEmptyModelDetailDoesNotAskTheModelAgain() {
        store.store(title: "Подготовка выставки", detail: "", for: "a.m4a")
        XCTAssertFalse(store.needsSummary(for: "a.m4a"))

        store.setManual(title: "Моё имя", for: "b.m4a")
        store.store(title: "Не нужен", detail: "", for: "b.m4a")
        XCTAssertFalse(store.needsSummary(for: "b.m4a"), "и при ручном имени пустой ответ — тоже ответ")
        XCTAssertFalse(SummaryStore(url: url).needsSummary(for: "a.m4a"), "и после перезапуска")
    }

    /// Расшифровку переписали — ответ модели устарел, но остаётся на экране, пока
    /// не придёт новый.
    func testRewrittenTranscriptMakesTheSummaryStaleButVisible() {
        let first = SummaryStore.fingerprint(of: "Обсудили бюджет на квартал.")
        store.store(title: "Бюджет на квартал", detail: "Обсудили бюджет.", for: "a.m4a", source: first)
        XCTAssertTrue(store.isUpToDate("a.m4a", fingerprint: first))
        XCTAssertTrue(
            store.isUpToDate("a.m4a", fingerprint: SummaryStore.fingerprint(of: "Обсудили  бюджет\nна квартал.")),
            "пробелы и переносы — не новый текст"
        )
        XCTAssertFalse(store.isUpToDate("a.m4a", fingerprint: SummaryStore.fingerprint(of: "Совсем другой разговор.")))

        XCTAssertTrue(store.markStale("a.m4a"))
        XCTAssertTrue(store.needsSummary(for: "a.m4a"))
        XCTAssertEqual(store.title(for: "a.m4a"), "Бюджет на квартал", "старый заголовок виден до нового")
        XCTAssertTrue(SummaryStore(url: url).needsSummary(for: "a.m4a"), "пометка переживает перезапуск")

        store.store(title: "Другой разговор", detail: "Новое.", for: "a.m4a", source: SummaryStore.fingerprint(of: "Совсем другой разговор."))
        XCTAssertFalse(store.needsSummary(for: "a.m4a"))
    }

    /// Текст стал коротким: ответ модели снимается, а имя человека и имя файла — нет.
    func testDroppingModelOutputKeepsHumanAndFileNames() {
        store.store(title: "Название модели", detail: "Описание", for: "gen.m4a")
        store.setManual(title: "Моё имя", for: "man.m4a")
        store.store(title: "—", detail: "Описание", for: "man.m4a")
        store.setImported(title: "Совещание 27.08", for: "imp.m4a")

        XCTAssertTrue(store.dropGenerated("gen.m4a"))
        XCTAssertNil(store.entry(for: "gen.m4a"), "заголовок модели ушёл совсем")
        XCTAssertTrue(store.dropGenerated("man.m4a"))
        XCTAssertEqual(store.title(for: "man.m4a"), "Моё имя")
        XCTAssertNil(store.detail(for: "man.m4a"))
        XCTAssertFalse(store.dropGenerated("imp.m4a"), "у имени файла ответа модели нет")
        XCTAssertEqual(store.title(for: "imp.m4a"), "Совещание 27.08")
        XCTAssertFalse(store.dropGenerated("none.m4a"))
        XCTAssertNil(SummaryStore(url: url).entry(for: "gen.m4a"), "и на диске")
    }

    /// При ручном имени устаревшее описание тоже заменяется новым.
    func testStaleDetailIsReplacedUnderManualName() {
        store.setManual(title: "Моё имя", for: "a.m4a")
        store.store(title: "—", detail: "Старое описание.", for: "a.m4a")
        store.markStale("a.m4a")

        store.store(title: "—", detail: "Новое описание.", for: "a.m4a")

        XCTAssertEqual(store.title(for: "a.m4a"), "Моё имя")
        XCTAssertEqual(store.detail(for: "a.m4a"), "Новое описание.")
    }

    // MARK: - Файл

    /// Испорченный файл не сбрасывается молча: копия остаётся рядом.
    func testCorruptFileIsBackedUpBeforeAnythingIsWritten() throws {
        let garbage = Data("{\"a.m4a\": {\"title\": ".utf8)
        try garbage.write(to: url)

        let reopened = SummaryStore(url: url)
        XCTAssertNil(reopened.title(for: "a.m4a"))
        reopened.store(title: "Новый", detail: "Описание", for: "b.m4a")

        let siblings = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil
        )
        let prefix = url.deletingPathExtension().lastPathComponent + ".corrupt-"
        let backups = siblings.filter { $0.lastPathComponent.hasPrefix(prefix) }
        defer { backups.forEach { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertEqual(backups.count, 1, "копия испорченного файла лежит рядом")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first)), garbage)
        XCTAssertEqual(SummaryStore(url: url).title(for: "b.m4a"), "Новый", "дальше хранилище работает")
    }

    /// Файл, который не читается (на телефоне — защита данных до первой
    /// разблокировки), нельзя затирать: в нём все заголовки.
    func testUnreadableFileIsNeverOverwritten() throws {
        store.setManual(title: "Важное имя", for: "a.m4a")
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        guard (try? Data(contentsOf: url)) == nil else {
            throw XCTSkip("файл читается и без прав — проверить отказ здесь нечем")
        }

        let blind = SummaryStore(url: url)
        XCTAssertFalse(blind.store(title: "Заголовок", detail: "Описание", for: "b.m4a"), "писать поверх нельзя")

        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(SummaryStore(url: url).title(for: "a.m4a"), "Важное имя", "прежний файл цел")

        // Файл снова читается — сохранённое раньше и сделанное с запуска сходятся.
        XCTAssertTrue(blind.store(title: "Заголовок", detail: "Описание", for: "b.m4a"))
        let merged = SummaryStore(url: url)
        XCTAssertEqual(merged.title(for: "a.m4a"), "Важное имя")
        XCTAssertEqual(merged.title(for: "b.m4a"), "Заголовок")
    }

    /// **Регрессия.** Пока файл не читался, хранилище не знало о ручном имени, и
    /// первый же ответ модели по той же записи решал защиту по пустой памяти, а
    /// при сведении с файлом затирал имя человека.
    func testUnreadableFileNeverLetsTheModelReplaceAManualTitleOfTheSamePath() throws {
        store.setManual(title: "Важное имя", for: "a.m4a")
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        guard (try? Data(contentsOf: url)) == nil else {
            throw XCTSkip("файл читается и без прав — проверить отказ здесь нечем")
        }

        let blind = SummaryStore(url: url)
        XCTAssertTrue(blind.isUnreadable)
        XCTAssertFalse(blind.store(title: "Ответ модели", detail: "Описание", for: "a.m4a"), "решать по пустой памяти нельзя")
        XCTAssertNil(blind.entry(for: "a.m4a"), "и в памяти не осталось")

        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        // Следующая правка сначала перечитывает файл — и видит ручное имя.
        XCTAssertTrue(blind.store(title: "Ответ модели", detail: "Описание", for: "a.m4a"))
        XCTAssertFalse(blind.isUnreadable)
        let reopened = SummaryStore(url: url)
        XCTAssertEqual(reopened.title(for: "a.m4a"), "Важное имя")
        XCTAssertEqual(reopened.entry(for: "a.m4a")?.manual, true)
        XCTAssertEqual(reopened.detail(for: "a.m4a"), "Описание", "описание модели при этом пришло")
    }

    /// Сведение файла с памятью: новое побеждает, но не-ручная запись ручное имя
    /// из файла не заменяет. Новое ручное имя — заменяет: это последнее слово человека.
    func testMergeNeverLetsANonManualEntryReplaceAManualOne() {
        let manual = SummaryStore.Entry(title: "Важное имя", detail: "", origin: .manual)
        let generated = SummaryStore.Entry(title: "Ответ модели", detail: "Описание", origin: .generated, summarized: true)
        let newer = SummaryStore.Entry(title: "Новое имя", detail: "", origin: .manual)

        let merged = SummaryStore.merge(
            stored: ["a": manual, "b": generated, "c": manual],
            current: ["a": generated, "b": newer, "c": newer, "d": generated]
        )

        XCTAssertEqual(merged["a"], manual, "ответ модели ручное имя не заменяет")
        XCTAssertEqual(merged["b"], newer)
        XCTAssertEqual(merged["c"], newer, "новое ручное имя главнее старого")
        XCTAssertEqual(merged["d"], generated)
    }

    /// Файл старой сборки: были только заголовок, описание и «ручное».
    func testLegacyFileIsUnderstood() throws {
        let legacy = """
        {"a.m4a": {"title": "Новая запись 5", "detail": "", "manual": true},
         "b.m4a": {"title": "Интервью Маши", "detail": "", "manual": true},
         "c.m4a": {"title": "Подготовка выставки", "detail": "Распределили задачи.", "manual": false},
         "d.m4a": {"title": "audio 5 2", "detail": "", "manual": false}}
        """
        try Data(legacy.utf8).write(to: url)

        let reopened = SummaryStore(url: url)

        XCTAssertEqual(reopened.entry(for: "a.m4a")?.origin, .imported, "служебное «ручное» имя — старый импорт")
        XCTAssertTrue(reopened.needsSummary(for: "a.m4a"))
        XCTAssertEqual(reopened.entry(for: "b.m4a")?.origin, .manual)
        XCTAssertTrue(reopened.needsSummary(for: "b.m4a"), "описания ещё нет")
        XCTAssertEqual(reopened.entry(for: "c.m4a")?.origin, .generated)
        XCTAssertFalse(reopened.needsSummary(for: "c.m4a"))
        XCTAssertEqual(reopened.entry(for: "d.m4a")?.origin, .imported)
    }

    /// **Регрессия.** Записи самой Lori импортом не бывали: служебное на вид имя
    /// у них — «Звонок», «12.09», «1:1», «Q3 2026» — набрал человек, и понижать
    /// его до имени файла нельзя. Понижается только принесённая запись.
    func testLegacyManualNamesOfOwnRecordingsStayManual() throws {
        let legacy = """
        {"Recordings/a.m4a": {"title": "Звонок", "detail": "", "manual": true},
         "Recordings/b.m4a": {"title": "12.09", "detail": "", "manual": true},
         "Recordings/c.m4a": {"title": "1:1", "detail": "Описание модели", "manual": true},
         "Recordings/d.m4a": {"title": "Q3 2026", "detail": "", "manual": true},
         "Imported/e.m4a": {"title": "Новая запись 5", "detail": "", "manual": true},
         "Imported/f.m4a": {"title": "Совещание 27.08", "detail": "", "manual": true}}
        """
        try Data(legacy.utf8).write(to: url)

        let reopened = SummaryStore(url: url)

        for path in ["Recordings/a.m4a", "Recordings/b.m4a", "Recordings/c.m4a", "Recordings/d.m4a"] {
            XCTAssertEqual(reopened.entry(for: path)?.origin, .manual, "\(path) — имя от человека")
        }
        XCTAssertFalse(reopened.needsSummary(for: "Recordings/c.m4a"), "описание модели уже было")
        XCTAssertEqual(reopened.entry(for: "Imported/e.m4a")?.origin, .imported, "служебное имя принесённого файла")
        XCTAssertEqual(reopened.entry(for: "Imported/f.m4a")?.origin, .manual)
    }

    /// Старые сборки читают из файла заголовок, описание и «ручное» — эти поля
    /// остаются на месте.
    func testSavedFileStaysReadableForOlderBuilds() throws {
        store.setManual(title: "Моё имя", for: "a.m4a")
        store.store(title: "Заголовок", detail: "Описание", for: "b.m4a")

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: Any]]
        XCTAssertEqual(object?["a.m4a"]?["title"] as? String, "Моё имя")
        XCTAssertEqual(object?["a.m4a"]?["manual"] as? Bool, true)
        XCTAssertEqual(object?["b.m4a"]?["detail"] as? String, "Описание")
        XCTAssertEqual(object?["b.m4a"]?["manual"] as? Bool, false)
    }
}
