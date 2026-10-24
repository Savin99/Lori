import UIKit
import XCTest
@testable import LoriLocal

/// Фоновое сопровождение пачки без самой фоновой задачи (в симуляторе её нет): итог
/// пачки, строка под полосой с настоящими названиями и экран, который не гаснет.
@MainActor
final class RunwayBatchTests: XCTestCase {
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

    /// Запоминает, что Runway делал с экраном, и подменяет уведомления своим центром.
    @MainActor
    private final class Screen {
        var calls: [Bool] = []
        let center = NotificationCenter()

        func hooks(active: Bool = true) -> TranscriptionRunway.SystemHooks {
            var hooks = TranscriptionRunway.SystemHooks()
            hooks.isActive = { active }
            // Сильная ссылка: `Screen` ничего не держит в ответ, цикла нет, а временный
            // `Screen().hooks()` иначе умирал бы до первого вызова.
            hooks.setScreenAwake = { [self] in self.calls.append($0) }
            hooks.notifications = center
            return hooks
        }

        func resign() { center.post(name: UIApplication.willResignActiveNotification, object: nil) }
        func becomeActive() { center.post(name: UIApplication.didBecomeActiveNotification, object: nil) }
    }

    private let recorded = "Recordings/Recording-2026-09-01T12-00-00Z.m4a"

    // MARK: - Итог пачки

    /// Успех задачи решает **эта** пачка: ни давняя ошибка, ни чужая «Прервано» его не портят.
    func testCompletionIsJudgedByThisBatchOnly() {
        typealias Runway = TranscriptionRunway
        let clean = TranscriptionBatchOutcome(total: 3, succeeded: ["а", "б", "в"])
        XCTAssertTrue(Runway.completionSuccess(expired: false, outcome: clean))

        let failed = TranscriptionBatchOutcome(total: 3, succeeded: ["а", "б"], failed: ["в"])
        XCTAssertFalse(Runway.completionSuccess(expired: false, outcome: failed), "ошибка в этой пачке — неудача")

        let interrupted = TranscriptionBatchOutcome(total: 3, succeeded: ["а"], interrupted: ["б", "в"])
        XCTAssertFalse(Runway.completionSuccess(expired: false, outcome: interrupted), "обрыв — не успех")

        XCTAssertFalse(Runway.completionSuccess(expired: true, outcome: clean), "система забрала процесс")

        let cancelled = TranscriptionBatchOutcome(total: 3, succeeded: ["а"], cancelled: 2)
        XCTAssertTrue(Runway.completionSuccess(expired: false, outcome: cancelled), "отмена человеком — не сбой")

        XCTAssertTrue(Runway.completionSuccess(expired: false, outcome: nil), "итога нет — винить нечего")
    }

    /// Сквозная проверка: старая ошибка осталась в `failed`, а итог новой пачки чист.
    func testOldFailureNoLongerSpoilsALaterBatchOutcome() async throws {
        fixture = try QueueFixture(files: ["Плохая.m4a", "Хорошая.m4a"])
        let service = fixture.service(gate: QueueGate(blocking: false), failing: ["Плохая.m4a"])
        service.enqueue(try fixture.entry("Плохая.m4a"), in: fixture.workspace, using: .gigaam)
        let first = await service.waitForDrain()
        XCTAssertFalse(TranscriptionRunway.completionSuccess(expired: false, outcome: first))

        service.enqueue(try fixture.entry("Хорошая.m4a"), in: fixture.workspace, using: .gigaam)
        let second = await service.waitForDrain()

        XCTAssertFalse(service.failed.isEmpty, "старая ошибка на карточке остаётся")
        XCTAssertTrue(
            TranscriptionRunway.completionSuccess(expired: false, outcome: second),
            "а следующая пачка из-за неё неудачной уже не считается"
        )
    }

    // MARK: - Название в Dynamic Island

    func testSubtitleFallsBackToTheFileNameByDefault() async throws {
        fixture = try QueueFixture(files: [recorded])
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        let runway = TranscriptionRunway(service: service, hooks: Screen().hooks())
        service.runway = runway

        service.enqueue(try fixture.entry(recorded), in: fixture.workspace, using: .gigaam)
        await gate.waitForArrivals(1)

        XCTAssertEqual(runway.currentSubtitle(), "Recording-2026-09-01T12-00-00Z", "поведение по умолчанию прежнее")

        await gate.openAll()
        await service.waitForDrain()
    }

