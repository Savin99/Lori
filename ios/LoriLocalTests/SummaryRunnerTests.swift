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
        try? FileManager.default.removeItem(at: storeURL.deletingPathExtension().appendingPathExtension("pending.json"))
        for root in workspaceRoots { try? FileManager.default.removeItem(at: root) }
    }

    private var workspaceRoots: [URL] = []

    /// Рабочая папка с записями и их расшифровками. Возраст записи задаёт
    /// порядок в списке: новые сверху.
    private func makeWorkspace(_ records: [(name: String, text: String, age: TimeInterval)]) throws -> WorkspaceStore {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LoriRunner-\(UUID().uuidString)", directoryHint: .isDirectory)
        workspaceRoots.append(root)
        let transcripts = root.appending(path: "Transcripts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        for record in records {
            let audio = root.appending(path: record.name)
            try Data("звук".utf8).write(to: audio)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-record.age)], ofItemAtPath: audio.path)
            let base = (record.name as NSString).deletingPathExtension
            try Data(Transcript(text: record.text).markdown(title: base, engine: "Стаб", mode: "Быстрый текст").utf8)
                .write(to: transcripts.appending(path: "\(base).md"))
        }
        let workspace = WorkspaceStore(rootURL: root)
        try workspace.refresh()
        return workspace
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

    /// Очередь на диске хранит только пути: после перезапуска текст перечитывается
    /// из файла расшифровки, поэтому у второго бегунка есть рабочая папка.
    func testPendingSummarySurvivesRunnerRestartAndPreservesManualTitle() async throws {
        let workspace = try makeWorkspace([("a.m4a", Self.transcript, 0)])
        store.setManual(title: "Моё интервью", for: "a.m4a")
        let first = runner(stage: Stage(false))
        first.summarize(path: "a.m4a", text: Self.transcript)
        XCTAssertEqual(first.pendingCount, 1)
        let resumed = runner(stage: Stage(true))
        resumed.connect(to: workspace)
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

    // MARK: - Очередь без текстов и без весов

    /// **Регрессия.** В файл очереди ложился весь текст расшифровки, и без
    /// скачанных весов он копил полные тексты всех записей бессрочно.
    func testPendingQueueOnDiskHoldsNoTranscriptText() throws {
        let runner = runner(stage: Stage(false))

        runner.summarize(path: "a.m4a", text: Self.transcript)

        let saved = String(decoding: try Data(contentsOf: store.pendingQueueURL), as: UTF8.self)
        XCTAssertTrue(saved.contains("a.m4a"))
        XCTAssertFalse(saved.contains("расшифровки"), "на диске только путь")
    }

    /// Без весов автоматические заявки не копятся: после скачивания записи без
    /// заголовка найдутся сами.
    func testAutomaticRequestsDoNotPileUpWithoutWeights() {
        let runner = runner(free: 8_000_000_000, models: StubModels(installed: []))

        runner.summarize(path: "a.m4a", text: Self.transcript)

        XCTAssertEqual(runner.pendingCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingQueueURL.path))
    }

    /// «Придумать заголовок» без модели — не ошибка, а предложение скачать: заявка
    /// ждёт веса и после скачивания выполняется сама.
    func testExplicitRequestWaitsForTheModelAndRunsAfterDownload() async throws {
        let workspace = try makeWorkspace([("a.m4a", Self.transcript, 0)])
        let models = SwitchableModels(installed: [])
        let runner = SummaryRunner(
            models: models, store: store, availableMemory: { 8_000_000_000 }, isForeground: { true },
            summarize: { _, _, _ in .init(title: "Заголовок", detail: "Описание") }
        )
        runner.connect(to: workspace)
        store.setManual(title: "Моё имя", for: "a.m4a")

        XCTAssertEqual(runner.requestTitle(for: "a.m4a"), .needsModel)
        XCTAssertEqual(runner.pendingCount, 1, "просьба ждёт модель")
        XCTAssertEqual(store.title(for: "a.m4a"), "Моё имя", "до ответа имя на месте")

        models.install(.light)
        await waitUntil { self.store.title(for: "a.m4a") == "Заголовок" }

        XCTAssertEqual(store.title(for: "a.m4a"), "Заголовок", "человек сам попросил заменить имя")
        XCTAssertEqual(runner.pendingCount, 0)
    }

    func testExplicitRequestForTooShortTextIsRefused() {
        let runner = runner(free: 8_000_000_000, models: StubModels(installed: [.light]))

        XCTAssertEqual(runner.requestTitle(for: "a.m4a", text: "Коротко."), .tooShort)
        XCTAssertEqual(runner.pendingCount, 0)
    }

    // MARK: - Перерасшифровка

    /// Расшифровку переписали — заголовок придумывается заново, а прежний виден,
    /// пока не придёт новый. Тот же текст (перезапуск тем же движком) модель
    /// второй раз не гоняет.
    func testRewrittenTranscriptRegeneratesTheTitleButTheSameTextDoesNot() async throws {
        let attempts = Attempts()
        let runner = SummaryRunner(
            models: StubModels(installed: [.light]), store: store,
            availableMemory: { 8_000_000_000 }, isForeground: { true },
            summarize: { _, _, text in
                attempts.bump()
                try await Task.sleep(for: .milliseconds(50))
                return .init(title: text.hasPrefix("Второй") ? "Второй заголовок" : "Первый заголовок", detail: "Описание")
            }
        )

        runner.summarize(path: "a.m4a", text: "Первый " + Self.transcript)
        await waitUntil { self.store.title(for: "a.m4a") == "Первый заголовок" && runner.running == nil }
        runner.summarize(path: "a.m4a", text: "Первый " + Self.transcript)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(attempts.value, 1, "тот же текст — тот же заголовок")

        runner.summarize(path: "a.m4a", text: "Второй " + Self.transcript)
        XCTAssertEqual(store.title(for: "a.m4a"), "Первый заголовок", "старый виден, пока считается новый")
        await waitUntil { self.store.title(for: "a.m4a") == "Второй заголовок" }
        XCTAssertEqual(attempts.value, 2)
        XCTAssertFalse(store.needsSummary(for: "a.m4a"))
    }

    // MARK: - Записи без заголовка после скачивания модели

    /// После скачивания весов заголовки придумываются сами: новые записи первыми
    /// и не больше `backlogLimit` за раз. Остальное — по кнопке в настройках.
    func testRecoveryAfterDownloadTakesNewestFirstAndIsBounded() async throws {
        let total = SummaryRunner.backlogLimit + 2
        let records = (1...total).map { ("запись-\($0).m4a", "Запись \($0). " + Self.transcript, TimeInterval($0 * 60)) }
        let workspace = try makeWorkspace(records)
        let order = Collected()
        let models = SwitchableModels(installed: [])
        let runner = SummaryRunner(
            models: models, store: store, availableMemory: { 8_000_000_000 }, isForeground: { true },
            summarize: { _, _, text in
                order.append(text)
                return .init(title: "Заголовок", detail: "Описание")
            }
        )
        runner.connect(to: workspace)
        runner.applicationDidBecomeActive()
        XCTAssertEqual(runner.pendingCount, 0, "без модели очередь не копится")

        models.install(.light)
        await waitUntil { order.values.count == SummaryRunner.backlogLimit && runner.pendingCount == 0 && runner.running == nil }

        let numbers = order.values.map { text in
            Int(text.dropFirst("Запись ".count).prefix { $0.isNumber }) ?? 0
        }
        XCTAssertEqual(numbers, Array(1...SummaryRunner.backlogLimit), "новые первыми, не больше предела")
        XCTAssertEqual(runner.backlogCount, 2, "остальные ждут")

        runner.summarizeBacklog()
        await waitUntil { order.values.count == total && runner.running == nil }
        XCTAssertEqual(order.values.count, total)
        XCTAssertEqual(runner.backlogCount, 0)
    }

    /// Короткую расшифровку не перечитывают на каждом возвращении в приложение.
    func testShortTranscriptIsNotRereadOnEveryReturn() async throws {
        let workspace = try makeWorkspace([("a.m4a", "Коротко.", 0)])
        let attempts = Attempts()
        let runner = SummaryRunner(
            models: StubModels(installed: [.light]), store: store,
            availableMemory: { 8_000_000_000 }, isForeground: { true },
            summarize: { _, _, _ in attempts.bump(); return .init(title: "Заголовок", detail: "Описание") }
        )
        runner.connect(to: workspace)

        runner.applicationDidBecomeActive()
        await waitUntil { runner.pendingCount == 0 && runner.running == nil }
        runner.applicationDidBecomeActive()

        XCTAssertEqual(runner.pendingCount, 0, "короткая запись больше не встаёт в очередь")
        XCTAssertEqual(attempts.value, 0)
    }

    /// Почему заголовок не считается — видно в журнале работы.
    func testIdleReasonsAreWrittenToTheJournal() {
        let background = runner(stage: Stage(false))
        background.summarize(path: "журнал-фон.m4a", text: Self.transcript)
        let empty = runner(free: 8_000_000_000, models: StubModels(installed: []))
        empty.summarize(path: "журнал-без-модели.m4a", text: Self.transcript)
        empty.summarize(path: "журнал-коротко.m4a", text: "Коротко.")

        let journal = (try? String(contentsOf: Journal.url, encoding: .utf8)) ?? ""
        XCTAssertTrue(journal.contains("заголовки: жду возвращения в Lori"))
        XCTAssertTrue(journal.contains("у «журнал-без-модели» пока заголовок из первой фразы"))
        XCTAssertTrue(journal.contains("текст короче 80 знаков — «журнал-коротко»"))
    }

    /// Пока памяти мало, drain зовут каждые 5 секунд и на каждое возвращение.
    /// Причина пишется в журнал один раз, а не строкой на каждый заход, хотя
    /// число свободных мегабайт в строке каждый раз другое.
    func testShortMemoryIsLoggedOnceNotOnEveryRetry() {
        func occurrences() -> Int {
            let journal = (try? String(contentsOf: Journal.url, encoding: .utf8)) ?? ""
            return journal.components(separatedBy: "заголовки: мало памяти").count - 1
        }
        let before = occurrences()
        let probe = Attempts()
        let runner = SummaryRunner(
            models: StubModels(installed: [.light]), store: store,
            availableMemory: { probe.bump(); return 100_000_000 + UInt64(probe.value) * 1_048_576 },
            isForeground: { true },
            summarize: { _, _, _ in .init(title: "Заголовок", detail: "Описание") }
        )

        runner.summarize(path: "память.m4a", text: Self.transcript)
        runner.applicationDidBecomeActive()
        runner.applicationDidBecomeActive()
        runner.applicationWillResignActive()

        XCTAssertEqual(occurrences() - before, 1)
    }

    /// Явная просьба по записи без расшифровки не пропадает молча.
    func testExplicitRequestWithoutTranscriptSaysWhy() async throws {
        let workspace = try makeWorkspace([])
        try Data("звук".utf8).write(to: workspaceRoots[0].appending(path: "без-текста.m4a"))
        try workspace.refresh()
        let runner = runner(free: 8_000_000_000, models: StubModels(installed: [.light]))
        runner.connect(to: workspace)

        XCTAssertEqual(runner.requestTitle(for: "без-текста.m4a"), .queued)
        await waitUntil { runner.failure != nil }

        XCTAssertEqual(runner.failure, "У записи нет расшифровки — заголовок придумывать не из чего.")
        XCTAssertEqual(runner.pendingCount, 0)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Что модель получила, по порядку. Пишется из `@Sendable`-замыкания.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ item: String) { lock.withLock { items.append(item) } }
        var values: [String] { lock.withLock { items } }
    }

    /// Каталог моделей, в котором веса «скачиваются» посреди теста.
    private final class SwitchableModels: SummaryModelStore {
        private var ready: Set<SummaryVariant>

        init(installed: Set<SummaryVariant>) {
            ready = installed
            super.init(root: FileManager.default.temporaryDirectory)
        }

        override func isInstalled(_ variant: SummaryVariant) -> Bool { ready.contains(variant) }

        func install(_ variant: SummaryVariant) {
            ready.insert(variant)
            refresh()
        }
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

/// Что экран «Заголовки» и строка настроек говорят о модели.
@MainActor
final class SummaryModelStoreTests: XCTestCase {
    private final class StubModels: SummaryModelStore {
        private let ready: Set<SummaryVariant>

        init(installed: Set<SummaryVariant>) {
            ready = installed
            super.init(root: FileManager.default.temporaryDirectory)
        }

        override func isInstalled(_ variant: SummaryVariant) -> Bool { ready.contains(variant) }
    }

    /// Одна кнопка «Скачать» — для модели, которая подходит телефону. Крупной
    /// нужно 3,1 ГБ свободных: на 8 ГБ это впритык, на 6 ГБ не бывает вовсе.
    func testRecommendedModelFollowsPhoneMemory() {
        XCTAssertEqual(SummaryModelStore.recommendedVariant(physicalMemory: 8_589_934_592), .heavy, "8 ГБ")
        XCTAssertEqual(SummaryModelStore.recommendedVariant(physicalMemory: 7_500_000_000), .heavy, "8 ГБ чуть ниже номинала")
        XCTAssertEqual(SummaryModelStore.recommendedVariant(physicalMemory: 12_884_901_888), .heavy, "12 ГБ")
        XCTAssertEqual(SummaryModelStore.recommendedVariant(physicalMemory: 6_442_450_944), .light, "6 ГБ")
        XCTAssertEqual(SummaryModelStore.recommendedVariant(physicalMemory: 4_294_967_296), .light, "4 ГБ")
    }

    /// Без модели заголовки всё равно есть — из первой фразы; «выключены» было неправдой.
    func testSettingsLineTellsWhatTitlesComeFrom() {
        XCTAssertEqual(StubModels(installed: []).statusLine, "первая фраза")
        XCTAssertFalse(StubModels(installed: []).isReady)
        XCTAssertEqual(StubModels(installed: [.light]).statusLine, "лёгкая модель")
        XCTAssertEqual(StubModels(installed: [.heavy, .light]).statusLine, "крупная модель")
        XCTAssertTrue(StubModels(installed: [.light]).isReady)
    }

    func testSizesAreWrittenTheRussianWay() {
        XCTAssertEqual(SummaryVariant.heavy.sizeLabel, "2,3 ГБ")
        XCTAssertEqual(SummaryVariant.light.sizeLabel, "1,1 ГБ")
    }
}
