import XCTest
@testable import LoriLocal

/// Подписи главного экрана: время без даты, длительность с часами, остаток,
/// абсолютное имя для экспорта, место в очереди.
final class HomeFormatTests: XCTestCase {
    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    /// Дата живёт в заголовке дня — на карточке только время, и для вчерашней
    /// записи тоже: «вчера, 14:20» повторило бы заголовок над карточкой.
    func testCardTimeHasNoDate() {
        XCTAssertEqual(HomeFormat.time(date("2026-10-04 14:20")), "14:20")
        XCTAssertEqual(HomeFormat.time(date("2025-01-02 09:05")), "09:05")
    }

    /// Час с лишним — «1:41:12», а не «101:12».
    func testLongDurationShowsHours() {
        XCTAssertEqual(HomeFormat.clock(24 * 60 + 10), "24:10")
        XCTAssertEqual(HomeFormat.clock(3600 + 41 * 60 + 12), "1:41:12")
    }

    func testRemainingIsApproximateAndShort() {
        XCTAssertEqual(HomeFormat.remaining(2), "ещё ~5 сек")
        XCTAssertEqual(HomeFormat.remaining(43), "ещё ~45 сек")
        XCTAssertEqual(HomeFormat.remaining(125), "ещё ~2 мин")
        XCTAssertEqual(HomeFormat.remaining(3600), "ещё ~1 ч")
        XCTAssertEqual(HomeFormat.remaining(3600 + 600), "ещё ~1 ч 10 мин")
    }

    /// Файл переживёт день: в имени — полная дата, а не «вчера».
    func testExportNameOfUntitledRecordIsAbsolute() {
        XCTAssertEqual(HomeFormat.absoluteTitle(date("2026-10-05 09:10")), "Запись 5 октября 2026, 09:10")
    }

    func testQueuePositionIsFeminineOrdinal() {
        XCTAssertEqual(HomeFormat.ordinal(1), "1-я")
        XCTAssertEqual(HomeFormat.ordinal(3), "3-я")
        XCTAssertEqual(HomeFormat.ordinal(0), "1-я", "места ноль не бывает")
    }

    func testCountsAreDeclined() {
        XCTAssertEqual(HomeFormat.records(1), "1 запись")
        XCTAssertEqual(HomeFormat.records(3), "3 записи")
        XCTAssertEqual(HomeFormat.records(5), "5 записей")
        XCTAssertEqual(HomeFormat.files(2), "2 файла")
    }
}

/// Строка состояния карточки: только когда записи есть что сказать, и с тем
/// действием, которое по смыслу следует дальше.
final class RecordStatusTests: XCTestCase {
    /// Готовая запись — тихая карточка: ни цвета, ни строки.
    func testFinishedRecordHasNoStatus() {
        XCTAssertNil(RecordStatus.make(state: .idle, hasTranscript: true, fraction: nil, remaining: nil))
    }

    func testRecordWithoutTranscriptOffersToTranscribe() throws {
        let status = try XCTUnwrap(RecordStatus.make(state: .idle, hasTranscript: false, fraction: nil, remaining: nil))
        XCTAssertEqual(status.text, "Без расшифровки")
        XCTAssertEqual(status.action, .transcribe)
        XCTAssertEqual(status.tone, .quiet)
    }

    func testQueuedShowsItsPlaceAndMemoryWait() throws {
        let plain = try XCTUnwrap(RecordStatus.make(state: .queued(position: 3, waitsForMemory: false), hasTranscript: false, fraction: nil, remaining: nil))
        XCTAssertEqual(plain.text, "В очереди · 3-я")
        XCTAssertNil(plain.action, "из очереди запись снимают «Остановить», а не кнопкой на карточке")
        XCTAssertEqual(plain.tone, .waiting)

        let memory = try XCTUnwrap(RecordStatus.make(state: .queued(position: 1, waitsForMemory: true), hasTranscript: false, fraction: nil, remaining: nil))
        XCTAssertEqual(memory.text, "В очереди · 1-я · жду память")
    }

    /// Проценты — по сделанному, вниз: «100%» до конца работы читалось бы как зависание.
    func testRunningShowsPercentAndRemaining() throws {
        let status = try XCTUnwrap(RecordStatus.make(state: .running, hasTranscript: false, fraction: 0.639, remaining: 125))
        XCTAssertEqual(status.text, "Расшифровываю · 63% · ещё ~2 мин")
        XCTAssertTrue(status.showsBar)
        XCTAssertEqual(status.fraction, 0.639)
        XCTAssertNil(status.action)
    }

