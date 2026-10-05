import XCTest
@testable import LoriLocal

/// Состояние очереди для интерфейса: место в очереди, «2 из 5», окно запуска,
/// итог пачки и «Отменить всё».
@MainActor
final class QueueStateTests: XCTestCase {
    private var fixture: QueueFixture!

    override func setUpWithError() throws {
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.engineKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.concurrencyKey)
    }

    override func tearDownWithError() throws {
        fixture?.cleanUp()
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.engineKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.concurrencyKey)
    }

    private let three = ["Первая.m4a", "Вторая.m4a", "Третья.m4a"]

    private func enqueueAll(_ names: [String], on service: TranscriptionService) throws {
        for name in names {
            service.enqueue(try fixture.entry(name), in: fixture.workspace, using: .gigaam)
        }
    }

    // MARK: - Место в очереди и состояние записи

    /// Место считается с единицы: 1 — пойдёт следующей. Идущая записи в очереди нет.
    func testQueuePositionCountsFromOneAndIsNilForTheRunningOne() async throws {
        fixture = try QueueFixture(files: three)
        let gate = QueueGate()
        let service = fixture.service(gate: gate)

        try enqueueAll(three, on: service)
        await gate.waitForArrivals(1)

        XCTAssertNil(service.queuePosition(for: "Первая.m4a"), "идущая не ждёт")
        XCTAssertEqual(service.queuePosition(for: "Вторая.m4a"), 1)
        XCTAssertEqual(service.queuePosition(for: "Третья.m4a"), 2)
        XCTAssertNil(service.queuePosition(for: "Небывалая.m4a"))

        await gate.release()
        await gate.waitForArrivals(2)
        XCTAssertNil(service.queuePosition(for: "Вторая.m4a"), "теперь идёт она")
        XCTAssertEqual(service.queuePosition(for: "Третья.m4a"), 1, "очередь подвинулась")

        await gate.openAll()
        await service.waitForDrain()
    }

    func testRecordStateTellsRunningQueuedAndUnknown() async throws {
        fixture = try QueueFixture(files: three)
        let gate = QueueGate()
        let service = fixture.service(gate: gate)

        try enqueueAll(three, on: service)
        await gate.waitForArrivals(1)

        XCTAssertEqual(service.state(for: "Первая.m4a"), .running)
        XCTAssertEqual(service.state(for: "Вторая.m4a"), .queued(position: 1, waitsForMemory: false))
        XCTAssertEqual(service.state(for: "Третья.m4a"), .queued(position: 2, waitsForMemory: false))
        XCTAssertEqual(service.state(for: "Небывалая.m4a"), .idle)
        for name in three { XCTAssertTrue(service.isActive(name), "\(name) занята") }
        XCTAssertFalse(service.isActive("Небывалая.m4a"))

        await gate.openAll()
        await service.waitForDrain()
        for name in three {
            XCTAssertEqual(service.state(for: name), .idle, "после работы запись свободна")
            XCTAssertFalse(service.isActive(name))
        }
    }

    /// «Жду память» — это та же очередь, но с оговоркой, и место у такой записи есть.
    func testRecordWaitingForMemoryKeepsItsPlaceAndSaysSo() async throws {
        fixture = try QueueFixture(files: ["Первая.m4a", "Вторая.m4a"])
        UserDefaults.standard.set(2, forKey: TranscriptionSettings.concurrencyKey)
        let gate = QueueGate()
        let service = TranscriptionService(
            engines: [.whisper: QueueEngine(gate: gate)],
            interruptedStore: fixture.store,
            // Один байт: ноль означал бы «система не сказала».
            availableMemory: { 1 }
        )
        for name in ["Первая.m4a", "Вторая.m4a"] {
            service.enqueue(try fixture.entry(name), in: fixture.workspace, using: .whisper)
        }
        await gate.waitForArrivals(1)

        XCTAssertEqual(service.state(for: "Вторая.m4a"), .queued(position: 1, waitsForMemory: true))

        await gate.openAll()
        await service.waitForDrain()
    }

    func testFailedAndInterruptedRecordsAreToldApart() async throws {
        fixture = try QueueFixture(files: ["Сбой.m4a", "Прервана.m4a", "Ждала.m4a"])
        let gate = QueueGate()
        let service = fixture.service(gate: gate, failing: ["Сбой.m4a"])

        service.enqueue(try fixture.entry("Сбой.m4a"), in: fixture.workspace, using: .gigaam)
        await gate.waitForArrivals(1)
        await gate.openAll()
        await service.waitForDrain()
        guard case let .failed(message) = service.state(for: "Сбой.m4a") else {
            return XCTFail("после ошибки состояние — failed, а не \(service.state(for: "Сбой.m4a"))")
        }
        XCTAssertTrue(message.contains("сбой на Сбой.m4a"), message)
        XCTAssertFalse(service.isActive("Сбой.m4a"))

        // Теперь оборвать: та, что шла, и та, что ждала, — обе «прервано».
        let held = QueueGate()
        let second = fixture.service(gate: held)
        second.enqueue(try fixture.entry("Прервана.m4a"), in: fixture.workspace, using: .gigaam)
        second.enqueue(try fixture.entry("Ждала.m4a"), in: fixture.workspace, using: .gigaam)
        await held.waitForArrivals(1)
        second.interruptEverything()
        XCTAssertEqual(second.state(for: "Прервана.m4a"), .interrupted, "ещё сворачивает работу, но уже «прервана»")
        XCTAssertEqual(second.state(for: "Ждала.m4a"), .interrupted)
        XCTAssertFalse(second.isActive("Ждала.m4a"))
        await held.openAll()
        await second.waitForDrain()
    }

    // MARK: - Счётчик пачки

    func testBatchCounterReadsTwoOfFiveStyle() async throws {
        fixture = try QueueFixture(files: three)
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        XCTAssertEqual(service.batchTotal, 0)
        XCTAssertEqual(service.batchPosition, 0, "без пачки номера нет")

        try enqueueAll(three, on: service)
        await gate.waitForArrivals(1)
        XCTAssertEqual(service.batchTotal, 3)
        XCTAssertEqual(service.batchDone, 0)
        XCTAssertEqual(service.batchPosition, 1)
        XCTAssertEqual(TranscriptionService.counter(done: service.batchDone, total: service.batchTotal), "1 из 3")

        await gate.release()
        await gate.waitForArrivals(2)
        XCTAssertEqual(service.batchDone, 1)
        XCTAssertEqual(service.batchPosition, 2)
        XCTAssertEqual(TranscriptionService.counter(done: service.batchDone, total: service.batchTotal), "2 из 3")

        await gate.release()
        await gate.waitForArrivals(3)
        XCTAssertEqual(service.batchDone, 2)
        XCTAssertEqual(service.batchPosition, 3)

        await gate.openAll()
        await service.waitForDrain()
        XCTAssertEqual(service.batchTotal, 0, "очередь опустела — счётчик обнулился")
        XCTAssertEqual(service.batchDone, 0)
        XCTAssertEqual(service.batchPosition, 0)
    }

    func testCounterNeverOvershootsTheTotal() {
        XCTAssertEqual(TranscriptionService.counter(done: 0, total: 5), "1 из 5")
        XCTAssertEqual(TranscriptionService.counter(done: 1, total: 5), "2 из 5")
        XCTAssertEqual(TranscriptionService.counter(done: 4, total: 5), "5 из 5")
        XCTAssertEqual(TranscriptionService.counter(done: 9, total: 5), "5 из 5", "«6 из 5» читается как поломка")
    }

    /// Запись, добавленная по ходу, входит в ту же пачку: «из» растёт, «сделано» — нет.
    func testRecordAddedMidBatchJoinsTheSameBatch() async throws {
        fixture = try QueueFixture(files: three)
        let gate = QueueGate()
        let service = fixture.service(gate: gate)

        try enqueueAll(Array(three.prefix(2)), on: service)
        await gate.waitForArrivals(1)
        XCTAssertEqual(service.batchTotal, 2)

        try enqueueAll([three[2]], on: service)
        XCTAssertEqual(service.batchTotal, 3, "добавленная по ходу — в той же пачке")
        XCTAssertEqual(service.batchDone, 0)

        await gate.openAll()
        let outcome = await service.waitForDrain()
        XCTAssertEqual(outcome?.total, 3)
        XCTAssertEqual(outcome?.succeeded, three)
    }

    /// Пачки друг с другом не складываются: вторая начинается с нуля.
    func testSecondBatchStartsFromZero() async throws {
        fixture = try QueueFixture(files: three)
        let first = QueueGate(blocking: false)
        let service = fixture.service(gate: first)

        try enqueueAll(Array(three.prefix(2)), on: service)
        await service.waitForDrain()
        XCTAssertEqual(service.lastBatch?.total, 2)

        let gate = QueueGate()
        let next = fixture.service(gate: gate)
        try enqueueAll([three[2]], on: next)
        await gate.waitForArrivals(1)
        XCTAssertEqual(next.batchTotal, 1, "две записи прошлой пачки в счёт не идут")
        XCTAssertEqual(next.batchDone, 0)

        await gate.openAll()
        await next.waitForDrain()
    }

    /// Снятая человеком запись из «из скольких» выходит: «из пяти» не ждёт четвёртую.
    func testCancelledRecordLeavesTheCounter() async throws {
        fixture = try QueueFixture(files: three)
        let gate = QueueGate()
        let service = fixture.service(gate: gate)

        try enqueueAll(three, on: service)
        await gate.waitForArrivals(1)
        service.cancel("Третья.m4a")
        XCTAssertEqual(service.batchTotal, 2)
        XCTAssertEqual(service.batchDone, 0)

        await gate.openAll()
        let outcome = await service.waitForDrain()
        XCTAssertEqual(outcome?.cancelled, 1)
        XCTAssertEqual(outcome?.succeeded, ["Первая.m4a", "Вторая.m4a"])
        XCTAssertEqual(outcome?.isClean, true, "отмена человеком — не сбой")
    }

    // MARK: - Итог пачки

    func testFailureCountsAsDoneAndLandsInTheOutcome() async throws {
        fixture = try QueueFixture(files: three)
        let gate = QueueGate()
        let service = fixture.service(gate: gate, failing: ["Вторая.m4a"])

        try enqueueAll(three, on: service)
        await gate.waitForArrivals(1)
        await gate.release()
        await gate.waitForArrivals(2)
        await gate.release()
        await gate.waitForArrivals(3)
        XCTAssertEqual(service.batchDone, 2, "обработана и та, что упала: очередь прошла мимо неё")
        await gate.openAll()

        let outcome = await service.waitForDrain()
        XCTAssertEqual(outcome?.failed, ["Вторая.m4a"])
        XCTAssertEqual(outcome?.succeeded, ["Первая.m4a", "Третья.m4a"])
        XCTAssertEqual(outcome?.isClean, false)
        XCTAssertEqual(service.lastBatch, outcome)
    }

    /// Старая ошибка живёт в `failed` — так и задумано, карточка её показывает, — но
    /// чужую следующую пачку неудачной она не делает.
    func testOldFailureDoesNotTaintTheNextBatch() async throws {
        fixture = try QueueFixture(files: three)
        let failing = QueueGate(blocking: false)
        let service = fixture.service(gate: failing, failing: ["Первая.m4a"])
        try enqueueAll(["Первая.m4a"], on: service)
        let bad = await service.waitForDrain()
        XCTAssertEqual(bad?.isClean, false)
        XCTAssertNotNil(service.error(for: "Первая.m4a"))

        try enqueueAll(["Вторая.m4a", "Третья.m4a"], on: service)
        let good = await service.waitForDrain()

        XCTAssertEqual(good?.isClean, true, "в этой пачке ошибок не было")
        XCTAssertEqual(good?.succeeded, ["Вторая.m4a", "Третья.m4a"])
        XCTAssertNotNil(service.error(for: "Первая.m4a"), "а карточка старой ошибки её по-прежнему показывает")
    }

    func testInterruptedRecordsAreNotCountedAsDoneOrFailed() async throws {
        fixture = try QueueFixture(files: three)
        let gate = QueueGate()
        let service = fixture.service(gate: gate)

        try enqueueAll(three, on: service)
        await gate.waitForArrivals(1)
        service.interruptEverything()
        await gate.openAll()
        let outcome = await service.waitForDrain()

        XCTAssertEqual(Set(outcome?.interrupted ?? []), Set(three))
        XCTAssertEqual(outcome?.succeeded, [])
        XCTAssertEqual(outcome?.failed, [])
        XCTAssertEqual(outcome?.isClean, false, "обрыв — не успех: задача не может отчитаться «готово»")
    }

    // MARK: - Окно запуска

    /// Между «вышла из очереди» и «вошла в работу» запись раньше числилась нигде, и
    /// карточка мигала «Без расшифровки». Теперь у окна есть своё состояние.
    func testStartingWindowIsReportedAsActive() async throws {
        fixture = try QueueFixture(files: ["Первая.m4a"])
        let cleanup = QueueGate()
        let engine = QueueGate()
        let service = fixture.service(gate: engine)
        service.willStart = { await cleanup.arrive("уборка") }

        service.enqueue(try fixture.entry("Первая.m4a"), in: fixture.workspace, using: .gigaam)
        await cleanup.waitForArrivals(1)

        XCTAssertEqual(service.starting, ["Первая.m4a"])
        XCTAssertEqual(service.state(for: "Первая.m4a"), .starting)
        XCTAssertTrue(service.isStarting("Первая.m4a"))
        XCTAssertTrue(service.isActive("Первая.m4a"), "запись занята, «Без расшифровки» тут было бы враньём")
        XCTAssertFalse(service.isQueued("Первая.m4a"), "из очереди она уже вышла")
        XCTAssertFalse(service.isRunning("Первая.m4a"), "а в работу ещё не вошла")
        XCTAssertEqual(service.currentPath, "Первая.m4a")
        XCTAssertNil(service.queuePosition(for: "Первая.m4a"))

        await cleanup.openAll()
        await engine.waitForArrivals(1)
        XCTAssertEqual(service.state(for: "Первая.m4a"), .running)
        XCTAssertTrue(service.starting.isEmpty, "вошла в работу — окно закрылось")

        await engine.openAll()
        await service.waitForDrain()
        XCTAssertEqual(service.state(for: "Первая.m4a"), .idle)
    }

    /// Недоступный движок — тоже конец окна: запись не должна остаться «запускающейся».
    func testStartingWindowClosesWhenTheEngineIsUnavailable() async throws {
        fixture = try QueueFixture(files: ["Первая.m4a"])
        let service = TranscriptionService(
            engines: [.gigaam: QueueEngine(gate: QueueGate(blocking: false), available: false)],
            interruptedStore: fixture.store,
            availableMemory: { 0 }
        )

        service.enqueue(try fixture.entry("Первая.m4a"), in: fixture.workspace, using: .gigaam)
        await service.waitForDrain()

        XCTAssertTrue(service.starting.isEmpty)
        guard case .failed = service.state(for: "Первая.m4a") else {
            return XCTFail("недоступный движок — это ошибка записи, а не зависшее «запускается»")
        }
    }

    func testCancelDuringStartingClearsTheStateAtOnce() async throws {
        fixture = try QueueFixture(files: ["Первая.m4a"])
        let cleanup = QueueGate()
        let engine = QueueGate()
        let service = fixture.service(gate: engine)
        service.willStart = { await cleanup.arrive("уборка") }

        service.enqueue(try fixture.entry("Первая.m4a"), in: fixture.workspace, using: .gigaam)
        await cleanup.waitForArrivals(1)
        service.cancel("Первая.m4a")

        XCTAssertEqual(service.state(for: "Первая.m4a"), .idle, "снятая запись больше не «запускается»")
        XCTAssertTrue(service.starting.isEmpty)

        await cleanup.openAll()
        let outcome = await service.waitForDrain()
        let reached = await engine.arrivals()
        XCTAssertTrue(reached.isEmpty, "до движка снятая запись не доходит")
        XCTAssertEqual(outcome?.cancelled, 1)
    }

    /// Несколько записей одновременно (настройка выше единицы): «текущая» — та, что
    /// началась раньше, а не та, что раньше по алфавиту.
    func testCurrentPathIsTheEarliestStartedNotTheAlphabeticalOne() async throws {
        fixture = try QueueFixture(files: ["Б.m4a", "А.m4a"])
        UserDefaults.standard.set(2, forKey: TranscriptionSettings.concurrencyKey)
        let gate = QueueGate()
        let service = fixture.service(gate: gate)

        service.enqueue(try fixture.entry("Б.m4a"), in: fixture.workspace, using: .gigaam)
        service.enqueue(try fixture.entry("А.m4a"), in: fixture.workspace, using: .gigaam)
        await gate.waitForArrivals(2)

        XCTAssertEqual(service.currentPath, "Б.m4a")

        await gate.openAll()
        await service.waitForDrain()
        XCTAssertNil(service.currentPath)
    }

    // MARK: - Постановка

    func testEnqueueTellsWhetherTheRecordIsInTheQueue() async throws {
        fixture = try QueueFixture(files: ["Первая.m4a"])
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        let entry = try fixture.entry("Первая.m4a")

        XCTAssertTrue(service.enqueue(entry, in: fixture.workspace, using: .gigaam))
        await gate.waitForArrivals(1)
        XCTAssertTrue(
            service.enqueue(entry, in: fixture.workspace, using: .gigaam),
            "уже идущая запись — это «да»: она будет расшифрована"
        )
        XCTAssertEqual(service.batchTotal, 1, "повторная постановка идущей записи в счёт не идёт")

        await gate.openAll()
        await service.waitForDrain()
    }

    /// Не удалось сохранить очередь — запись не встаёт, и всё остаётся как было,
    /// включая ошибку прошлой попытки: человек видит запись такой, какой она и была.
    func testEnqueueRollsBackWhenTheQueueCannotBeSaved() async throws {
        fixture = try QueueFixture(files: ["Первая.m4a"])
        // Родитель файла очереди — обычный файл, а не папка: сохранить туда нельзя.
        let blocker = FileManager.default.temporaryDirectory.appending(path: "LoriBlocker-\(UUID().uuidString)")
        try Data("файл вместо папки".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let service = TranscriptionService(
            engines: [.gigaam: QueueEngine(gate: QueueGate(blocking: false), failing: ["Первая.m4a"])],
            interruptedStore: blocker.appending(path: "queue.json"),
            availableMemory: { 0 }
        )
        let entry = try fixture.entry("Первая.m4a")
        _ = await service.transcribe(entry, in: fixture.workspace, using: .gigaam)
        let failure = try XCTUnwrap(service.error(for: "Первая.m4a"), "для проверки нужна ошибка прошлой попытки")

        let accepted = service.enqueue(entry, in: fixture.workspace, using: .gigaam)

        XCTAssertFalse(accepted)
        XCTAssertEqual(
            service.lastError,
            "Не удалось сохранить очередь. Освободи место и повтори.",
            "человек должен узнать, почему запись не встала"
        )
        XCTAssertTrue(service.isIdle)
        XCTAssertEqual(service.batchTotal, 0)
        XCTAssertEqual(service.state(for: "Первая.m4a"), .failed(failure), "прошлая ошибка осталась на месте")
    }

    // MARK: - «Отменить всё»

    func testCancelAllStopsRunningWaitingAndInterruptedAndLeavesNothingBehind() async throws {
        fixture = try QueueFixture(files: ["А.m4a", "Б.m4a", "В.m4a", "Г.m4a"])
        // Г — прерванная в прошлый раз: «Отменить всё» не должно оставлять её на
        // ближайшее возвращение в приложение.
        try InterruptedRecords.saveJobs(
            ["Г.m4a": TranscriptionJob(id: UUID().uuidString, kind: .gigaam, values: [:], created: .now)],
            to: fixture.store
        )
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        XCTAssertEqual(service.interrupted, ["Г.m4a"])

        try enqueueAll(["А.m4a", "Б.m4a", "В.m4a"], on: service)
        await gate.waitForArrivals(1)
        service.cancelAll()

        XCTAssertTrue(service.queued.isEmpty)
        XCTAssertTrue(service.waitingForMemory.isEmpty)
        XCTAssertTrue(service.interrupted.isEmpty, "и прерванные снимаются")
        for name in ["Б.m4a", "В.m4a", "Г.m4a"] { XCTAssertEqual(service.state(for: name), .idle) }
        XCTAssertTrue(InterruptedRecords.load(from: fixture.store).isEmpty, "очередь стёрта и с диска")
        XCTAssertEqual(service.batchTotal, 0, "снятые из счёта вышли")

        // Идущая сворачивается не мгновенно: место за ней держится, пока движок не отпустит.
        await gate.openAll()
        let outcome = await service.waitForDrain()

        XCTAssertTrue(service.isIdle)
        XCTAssertEqual(outcome?.cancelled, 3)
        XCTAssertEqual(outcome?.isClean, true, "отмена человеком — не сбой")
        XCTAssertTrue(service.failed.isEmpty, "отмена — не ошибка")
        XCTAssertTrue(try fixture.workspace.entries(at: "").allSatisfy { $0.name != "Transcripts" }, "ничего не расшифровано")
        let reached = await gate.arrivals()
        XCTAssertEqual(reached, ["А.m4a"], "ждущие до движка не дошли")
        XCTAssertEqual(service.batchTotal, 0)
        XCTAssertEqual(service.batchDone, 0)

        // Новый запуск ничего не поднимает.
        let restarted = fixture.service(gate: QueueGate(blocking: false))
        XCTAssertTrue(restarted.interrupted.isEmpty)
    }

    func testCancelAllIsHarmlessWhenNothingIsGoingOn() throws {
        fixture = try QueueFixture()
        let service = fixture.service(gate: QueueGate())

        service.cancelAll()

        XCTAssertTrue(service.isIdle)
        XCTAssertEqual(service.batchTotal, 0)
        XCTAssertNil(service.lastBatch)
    }

    /// Нажали «Отменить всё», пока записи ещё запускаются: движок не должен получить ни одной.
    func testCancelAllWhileRecordsAreStartingNeverReachesTheEngine() async throws {
        fixture = try QueueFixture(files: three)
        let cleanup = QueueGate()
        let engine = QueueGate()
        let service = fixture.service(gate: engine)
        service.willStart = { await cleanup.arrive("уборка") }

        try enqueueAll(three, on: service)
        await cleanup.waitForArrivals(1)
        service.cancelAll()
        XCTAssertTrue(service.starting.isEmpty)

        await cleanup.openAll()
        let outcome = await service.waitForDrain()

        let reached = await engine.arrivals()
        XCTAssertTrue(reached.isEmpty)
        XCTAssertEqual(outcome?.cancelled, 3)
        XCTAssertTrue(service.isIdle)
    }

    /// После «Отменить всё» можно сразу добавлять новое: оно встанет за сворачивающейся
    /// записью и пойдёт, как только место освободится.
    func testNewRecordAfterCancelAllRunsOnceTheLaneFrees() async throws {
        fixture = try QueueFixture(files: ["Старая.m4a", "Новая.m4a"])
        let gate = QueueGate()
        let service = fixture.service(gate: gate)

        service.enqueue(try fixture.entry("Старая.m4a"), in: fixture.workspace, using: .gigaam)
        await gate.waitForArrivals(1)
        service.cancelAll()
        service.enqueue(try fixture.entry("Новая.m4a"), in: fixture.workspace, using: .gigaam)
        XCTAssertEqual(service.state(for: "Новая.m4a"), .queued(position: 1, waitsForMemory: false))

        await gate.openAll()
        let outcome = await service.waitForDrain()

        let reached = await gate.arrivals()
        XCTAssertEqual(reached, ["Старая.m4a", "Новая.m4a"])
        XCTAssertEqual(outcome?.succeeded, ["Новая.m4a"])
        XCTAssertNoThrow(try fixture.workspace.readText(at: "Transcripts/Новая.md"))
        XCTAssertThrowsError(try fixture.workspace.readText(at: "Transcripts/Старая.md"))
    }
}
