import XCTest
@testable import LoriLocal

/// Когда запускать модель заголовков, а когда воздержаться.
@MainActor
final class SummaryRunnerTests: XCTestCase {
    private var storeURL: URL!
    private var store: SummaryStore!

    override func setUpWithError() throws {
        storeURL = FileManager.default.temporaryDirectory.appending(path: "run-\(UUID().uuidString).json")
        store = SummaryStore(url: storeURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeURL)
    }

    /// Передний план задаётся явно: настоящий `UIApplication.applicationState`
    /// под тестовым хостом непредсказуем, и проверка про фон стала бы плавающей.
    private func runner(
        free: UInt64,
        answer: Summarizer.Summary = .init(title: "Заголовок", detail: "Описание"),
        models: SummaryModelStore? = nil,
        foreground: Bool = true
    ) -> SummaryRunner {
        SummaryRunner(
            models: models ?? SummaryModelStore(root: FileManager.default.temporaryDirectory),
            store: store,
            availableMemory: { free },
            isForeground: { foreground },
            summarize: { _, _, _ in answer }
        )
    }

    /// Без скачанных весов ничего не запускается — приложение работает как раньше.
    func testNothingRunsWithoutWeights() {
        let runner = runner(free: 8_000_000_000)

        XCTAssertNil(runner.choose(), "весов нет — и модели нет")
    }

    /// Крупная модель требует памяти; если её мало, берём лёгкую.
    func testHeavyModelIsSkippedWhenMemoryIsTight() {
        let models = StubModels(installed: [.heavy, .light])

        let tight = SummaryRunner(models: models, store: store, availableMemory: { 2_000_000_000 })
        let roomy = SummaryRunner(models: models, store: store, availableMemory: { 6_000_000_000 })

        XCTAssertEqual(tight.choose(), .light, "на крупную памяти не хватает")
        XCTAssertEqual(roomy.choose(), .heavy, "есть память — берём модель получше")
    }

    /// Симулятор и часть устройств отвечают нулём на вопрос о свободной памяти.
    /// Ноль — это «неизвестно», а не «памяти нет»: на этом проверка уже отказала
    /// при скачанных весах и говорила, что модель не скачана.
    func testUnknownMemoryDoesNotBlockTheModel() {
        let runner = SummaryRunner(
            models: StubModels(installed: [.light]),
            store: store,
            availableMemory: { 0 }
        )

        XCTAssertEqual(runner.choose(), .light)
        XCTAssertNil(runner.obstacle())
    }

    /// Причины различаются: «нет весов» и «мало памяти» — разные сообщения.
    func testObstacleTellsWeightsFromMemory() {
        let empty = runner(free: 8_000_000_000)
        XCTAssertEqual(empty.obstacle(), .noWeights)

        let tight = SummaryRunner(
            models: StubModels(installed: [.heavy]),
            store: store,
            availableMemory: { 500_000_000 }
        )
        XCTAssertEqual(tight.obstacle(), .notEnoughMemory)
        XCTAssertTrue(tight.obstacle()?.message.contains("памяти") == true)
    }

    /// Совсем мало памяти — не запускаем ничего.
    func testNothingRunsWhenMemoryIsExhausted() {
        let runner = SummaryRunner(
            models: StubModels(installed: [.heavy, .light]),
            store: store,
            availableMemory: { 300_000_000 }
        )

        XCTAssertNil(runner.choose())
    }

    /// Короткую заметку заголовком не украшают.
    func testShortTranscriptIsLeftAlone() {
        let runner = runner(free: 8_000_000_000, models: StubModels(installed: [.light]))

        runner.summarize(path: "a.m4a", text: "Проверка связи.")

        XCTAssertNil(runner.running)
        XCTAssertNil(store.title(for: "a.m4a"))
    }

