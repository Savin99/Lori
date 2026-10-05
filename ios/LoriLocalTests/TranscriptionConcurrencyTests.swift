import XCTest
@testable import LoriLocal

/// Шлагбаум для заглушек: движок доезжает до него и стоит, пока тест не откроет.
///
/// Без него «идут ли две записи одновременно» не проверить вовсе: обычная заглушка
/// возвращает текст мгновенно, и любая очередь выглядит параллельной.
private actor Gate {
    private var open = false
    private var arrived: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var expectation: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    func arrive(_ path: String) async {
        arrived.append(path)
        if let expectation, arrived.count >= expectation.count {
            self.expectation = nil
            expectation.continuation.resume()
        }
        guard !open else { return }
        await withCheckedContinuation { held.append($0) }
    }

    func openGate() {
        open = true
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }

    func arrivals() -> [String] { arrived }

    /// Ждёт, пока до шлагбаума доедут `count` записей. Опрос в цикле здесь был бы
    /// гонкой, а не проверкой: тест обязан падать по таймауту, а не проходить случайно.
    func waitForArrivals(_ count: Int) async {
        guard arrived.count < count else { return }
        await withCheckedContinuation { continuation in
            expectation = (count, continuation)
        }
    }
}

private struct GatedEngine: Transcribing {
    let name = "Шлагбаум"
    let gate: Gate

    func isAvailable() async -> Bool { true }

    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript {
        progress(0, 4)
        await gate.arrive(audioURL.lastPathComponent)
        try Task.checkCancellation()
        progress(4, 4)
        return Transcript(text: "готово \(audioURL.lastPathComponent)")
    }
}