    func testSubtitleTakesTheTitleFromTheApp() async throws {
        fixture = try QueueFixture(files: [recorded, "Вторая.m4a", "Третья.m4a"])
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        let runway = TranscriptionRunway(service: service, hooks: Screen().hooks())
        service.runway = runway
        let titled = self.recorded
        runway.displayTitle = { path in path == titled ? "Совещание по бюджету" : nil }

        for name in [recorded, "Вторая.m4a", "Третья.m4a"] {
            service.enqueue(try fixture.entry(name), in: fixture.workspace, using: .gigaam)
        }
        await gate.waitForArrivals(1)
        XCTAssertEqual(runway.currentSubtitle(), "1 из 3 · Совещание по бюджету")

        // Дальше идёт запись без заголовка — имя файла, как раньше.
        await gate.release()
        await gate.waitForArrivals(2)
        XCTAssertEqual(runway.currentSubtitle(), "2 из 3 · Вторая")

        await gate.openAll()
        await service.waitForDrain()
    }

    /// Название — не путь: «Отчёт 27.08» не должно потерять «.08» как «расширение».
    func testTitleIsNotRunThroughPathParsing() {
        XCTAssertEqual(
            TranscriptionRunway.subtitle(done: 1, total: 5, name: "Отчёт 27.08"),
            "2 из 5 · Отчёт 27.08"
        )
        XCTAssertEqual(
            TranscriptionRunway.subtitle(done: 1, total: 5, current: "Recordings/Отчёт 27.08.m4a"),
            "2 из 5 · Отчёт 27.08",
            "для пути расширение, наоборот, отрезается"
        )
        XCTAssertEqual(TranscriptionRunway.subtitle(done: 0, total: 1, name: "Планёрка"), "Планёрка")
        XCTAssertEqual(TranscriptionRunway.subtitle(done: 0, total: 1, name: nil), "одна запись")
        XCTAssertEqual(TranscriptionRunway.subtitle(done: 2, total: 5, name: nil), "3 из 5")
        XCTAssertEqual(TranscriptionRunway.subtitle(done: 2, total: 5, name: ""), "3 из 5")
    }

    func testBlankTitleFallsBackToTheFileName() async throws {
        fixture = try QueueFixture(files: ["Планёрка.m4a"])
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        let runway = TranscriptionRunway(service: service, hooks: Screen().hooks())
        service.runway = runway
        runway.displayTitle = { _ in "   \n" }

        service.enqueue(try fixture.entry("Планёрка.m4a"), in: fixture.workspace, using: .gigaam)
        await gate.waitForArrivals(1)

        XCTAssertEqual(runway.currentSubtitle(), "Планёрка")

        await gate.openAll()
        await service.waitForDrain()
    }

    func testSubtitleWithNothingRunning() throws {
        fixture = try QueueFixture()
        let service = fixture.service(gate: QueueGate())
        let runway = TranscriptionRunway(service: service, hooks: Screen().hooks())

        XCTAssertEqual(runway.currentSubtitle(), "одна запись")
    }

    // MARK: - Экран не гаснет

    func testScreenStaysAwakeWhileTheQueueRunsAndIsReleasedWhenDrained() async throws {
        fixture = try QueueFixture(files: ["Первая.m4a", "Вторая.m4a"])
        let screen = Screen()
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        let runway = TranscriptionRunway(service: service, hooks: screen.hooks())
        service.runway = runway
        XCTAssertEqual(screen.calls, [], "пока очереди нет, экран не трогаем")

        service.enqueue(try fixture.entry("Первая.m4a"), in: fixture.workspace, using: .gigaam)
        XCTAssertEqual(screen.calls, [true], "пошла очередь — экран держим")
        service.enqueue(try fixture.entry("Вторая.m4a"), in: fixture.workspace, using: .gigaam)
        XCTAssertEqual(screen.calls, [true], "вторая запись в той же пачке флаг не дёргает")

        await gate.waitForArrivals(1)
        await gate.openAll()
        await service.waitForDrain()

        XCTAssertEqual(screen.calls, [true, false], "очередь опустела — экран отпущен")
    }

