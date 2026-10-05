import XCTest
@testable import LoriLocal

/// Ошибки записей переживают перезапуск: после него запись, на которой расшифровка не
/// вышла, обязана выглядеть как «Ошибка», а не как нетронутая.
@MainActor
final class QueueFailureTests: XCTestCase {
    private var fixture: QueueFixture!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.engineKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.concurrencyKey)
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.engineKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.concurrencyKey)
    }

    /// Пачка из трёх, на средней сбой. Возвращает сервис, у которого пачка уже кончилась.
    private func runBatchWithOneFailure() async throws -> (service: TranscriptionService, message: String) {
        fixture = try QueueFixture(files: ["Первая.m4a", "Вторая.m4a", "Третья.m4a"])
        let service = fixture.service(gate: QueueGate(blocking: false), failing: ["Вторая.m4a"])
        for name in ["Первая.m4a", "Вторая.m4a", "Третья.m4a"] {
            service.enqueue(try fixture.entry(name), in: fixture.workspace, using: .gigaam)
        }
        await service.waitForDrain()
        let message = try XCTUnwrap(service.error(for: "Вторая.m4a"), "без ошибки в памяти проверять нечего")
        return (service, message)
    }

    // MARK: - Переживает перезапуск

    func testFailureSurvivesRelaunch() async throws {
        let (_, message) = try await runBatchWithOneFailure()

        // Новый запуск: тот же файл, память пустая.
        let restarted = fixture.service(gate: QueueGate(blocking: false))

        XCTAssertEqual(restarted.error(for: "Вторая.m4a"), message)
        XCTAssertEqual(restarted.state(for: "Вторая.m4a"), .failed(message))
        XCTAssertNil(restarted.error(for: "Первая.m4a"), "у удавшихся ошибки нет")
        XCTAssertNil(restarted.error(for: "Третья.m4a"))
    }

    /// Ошибка — не обрыв: запись не «Прервано», в очередь сама не встаёт и звук никуда не уходит.
    func testRestoredFailureIsNotAnInterruptionAndIsNeverRetriedOnItsOwn() async throws {
        let (_, message) = try await runBatchWithOneFailure()
        let order = QueueGate(blocking: false)
        let restarted = fixture.service(gate: order)

        XCTAssertTrue(restarted.interrupted.isEmpty)
        restarted.resumeInterrupted(in: fixture.workspace)
        restarted.applicationDidBecomeActive(in: fixture.workspace)

        let reached = await order.arrivals()
        XCTAssertTrue(reached.isEmpty, "упавшая запись сама не пересчитывается")
        XCTAssertTrue(restarted.isIdle)
        XCTAssertEqual(restarted.error(for: "Вторая.m4a"), message, "и ошибка на месте")
    }

    func testRestoredFailureDoesNotTaintTheNextBatch() async throws {
        _ = try await runBatchWithOneFailure()
        let restarted = fixture.service(gate: QueueGate(blocking: false))

        restarted.enqueue(try fixture.entry("Первая.m4a"), in: fixture.workspace, using: .gigaam)
        let outcome = await restarted.waitForDrain()

        XCTAssertEqual(outcome?.isClean, true, "ошибка прошлой пачки в эту не попадает")
        XCTAssertNotNil(restarted.error(for: "Вторая.m4a"), "но на своей карточке она остаётся")
    }

    /// Недоступный движок — тоже ошибка записи, и она запоминается так же.
    func testUnavailableEngineFailureIsRemembered() async throws {
        fixture = try QueueFixture(files: ["Первая.m4a"])
        let service = TranscriptionService(
            engines: [.gigaam: QueueEngine(gate: QueueGate(blocking: false), available: false)],
            interruptedStore: fixture.store,
            availableMemory: { 0 }
        )
        service.enqueue(try fixture.entry("Первая.m4a"), in: fixture.workspace, using: .gigaam)
        await service.waitForDrain()

        let restarted = fixture.service(gate: QueueGate(blocking: false))

        XCTAssertEqual(restarted.error(for: "Первая.m4a"), TranscriptionError.modelsMissing.errorDescription)
    }

    // MARK: - Когда ошибка уходит

    func testReEnqueueClearsTheFailureAtOnceAndOnDisk() async throws {
        _ = try await runBatchWithOneFailure()
        let gate = QueueGate()
        let restarted = fixture.service(gate: gate)
        XCTAssertNotNil(restarted.error(for: "Вторая.m4a"))

        restarted.enqueue(try fixture.entry("Вторая.m4a"), in: fixture.workspace, using: .gigaam)

        XCTAssertNil(restarted.error(for: "Вторая.m4a"), "поставили заново — прошлой ошибки больше нет")
        XCTAssertEqual(restarted.state(for: "Вторая.m4a"), .starting)
        XCTAssertTrue(
            InterruptedRecords.failures(from: fixture.store).isEmpty,
            "и на диске её уже нет: падение процесса посреди работы не вернёт старую ошибку"
        )

        await gate.waitForArrivals(1)
        await gate.openAll()
        await restarted.waitForDrain()
    }

    /// Новая ошибка заменяет старую, а не складывается с ней.
    func testNewFailureReplacesTheOldOne() async throws {
        _ = try await runBatchWithOneFailure()
        let restarted = fixture.service(gate: QueueGate(blocking: false), failing: ["Вторая.m4a"])

        restarted.enqueue(try fixture.entry("Вторая.m4a"), in: fixture.workspace, using: .gigaam)
        await restarted.waitForDrain()

        XCTAssertEqual(restarted.failed.count, 1)
        XCTAssertEqual(
            InterruptedRecords.failures(from: fixture.store),
            ["Вторая.m4a": try XCTUnwrap(restarted.error(for: "Вторая.m4a"))]
        )
    }

    func testSuccessfulRerunClearsTheFailureOnDisk() async throws {
        _ = try await runBatchWithOneFailure()
        let restarted = fixture.service(gate: QueueGate(blocking: false))

        restarted.enqueue(try fixture.entry("Вторая.m4a"), in: fixture.workspace, using: .gigaam)
        await restarted.waitForDrain()

        XCTAssertNil(restarted.error(for: "Вторая.m4a"))
        XCTAssertTrue(InterruptedRecords.failures(from: fixture.store).isEmpty)
        XCTAssertNil(fixture.service(gate: QueueGate(blocking: false)).error(for: "Вторая.m4a"))
    }

    func testForgettingARecordClearsItsFailureEverywhere() async throws {
        let (service, _) = try await runBatchWithOneFailure()

        service.forget("Вторая.m4a")

        XCTAssertNil(service.error(for: "Вторая.m4a"))
        XCTAssertEqual(service.state(for: "Вторая.m4a"), .idle)
        XCTAssertTrue(InterruptedRecords.failures(from: fixture.store).isEmpty)
    }

    /// Удаление снимает и очередь: запись не должна остаться ждать там, где её уже нет.
    func testForgettingAQueuedRecordTakesItOutOfTheQueue() async throws {
        fixture = try QueueFixture(files: ["Первая.m4a", "Вторая.m4a"])
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        for name in ["Первая.m4a", "Вторая.m4a"] {
            service.enqueue(try fixture.entry(name), in: fixture.workspace, using: .gigaam)
        }
        await gate.waitForArrivals(1)

        service.forget("Вторая.m4a")

        XCTAssertEqual(service.state(for: "Вторая.m4a"), .idle)
        XCTAssertNil(service.queuePosition(for: "Вторая.m4a"))
        await gate.openAll()
        await service.waitForDrain()
        let reached = await gate.arrivals()
        XCTAssertEqual(reached, ["Первая.m4a"], "удалённая запись до движка не дошла")
    }

    /// Файл убрали мимо приложения (через «Файлы») — об этом узнаётся по его отсутствию.
    func testFailureOfAVanishedFileIsPrunedOnResume() async throws {
        let (_, _) = try await runBatchWithOneFailure()
        try FileManager.default.removeItem(at: fixture.root.appending(path: "Вторая.m4a"))
        let restarted = fixture.service(gate: QueueGate(blocking: false))
        XCTAssertNotNil(restarted.error(for: "Вторая.m4a"), "до проверки ошибка ещё в памяти")

        restarted.resumeInterrupted(in: fixture.workspace)

        XCTAssertNil(restarted.error(for: "Вторая.m4a"))
        XCTAssertTrue(InterruptedRecords.failures(from: fixture.store).isEmpty)
    }

    /// Отмена человеком ошибки не оставляет.
    func testCancelledRecordLeavesNoFailureBehind() async throws {
        fixture = try QueueFixture(files: ["Первая.m4a", "Вторая.m4a"])
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        for name in ["Первая.m4a", "Вторая.m4a"] {
            service.enqueue(try fixture.entry(name), in: fixture.workspace, using: .gigaam)
        }
        await gate.waitForArrivals(1)
        service.cancel("Первая.m4a")
        await gate.openAll()
        await service.waitForDrain()

        XCTAssertTrue(service.failed.isEmpty)
        XCTAssertTrue(InterruptedRecords.failures(from: fixture.store).isEmpty)
    }

    /// Прямой вызов `transcribe` — не очередь: его ошибки в файл очереди не пишутся.
    /// Иначе тесты и разовые прогоны сорили бы в настоящем файле приложения.
    func testDirectTranscribeFailureIsNotWrittenToTheQueueFile() async throws {
        fixture = try QueueFixture(files: ["Первая.m4a"])
        let service = fixture.service(gate: QueueGate(blocking: false), failing: ["Первая.m4a"])

        _ = await service.transcribe(try fixture.entry("Первая.m4a"), in: fixture.workspace, using: .gigaam)

        XCTAssertNotNil(service.error(for: "Первая.m4a"))
        XCTAssertTrue(InterruptedRecords.failures(from: fixture.store).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.path))
    }

    // MARK: - Формат файла

    private func job() -> TranscriptionJob {
        TranscriptionJob(id: UUID().uuidString, kind: .gigaam, values: [:], created: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testFailuresRoundTripThroughTheArchive() throws {
        fixture = try QueueFixture()
        let jobs = ["Идёт.m4a": job()]

        try InterruptedRecords.saveJobs(
            jobs, legacy: ["Старая.m4a": .gemini], failures: ["Упала.m4a": "Сервис не ответил"], to: fixture.store
        )

        XCTAssertEqual(InterruptedRecords.failures(from: fixture.store), ["Упала.m4a": "Сервис не ответил"])
        XCTAssertEqual(InterruptedRecords.jobs(from: fixture.store), jobs)
        XCTAssertEqual(
            InterruptedRecords.load(from: fixture.store),
            ["Идёт.m4a": .gigaam, "Старая.m4a": .gemini],
            "ошибки в «прерванные» не попадают"
        )
    }

    /// Файл, записанный прежней версией (без ключа `failures`), читается как раньше.
    func testArchiveWrittenWithoutFailuresStillLoads() throws {
        fixture = try QueueFixture()
        let jobs = ["Идёт.m4a": job()]
        let older = try JSONSerialization.data(withJSONObject: [
            "jobs": try JSONSerialization.jsonObject(with: JSONEncoder().encode(jobs)),
            "legacy": ["Старая.m4a": "gemini"],
        ])
        try older.write(to: fixture.store)

        XCTAssertEqual(InterruptedRecords.failures(from: fixture.store), [:])
        XCTAssertEqual(InterruptedRecords.jobs(from: fixture.store), jobs)
        XCTAssertEqual(InterruptedRecords.load(from: fixture.store), ["Идёт.m4a": .gigaam, "Старая.m4a": .gemini])

        // И сервис на таком файле поднимается без ошибок.
        let service = fixture.service(gate: QueueGate(blocking: false))
        XCTAssertTrue(service.failed.isEmpty)
        XCTAssertEqual(service.interrupted, ["Идёт.m4a", "Старая.m4a"])
    }

    /// Файл самой первой версии — голый словарь «путь → движок» — тоже читается.
    func testPlainLegacyDictionaryHasNoFailures() throws {
        fixture = try QueueFixture()
        InterruptedRecords.save(["Старая.m4a": .gigaam], to: fixture.store)

        XCTAssertEqual(InterruptedRecords.failures(from: fixture.store), [:])
        XCTAssertEqual(InterruptedRecords.load(from: fixture.store), ["Старая.m4a": .gigaam])
    }

    /// Старая сборка открывает новый файл: лишний ключ ей не мешает. Форма прежнего
    /// архива повторена здесь буквально — это и есть то, что умела прежняя версия.
    func testOlderReaderIgnoresTheNewKey() throws {
        fixture = try QueueFixture()
        try InterruptedRecords.saveJobs(
            ["Идёт.m4a": job()], legacy: [:], failures: ["Упала.m4a": "Сбой"], to: fixture.store
        )
        struct OlderArchive: Decodable {
            let jobs: [String: TranscriptionJob]
            let legacy: [String: TranscriptionEngineKind]
        }

        let decoded = try JSONDecoder().decode(OlderArchive.self, from: Data(contentsOf: fixture.store))

        XCTAssertEqual(Array(decoded.jobs.keys), ["Идёт.m4a"])
    }

    /// Без ошибок файл байт в байт такой же по составу ключей, как до этого изменения.
    func testArchiveWithoutFailuresDoesNotGrowANewKey() throws {
        fixture = try QueueFixture()

        try InterruptedRecords.saveJobs(["Идёт.m4a": job()], to: fixture.store)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.store)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["jobs", "legacy"])
    }
}