@MainActor
final class TranscriptionConcurrencyTests: XCTestCase {
    private var root: URL!
    private var store: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "LoriLanes-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = FileManager.default.temporaryDirectory
            .appending(path: "LoriInterrupted-\(UUID().uuidString).json")
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.engineKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.concurrencyKey)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: store)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.engineKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.concurrencyKey)
    }

    private func workspace(_ names: [String]) throws -> (WorkspaceStore, [WorkspaceEntry]) {
        let workspace = WorkspaceStore(rootURL: root)
        workspace.start()
        for name in names {
            try Data("не настоящее аудио".utf8).write(to: root.appending(path: name))
        }
        try workspace.refresh()
        return (workspace, try names.map { try workspace.entry(at: $0) })
    }

    private func service(
        _ gate: Gate,
        as kind: TranscriptionEngineKind,
        memory: UInt64 = 0
    ) -> TranscriptionService {
        TranscriptionService(
            engines: [kind: GatedEngine(gate: gate)],
            interruptedStore: store,
            availableMemory: { memory }
        )
    }

    /// Умолчание — очередь по одной. Владелец попробовал две и вернулся к очереди.
    func testEngineWaitsForSummaryReleaseBeforeStarting() async throws {
        let (workspace, entries) = try workspace(["Первая.m4a"])
        let cleanup = Gate()
        let engine = Gate()
        let service = service(engine, as: .gigaam)
        service.willStart = { await cleanup.arrive("summary") }
        service.enqueue(entries[0], in: workspace, using: .gigaam)
        await cleanup.waitForArrivals(1)
        let early = await engine.arrivals()
        XCTAssertTrue(early.isEmpty)
        await cleanup.openGate()
        await engine.waitForArrivals(1)
        await engine.openGate()
        await service.waitForDrain()
        XCTAssertNotNil(workspace.existingTranscript(for: entries[0]))
    }

    func testCancelDuringSummaryReleaseDoesNotStartRecognition() async throws {
        let (workspace, entries) = try workspace(["Первая.m4a"])
        let cleanup = Gate()
        let engine = Gate()
        let service = service(engine, as: .gigaam)
        service.willStart = { await cleanup.arrive("summary") }
        service.enqueue(entries[0], in: workspace, using: .gigaam)
        await cleanup.waitForArrivals(1)
        service.cancel(entries[0].relativePath)
        await cleanup.openGate()
        await service.waitForDrain()
        let started = await engine.arrivals()
        XCTAssertTrue(started.isEmpty)
        XCTAssertNil(workspace.existingTranscript(for: entries[0]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "Первая.m4a").path))
    }

    func testRecordsQueueOneAtATimeByDefault() async throws {
        let (workspace, entries) = try workspace(["Первая.m4a", "Вторая.m4a", "Третья.m4a"])
        let gate = Gate()
        let service = service(gate, as: .gigaam)

        for entry in entries { service.enqueue(entry, in: workspace, using: .gigaam) }
        await gate.waitForArrivals(1)

        XCTAssertEqual(service.running.count, 1, "по умолчанию записи идут по одной")
        XCTAssertEqual(service.queued.count, 2)

        await gate.openGate()
        await service.waitForDrain()
        XCTAssertEqual(try workspace.entries(at: "Transcripts").count, 3, "очередь обязана дойти до конца")
        // Не только «по одной», но и «по очереди»: движок видит записи ровно в том
        // порядке, в каком их поставили. Счёт «две из трёх сделаны» без этого
        // выполнился бы и при порядке наоборот.
        let order = await gate.arrivals()
        XCTAssertEqual(order, ["Первая.m4a", "Вторая.m4a", "Третья.m4a"], "очередь идёт в порядке постановки")
    }

    /// Настройка осталась и работает: два разных аудио считаются одновременно.
    func testTwoRecordingsRunAtTheSameTimeWhenAsked() async throws {
        let (workspace, entries) = try workspace(["Первая.m4a", "Вторая.m4a", "Третья.m4a"])
        UserDefaults.standard.set(2, forKey: TranscriptionSettings.concurrencyKey)
        let gate = Gate()
        let service = service(gate, as: .gigaam)

        for entry in entries { service.enqueue(entry, in: workspace, using: .gigaam) }
        await gate.waitForArrivals(2)

        XCTAssertEqual(service.running.count, 2, "две записи обязаны идти одновременно")
        XCTAssertEqual(service.queued, ["Третья.m4a"], "третья ждёт: предел — две")
        XCTAssertTrue(service.waitingForMemory.isEmpty, "памяти хватает — это обычная очередь")

        await gate.openGate()
        await service.waitForDrain()
        XCTAssertTrue(service.isIdle)
        XCTAssertEqual(try workspace.entries(at: "Transcripts").count, 3)
    }

    /// Предел общий, а не по типу движка: облачная запись занимает то же место, что
    /// и локальная. Иначе «по одной» означало бы две — одну в сеть, одну на телефон.
    func testLimitCountsCloudAndDeviceTogether() async throws {
        let (workspace, entries) = try workspace(["Локальная.m4a", "Облачная.m4a"])
        let gate = Gate()
        let service = TranscriptionService(
            engines: [.gigaam: GatedEngine(gate: gate), .gemini: GatedEngine(gate: gate)],
            interruptedStore: store,
            availableMemory: { 0 }
        )

        service.enqueue(entries[0], in: workspace, using: .gigaam)
        service.enqueue(entries[1], in: workspace, using: .gemini)
        await gate.waitForArrivals(1)

        XCTAssertEqual(service.running.count, 1)
        XCTAssertEqual(service.queued, ["Облачная.m4a"])

        await gate.openGate()
        await service.waitForDrain()
        XCTAssertEqual(try workspace.entries(at: "Transcripts").count, 2)
    }

    /// Выше трёх настройка не поднимается, и мусор в ней не ломает очередь.
    func testConcurrencyOutsideTheRangeFallsBackToOne() {
        UserDefaults.standard.set(99, forKey: TranscriptionSettings.concurrencyKey)
        XCTAssertEqual(TranscriptionSettings.concurrency, 1)
        UserDefaults.standard.set(0, forKey: TranscriptionSettings.concurrencyKey)
        XCTAssertEqual(TranscriptionSettings.concurrency, 1)
        UserDefaults.standard.set(3, forKey: TranscriptionSettings.concurrencyKey)
        XCTAssertEqual(TranscriptionSettings.concurrency, 3)
    }

    /// Сторож по памяти: вторая локальная запись ждёт, а не роняет приложение.
    /// Ронять было чем — на 618 МБ весов Whisper вторая копия не влезает в потолок.
    func testSecondDeviceRecordWaitsWhenMemoryIsTight() async throws {
        let (workspace, entries) = try workspace(["Первая.m4a", "Вторая.m4a"])
        UserDefaults.standard.set(2, forKey: TranscriptionSettings.concurrencyKey)
        let gate = Gate()
        // Один байт свободной памяти: ноль означал бы «система не сказала».
        let service = service(gate, as: .whisper, memory: 1)

        for entry in entries { service.enqueue(entry, in: workspace, using: .whisper) }
        await gate.waitForArrivals(1)

        XCTAssertEqual(service.running.count, 1)
        XCTAssertEqual(service.waitingForMemory, ["Вторая.m4a"])
        XCTAssertTrue(service.queued.contains("Вторая.m4a"))

        await gate.openGate()
        await service.waitForDrain()
        XCTAssertTrue(service.waitingForMemory.isEmpty, "память освободилась — запись обязана пройти")
        XCTAssertEqual(try workspace.entries(at: "Transcripts").count, 2)
    }

    /// Регрессия: «Отменить» у одной записи снимало ту, что шла, а не ту, которую
    /// просили. С единственной задачей на весь сервис иначе и быть не могло.
    func testCancelTouchesOnlyTheAskedRecord() async throws {
        let (workspace, entries) = try workspace(["Ненужная.m4a", "Нужная.m4a"])
        UserDefaults.standard.set(2, forKey: TranscriptionSettings.concurrencyKey)
        let gate = Gate()
        let service = service(gate, as: .gigaam)

        for entry in entries { service.enqueue(entry, in: workspace, using: .gigaam) }
        await gate.waitForArrivals(2)

        service.cancel("Ненужная.m4a")
        await gate.openGate()
        await service.waitForDrain()

        XCTAssertNoThrow(
            try workspace.readText(at: "Transcripts/Нужная.md"),
            "соседняя запись обязана досчитаться"
        )
        XCTAssertThrowsError(try workspace.readText(at: "Transcripts/Ненужная.md"))
        XCTAssertNil(service.error(for: "Ненужная.m4a"), "отмена человеком — не ошибка")
    }

    func testCloudJobResumesOnReturnWithOriginalSettings() async throws {
        let (workspace, entries) = try workspace(["Возврат.m4a"])
        let key = TranscriptionSettings.elevenLabsModeKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set("verbatim", forKey: key)
        let expected = TranscriptionSettings.mode(for: .elevenLabs)?.title
        let gate = Gate()
        let service = service(gate, as: .elevenLabs)
        service.enqueue(entries[0], in: workspace, using: .elevenLabs)
        await gate.waitForArrivals(1)
        service.applicationDidEnterBackground()
        service.interruptEverything()
        await gate.openGate()
        await service.waitForDrain()
        XCTAssertTrue(service.interrupted.contains("Возврат.m4a"))
        UserDefaults.standard.set("clean", forKey: key)
        service.applicationDidBecomeActive(in: workspace)
        await service.waitForDrain()
        let document = TranscriptDocument.parse(try workspace.readText(at: "Transcripts/Возврат.md"))
        XCTAssertEqual(document.mode, expected)
        XCTAssertTrue(service.interrupted.isEmpty)
        XCTAssertNil(service.error(for: "Возврат.m4a"))
    }

    // MARK: - Обрыв

    /// Пока запись идёт, она записана в файл. Смахнули приложение — обработчик
    /// истечения не позовут вовсе, и файл остаётся единственным следом.
    func testRunningRecordIsWrittenToDiskWhileItWorks() async throws {
        let (workspace, entries) = try workspace(["Долгая.m4a"])
        let gate = Gate()
        let service = service(gate, as: .gigaam)

        service.enqueue(entries[0], in: workspace, using: .gigaam)
        await gate.waitForArrivals(1)
        XCTAssertEqual(InterruptedRecords.load(from: store), ["Долгая.m4a": .gigaam])

        await gate.openGate()
        await service.waitForDrain()
        XCTAssertTrue(InterruptedRecords.load(from: store).isEmpty, "досчитанная запись из файла уходит")
    }

    func testInterruptionIsNotAnErrorAndSurvivesRestart() async throws {
        let (workspace, entries) = try workspace(["Прерванная.m4a", "Ждущая.m4a"])
        UserDefaults.standard.set(1, forKey: TranscriptionSettings.concurrencyKey)
        let gate = Gate()
        let service = service(gate, as: .gigaam)

        for entry in entries { service.enqueue(entry, in: workspace, using: .gigaam) }
        await gate.waitForArrivals(1)

        service.interruptEverything()
        await gate.openGate()
        await service.waitForDrain()

        XCTAssertEqual(service.interrupted, ["Прерванная.m4a", "Ждущая.m4a"], "и та, что шла, и та, что ждала")
        XCTAssertNil(service.error(for: "Прерванная.m4a"), "обрыв системой — не ошибка движка")
        XCTAssertEqual(
            InterruptedRecords.load(from: store),
            ["Прерванная.m4a": .gigaam, "Ждущая.m4a": .gigaam],
            "движок обязан храниться вместе с путём"
        )

        // Новый запуск: те же записи считаются заново, с нуля.
        let restarted = TranscriptionService(
            engines: [.gigaam: GatedEngine(gate: Gate())],
            interruptedStore: store,
            availableMemory: { 0 }
        )
        XCTAssertEqual(restarted.interrupted, ["Прерванная.m4a", "Ждущая.m4a"])
        restarted.resumeInterrupted(in: workspace)
        XCTAssertEqual(restarted.batchCount, 2)
        XCTAssertTrue(restarted.interrupted.isEmpty, "поставленная заново запись больше не «прервана»")
        restarted.cancelAll()
    }

    /// Самое важное правило автовосстановления: тем же движком, каким считали, и
    /// облачные — не сами. Иначе запись, прерванная на GigaAM, уезжает в Gemini просто
    /// потому, что в настройках теперь стоит он: молча подменённый движок плюс 22 МБ
    /// звука третьей стороне без нажатия. Ровно это и случилось на живом прогоне.
    func testResumeKeepsTheEngineAndNeverSendsToCloudOnItsOwn() async throws {
        let (workspace, _) = try workspace(["Локальная.m4a", "Облачная.m4a"])
        InterruptedRecords.save(["Локальная.m4a": .gigaam, "Облачная.m4a": .gemini], to: store)
        // В настройках теперь Gemini — и это не должно ничего решать.
        UserDefaults.standard.set(TranscriptionEngineKind.gemini.rawValue, forKey: TranscriptionSettings.engineKey)
        let gate = Gate()
        let service = TranscriptionService(
            engines: [.gigaam: GatedEngine(gate: gate), .gemini: GatedEngine(gate: gate)],
            interruptedStore: store,
            availableMemory: { 0 }
        )

        service.resumeInterrupted(in: workspace)
        await gate.waitForArrivals(1)

        XCTAssertEqual(service.running, ["Локальная.m4a"], "перезапускается только локальная")
        XCTAssertTrue(service.queued.isEmpty, "облачная в очередь не встаёт вовсе")
        XCTAssertTrue(
            service.isInterrupted("Облачная.m4a"),
            "облачная остаётся «Прервано»: отправлять звук наружу без нажатия нельзя"
        )

        await gate.openGate()
        await service.waitForDrain()
        XCTAssertNoThrow(try workspace.readText(at: "Transcripts/Локальная.md"))
        XCTAssertThrowsError(try workspace.readText(at: "Transcripts/Облачная.md"))
    }

    /// Экран обязан знать, каким движком считали оборванную запись: облачную
    /// приложение само не поднимет, и сказать об этом можно только зная движок.
    /// Раньше экран обещал «начнётся заново» всем подряд — облачной записи это
    /// прямое враньё, и человек ждал перезапуска, которого не будет.
    func testInterruptedEngineIsKnownToTheScreen() throws {
        let (_, _) = try workspace(["Локальная.m4a", "Облачная.m4a"])
        InterruptedRecords.save(["Локальная.m4a": .gigaam, "Облачная.m4a": .gemini], to: store)
        let service = TranscriptionService(
            engines: [.gigaam: GatedEngine(gate: Gate())],
            interruptedStore: store,
            availableMemory: { 0 }
        )

        XCTAssertEqual(service.interruptedEngine(for: "Локальная.m4a"), .gigaam)
        XCTAssertEqual(service.interruptedEngine(for: "Облачная.m4a"), .gemini)
        XCTAssertEqual(service.interruptedEngine(for: "Облачная.m4a")?.leavesDevice, true)
        XCTAssertNil(service.interruptedEngine(for: "Небывалая.m4a"))
    }

    /// Записи могло не стать, пока приложение не работало: список не должен
    /// вечно тащить путь, которого нет.
    func testResumeForgetsRecordsThatNoLongerExist() async throws {
        let (workspace, _) = try workspace(["Есть.m4a"])
        InterruptedRecords.save(["Есть.m4a": .gigaam, "Удалена.m4a": .gigaam], to: store)
        let service = TranscriptionService(
            engines: [.gigaam: GatedEngine(gate: Gate())],
            interruptedStore: store,
            availableMemory: { 0 }
        )

        service.resumeInterrupted(in: workspace)

        XCTAssertEqual(service.batchCount, 1)
        XCTAssertNil(InterruptedRecords.load(from: store)["Удалена.m4a"])
        service.cancelAll()
    }
}