    /// Ушёл с переднего плана — отпускаем сразу, вернулся — держим снова, пока очередь идёт.
    func testScreenIsReleasedWhenTheAppResignsAndTakenBackOnReturn() async throws {
        fixture = try QueueFixture(files: ["Первая.m4a"])
        let screen = Screen()
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        let runway = TranscriptionRunway(service: service, hooks: screen.hooks())
        service.runway = runway

        service.enqueue(try fixture.entry("Первая.m4a"), in: fixture.workspace, using: .gigaam)
        await gate.waitForArrivals(1)
        XCTAssertEqual(screen.calls, [true])

        screen.resign()
        XCTAssertEqual(screen.calls, [true, false], "ушли из-под пальца — флаг не должен пережить уход")
        screen.resign()
        XCTAssertEqual(screen.calls, [true, false], "повторное уведомление ничего не меняет")

        screen.becomeActive()
        XCTAssertEqual(screen.calls, [true, false, true], "вернулись, а очередь ещё идёт")

        await gate.openAll()
        await service.waitForDrain()
        XCTAssertEqual(screen.calls, [true, false, true, false])
    }

    /// Очередь пуста — на виду приложение или нет, экран не трогаем вовсе.
    func testIdleQueueNeverHoldsTheScreen() throws {
        fixture = try QueueFixture()
        let screen = Screen()
        let service = fixture.service(gate: QueueGate())
        let runway = TranscriptionRunway(service: service, hooks: screen.hooks())

        screen.resign()
        screen.becomeActive()
        runway.applicationDidBecomeActive()
        runway.applicationDidEnterBackground()

        XCTAssertEqual(screen.calls, [])
    }

    /// Запись поставили, пока приложение не на виду, — экран держать нечем и незачем.
    func testScreenIsNotHeldWhileTheAppIsNotActive() async throws {
        fixture = try QueueFixture(files: ["Первая.m4a"])
        let screen = Screen()
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        let runway = TranscriptionRunway(service: service, hooks: screen.hooks(active: false))
        service.runway = runway

        service.enqueue(try fixture.entry("Первая.m4a"), in: fixture.workspace, using: .gigaam)
        XCTAssertEqual(screen.calls, [])

        screen.becomeActive()
        XCTAssertEqual(screen.calls, [true], "приложение вышло на передний план — теперь держим")

        await gate.waitForArrivals(1)
        await gate.openAll()
        await service.waitForDrain()
        XCTAssertEqual(screen.calls, [true, false])
    }

    /// Отмена всего тоже отпускает экран: очередь опустела, держать нечего.
    func testCancelAllReleasesTheScreen() async throws {
        fixture = try QueueFixture(files: ["Первая.m4a", "Вторая.m4a"])
        let screen = Screen()
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        let runway = TranscriptionRunway(service: service, hooks: screen.hooks())
        service.runway = runway

        for name in ["Первая.m4a", "Вторая.m4a"] {
            service.enqueue(try fixture.entry(name), in: fixture.workspace, using: .gigaam)
        }
        await gate.waitForArrivals(1)
        service.cancelAll()
        await gate.openAll()
        await service.waitForDrain()

        XCTAssertEqual(screen.calls, [true, false])
    }
}