    /// Запись между очередью и работой не мигает «Без расшифровки».
    func testStartingIsAlreadyWork() throws {
        let status = try XCTUnwrap(RecordStatus.make(state: .starting, hasTranscript: false, fraction: nil, remaining: nil))
        XCTAssertEqual(status.text, "Расшифровываю")
        XCTAssertTrue(status.showsBar)
        XCTAssertNil(status.fraction)
    }

    func testInterruptedOffersToContinue() throws {
        let status = try XCTUnwrap(RecordStatus.make(state: .interrupted, hasTranscript: false, fraction: nil, remaining: nil))
        XCTAssertEqual(status.text, "Прервано")
        XCTAssertEqual(status.action, .resume)
        XCTAssertEqual(status.action?.title, "Продолжить")
    }

    /// На карточке — первая фраза ошибки; что делать — на экране записи.
    func testFailureShowsShortReasonAndRetry() throws {
        let status = try XCTUnwrap(RecordStatus.make(
            state: .failed("Ключ ElevenLabs не сохранён. Настройки → «ElevenLabs» → вставь ключ."),
            hasTranscript: true,
            fraction: nil,
            remaining: nil
        ))
        XCTAssertEqual(status.text, "Ключ ElevenLabs не сохранён")
        XCTAssertEqual(status.action, .retry)
        XCTAssertEqual(status.tone, .failure)
    }

    func testShortReasonKeepsSingleSentenceAndAbbreviations() {
        XCTAssertEqual(RecordStatus.shortReason("Нет связи с сервисом"), "Нет связи с сервисом")
        XCTAssertEqual(RecordStatus.shortReason("Сервис не ответил вовремя. Через VPN канал обычно медленный."), "Сервис не ответил вовремя")
        // Точка слишком близко к началу — это сокращение, а не конец фразы.
        XCTAssertEqual(RecordStatus.shortReason("См. журнал работы"), "См. журнал работы")
        XCTAssertEqual(RecordStatus.shortReason("   "), "Не получилось")
    }
}

/// Блок очереди: о чём он говорит и что будет дальше.
final class QueueSummaryTests: XCTestCase {
    private func title(_ path: String) -> String {
        ["a.m4a": "Совещание по бюджету", "b.m4a": "Интервью Маши", "c.m4a": "Звонок поставщику", "d.m4a": "Планёрка"][path] ?? path
    }

    func testNothingInWorkMeansNoBlock() {
        XCTAssertNil(QueueSummary.make(
            current: nil, queued: [], batchDone: 0, batchTotal: 0,
            fraction: nil, remaining: nil, note: nil, waitingForMemory: [], title: title
        ))
    }

    func testRunningRecordWithQueueBehindIt() throws {
        let summary = try XCTUnwrap(QueueSummary.make(
            current: "a.m4a", queued: ["b.m4a", "c.m4a", "d.m4a"], batchDone: 1, batchTotal: 5,
            fraction: 0.63, remaining: 120, note: "часть 3 из 5", waitingForMemory: [], title: title
        ))
        XCTAssertEqual(summary.counter, "2 из 5")
        XCTAssertEqual(summary.title, "Совещание по бюджету")
        XCTAssertEqual(summary.focusPath, "a.m4a")
        XCTAssertEqual(summary.next, "Дальше: Интервью Маши, ещё 2")
        XCTAssertEqual(summary.fraction, 0.63)
        XCTAssertNil(summary.note, "при известной доле проценты говорят сами")
        XCTAssertFalse(summary.isWaiting)
    }

    /// Одна запись — без «1 из 1», и без «Дальше».
    func testSingleRecordHasNoCounter() throws {
        let summary = try XCTUnwrap(QueueSummary.make(
            current: "a.m4a", queued: [], batchDone: 0, batchTotal: 1,
            fraction: nil, remaining: nil, note: "жду ответ сервиса", waitingForMemory: [], title: title
        ))
        XCTAssertNil(summary.counter)
        XCTAssertNil(summary.next)
        XCTAssertEqual(summary.note, "жду ответ сервиса", "без доли блок говорит, чем занят движок")
    }

