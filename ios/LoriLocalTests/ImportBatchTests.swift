import XCTest
@testable import LoriLocal

/// Пакетный импорт на уровне сервиса: пять файлов за один раз, по порядку, с понятным
/// итогом по каждому — и так, чтобы один плохой не погубил остальные.
@MainActor
final class ImportBatchTests: XCTestCase {
    private let manager = FileManager.default
    private var fixture: QueueFixture!
    private var outside: URL!

    override func setUpWithError() throws {
        try? manager.removeItem(at: ImportInbox.staging)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.engineKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.concurrencyKey)
        fixture = try QueueFixture()
        outside = manager.temporaryDirectory.appending(path: "LoriBatchSrc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        fixture?.cleanUp()
        try? manager.removeItem(at: outside)
        try? manager.removeItem(at: ImportInbox.staging)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.engineKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.concurrencyKey)
    }

    /// Файл в промежуточной папке — как после выбора в «Файлах» или вставки из буфера.
    /// Негодные форматы кладутся прямо, в обход `stage`: он их не пропустил бы, а здесь
    /// проверяется то, что будет, если такой всё же дойдёт.
    @discardableResult
    private func staged(_ name: String, bytes: [UInt8] = [1, 2, 3]) throws -> URL {
        try manager.createDirectory(at: ImportInbox.staging, withIntermediateDirectories: true)
        let url = ImportInbox.staging.appending(path: name)
        try Data(bytes).write(to: url)
        return url
    }

    private var stagedNames: [String] { ImportInbox.waiting().map(\.lastPathComponent).sorted() }

    // MARK: - Один файл

    func testOneFileIsImportedAndQueuedAsOneAction() async throws {
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        let file = try staged("Совещание.m4a")

        let path = try await service.importAndEnqueue(file, into: fixture.workspace, using: .gigaam)

        XCTAssertEqual(path, "Imported/Совещание.m4a")
        XCTAssertTrue(service.isActive(path), "запись в очереди или уже запускается")
        XCTAssertEqual(stagedNames, [], "промежуточная копия убрана: иначе вернулась бы в панель и ушла второй раз")
        XCTAssertTrue(manager.fileExists(atPath: fixture.root.appending(path: path).path))

        await gate.waitForArrivals(1)
        await gate.openAll()
        await service.waitForDrain()
        XCTAssertNoThrow(try fixture.workspace.readText(at: "Transcripts/Совещание.md"))
    }

    /// Интерфейс задаёт записи временный заголовок — и должен успеть раньше, чем она кончится.
    func testHookRunsBeforeTheWorkCanProgress() async throws {
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        let file = try staged("Звонок.m4a")
        var seen: [(path: String, state: TranscriptionRecordState, hasTranscript: Bool)] = []

        let path = try await service.importAndEnqueue(file, into: fixture.workspace, using: .gigaam) { path in
            seen.append((
                path,
                service.state(for: path),
                (try? self.fixture.workspace.readText(at: "Transcripts/Звонок.md")) != nil
            ))
        }

        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].path, path)
        XCTAssertTrue(seen[0].state.isActive, "к моменту вызова запись уже в очереди: \(seen[0].state)")
        XCTAssertFalse(seen[0].hasTranscript, "а расшифровки ещё нет")

        await gate.waitForArrivals(1)
        await gate.openAll()
        await service.waitForDrain()
    }

    func testUnsupportedFormatIsRefusedAndTheStagedCopyIsCleanedUp() async throws {
        let service = fixture.service(gate: QueueGate(blocking: false))
        let file = try staged("Голосовое.ogg")

        do {
            _ = try await service.importAndEnqueue(file, into: fixture.workspace, using: .gigaam)
            XCTFail("неподдерживаемый формат должен быть отклонён")
        } catch let error as ImportError {
            XCTAssertEqual(error, .unsupportedFormat(fileName: "Голосовое.ogg"))
        }

        XCTAssertEqual(stagedNames, [], "негодная промежуточная копия убрана")
        XCTAssertFalse(manager.fileExists(atPath: fixture.root.appending(path: "Imported").path), "в рабочую папку ничего не попало")
        XCTAssertTrue(service.isIdle)
        XCTAssertEqual(service.batchTotal, 0)
    }

    /// Не вышло скопировать — файл остаётся в промежуточной папке: человек повторит.
    func testFailedCopyKeepsTheStagedFileForARetry() async throws {
        let service = fixture.service(gate: QueueGate(blocking: false))
        // `Imported` — обычный файл: папку создать нельзя, и копировать некуда.
        try Data("файл вместо папки".utf8).write(to: fixture.root.appending(path: "Imported"))
        let file = try staged("Запись.m4a")

        do {
            _ = try await service.importAndEnqueue(file, into: fixture.workspace, using: .gigaam)
            XCTFail("копировать некуда — должна быть ошибка")
        } catch {
            XCTAssertNil(error as? ImportError, "это не отказ по формату")
        }

        XCTAssertEqual(stagedNames, ["Запись.m4a"], "файл на месте для повтора")
        XCTAssertTrue(service.isIdle)
    }

    /// Очередь не сохранилась — импорт откатывается целиком, как будто ничего не было.
    func testQueueFailureRollsTheImportBack() async throws {
        let blocker = manager.temporaryDirectory.appending(path: "LoriBlocker-\(UUID().uuidString)")
        try Data("файл вместо папки".utf8).write(to: blocker)
        defer { try? manager.removeItem(at: blocker) }
        let service = TranscriptionService(
            engines: [.gigaam: QueueEngine(gate: QueueGate(blocking: false))],
            interruptedStore: blocker.appending(path: "queue.json"),
            availableMemory: { 0 }
        )
        let file = try staged("Запись.m4a")

        do {
            _ = try await service.importAndEnqueue(file, into: fixture.workspace, using: .gigaam)
            XCTFail("очередь не сохраняется — запись не должна встать")
        } catch let error as ImportError {
            XCTAssertEqual(error, .queueUnavailable(fileName: "Запись.m4a"))
            XCTAssertTrue(error.localizedDescription.contains("Запись.m4a"))
        }

        XCTAssertEqual(stagedNames, ["Запись.m4a"], "промежуточный файл остался прикреплённым")
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: fixture.root.appending(path: "Imported").path), [], "копия в рабочей папке откачена")
        XCTAssertTrue(service.isIdle)
        try fixture.workspace.refresh()
        XCTAssertTrue(fixture.workspace.audio.isEmpty, "в списке записей пусто")
    }

    // MARK: - Пачка

    func testBatchImportsEveryFileInOrderAndQueuesThemInThatOrder() async throws {
        let order = QueueGate(blocking: false)
        let service = fixture.service(gate: order)
        let names = ["Третья.m4a", "Первая.mp3", "Пятая.wav", "Вторая.m4a", "Четвёртая.aac"]
        let files = try names.map { try staged($0) }

        let report = await service.importAndEnqueue(files, into: fixture.workspace, using: .gigaam)
        await service.waitForDrain()

        XCTAssertTrue(report.isComplete)
        XCTAssertNil(report.blockedBy)
        XCTAssertEqual(report.imported.map(\.source), files, "в порядке выбора")
        XCTAssertEqual(report.imported.map(\.path), names.map { "Imported/\($0)" })
        let arrivals = await order.arrivals()
        XCTAssertEqual(arrivals, names, "движок видит файлы ровно в порядке пачки")
        XCTAssertEqual(stagedNames, [], "вошедшее из промежуточной папки убрано")
        XCTAssertEqual(try fixture.workspace.entries(at: "Transcripts").count, 5)
        XCTAssertEqual(service.lastBatch?.total, 5)
        XCTAssertEqual(service.lastBatch?.succeeded.count, 5)
    }

    /// Пять файлов, один из них `.ogg`: четыре идут, пятый назван с причиной.
    func testBatchReportsAPartialFailureAndTheRestGoOn() async throws {
        let order = QueueGate(blocking: false)
        let service = fixture.service(gate: order)
        let files = [
            try staged("Один.m4a"),
            try staged("Два.mp3"),
            try staged("Голосовое.opus"),
            try staged("Четыре.wav"),
            try staged("Пять.m4a"),
        ]

        let report = await service.importAndEnqueue(files, into: fixture.workspace, using: .gigaam)
        await service.waitForDrain()

        XCTAssertEqual(report.imported.map(\.source.lastPathComponent), ["Один.m4a", "Два.mp3", "Четыре.wav", "Пять.m4a"])
        XCTAssertEqual(report.failed.map(\.source.lastPathComponent), ["Голосовое.opus"])
        XCTAssertTrue(report.failed[0].message.contains("Голосовое.opus"), report.failed[0].message)
        XCTAssertFalse(report.isComplete)
        let arrivals = await order.arrivals()
        XCTAssertEqual(arrivals, ["Один.m4a", "Два.mp3", "Четыре.wav", "Пять.m4a"])
        XCTAssertEqual(stagedNames, [], "и принятые, и негодный из промежуточной папки убраны")
        XCTAssertEqual(service.lastBatch?.total, 4)
    }

    /// Пять файлов при пропавшем ключе — не пять строк «Ошибка», а один отказ до начала.
    func testBatchStopsBeforeImportingWhenTheEngineIsNotReady() async throws {
        let service = TranscriptionService(
            engines: [.gemini: QueueEngine(gate: QueueGate(blocking: false), available: false)],
            interruptedStore: fixture.store,
            availableMemory: { 0 }
        )
        let names = ["А.m4a", "Б.m4a", "В.m4a", "Г.m4a", "Д.m4a"]
        let files = try names.map { try staged($0) }

        let report = await service.importAndEnqueue(files, into: fixture.workspace, using: .gemini)

        XCTAssertEqual(report.blockedBy, TranscriptionError.missingKey(.gemini).errorDescription)
        XCTAssertTrue(report.imported.isEmpty)
        XCTAssertTrue(report.failed.isEmpty, "не пять одинаковых ошибок, а один отказ")
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(stagedNames, names.sorted(), "файлы остались прикреплёнными — починить ключ и повторить")
        XCTAssertFalse(manager.fileExists(atPath: fixture.root.appending(path: "Imported").path), "ничего не импортировано")
        XCTAssertTrue(service.isIdle)
        XCTAssertTrue(service.failed.isEmpty, "и строк «Ошибка» на карточках нет")
    }

    /// Выбранный в настройках движок — тот, что проверяется и тот, что получают все записи.
    func testBatchUsesTheEngineFromSettingsWhenNotAskedExplicitly() async throws {
        UserDefaults.standard.set(TranscriptionEngineKind.gemini.rawValue, forKey: TranscriptionSettings.engineKey)
        let service = TranscriptionService(
            engines: [.gemini: QueueEngine(gate: QueueGate(blocking: false), available: false)],
            interruptedStore: fixture.store,
            availableMemory: { 0 }
        )

        let report = await service.importAndEnqueue([try staged("А.m4a")], into: fixture.workspace)

        XCTAssertEqual(report.blockedBy, TranscriptionError.missingKey(.gemini).errorDescription)
    }

    func testEveryFileOfABatchGetsThatOneEngine() async throws {
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        let files = try ["А.m4a", "Б.m4a", "В.m4a"].map { try staged($0) }

        let report = await service.importAndEnqueue(files, into: fixture.workspace, using: .gigaam)
        await gate.waitForArrivals(1)

        XCTAssertTrue(report.isComplete)
        let saved = InterruptedRecords.load(from: fixture.store)
        XCTAssertEqual(saved.count, 3)
        XCTAssertTrue(saved.values.allSatisfy { $0 == .gigaam })

        await gate.openAll()
        await service.waitForDrain()
    }

    func testEmptyBatchDoesNothing() async throws {
        let service = TranscriptionService(
            engines: [.gigaam: QueueEngine(gate: QueueGate(blocking: false), available: false)],
            interruptedStore: fixture.store,
            availableMemory: { 0 }
        )

        let report = await service.importAndEnqueue([], into: fixture.workspace, using: .gigaam)

        XCTAssertEqual(report, TranscriptionImportReport())
        XCTAssertNil(report.blockedBy, "проверять движок ради пустой пачки незачем")
    }

    /// Хук получает и исходный файл, и путь записи: по имени принесённого файла интерфейс
    /// задаёт заголовок.
    func testHookKnowsTheSourceFileAndTheFinalPath() async throws {
        let service = fixture.service(gate: QueueGate(blocking: false))
        let files = [try staged("Совещание.m4a"), try staged("Совещание.mp3")]
        var calls: [(String, String)] = []

        let report = await service.importAndEnqueue(files, into: fixture.workspace, using: .gigaam) { source, path in
            calls.append((source.lastPathComponent, path))
        }
        await service.waitForDrain()

        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(calls.map(\.0), ["Совещание.m4a", "Совещание.mp3"])
        XCTAssertEqual(calls.map(\.1), ["Imported/Совещание.m4a", "Imported/Совещание 2.mp3"], "и путь — уже с номером")
    }

    /// Сквозная проверка исправленной ошибки: одинаковая база с разными расширениями больше
    /// не делит одну расшифровку на двоих.
    func testSameBaseNamesNoLongerShareOneTranscript() async throws {
        let service = fixture.service(gate: QueueGate(blocking: false))
        let files = [try staged("Совещание.m4a", bytes: [1]), try staged("Совещание.mp3", bytes: [2])]

        let report = await service.importAndEnqueue(files, into: fixture.workspace, using: .gigaam)
        await service.waitForDrain()

        XCTAssertTrue(report.isComplete)
        XCTAssertTrue(try fixture.workspace.readText(at: "Transcripts/Совещание.md").contains("Совещание.m4a"))
        XCTAssertTrue(try fixture.workspace.readText(at: "Transcripts/Совещание 2.md").contains("Совещание 2.mp3"))
    }

    /// Свежая пачка стоит в списке «новые сверху» вверху и читается в порядке расшифровки.
    func testBatchAppearsOnTopOfTheListInProcessingOrder() async throws {
        try fixture.addAudio("Recordings/Вчерашняя.m4a")
        try manager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: fixture.root.appending(path: "Recordings/Вчерашняя.m4a").path
        )
        let service = fixture.service(gate: QueueGate(blocking: false))
        let names = ["Первая.m4a", "Вторая.m4a", "Третья.m4a"]
        let files = try names.map { try staged($0) }
        // Даты у оригиналов нарочно давние: на списке это сказаться не должно.
        for file in files { try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: file.path) }

        let report = await service.importAndEnqueue(files, into: fixture.workspace, using: .gigaam)
        await service.waitForDrain()
        try fixture.workspace.refresh()

        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(
            fixture.workspace.audio.map(\.relativePath),
            ["Imported/Первая.m4a", "Imported/Вторая.m4a", "Imported/Третья.m4a", "Recordings/Вчерашняя.m4a"],
            "пачка наверху, первая в очереди — первая сверху"
        )
    }
}