    /// Заголовок, заданный человеком, модель не переписывает.
    func testManualTitleIsNotOverwritten() async {
        store.setManual(title: "Моё имя", for: "a.m4a")
        let runner = runner(free: 8_000_000_000, models: StubModels(installed: [.light]))

        runner.summarize(path: "a.m4a", text: String(repeating: "текст расшифровки ", count: 20))
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(store.title(for: "a.m4a"), "Моё имя")
    }

    /// Нажатие «Придумать заголовок» должно работать и тогда, когда заголовок
    /// уже есть: иначе повторное нажатие молча ничего не делает, и это выглядит
    /// как сломанная кнопка. Ровно так и было на устройстве.
    func testForcedRunReplacesExistingTitle() async {
        store.store(title: "Вот обобщённый и структурированный текст", detail: "…", for: "a.m4a")
        let runner = runner(free: 8_000_000_000, models: StubModels(installed: [.light]))

        runner.summarize(path: "a.m4a", text: String(repeating: "текст расшифровки ", count: 20), force: true)
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(store.title(for: "a.m4a"), "Заголовок", "кнопка перебивает прежний заголовок")
    }

    /// Автомат чужого не трогает: заголовок уже есть — и ладно.
    func testAutomaticRunKeepsExistingTitle() async {
        store.store(title: "Уже придуманный", detail: "…", for: "a.m4a")
        let runner = runner(free: 8_000_000_000, models: StubModels(installed: [.light]))

        runner.summarize(path: "a.m4a", text: String(repeating: "текст расшифровки ", count: 20))
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(store.title(for: "a.m4a"), "Уже придуманный")
    }

    func testSummaryIsStored() async {
        let runner = runner(free: 8_000_000_000, models: StubModels(installed: [.light]))

        runner.summarize(path: "a.m4a", text: String(repeating: "текст расшифровки ", count: 20))
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(store.title(for: "a.m4a"), "Заголовок")
        XCTAssertEqual(store.detail(for: "a.m4a"), "Описание")
        XCTAssertNil(runner.running, "после работы бегунок свободен")
    }

