import XCTest
@testable import LoriLocal

/// Какое имя файла говорит о записи, а какое поставила программа.
final class RecordGenericNameTests: XCTestCase {
    /// Имена, которые дают диктофоны, мессенджеры, камера и сама Lori. Ни одно
    /// не должно побеждать первую фразу расшифровки.
    func testServiceNamesAreGeneric() {
        let names = [
            "Новая запись", "Новая запись 12", "Новая запись 48.m4a", "New Recording 5",
            "audio 5 2", "audio_5_2", "Вставленное 1788520000",
            "Recording-2026-09-04T22-22-10Z", "IMG_1234", "IMG_1234 2", "rec_001",
            "audio_2026-09-01_12-00-00", "audio_1@31-07-2023_21-36-43",
            "PTT-20260901-WA0001", "AUD-20260901-WA0003", "WhatsApp Audio 2026-09-01 at 12.00.00",
            "voice_message_2026-09-01", "Voice Message", "Голосовое сообщение", "Голосовое сообщение (3)",
            "20260901", "2026-09-01", "01.09.2026", "12:00", "12-00-00", "1788520000",
            "Untitled", "Untitled 2", "Без названия", "Без названия 3", "Запись 21:46",
            "Screen Recording 2026-09-01 at 12.00.00", "RPReplay_Final1693574400",
            "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "", "   ", "—",
        ]
        for name in names {
            XCTAssertTrue(RecordTitle.isGenericName(name), "«\(name)» — служебное имя")
        }
    }

    /// Имя, которое дал человек, остаётся главной приметой записи.
    func testHumanNamesAreMeaningful() {
        let names = [
            "Совещание 27.08", "Совещание 27.08.m4a", "Интервью Маши", "Планёрка", "Встреча с Анной",
            "Meeting notes", "MVP", "Звонок Маше", "Q3 итоги", "2025 Итоги года", "Лекция 5",
        ]
        for name in names {
            XCTAssertFalse(RecordTitle.isGenericName(name), "«\(name)» — имя от человека")
        }
    }

    func testGenericNameIsShownReadable() {
        XCTAssertEqual(RecordTitle.cleanedName("audio_5_2"), "audio 5 2")
        XCTAssertEqual(RecordTitle.cleanedName("Новая  запись_12 "), "Новая запись 12")
        XCTAssertEqual(RecordTitle.cleanedName("PTT-20260901-WA0001"), "PTT-20260901-WA0001", "дефисы в датах к месту")
    }
}

/// Один источник заголовка и описания на все экраны.
final class RecordTitleResolveTests: XCTestCase {
    private let recordedAt = Date(timeIntervalSince1970: 1_788_520_000)

    /// Превью настоящего файла расшифровки — с режимом, говорящими и таймкодами.
    private let preview = TranscriptPreviews.Preview.make(from: Transcript(
        text: "",
        segments: [
            TranscriptSegment(start: 0, end: 4, text: "S1: Обсудили бюджет на квартал."),
            TranscriptSegment(start: 4, end: 9, text: "S2: Дальше договорились о найме."),
        ]
    ).markdown(title: "Новая запись 12", engine: "Gemini · gemini-3.5-transcribe", mode: "Спикеры и таймкоды"))

    private func entry(_ title: String, _ origin: SummaryStore.Origin, detail: String = "") -> SummaryStore.Entry {
        SummaryStore.Entry(title: title, detail: detail, origin: origin, summarized: origin == .generated)
    }

    private func resolve(_ summary: SummaryStore.Entry?, _ preview: TranscriptPreviews.Preview?) -> RecordTitle {
        RecordTitle.resolve(summary: summary, preview: preview, recordedAt: recordedAt, now: recordedAt)
    }

    func testPreviewOfARealFileIsClean() {
        XCTAssertEqual(preview.title, "Обсудили бюджет на квартал")
        XCTAssertEqual(preview.snippet, "Дальше договорились о найме.")
        XCTAssertEqual(preview.head, "Обсудили бюджет на квартал. Дальше договорились о найме.")
    }

    /// Имя от человека главнее всего — и под ним начало текста, а не продолжение.
    func testManualNameWinsEverything() {
        let resolved = resolve(entry("Моё интервью", .manual), preview)
        XCTAssertEqual(resolved.title, "Моё интервью")
        XCTAssertEqual(resolved.source, .manual)
        XCTAssertEqual(resolved.detail, preview.head, "сниппет с середины фразы не нужен")
        XCTAssertNil(resolved.generatedDetail)
    }

    func testModelTitleWinsOverTextAndFileName() {
        let resolved = resolve(entry("Бюджет и найм", .generated, detail: "Обсудили бюджет и найм."), preview)
        XCTAssertEqual(resolved.title, "Бюджет и найм")
        XCTAssertEqual(resolved.source, .model)
        XCTAssertEqual(resolved.detail, "Обсудили бюджет и найм.")
        XCTAssertEqual(resolved.generatedDetail, "Обсудили бюджет и найм.")
    }

    /// Пустое описание модели — повод показать начало текста, а не пустоту.
    func testModelTitleWithoutDetailShowsTheText() {
        let resolved = resolve(entry("Бюджет и найм", .generated), preview)
        XCTAssertEqual(resolved.detail, preview.head)
        XCTAssertNil(resolved.generatedDetail)
    }

    /// Осмысленное имя принесённого файла — примета записи, первая фраза его не подменяет.
    func testMeaningfulImportedNameWinsOverFirstPhrase() {
        let resolved = resolve(entry("Совещание 27.08", .imported), preview)
        XCTAssertEqual(resolved.title, "Совещание 27.08")
        XCTAssertEqual(resolved.source, .importedName)
        XCTAssertEqual(resolved.detail, preview.head)
    }

