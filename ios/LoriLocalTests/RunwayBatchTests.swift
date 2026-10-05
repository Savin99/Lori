import UIKit
import XCTest
@testable import LoriLocal

/// Фоновое сопровождение пачки без самой фоновой задачи (в симуляторе её нет): итог
/// пачки, строка под полосой с настоящими названиями и экран, который не гаснет.
@MainActor
final class RunwayBatchTests: XCTestCase {
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