    func testImportedRecordingReceivesAutomaticTitle() async throws {
        store.setImported(title: "Новая запись 5", for: "a.m4a")
        let runner = runner(free: 8_000_000_000, models: StubModels(installed: [.light]))
        runner.summarize(path: "a.m4a", text: Self.transcript)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.title(for: "a.m4a"), "Заголовок")
    }

    func testExplicitRegenerationReplacesLegacyImportedTitleWithExistingDescription() async throws {
        store.setManual(title: "Новая запись 5", for: "a.m4a")
        store.store(title: "Невидимый ответ модели", detail: "Описание было", for: "a.m4a")
        XCTAssertFalse(store.needsSummary(for: "a.m4a"))
        XCTAssertTrue(store.allowGeneratedTitle(for: "a.m4a"))
        let runner = runner(free: 8_000_000_000, models: StubModels(installed: [.light]))
        runner.summarize(path: "a.m4a", text: Self.transcript, force: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.title(for: "a.m4a"), "Заголовок")
    }

    // MARK: - Фон: модель на графическом процессоре

    /// Текст, которого хватает, чтобы модель взялась за работу.
    private static let transcript = String(repeating: "текст расшифровки ", count: 20)

    /// Переключаемый передний план: уход в фон и возвращение в одном тесте.
    private final class Stage {
        var isForeground: Bool
        init(_ isForeground: Bool) { self.isForeground = isForeground }
    }

    /// Сколько раз модель бралась за работу. Считается из `@Sendable`-замыкания,
    /// поэтому под замком.
    private final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private func runner(stage: Stage, attempts: Attempts? = nil, delay: Duration = .zero) -> SummaryRunner {
        SummaryRunner(
            models: StubModels(installed: [.light]),
            store: store,
            availableMemory: { 8_000_000_000 },
            isForeground: { stage.isForeground },
            summarize: { _, _, _ in
                attempts?.bump()
                if delay > .zero { try await Task.sleep(for: delay) }
                return .init(title: "Заголовок", detail: "Описание")
            }
        )
    }

    /// **Регрессия, стоившая процесса.** Модель заголовков считает на графическом
    /// процессоре, а в фоне iOS доступа к нему не даёт: команда возвращается с
    /// ошибкой, MLX бросает из неё C++-исключение с очереди Metal, и приложение
    /// гибнет по `abort()`. Крэш-лог с телефона за 2 сентября: облачная
    /// расшифровка дошла при свёрнутом приложении, заголовок взялся считаться и
    /// убил процесс через 12 секунд.
    func testNothingRunsWhileTheAppIsInBackground() async {
        let runner = runner(free: 8_000_000_000, models: StubModels(installed: [.light]), foreground: false)

        runner.summarize(path: "a.m4a", text: Self.transcript)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(runner.running, "в фоне модель не запускается")
        XCTAssertNil(store.title(for: "a.m4a"), "и заголовка не появляется")
    }

    /// Отложенное не теряется: вернулись в приложение — заголовок посчитался.
    func testWorkPostponedInBackgroundRunsOnReturn() async {
        let stage = Stage(false)
        let runner = runner(stage: stage)

        runner.summarize(path: "a.m4a", text: Self.transcript)
        XCTAssertNil(store.title(for: "a.m4a"), "в фоне ничего не считалось")

        stage.isForeground = true
        runner.applicationDidBecomeActive()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(store.title(for: "a.m4a"), "Заголовок")
    }

    /// Уход в фон обрывает счёт — и возвращает запись в очередь, а не теряет её.
    /// Чекпоинтов у генерации нет, поэтому по возвращении она идёт заново.
    func testLeavingTheAppStopsTheModelAndKeepsTheWork() async {
        let stage = Stage(true)
        let attempts = Attempts()
        let runner = runner(stage: stage, attempts: attempts, delay: .seconds(5))

        runner.summarize(path: "a.m4a", text: Self.transcript)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(runner.running, "a.m4a", "счёт идёт")

        stage.isForeground = false
        runner.applicationWillResignActive()
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(runner.running, "уход в фон оборвал счёт")
        XCTAssertNil(store.title(for: "a.m4a"), "оборванный ответ не сохраняется")

        stage.isForeground = true
        runner.applicationDidBecomeActive()
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(attempts.value, 2, "работа вернулась в очередь и пошла заново")
    }

    /// Две расшифровки, закончившиеся подряд, дают заголовок обеим. Раньше вторая
    /// молча терялась, и выглядело это как «модель срабатывает через раз».
    func testSecondRecordWaitsInsteadOfBeingDropped() async {
        let runner = runner(stage: Stage(true), delay: .milliseconds(120))

        runner.summarize(path: "a.m4a", text: Self.transcript)
        runner.summarize(path: "b.m4a", text: Self.transcript)
        try? await Task.sleep(for: .seconds(1))

        XCTAssertEqual(store.title(for: "a.m4a"), "Заголовок")
        XCTAssertEqual(store.title(for: "b.m4a"), "Заголовок", "вторая дождалась очереди")
    }

    /// Все отложенные записи должны дождаться обработки.
    func testPostponedQueueDoesNotDropOlderTranscripts() async {
        let stage = Stage(false)
        let runner = runner(stage: stage)
        let paths = (1...6).map { "запись-\($0).m4a" }

        for path in paths { runner.summarize(path: path, text: Self.transcript) }
        stage.isForeground = true
        runner.applicationDidBecomeActive()
        try? await Task.sleep(for: .seconds(1))

        let done = paths.filter { store.title(for: $0) != nil }
        XCTAssertEqual(done.count, paths.count, "все задания должны сохраниться")
        XCTAssertEqual(done, paths, "старые задания не теряются")
    }

    func testMemoryRecoveryRetriesWithoutAnotherForegroundEvent() async {
        let recovered = Attempts()
        let runner = SummaryRunner(
            models: StubModels(installed: [.light]), store: store,
            availableMemory: { recovered.value == 0 ? 100_000_000 : 8_000_000_000 },
            isForeground: { true },
            summarize: { _, _, _ in .init(title: "Готово", detail: "Описание") }
        )
        runner.summarize(path: "memory.m4a", text: Self.transcript)
        XCTAssertEqual(runner.pendingCount, 1)
        XCTAssertNil(runner.running)
        recovered.bump()
        let deadline = Date().addingTimeInterval(7)
        while runner.pendingCount > 0 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.detail(for: "memory.m4a"), "Описание")
        XCTAssertEqual(runner.pendingCount, 0)
    }

    func testPendingSummarySurvivesRunnerRestartAndPreservesManualTitle() async {
        store.setManual(title: "Моё интервью", for: "a.m4a")
        let first = runner(stage: Stage(false))
        first.summarize(path: "a.m4a", text: Self.transcript)
        XCTAssertEqual(first.pendingCount, 1)
        let resumed = runner(stage: Stage(true))
        XCTAssertEqual(resumed.pendingCount, 1)
        resumed.applicationDidBecomeActive()
        try? await Task.sleep(for: .milliseconds(300))
        let reloaded = SummaryStore(url: storeURL)
        XCTAssertEqual(reloaded.title(for: "a.m4a"), "Моё интервью")
        XCTAssertEqual(reloaded.detail(for: "a.m4a"), "Описание")
        XCTAssertEqual(resumed.pendingCount, 0)
    }

    func testTranscriptionWaitsForSummaryCleanupAndKeepsPendingWork() async {
        let started = expectation(description: "генерация началась")
        let released = Attempts()
        let runner = SummaryRunner(
            models: StubModels(installed: [.light]), store: store,
            availableMemory: { 8_000_000_000 }, isForeground: { true },
            summarize: { _, _, _ in
                started.fulfill()
                do { try await Task.sleep(for: .seconds(20)) } catch {
                    // Освобождение модели продолжается после получения отмены.
                    await Task {
                        try? await Task.sleep(for: .milliseconds(100))
                        released.bump()
                    }.value
                    throw CancellationError()
                }
                return .init(title: "Не должно сохраниться", detail: "Описание")
            }
        )
        runner.summarize(path: "a.m4a", text: Self.transcript)
        await fulfillment(of: [started], timeout: 2)
        await runner.prepareForTranscription()
        XCTAssertEqual(released.value, 1)
        XCTAssertNil(runner.running)
        XCTAssertEqual(runner.pendingCount, 1)
        XCTAssertNil(store.title(for: "a.m4a"))
    }

    /// Каталог с подставленным списком скачанного: настоящих весов в тестах нет.
    func testOneFailedRecordDoesNotBlockOthersAndRetriesOnReturn() async throws {
        let recovered = Attempts()
        let runner = SummaryRunner(
            models: StubModels(installed: [.light]), store: store,
            availableMemory: { 8_000_000_000 }, isForeground: { true },
            summarize: { _, _, text in
                if text.hasPrefix("Первая"), recovered.value == 0 { throw Summarizer.Failure.emptyAnswer }
                return .init(title: "Готовый заголовок", detail: "Описание записи")
            }
        )
        runner.summarize(path: "first.m4a", text: "Первая " + Self.transcript)
        runner.summarize(path: "second.m4a", text: "Вторая " + Self.transcript)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(store.title(for: "first.m4a"))
        XCTAssertEqual(store.title(for: "second.m4a"), "Готовый заголовок")
        XCTAssertEqual(runner.pendingCount, 1)
        XCTAssertNil(runner.running, "ошибка не запускает бесконечный цикл")

        recovered.bump()
        runner.applicationDidBecomeActive()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.title(for: "first.m4a"), "Готовый заголовок")
        XCTAssertEqual(runner.pendingCount, 0)
    }

    private final class StubModels: SummaryModelStore {
        private let ready: Set<SummaryVariant>

        init(installed: Set<SummaryVariant>) {
            ready = installed
            super.init(root: FileManager.default.temporaryDirectory)
        }

        override func isInstalled(_ variant: SummaryVariant) -> Bool { ready.contains(variant) }
    }
}