    /// **Регрессия.** «Новая запись 12» побеждала первую фразу навсегда.
    func testGenericImportedNameGivesWayToFirstPhrase() {
        let resolved = resolve(entry("Новая запись 12", .imported), preview)
        XCTAssertEqual(resolved.title, "Обсудили бюджет на квартал")
        XCTAssertEqual(resolved.source, .transcript)
        XCTAssertEqual(resolved.detail, "Дальше договорились о найме.", "заголовок из текста — сниппет его продолжает")
    }

    /// Пока расшифровки нет, служебное имя всё же лучше даты — в читаемом виде.
    func testGenericImportedNameIsShownCleanWithoutTranscript() {
        let resolved = resolve(entry("audio_5_2", .imported), nil)
        XCTAssertEqual(resolved.title, "audio 5 2")
        XCTAssertEqual(resolved.source, .genericName)
        XCTAssertNil(resolved.detail)
    }

    func testDateIsTheLastResort() {
        let resolved = resolve(nil, nil)
        XCTAssertEqual(resolved.title, "Запись \(LoriFormat.stamp(recordedAt, now: recordedAt))")
        XCTAssertEqual(resolved.source, .date)
        XCTAssertNil(resolved.detail)

        let empty = TranscriptPreviews.Preview.make(from: "# Запись\n\n_Режим: Точность_\n")
        XCTAssertEqual(resolve(nil, empty).source, .date, "пустая расшифровка заголовка не даёт")
    }

    /// Описание модели при ручном имени — главнее начала текста.
    func testModelDetailUnderManualName() {
        let resolved = resolve(entry("Моё интервью", .manual, detail: "Разговор о найме."), preview)
        XCTAssertEqual(resolved.detail, "Разговор о найме.")
        XCTAssertEqual(resolved.generatedDetail, "Разговор о найме.")
    }

    func testTranscriptPathFollowsTheAudioName() {
        XCTAssertEqual(RecordTitle.transcriptPath(forAudio: "Recordings/Совещание 27.08.m4a"), "Transcripts/Совещание 27.08.md")
        XCTAssertEqual(RecordTitle.transcriptPath(forAudio: "Imported/audio 5.mp3"), "Transcripts/audio 5.md")
    }
}

/// Превью карточки: читается один раз и перечитывается, когда текст поменялся.
@MainActor
final class TranscriptPreviewsTests: XCTestCase {
    private var root: URL!
    private var workspace: WorkspaceStore!
    private let path = "Recordings/Встреча.m4a"

    // Асинхронные setUp/tearDown выполняются на главном акторе, как и сам класс.
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "LoriPreviews-\(UUID().uuidString)", directoryHint: .isDirectory)
        workspace = WorkspaceStore(rootURL: root)
        workspace.start()
        let recordings = root.appending(path: "Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try Data("звук".utf8).write(to: recordings.appending(path: "Встреча.m4a"))
        try workspace.refresh()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var audioURL: URL { root.appending(path: path) }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// **Регрессия.** Строка просит превью один раз, в своём `.task`. Если
    /// расшифровки ещё не было, запись забывалась, и карточка оставалась датой
    /// до перезапуска, хотя текст давно лёг на диск.
    func testPreviewAppearsWhenTheTranscriptIsSavedLater() async throws {
        let previews = TranscriptPreviews()
        previews.load(try workspace.entry(at: path), in: workspace)
        XCTAssertNil(previews.preview(for: path))

        _ = try workspace.saveTranscript(Transcript(text: "Обсудили бюджет на квартал. Потом найм."), for: audioURL)
        await waitUntil { previews.preview(for: path) != nil }

        XCTAssertEqual(previews.preview(for: path)?.title, "Обсудили бюджет на квартал")
    }

    /// Перечитывание после перерасшифровки не сбрасывает прежнее превью: карточка
    /// не мигает датой, пока новый текст читается.
    func testSavedTranscriptKeepsTheOldPreviewUntilTheNewOneIsRead() async throws {
        _ = try workspace.saveTranscript(Transcript(text: "Первый вариант текста записи. Дальше."), for: audioURL)
        let previews = TranscriptPreviews()
        previews.load(try workspace.entry(at: path), in: workspace)
        await waitUntil { previews.preview(for: path) != nil }
        XCTAssertEqual(previews.preview(for: path)?.title, "Первый вариант текста записи")

        _ = try workspace.saveTranscript(Transcript(text: "Второй вариант после перерасшифровки. Дальше."), for: audioURL)
        previews.transcriptSaved(path, in: workspace)
        XCTAssertEqual(previews.preview(for: path)?.title, "Первый вариант текста записи", "старое видно, пока читается новое")

        await waitUntil { previews.preview(for: path)?.title != "Первый вариант текста записи" }
        XCTAssertEqual(previews.preview(for: path)?.title, "Второй вариант после перерасшифровки")
    }

    /// Переименование не заставляет перечитывать текст и не роняет карточку в дату.
    func testRenamedRecordKeepsItsPreview() async throws {
        _ = try workspace.saveTranscript(Transcript(text: "Обсудили бюджет на квартал. Потом найм."), for: audioURL)
        let previews = TranscriptPreviews()
        previews.load(try workspace.entry(at: path), in: workspace)
        await waitUntil { previews.preview(for: path) != nil }

        previews.move(from: path, to: "Recordings/Бюджет.m4a")

        XCTAssertNil(previews.preview(for: path))
        XCTAssertEqual(previews.preview(for: "Recordings/Бюджет.m4a")?.title, "Обсудили бюджет на квартал")
    }
}