    func testOnlyOneQueuedAfterCurrentHasNoTail() throws {
        let summary = try XCTUnwrap(QueueSummary.make(
            current: "a.m4a", queued: ["b.m4a"], batchDone: 0, batchTotal: 2,
            fraction: 0.1, remaining: nil, note: nil, waitingForMemory: ["b.m4a"], title: title
        ))
        XCTAssertEqual(summary.next, "Дальше: Интервью Маши")
        XCTAssertTrue(summary.waitsForMemory)
    }

    /// Ни одна ещё не пошла — блок говорит о первой ждущей, и «дальше» — о второй.
    func testWaitingQueueFocusesTheFirstOne() throws {
        let summary = try XCTUnwrap(QueueSummary.make(
            current: nil, queued: ["b.m4a", "c.m4a"], batchDone: 0, batchTotal: 2,
            fraction: 0.5, remaining: 10, note: "x", waitingForMemory: [], title: title
        ))
        XCTAssertTrue(summary.isWaiting)
        XCTAssertEqual(summary.focusPath, "b.m4a")
        XCTAssertEqual(summary.next, "Дальше: Звонок поставщику")
        XCTAssertNil(summary.fraction, "у ждущей записи прогресса нет")
        XCTAssertNil(summary.remaining)
        XCTAssertNil(summary.note)
    }
}

/// Одно сообщение на всё действие, с причинами от сервисов как есть.
final class ImportNoticeTests: XCTestCase {
    func testNothingRejectedMeansNoMessage() {
        XCTAssertNil(ImportNotice.rejected([]))
        XCTAssertNil(ImportNotice.partial([], imported: 5))
        XCTAssertNil(ImportNotice.pasteSkipped([], taken: 3))
    }

    func testSingleRejectionIsTheServiceText() {
        let message = ImportNotice.rejected(["Формат «.ogg» Lori не расшифровывает."])
        XCTAssertEqual(message?.title, "Файл не добавлен")
        XCTAssertEqual(message?.text, "Формат «.ogg» Lori не расшифровывает.")
    }

    func testSeveralRejectionsAreOneMessage() {
        let message = ImportNotice.rejected(["первый", "второй"])
        XCTAssertEqual(message?.title, "Не добавлено: 2 файла")
        XCTAssertEqual(message?.text, "первый\n\nвторой")
    }

    /// Частичный успех называет, сколько ушло и где остальные.
    func testPartialImportSaysWhatHappenedAndWhereTheRestIs() throws {
        let message = try XCTUnwrap(ImportNotice.partial(["«x.m4a» не поставлена в очередь"], imported: 4))
        XCTAssertEqual(message.title, "Не все файлы добавлены")
        XCTAssertTrue(message.text.hasPrefix("В расшифровку ушло 4 из 5. Остальные остались в панели."))
        XCTAssertTrue(message.text.contains("«x.m4a» не поставлена в очередь"))
    }

    func testBlockedSaysFilesStayed() {
        let message = ImportNotice.blocked("Ключ ElevenLabs не сохранён.")
        XCTAssertEqual(message.title, "Расшифровка не началась")
        XCTAssertTrue(message.text.contains("Ключ ElevenLabs не сохранён."))
        XCTAssertTrue(message.text.hasSuffix("Файлы остались в панели."))
    }

    func testPasteCountsWhatWasTaken() {
        XCTAssertEqual(ImportNotice.pasteSkipped(["нечитаемый"], taken: 4)?.title, "Вставлено не всё: 4 из 5")
        XCTAssertEqual(ImportNotice.pasteSkipped(["нечитаемый"], taken: 0)?.title, "Из буфера ничего не вставлено")
    }
}

/// Поиск: одна находка на запись, заголовки в индексе, сниппет без разметки.
final class SearchIndexTests: XCTestCase {
    private func entry(_ path: String, minutesAgo: Double) -> WorkspaceEntry {
        WorkspaceEntry(relativePath: path, isDirectory: false, size: 1, modifiedAt: Date(timeIntervalSinceNow: -minutesAgo * 60))
    }

    private let markdown = """
    # Recording-2026

    _Расшифровано: ElevenLabs Scribe v2, в облаке_

    _Режим: Дословно_

    **[0:00–0:07]** S1: Обсудили бюджет на квартал.

    **[0:07–0:15]** S2: Рекламу режем на треть, найм оставляем.
    """

