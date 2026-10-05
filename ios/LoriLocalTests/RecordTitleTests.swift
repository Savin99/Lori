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

    /// **Регрессия.** UUID — имя временного файла системы или чужого приложения.
    /// Раньше он считался служебным только случайно: кусок из букв и цифр шёл в
    /// «коды», лишь когда букв в нём не больше трёх, и около 80% случайных UUID
    /// выходили «осмысленными» и побеждали первую фразу расшифровки.
    func testUUIDNamesAreGeneric() {
        for _ in 0..<50 {
            let uuid = UUID().uuidString
            let compact = uuid.replacingOccurrences(of: "-", with: "")
            for name in [uuid, uuid.lowercased(), compact, compact.lowercased(), "\(uuid) 2", "audio_\(uuid)", "\(uuid).m4a"] {
                XCTAssertTrue(RecordTitle.isGenericName(name), "«\(name)» — имя временного файла")
            }
        }
    }

    /// Слова из букв a–f — не UUID: «Cafe» или «Decade» назвал человек.
    func testHexLookingWordsStayMeaningful() {
        for name in ["Cafe", "Decade", "Bead", "Face ID", "deadbeef"] {
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

/// Имя файла из заголовка и «Готово» без правки.
final class RecordFileNameTests: XCTestCase {
    func testNoOpRenameIsDetected() {
        XCTAssertTrue(RecordTitle.isNoOpRename(typed: " Моё  интервью ", current: "Моё интервью"))
        XCTAssertTrue(RecordTitle.isNoOpRename(typed: "   ", current: "Моё интервью"), "пустое поле — не имя")
        XCTAssertFalse(RecordTitle.isNoOpRename(typed: "Моё интервью 2", current: "Моё интервью"))
    }

    func testFileNameKeepsTheTitleButNotItsPathCharacters() {
        XCTAssertEqual(RecordTitle.fileBaseName(for: "Совещание 27.08", extension: "m4a"), "Совещание 27.08")
        XCTAssertEqual(RecordTitle.fileBaseName(for: "Запись 21:46", extension: "m4a"), "Запись 21-46")
        XCTAssertEqual(RecordTitle.fileBaseName(for: "план/факт\\итог", extension: "m4a"), "план-факт-итог")
        XCTAssertEqual(RecordTitle.fileBaseName(for: "Две\nстроки\tи таб", extension: "m4a"), "Две строки и таб")
        XCTAssertEqual(RecordTitle.fileBaseName(for: "Встреча.M4A", extension: "m4a"), "Встреча", "расширение не удваивается")
        XCTAssertEqual(RecordTitle.fileBaseName(for: ". .скрытая", extension: "m4a"), "скрытая")
        XCTAssertNil(RecordTitle.fileBaseName(for: " ... ", extension: "m4a"))
    }

    /// Обрезка по границе знака: половина буквы в имени файла — битый UTF-8.
    func testLongFileNameIsCutOnACharacterBoundary() throws {
        let name = try XCTUnwrap(RecordTitle.fileBaseName(for: String(repeating: "Ёж🦔", count: 100), extension: "aiff"))
        XCTAssertLessThanOrEqual(name.utf8.count + ".aiff".utf8.count, RecordTitle.maxFileNameBytes)
        XCTAssertTrue(String(repeating: "Ёж🦔", count: 100).hasPrefix(name))
    }
}

/// Переименование целиком: файл, заголовок, тема, говорящие.
@MainActor
final class RecordRenameTests: XCTestCase {
    private var root: URL!
    private var workspace: WorkspaceStore!
    private var summaries: SummaryStore!
    private var topics: TopicStore!
    private var speakers: SpeakerNames!
    private var previews: TranscriptPreviews!
    private let path = "Recordings/Встреча.m4a"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "LoriRename-\(UUID().uuidString)", directoryHint: .isDirectory)
        workspace = WorkspaceStore(rootURL: root)
        workspace.start()
        let recordings = root.appending(path: "Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let audio = recordings.appending(path: "Встреча.m4a")
        try Data("звук".utf8).write(to: audio)
        _ = try workspace.saveTranscript(Transcript(text: "Обсудили бюджет на квартал. Потом найм."), for: audio)
        try workspace.refresh()
        summaries = SummaryStore(url: root.appending(path: "summaries.json"))
        topics = TopicStore(url: root.appending(path: "topics.json"))
        speakers = SpeakerNames(url: root.appending(path: "speakers.json"))
        previews = TranscriptPreviews()
        topics.assign("Работа", to: path)
        speakers.rename("S1", to: "Лёша", in: path)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func commit(_ typed: String, current: String) throws -> String? {
        try RecordRename.commit(
            try workspace.entry(at: path), typed: typed, currentTitle: current,
            workspace: workspace, summaries: summaries, topics: topics, speakers: speakers, previews: previews
        )
    }

    /// **Регрессия.** «Готово» без правки стирало тему и имена говорящих: перенос
    /// «со старого пути на новый» шёл по одному и тому же пути.
    func testDoneWithoutChangesKeepsTopicAndSpeakerNames() throws {
        XCTAssertNil(try commit("Обсудили бюджет на квартал", current: "Обсудили бюджет на квартал"))

        XCTAssertEqual(topics.topic(for: path), "Работа")
        XCTAssertEqual(speakers.name(of: "S1", in: path), "Лёша")
        XCTAssertNil(summaries.entry(for: path), "ручным заголовком ничего не стало")
    }

    /// Заголовок остаётся ровно таким, как набран; файл — пригодным для диска;
    /// тема, говорящие и превью едут за записью.
    func testRenameMovesEverythingAndKeepsTheTitleAsTyped() async throws {
        previews.load(try workspace.entry(at: path), in: workspace)
        let deadline = Date().addingTimeInterval(3)
        while previews.preview(for: path) == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

        let renamed = try XCTUnwrap(try commit("Итоги: план/факт", current: "Обсудили бюджет на квартал"))

        XCTAssertEqual(renamed, "Recordings/Итоги- план-факт.m4a")
        XCTAssertEqual(summaries.title(for: renamed), "Итоги: план/факт")
        XCTAssertEqual(summaries.entry(for: renamed)?.origin, .manual)
        XCTAssertEqual(topics.topic(for: renamed), "Работа")
        XCTAssertNil(topics.topic(for: path))
        XCTAssertEqual(speakers.name(of: "S1", in: renamed), "Лёша")
        XCTAssertNotNil(previews.preview(for: renamed), "карточка не падает в дату")
        let resolved = RecordTitle.resolve(try workspace.entry(at: renamed), summaries: summaries, previews: previews)
        XCTAssertEqual(resolved.title, "Итоги: план/факт")
        XCTAssertEqual(resolved.source, .manual)
    }

    /// Новый заголовок при том же имени файла — только заголовок, без переносов.
    func testTitleChangeWithoutFileChangeTouchesNothingElse() throws {
        XCTAssertEqual(try commit("Встреча", current: "Обсудили бюджет на квартал"), path)

        XCTAssertEqual(summaries.title(for: path), "Встреча")
        XCTAssertEqual(topics.topic(for: path), "Работа")
        XCTAssertEqual(speakers.name(of: "S1", in: path), "Лёша")
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

    /// Первое чтение ждёт `release`, остальные отвечают сразу.
    private final class ReadGate: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var held: CheckedContinuation<Void, Never>?

        var isHolding: Bool { lock.withLock { held != nil } }

        func next() async -> Int {
            let call = lock.withLock { count += 1; return count }
            if call == 1 {
                await withCheckedContinuation { continuation in
                    lock.withLock { held = continuation }
                }
            }
            return call
        }

        func release() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { held = nil }
                return held
            }
            continuation?.resume()
        }
    }

    /// **Регрессия.** Номер чтения считался по записи и после `invalidate` (и
    /// `move`) начинался заново с единицы: опоздавшее старое чтение совпадало
    /// номером с новым и затирало свежее превью устаревшим.
    func testLateOldReadNeverOverwritesAFreshPreview() async throws {
        _ = try workspace.saveTranscript(Transcript(text: "Текст записи. Дальше."), for: audioURL)
        let gate = ReadGate()
        let previews = TranscriptPreviews(reader: { _ in
            let call = await gate.next()
            return TranscriptPreviews.Preview(title: call == 1 ? "Старое" : "Новое", snippet: nil, head: nil)
        })

        previews.load(try workspace.entry(at: path), in: workspace)
        await waitUntil { gate.isHolding }
        previews.invalidate(path)
        previews.transcriptSaved(path, in: workspace)
        await waitUntil { previews.preview(for: path)?.title == "Новое" }

        gate.release()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(previews.preview(for: path)?.title, "Новое", "опоздавшее чтение отброшено")
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
