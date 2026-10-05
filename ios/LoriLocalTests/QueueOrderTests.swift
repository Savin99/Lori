import XCTest
@testable import LoriLocal

/// Порядок очереди: записи идут так, как их добавили, — и до перезапуска, и после.
@MainActor
final class QueueOrderTests: XCTestCase {
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

    /// Имена нарочно не по алфавиту: «Вторая» < «Первая» < «Третья» < «Четвёртая»,
    /// а ставят их в порядке «Третья, Первая, Четвёртая, Вторая».
    private let addedOrder = ["Третья.m4a", "Первая.m4a", "Четвёртая.m4a", "Вторая.m4a"]

    /// То самое, ради чего порядок и записан в снимок задания: человек поставил пять
    /// файлов подряд, телефон перезапустили — досчитываться они обязаны в том же порядке.
    func testRelaunchResumesInTheOrderRecordsWereAdded() async throws {
        fixture = try QueueFixture(files: addedOrder)
        let workspace = fixture.workspace
        let gate = QueueGate()
        let service = fixture.service(gate: gate)

        for name in addedOrder { service.enqueue(try fixture.entry(name), in: workspace, using: .gigaam) }
        await gate.waitForArrivals(1)
        service.interruptEverything()
        await gate.openAll()
        await service.waitForDrain()
        XCTAssertEqual(service.interrupted, Set(addedOrder), "и та, что шла, и те, что ждали")

        // Новый запуск: тот же файл очереди, память пустая.
        let order = QueueGate(blocking: false)
        let restarted = fixture.service(gate: order)
        restarted.resumeInterrupted(in: workspace)
        await restarted.waitForDrain()

        let arrivals = await order.arrivals()
        XCTAssertEqual(arrivals, addedOrder, "после перезапуска очередь идёт в порядке добавления")
        XCTAssertNotEqual(arrivals, arrivals.sorted(), "тест ничего не доказывает, если порядок совпал с алфавитным")
    }

    /// Порядок не должен «съезжать» от перезапуска к перезапуску: повторная
    /// постановка тем же движком не перезаписывает снимок, а с ним и дату.
    func testOrderSurvivesSeveralRelaunchesInARow() async throws {
        fixture = try QueueFixture(files: addedOrder)
        let workspace = fixture.workspace
        let first = fixture.service(gate: QueueGate())
        for name in addedOrder { first.enqueue(try fixture.entry(name), in: workspace, using: .gigaam) }
        first.interruptEverything()

        // Второй запуск поднимает очередь и тут же снова обрывается.
        let gate = QueueGate()
        let second = fixture.service(gate: gate)
        second.resumeInterrupted(in: workspace)
        await gate.waitForArrivals(1)
        second.interruptEverything()
        await gate.openAll()
        await second.waitForDrain()

        let order = QueueGate(blocking: false)
        let third = fixture.service(gate: order)
        third.resumeInterrupted(in: workspace)
        await third.waitForDrain()

        let arrivals = await order.arrivals()
        XCTAssertEqual(arrivals, addedOrder)
    }

    /// Порядок берётся из даты снимка, а не из имени и не из порядка словаря.
    func testResumeFollowsSnapshotDatesNotNames() async throws {
        fixture = try QueueFixture(files: ["А.m4a", "Б.m4a", "В.m4a"])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try InterruptedRecords.saveJobs([
            "А.m4a": job(created: start.addingTimeInterval(20)),
            "Б.m4a": job(created: start.addingTimeInterval(10)),
            "В.m4a": job(created: start),
        ], to: fixture.store)

        let order = QueueGate(blocking: false)
        let service = fixture.service(gate: order)
        service.resumeInterrupted(in: fixture.workspace)
        await service.waitForDrain()

        let arrivals = await order.arrivals()
        XCTAssertEqual(arrivals, ["В.m4a", "Б.m4a", "А.m4a"])
    }

    /// Равные даты не дают случайного порядка: ничья решается путём.
    func testEqualDatesAreSettledByPath() async throws {
        fixture = try QueueFixture(files: ["Б.m4a", "А.m4a", "В.m4a"])
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        try InterruptedRecords.saveJobs([
            "Б.m4a": job(created: moment),
            "В.m4a": job(created: moment),
            "А.m4a": job(created: moment),
        ], to: fixture.store)

        let order = QueueGate(blocking: false)
        let service = fixture.service(gate: order)
        service.resumeInterrupted(in: fixture.workspace)
        await service.waitForDrain()

        let arrivals = await order.arrivals()
        XCTAssertEqual(arrivals, ["А.m4a", "Б.m4a", "В.m4a"])
    }

    /// Файл прежней версии хранил только движок: даты у таких записей нет, и они идут
    /// первыми и по алфавиту — как и раньше, но теперь это хотя бы оговорено.
    func testLegacyRecordsWithoutSnapshotGoFirst() async throws {
        fixture = try QueueFixture(files: ["Старая Б.m4a", "Старая А.m4a", "Новая.m4a"])
        try InterruptedRecords.saveJobs(
            ["Новая.m4a": job(created: Date(timeIntervalSince1970: 1_800_000_000))],
            legacy: ["Старая Б.m4a": .gigaam, "Старая А.m4a": .gigaam],
            to: fixture.store
        )

        let order = QueueGate(blocking: false)
        let service = fixture.service(gate: order)
        service.resumeInterrupted(in: fixture.workspace)
        await service.waitForDrain()

        let arrivals = await order.arrivals()
        XCTAssertEqual(arrivals, ["Старая А.m4a", "Старая Б.m4a", "Новая.m4a"])
    }

    private func job(created: Date, kind: TranscriptionEngineKind = .gigaam) -> TranscriptionJob {
        TranscriptionJob(id: UUID().uuidString, kind: kind, values: [:], created: created)
    }
}