    private func document(_ path: String, title: String, minutesAgo: Double = 1, markdown: String? = nil) -> TranscriptSearchStore.Document {
        let source = markdown ?? self.markdown
        return TranscriptSearchStore.Document(
            entry: entry(path, minutesAgo: minutesAgo),
            title: title,
            name: (path as NSString).deletingPathExtension,
            lines: TranscriptDocument.parse(source).lines.map(\.text)
        )
    }

    /// Совпали и заголовок, и текст — находка всё равно одна.
    func testOneHitPerRecording() {
        let hits = TranscriptSearchStore.hits(in: [document("Imported/a.m4a", title: "Бюджет на квартал")], needle: "бюджет")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.title, "Бюджет на квартал")
    }

    /// Сниппет — слова, а не `**[0:07–0:15]** S2:` и не служебные строки.
    func testSnippetIsCleanText() throws {
        let hit = try XCTUnwrap(TranscriptSearchStore.hits(in: [document("a.m4a", title: "Запись 14:05")], needle: "рекламу").first)
        XCTAssertEqual(hit.snippet, "Рекламу режем на треть, найм оставляем.")
        let services = TranscriptSearchStore.hits(in: [document("a.m4a", title: "Запись")], needle: "Расшифровано")
        XCTAssertTrue(services.isEmpty, "служебная строка в поиск не попадает")
    }

    /// Заголовок из хранилища (модель, человек, имя файла) ищется так же, как текст.
    func testResolvedTitleIsSearchable() {
        let hits = TranscriptSearchStore.hits(in: [document("Recordings/Recording-1.m4a", title: "Интервью Маши", markdown: "")], needle: "маши")
        XCTAssertEqual(hits.count, 1)
        XCTAssertNil(hits.first?.snippet, "в тексте совпадения нет — сниппета тоже")
    }

    /// «Всё» находится по «все»: в расшифровке «ё» пишется как придётся.
    func testYoIsFoldedIntoYe() {
        let hits = TranscriptSearchStore.hits(
            in: [document("a.m4a", title: "Итоги", markdown: "S1: Всё готово к релизу.")],
            needle: "все готово"
        )
        XCTAssertEqual(hits.count, 1)
    }

    func testTitleMatchesComeFirstThenNewest() {
        let documents = [
            document("text-new.m4a", title: "Планёрка", minutesAgo: 1, markdown: "S1: Говорили про бюджет."),
            document("title-old.m4a", title: "Бюджет отдела", minutesAgo: 60, markdown: ""),
            document("text-old.m4a", title: "Созвон", minutesAgo: 120, markdown: "S1: Бюджет согласован."),
        ]
        let hits = TranscriptSearchStore.hits(in: documents, needle: "бюджет")
        XCTAssertEqual(hits.map(\.entry.relativePath), ["title-old.m4a", "text-new.m4a", "text-old.m4a"])
    }

    /// Совпадение в конце длинной реплики попадает в сниппет, а не теряется за многоточием.
    func testExcerptCentersOnTheMatch() throws {
        let long = String(repeating: "слово ", count: 60) + "иголка " + String(repeating: "хвост ", count: 30)
        let range = try XCTUnwrap(long.range(of: "иголка"))
        let excerpt = TranscriptSearchStore.excerpt(of: long, around: range)
        XCTAssertTrue(excerpt.contains("иголка"))
        XCTAssertTrue(excerpt.hasPrefix("…"))
        XCTAssertTrue(excerpt.hasSuffix("…"))
        XCTAssertLessThanOrEqual(excerpt.count, 124)
    }
}

/// Пункт меню и подсказка буфера считают аудио — по типам, без чтения.
@MainActor
final class ComposerClipboardTests: XCTestCase {
    func testPasteTitleCountsSeveralAudio() {
        let model = ComposerModel()
        XCTAssertEqual(model.pasteTitle, "Вставить аудио")
        model.clipboardInventory = ClipboardAudio.Inventory(audio: 5, fileReferences: 0)
        XCTAssertEqual(model.pasteTitle, "Вставить 5 аудио")
        XCTAssertEqual(model.clipboardHint, "В буфере 5 аудио")
    }

    func testHintFallsBackWithoutCount() {
        let model = ComposerModel()
        model.clipboard = .audio
        XCTAssertEqual(model.clipboardHint, "В буфере есть аудио")
    }
}