/// Фоновая задача целиком, но на подставной системе (`FakeSystem`, `FakeRunwayTask`):
/// подача заявки и гонки её ответа, истечение и закрытие задачи, полоса, пробуждение
/// событиями фоновой передачи. Настоящей задачи в симуляторе нет, а `BGTask` не создать.
@MainActor
final class RunwayBackgroundTests: XCTestCase {
    private var fixture: QueueFixture!
    private let identifier = TranscriptionRunway.taskIdentifier

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.engineKey)
        UserDefaults.standard.set(1, forKey: TranscriptionSettings.concurrencyKey)
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.engineKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.concurrencyKey)
    }

    private func preparingText(_ runway: TranscriptionRunway) -> String? {
        guard case let .foregroundOnly(text) = runway.state else { return nil }
        return text
    }

    // MARK: Подача заявки

    /// Настоящий планировщик отвечает списком ждущих заявок с чужой очереди (замерено:
    /// `com.apple.root.utility-qos`), и обработчик это переживает. Замыкание формируется в
    /// модуле приложения (Swift 6, `systemPendingRequests`): получи оно изоляцию главного
    /// актора, как обработчик `register` до исправления, — проверка очереди уронила бы
    /// тестовый хост. Почему у этого метода ловушки нет, — в комментарии к `systemPendingRequests`.
    func testPendingRequestsAnswerOffTheMainThreadWithoutTrapping() async {
        let answered = expectation(description: "планировщик ответил списком")
        TranscriptionRunway.systemPendingRequests { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
    }

    /// Заявка принята: подана ровно с зарегистрированным идентификатором, список ждущих
    /// разобран замыканием Runway на чужой очереди, а с концом пачки заявку снимают.
    func testAcceptedSubmissionIsListedFromAForeignQueueAndWithdrawnAtTheEnd() async throws {
        fixture = try QueueFixture(files: ["Первая.m4a"])
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        let system = FakeSystem(active: true)
        var hooks = system.hooks()
        let listed = expectation(description: "список ждущих разобран")
        hooks.pendingRequests = { reply in
            // Настоящий планировщик — и замыкание самого Runway зовётся с его очереди.
            TranscriptionRunway.systemPendingRequests { identifiers in
                reply(identifiers)
                listed.fulfill()
            }
        }
        let runway = TranscriptionRunway(service: service, hooks: hooks)
        service.runway = runway

        service.enqueue(try fixture.entry("Первая.m4a"), in: fixture.workspace, using: .gigaam)
        XCTAssertEqual(system.submitted, [identifier])
        XCTAssertTrue(runway.hasLiveSubmission)
        XCTAssertTrue(preparingText(runway)?.contains("готовит") == true, "\(runway.state)")
        XCTAssertTrue(system.isOpen("Lori transcription"), "запасное окно — сразу, не дожидаясь задачи")
        await fulfillment(of: [listed], timeout: 10)

        await gate.waitForArrivals(1)
        await gate.openAll()
        await service.waitForDrain()
        XCTAssertEqual(system.cancelled, [identifier], "пачка кончилась — заявку сняли")
        XCTAssertFalse(runway.hasLiveSubmission)
        XCTAssertFalse(system.isOpen("Lori transcription"))
    }

    /// iOS 27: пачка кончилась раньше, чем планировщик ответил. `cancel` в конце пачки
    /// снимать было нечего — запоздало принятую заявку снимают по её ответу, иначе задача
    /// запустилась бы впустую.
    func testLateAcceptanceAfterTheBatchEndedIsWithdrawn() async throws {
        fixture = try QueueFixture(files: ["Первая.m4a"])
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        let system = FakeSystem(active: true)
        let submissions = SubmissionGate()
        var hooks = system.hooks()
        hooks.submitsAsynchronously = true
        hooks.submitAsync = { _ in try await submissions.submit() }
        let runway = TranscriptionRunway(service: service, hooks: hooks)
        service.runway = runway

        service.enqueue(try fixture.entry("Первая.m4a"), in: fixture.workspace, using: .gigaam)
        await submissions.waitForSubmissions(1)
        await gate.waitForArrivals(1)
        await gate.openAll()
        await service.waitForDrain()
        XCTAssertEqual(system.cancelled, [identifier])

        await submissions.answer(0)
        await eventually("ответ планировщика разобран") { runway.answeredSubmissions == 1 }
        XCTAssertEqual(system.cancelled, [identifier, identifier], "запоздало принятую заявку сняли")
        XCTAssertFalse(runway.hasLiveSubmission)
    }

    /// iOS 27: запоздалый отказ прежней заявки не трогает новую — ни её отметку, ни строку,
    /// — а запоздалое принятие прежней не снимает новую (идентификатор у них один).
    func testLateAnswersToAnOldSubmissionLeaveTheNewOneAlone() async throws {
        fixture = try QueueFixture(files: ["Первая.m4a", "Вторая.m4a"])
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        let system = FakeSystem(active: true)
        let submissions = SubmissionGate()
        var hooks = system.hooks()
        hooks.submitsAsynchronously = true
        hooks.submitAsync = { _ in try await submissions.submit() }
        let runway = TranscriptionRunway(service: service, hooks: hooks)
        service.runway = runway

        service.enqueue(try fixture.entry("Первая.m4a"), in: fixture.workspace, using: .gigaam)
        await submissions.waitForSubmissions(1)
        await gate.waitForArrivals(1)
        await gate.release()
        await service.waitForDrain()

        service.enqueue(try fixture.entry("Вторая.m4a"), in: fixture.workspace, using: .gigaam)
        await submissions.waitForSubmissions(2)
        let waitingText = preparingText(runway)

        await submissions.answer(0, error: NSError(domain: "BGTaskSchedulerErrorDomain", code: 1))
        await eventually("отказ разобран") { runway.answeredSubmissions == 1 }
        XCTAssertTrue(runway.hasLiveSubmission, "отказ прежней заявки не снимает отметку новой")
        XCTAssertEqual(preparingText(runway), waitingText, "и строку новой не подменяет")

        await submissions.answer(1)
        await eventually("принятие разобрано") { runway.answeredSubmissions == 2 }
        XCTAssertEqual(system.cancelled, [identifier], "новую не сняли — только конец первой пачки")

        await gate.waitForArrivals(2)
        await gate.openAll()
        await service.waitForDrain()
        XCTAssertEqual(system.cancelled, [identifier, identifier])
    }

    // MARK: Истечение и закрытие

    /// Истечение при облачной записи у системы: задачу отдают сразу и один раз, запись
    /// ждёт ответ («Жду ответ сервиса», а не «Прервано») и доделывается.
    func testExpiryWithACloudRecordAtTheSystemHandsTheTaskBackAtOnce() async throws {
        fixture = try QueueFixture(files: ["Облако.m4a"])
        let gate = QueueGate()
        let service = TranscriptionService(
            engines: [.elevenLabs: QueueEngine(gate: gate)],
            interruptedStore: fixture.store,
            availableMemory: { 0 },
            transfers: .init(holds: { _ in true })
        )
        let system = FakeSystem(active: false)
        let runway = TranscriptionRunway(service: service, hooks: system.hooks())
        service.runway = runway
        service.enqueue(try fixture.entry("Облако.m4a"), in: fixture.workspace, using: .elevenLabs)
        await gate.waitForArrivals(1)

        let task = FakeRunwayTask()
        let driving = Task { await runway.drive(task) }
        await eventually("задача взяла пачку") { runway.state == .running }
        XCTAssertTrue(task.hasExpirationHandler)

        await task.expireFromSystemQueue()
        await eventually("задачу отдали системе") { task.completions == [false] }
        XCTAssertFalse(task.hasExpirationHandler, "обработчик снят при закрытии")
        XCTAssertEqual(service.state(for: "Облако.m4a"), .awaitingService)
        XCTAssertTrue(preparingText(runway)?.contains("уже у сервиса") == true, "\(runway.state)")
        XCTAssertTrue(runway.wantsSubmission, "новая запись по ходу попросит новую задачу")

        await gate.openAll()
        await driving.value
        XCTAssertEqual(task.completions, [false], "закрыта один раз — конец пачки второй раз не отвечает")
        XCTAssertNoThrow(try fixture.workspace.readText(at: "Transcripts/Облако.md"))
        XCTAssertFalse(runway.wantsSubmission)
    }

    /// Истечение без записи у системы: всё прерывается, а задача закрывается, когда
    /// работа свернулась, — неуспехом.
    func testExpiryWithNothingAtTheSystemInterruptsAndClosesWhenWorkStops() async throws {
        fixture = try QueueFixture(files: ["Телефон.m4a"])
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        let system = FakeSystem(active: false)
        let runway = TranscriptionRunway(service: service, hooks: system.hooks())
        service.runway = runway
        service.enqueue(try fixture.entry("Телефон.m4a"), in: fixture.workspace, using: .gigaam)
        await gate.waitForArrivals(1)

        let task = FakeRunwayTask()
        let driving = Task { await runway.drive(task) }
        await eventually("задача взяла пачку") { runway.state == .running }
        await task.expireFromSystemQueue()
        await eventually("запись прервана") { service.state(for: "Телефон.m4a") == .interrupted }
        XCTAssertEqual(task.completions, [], "пока работа сворачивается, задачу держим")

        await gate.openAll()
        await driving.value
        XCTAssertEqual(task.completions, [false])
        XCTAssertFalse(runway.wantsSubmission)
    }

    // MARK: Полоса

    func testBarUnitsRestartOnlyWhenTheBatchShrinks() {
        typealias Runway = TranscriptionRunway
        XCTAssertEqual(Runway.barUnits(previous: 600_000, previousTotal: 2, total: 2, done: 0, partial: 0.5), 600_000,
                       "доля на миг упала — полоса назад не идёт")
        XCTAssertEqual(Runway.barUnits(previous: 600_000, previousTotal: 2, total: 2, done: 1, partial: 0.1), 1_100_000)
        XCTAssertEqual(Runway.barUnits(previous: 600_000, previousTotal: 2, total: 3, done: 0, partial: 0.5), 600_000,
                       "запись добавили — тоже не назад")
        XCTAssertEqual(Runway.barUnits(previous: 950_000, previousTotal: 2, total: 1, done: 0, partial: 0.05), 50_000,
                       "запись сняли — счёт заново, иначе максимум 0,95 держал бы полосу весь прогон следующей")
        XCTAssertEqual(Runway.barUnits(previous: 0, previousTotal: 1, total: 1, done: 1, partial: 0.9), Runway.unitsPerRecord,
                       "не выше всех единиц")
    }

    /// Сквозная проверка: А дошла до 0,855 и её сняли — полоса Б идёт с нуля и растёт,
    /// а не стоит на максимуме А, пока идёт Б. Тик полосы ловится и **пока А ещё
    /// сворачивается** (движок не вернулся, она в `running`): её доля уже не должна держать
    /// полосу, иначе сброс максимума взял бы ту же долю заново (`batchRunning`).
    func testBarKeepsMovingAfterARecordIsRemovedMidBatch() async throws {
        fixture = try QueueFixture(files: ["А.m4a", "Б.m4a"])
        let gate = QueueGate()
        let service = TranscriptionService(
            engines: [.gigaam: SteppingEngine(gate: gate, steps: ["А.m4a": [9], "Б.m4a": [1, 2]])],
            interruptedStore: fixture.store,
            availableMemory: { 0 }
        )
        let system = FakeSystem(active: true)
        let runway = TranscriptionRunway(service: service, hooks: system.hooks())
        service.runway = runway
        for name in ["А.m4a", "Б.m4a"] {
            service.enqueue(try fixture.entry(name), in: fixture.workspace, using: .gigaam)
        }
        await gate.waitForArrivals(1)

        let task = FakeRunwayTask()
        let driving = Task { await runway.drive(task) }
        await eventually("полоса дошла до доли А") { task.completedUnitCount >= 850_000 }

        service.cancel("А.m4a")
        await eventually("тик полосы после снятия") { task.totalUnitCount == TranscriptionRunway.unitsPerRecord }
        XCTAssertTrue(service.running.contains("А.m4a"), "А ещё сворачивается — ровно то окно, что проверяем")
        XCTAssertLessThan(task.completedUnitCount, 100_000, "снятая запись больше не держит полосу")
        await gate.release()
        await gate.waitForArrivals(2)
        await eventually("полоса пошла заново по Б: \(task.completedUnitCount)") {
            (90_000..<100_000).contains(task.completedUnitCount)
        }
        XCTAssertEqual(task.totalUnitCount, TranscriptionRunway.unitsPerRecord)

        await gate.release()
        await gate.waitForArrivals(3)
        await eventually("и растёт дальше: \(task.completedUnitCount)") {
            (185_000..<195_000).contains(task.completedUnitCount)
        }
        await gate.openAll()
        await driving.value
        XCTAssertEqual(task.completions, [true], "снятие человеком — не сбой")
    }

    // MARK: Пробуждение событиями фоновой передачи

    private func cloudRecordWithReceipt() throws -> TranscriptionService {
        let job = TranscriptionJob.capture(kind: .elevenLabs)
        try InterruptedRecords.saveJobs(["Облако.m4a": job], to: fixture.store)
        return TranscriptionService(
            engines: [.elevenLabs: QueueEngine(gate: QueueGate(blocking: false))],
            interruptedStore: fixture.store,
            availableMemory: { 0 },
            transfers: .init(holds: { _ in false }, hasAnswer: { _ in true }, takeDeferral: { _ in false })
        )
    }

    /// Процесс подняли в фоне ради ответа: своё окно, запись доделана по расписке, и
    /// только потом — ответ системе и конец окна.
    func testWakeInTheBackgroundSavesThenAnswersTheSystem() async throws {
        fixture = try QueueFixture(files: ["Облако.m4a"])
        let service = try cloudRecordWithReceipt()
        let system = FakeSystem(active: false)
        let runway = TranscriptionRunway(service: service, hooks: system.hooks())
        service.runway = runway
        let answered = Counter()

        runway.systemWokeForTransfers { answered.value += 1 }
        XCTAssertTrue(system.isOpen("Lori: ответ сервиса"))
        XCTAssertTrue(runway.canExecuteInBackground)
        XCTAssertEqual(answered.value, 0, "системе отвечают после сохранения, а не сразу")

        system.deliverTransferEvents()
        await eventually("пробуждение закончено") { answered.value == 1 }
        XCTAssertNoThrow(try fixture.workspace.readText(at: "Transcripts/Облако.md"))
        XCTAssertFalse(service.isInterrupted("Облако.m4a"))
        XCTAssertFalse(system.isOpen("Lori: ответ сервиса"))
    }

    /// Lori на экране: окна не нужно, и режим «только готовые ответы» тоже — прерванное
    /// поднимет обычный ход переднего плана.
    func testWakeWhileLoriIsOnScreenNeitherHoldsAWindowNorRestrictsToAnswers() async throws {
        fixture = try QueueFixture(files: ["Облако.m4a"])
        let service = try cloudRecordWithReceipt()
        let system = FakeSystem(active: true)
        let runway = TranscriptionRunway(service: service, hooks: system.hooks())
        service.runway = runway
        let answered = Counter()

        runway.systemWokeForTransfers { answered.value += 1 }
        XCTAssertEqual(system.begun, [], "на экране окно не нужно")
        system.deliverTransferEvents()
        await eventually("системе ответили") { answered.value == 1 }
        XCTAssertTrue(service.isIdle, "пробуждение само ничего не подняло")
        XCTAssertTrue(service.isInterrupted("Облако.m4a"))
    }

    /// Окно пробуждения кончилось, а работу ведёт живая задача планировщика: прерывать её
    /// нельзя — раньше обработчик окна звал `interruptEverything` без этой проверки.
    func testWakeWindowExpiryLeavesWorkUnderALiveTaskAlone() async throws {
        fixture = try QueueFixture(files: ["Телефон.m4a"])
        let gate = QueueGate()
        let service = fixture.service(gate: gate)
        let system = FakeSystem(active: false)
        let runway = TranscriptionRunway(service: service, hooks: system.hooks())
        service.runway = runway
        service.enqueue(try fixture.entry("Телефон.m4a"), in: fixture.workspace, using: .gigaam)
        await gate.waitForArrivals(1)
        let task = FakeRunwayTask()
        let driving = Task { await runway.drive(task) }
        await eventually("задача взяла пачку") { runway.state == .running }
        let answered = Counter()

        runway.systemWokeForTransfers { answered.value += 1 }
        system.expireWindow("Lori: ответ сервиса")
        XCTAssertEqual(answered.value, 1, "окно кончилось — системе ответили")
        XCTAssertFalse(system.isOpen("Lori: ответ сервиса"))
        XCTAssertFalse(service.isInterrupted("Телефон.m4a"), "работу под живой задачей окно пробуждения не прерывает")
        XCTAssertEqual(task.completions, [])

        await gate.openAll()
        await driving.value
        XCTAssertEqual(task.completions, [true])
    }

    /// Lori открыли, пока шло пробуждение: окно закрывается сразу (иначе, кончившись, оно
    /// прервало бы работу на экране), а системе отвечают, когда события доставлены.
    func testOpeningLoriEndsTheWakeWindow() async throws {
        fixture = try QueueFixture()
        let service = fixture.service(gate: QueueGate())
        let system = FakeSystem(active: false)
        let runway = TranscriptionRunway(service: service, hooks: system.hooks())
        service.runway = runway
        let answered = Counter()

        runway.systemWokeForTransfers { answered.value += 1 }
        XCTAssertTrue(system.isOpen("Lori: ответ сервиса"))
        system.active = true
        runway.applicationDidBecomeActive()
        XCTAssertFalse(system.isOpen("Lori: ответ сервиса"))
        XCTAssertEqual(answered.value, 0, "события ещё не доставлены — отвечать рано")

        system.deliverTransferEvents()
        await eventually("системе ответили") { answered.value == 1 }
    }
}

@MainActor
private final class Counter {
    var value = 0
}

/// Движок, который идёт шагами «done из 10» и на каждом ждёт шлагбаума.
private struct SteppingEngine: Transcribing {
    let name = "Шаги"
    let gate: QueueGate
    let steps: [String: [Int]]

    func isAvailable() async -> Bool { true }

    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript {
        let file = audioURL.lastPathComponent
        for done in steps[file] ?? [] {
            progress(done, 10)
            await gate.arrive("\(file) \(done)")
            try Task.checkCancellation()
        }
        progress(10, 10)
        return Transcript(text: "готово \(file)")
    }
}
